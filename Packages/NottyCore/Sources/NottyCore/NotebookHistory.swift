import Foundation

struct NotebookHistory {
    typealias Format = NotebookRevisionFormat

    struct Link {
        let revisionID: UUID
        let digest: String
        let sequence: Int
    }

    /// A single contiguous authenticated metadata prefix, scoped to one exact HEAD.
    final class MetadataIndex {
        struct Entry {
            let link: Link
            let parentID: UUID?
            let parentDigest: String?
            let checkpointDigest: String?
        }

        var entries: [Entry] = []
        var visited = Set<UUID>()
        var offsets: [UUID: Int] = [:]
        var reachedGenesis = false
        var summaries: [UUID: NotebookRevisionSummary] = [:]
    }

    private struct SummaryReplay {
        var ids: Set<UUID>
        var title: String
        var pageCount: Int

        init(_ state: Format.State) {
            ids = Set(state.strokes.map(\.id))
            title = state.title
            pageCount = state.pageCount
        }

        mutating func apply(_ delta: Format.Delta) throws {
            try Format.validateDeltaShape(delta)
            let removed = delta.removedIDs ?? []
            guard removed.allSatisfy({ ids.contains($0) }) else {
                throw NotebookRepositoryError.corruptData("A history delta removes an unknown stroke.")
            }
            for id in removed { ids.remove(id) }
            for reference in delta.upserts ?? [] { ids.insert(reference.id) }
            guard ids.count <= NotebookRepository.maximumStrokeCount,
                  (delta.placements ?? []).allSatisfy({
                    ids.contains($0.id) && (0..<ids.count).contains($0.index)
                  }) else {
                throw NotebookRepositoryError.corruptData("A history delta has an invalid placement.")
            }
            if let replacement = delta.replacementOrder, Set(replacement) != ids {
                throw NotebookRepositoryError.corruptData("A history delta has an inconsistent replacement order.")
            }
            title = delta.titleChange ?? title
            pageCount = delta.pageCountChange ?? pageCount
        }
    }

    struct AuditResult {
        let report: NotebookHistoryAudit
        let summaries: [NotebookRevisionSummary]
        let links: [Link]
    }

    struct HeadSnapshot: Sendable, Equatable {
        let head: Format.Head
        let digest: String
    }

    let metrics: NotebookStorageMetricsRecorder?
    let directory: URL
    let notebookID: UUID
    let assetVerificationObserver: (@Sendable (String) -> Void)?
    private let assetDirectory: URL
    private let auditCancellation: NotebookHistoryAuditCancellation?
    private let auditProgress: (@Sendable (NotebookHistoryAuditProgress) -> Void)?

    init(
        directory: URL, notebookID: UUID,
        assetVerificationObserver: (@Sendable (String) -> Void)?,
        assetDirectory: URL? = nil,
        metrics: NotebookStorageMetricsRecorder? = nil,
        auditCancellation: NotebookHistoryAuditCancellation? = nil,
        auditProgress: (@Sendable (NotebookHistoryAuditProgress) -> Void)? = nil
    ) {
        self.metrics = metrics
        self.auditCancellation = auditCancellation
        self.auditProgress = auditProgress
        self.directory = directory
        self.notebookID = notebookID
        self.assetVerificationObserver = assetVerificationObserver
        self.assetDirectory = assetDirectory ?? directory.appendingPathComponent("assets", isDirectory: true)
    }

    func readHead() throws -> Format.Head? {
        try readHeadSnapshot()?.head
    }

    func readHeadSnapshot() throws -> HeadSnapshot? {
        let url = directory.appendingPathComponent("HEAD.json")
        guard try NotebookFileSystem.kind(url) != nil else { return nil }
        let data = try readMetadata(url)
        let head: Format.Head = try Format.decode(data)
        guard head.schemaVersion == 1 || head.schemaVersion == 2 else {
            throw NotebookRepositoryError.unsupportedVersion(head.schemaVersion)
        }
        guard head.notebookID == notebookID, Format.isDigest(head.revisionDigest),
              (head.schemaVersion == 2) == (head.generationID != nil),
              head.migrationReceiptDigest.map(Format.isDigest) ?? true,
              head.schemaVersion == 2 || head.migrationReceiptDigest == nil else {
            throw NotebookRepositoryError.corruptData("The notebook HEAD has invalid metadata.")
        }
        return HeadSnapshot(head: head, digest: Format.digest(data, metrics: metrics))
    }

    func generationDirectory(_ head: Format.Head) throws -> URL {
        guard head.schemaVersion == 2, let generation = head.generationID else {
            throw NotebookRepositoryError.corruptData("The history generation is missing.")
        }
        let history = directory.appendingPathComponent("history", isDirectory: true)
        try requireDirectory(history)
        let result = history.appendingPathComponent(generation.uuidString.lowercased(), isDirectory: true)
        try requireDirectory(result)
        try requireDirectory(result.appendingPathComponent("events", isDirectory: true))
        try requireDirectory(result.appendingPathComponent("checkpoints", isDirectory: true))
        return result
    }

    func selectedLinks(_ head: Format.Head) throws -> [Link] {
        var links: [Link] = []
        var visited = Set<UUID>()
        var id = head.revisionID
        var digest: String? = head.revisionDigest
        var expectedSequence: Int?
        let generation = head.schemaVersion == 2 ? try generationDirectory(head) : nil
        while true {
            try auditCancellation?.check()
            guard visited.insert(id).inserted else {
                throw NotebookRepositoryError.corruptData("The committed history contains a cycle.")
            }
            let sequence: Int
            let parent: UUID?
            let parentDigest: String?
            let actualDigest: String
            if let generation {
                guard let digest else {
                    throw NotebookRepositoryError.corruptData("An authenticated parent digest is missing.")
                }
                let (event, _) = try readEvent(id: id, digest: digest, generation: generation)
                sequence = event.sequence
                parent = event.parentRevisionID
                parentDigest = event.parentDigest
                actualDigest = digest
            } else {
                let revisions = directory.appendingPathComponent("revisions", isDirectory: true)
                try requireDirectory(revisions)
                let data = try readMetadata(revisions.appendingPathComponent("\(id.uuidString.lowercased()).json"))
                actualDigest = Format.digest(data, metrics: metrics)
                if let digest, digest != actualDigest {
                    throw NotebookRepositoryError.corruptData("The selected legacy revision failed integrity validation.")
                }
                let revision: Format.LegacyRevision = try Format.decode(data)
                try validateLegacy(revision, id: id)
                sequence = revision.sequence
                parent = revision.parentRevisionID
                parentDigest = nil
            }
            if let expectedSequence, sequence != expectedSequence {
                throw NotebookRepositoryError.corruptData("The committed history has a sequence gap.")
            }
            links.append(Link(revisionID: id, digest: actualDigest, sequence: sequence))
            guard let parent else { break }
            expectedSequence = sequence - 1
            id = parent
            digest = parentDigest
        }
        return links.reversed()
    }

    func readLegacy(_ link: Link) throws -> Format.LegacyRevision {
        let revisions = directory.appendingPathComponent("revisions", isDirectory: true)
        try requireDirectory(revisions)
        let data = try readMetadata(revisions.appendingPathComponent("\(link.revisionID.uuidString.lowercased()).json"))
        guard Format.digest(data, metrics: metrics) == link.digest else {
            throw NotebookRepositoryError.corruptData("Legacy history changed during validation.")
        }
        let revision: Format.LegacyRevision = try Format.decode(data)
        try validateLegacy(revision, id: link.revisionID)
        return revision
    }

    func selectedSequence(_ head: Format.Head) throws -> Int {
        if head.schemaVersion == 1 {
            return try readLegacy(Link(
                revisionID: head.revisionID, digest: head.revisionDigest, sequence: 0
            )).sequence
        }
        return try readEvent(
            id: head.revisionID, digest: head.revisionDigest,
            generation: generationDirectory(head)
        ).0.sequence
    }

    func current(_ head: Format.Head) throws -> Format.Materialized {
        if head.schemaVersion == 1 {
            let link = Link(revisionID: head.revisionID, digest: head.revisionDigest, sequence: 0)
            let revision = try readLegacy(link)
            return Format.Materialized(
                revisionID: revision.revisionID, sequence: revision.sequence,
                editStamp: revision.editStamp, savedAt: revision.savedAt,
                state: revision.state, checkpointCredit: 0
            )
        }
        let generation = try generationDirectory(head)
        var id = head.revisionID
        var digest = head.revisionDigest
        var visited = Set<UUID>()
        var tail: [(Format.Event, Int)] = []
        var newest: Format.Event?
        var expectedSequence: Int?
        while true {
            guard visited.insert(id).inserted else {
                throw NotebookRepositoryError.corruptData("The active history contains a cycle.")
            }
            let (event, bytes) = try readEvent(id: id, digest: digest, generation: generation)
            if newest == nil { newest = event }
            if let expectedSequence, event.sequence != expectedSequence {
                throw NotebookRepositoryError.corruptData("The active history has a sequence gap.")
            }
            if let checkpoint = event.checkpointDigest {
                let replay = Format.Replay(try readCheckpoint(checkpoint, event: event, generation: generation))
                var credit = 0
                for (later, bytes) in tail.reversed() {
                    try replay.apply(later.delta)
                    credit = try addingCredit(credit, bytes)
                }
                guard let newest else {
                    throw NotebookRepositoryError.corruptData("The selected event is missing.")
                }
                return Format.Materialized(
                    revisionID: newest.revisionID, sequence: newest.sequence,
                    editStamp: newest.editStamp, savedAt: newest.savedAt,
                    state: replay.state, checkpointCredit: credit, recoverySource: newest.recoverySource
                )
            }
            tail.append((event, bytes))
            guard let parent = event.parentRevisionID, let parentDigest = event.parentDigest else {
                throw NotebookRepositoryError.corruptData("The committed history has no initial checkpoint.")
            }
            expectedSequence = event.sequence - 1
            id = parent
            digest = parentDigest
        }
    }

    func audit(
        _ head: Format.Head,
        beforeRevisionID: UUID? = nil,
        summaryLimit: Int = 0,
        links collectedLinks: [Link]? = nil
    ) throws -> AuditResult {
        let links = try collectedLinks ?? selectedLinks(head)
        let upperBound: Int
        if let beforeRevisionID {
            guard let index = links.firstIndex(where: { $0.revisionID == beforeRevisionID }) else {
                throw NotebookRepositoryError.invalidContent("The history cursor is not committed.")
            }
            upperBound = index
        } else {
            upperBound = links.count
        }
        let lowerBound = max(0, upperBound - summaryLimit)
        try validateAssetsDirectory(.empty)
        var summaries: [NotebookRevisionSummary] = []
        var replay = Format.Replay()
        var sizes: [String: Int] = [:]
        var totalBytes = 0
        var credit = 0
        let generation = head.schemaVersion == 2 ? try generationDirectory(head) : nil
        for (index, link) in links.enumerated() {
            try auditCancellation?.check()
            let stamp: NotebookEditStamp?
            let savedAt: Date
            let recoverySource: NotebookRecoveryProvenance?
            if let generation {
                let (event, bytes) = try readEvent(id: link.revisionID, digest: link.digest, generation: generation)
                try verifyDeltaAssets(event.delta, replay: replay, sizes: &sizes, totalBytes: &totalBytes)
                try replay.apply(event.delta)
                credit = try addingCredit(credit, bytes)
                if let checkpoint = event.checkpointDigest {
                    let checkpointSnapshot = try readCheckpointSnapshot(checkpoint, event: event, generation: generation)
                    guard checkpointSnapshot.state == replay.state else {
                        throw NotebookRepositoryError.corruptData("A history checkpoint does not match its event replay.")
                    }
                    let checkpointBytes = checkpointSnapshot.encodedBytes
                    guard event.sequence == 1 || credit >= checkpointBytes else {
                        throw NotebookRepositoryError.corruptData("A checkpoint exceeds its accumulated byte credit.")
                    }
                    credit = 0
                } else if event.sequence == 1 {
                    throw NotebookRepositoryError.corruptData("The initial history checkpoint is missing.")
                }
                stamp = event.editStamp
                savedAt = event.savedAt
                recoverySource = event.recoverySource
            } else {
                let revision = try readLegacy(link)
                replay = Format.Replay(revision.state)
                try verifyStateAssets(revision.state, sizes: &sizes)
                stamp = revision.editStamp
                savedAt = revision.savedAt
                recoverySource = nil
            }
            if summaryLimit > 0, (lowerBound..<upperBound).contains(index) {
                summaries.append(NotebookRevisionSummary(
                    notebookID: notebookID, revisionID: link.revisionID, sequence: link.sequence,
                    title: replay.title, pageCount: replay.pageCount, strokeCount: replay.count,
                    editStamp: stamp, savedAt: savedAt, recoverySource: recoverySource
                ))
            }
        }
        return AuditResult(
            report: NotebookHistoryAudit(
                notebookID: notebookID, headRevisionID: head.revisionID,
                revisionCount: links.count, verifiedAssetCount: sizes.count
            ),
            summaries: summaries.reversed(), links: links
        )
    }

    private func extendIndex(
        _ index: MetadataIndex, through offset: Int, head: Format.Head
    ) throws {
        let generation = head.schemaVersion == 2 ? try generationDirectory(head) : nil
        while index.entries.count <= offset && !index.reachedGenesis {
            try auditCancellation?.check()
            let previous = index.entries.last
            let id = previous?.parentID ?? head.revisionID
            let digest = previous?.parentDigest ?? (previous == nil ? head.revisionDigest : nil)
            guard index.visited.insert(id).inserted else {
                throw NotebookRepositoryError.corruptData("The committed history contains a cycle.")
            }
            let entry: MetadataIndex.Entry
            if let generation {
                guard let digest else {
                    throw NotebookRepositoryError.corruptData("An authenticated parent digest is missing.")
                }
                let event = try readEvent(id: id, digest: digest, generation: generation).0
                entry = MetadataIndex.Entry(
                    link: Link(revisionID: id, digest: digest, sequence: event.sequence),
                    parentID: event.parentRevisionID, parentDigest: event.parentDigest,
                    checkpointDigest: event.checkpointDigest
                )
            } else {
                let revisions = directory.appendingPathComponent("revisions", isDirectory: true)
                try requireDirectory(revisions)
                let data = try readMetadata(revisions.appendingPathComponent("\(id.uuidString.lowercased()).json"))
                let actual = Format.digest(data, metrics: metrics)
                guard digest == nil || digest == actual else {
                    throw NotebookRepositoryError.corruptData("The selected legacy revision failed integrity validation.")
                }
                let revision: Format.LegacyRevision = try Format.decode(data)
                try validateLegacy(revision, id: id)
                entry = MetadataIndex.Entry(
                    link: Link(revisionID: id, digest: actual, sequence: revision.sequence),
                    parentID: revision.parentRevisionID, parentDigest: nil, checkpointDigest: nil
                )
            }
            if let previous, entry.link.sequence != previous.link.sequence - 1 {
                throw NotebookRepositoryError.corruptData("The committed history has a sequence gap.")
            }
            index.offsets[id] = index.entries.count
            index.entries.append(entry)
            index.reachedGenesis = entry.parentID == nil
        }
    }

    private func selectedOffset(
        _ revisionID: UUID, head: Format.Head, index: MetadataIndex
    ) throws -> Int {
        while true {
            if let offset = index.offsets[revisionID] {
                return offset
            }
            guard !index.reachedGenesis else {
                throw NotebookRepositoryError.invalidContent("The requested revision is not committed.")
            }
            try extendIndex(index, through: index.entries.count, head: head)
        }
    }

    func summaries(
        head: Format.Head, beforeRevisionID: UUID?, limit: Int, index: MetadataIndex
    ) throws -> [NotebookRevisionSummary] {
        let start = try beforeRevisionID.map { try selectedOffset($0, head: head, index: index) + 1 } ?? 0
        try extendIndex(index, through: start + limit - 1, head: head)
        let end = min(start + limit, index.entries.count)
        guard start < end else { return [] }
        let requested = start..<end
        if requested.allSatisfy({ index.summaries[index.entries[$0].link.revisionID] != nil }) {
            return requested.compactMap { index.summaries[index.entries[$0].link.revisionID] }
        }
        if head.schemaVersion == 1 {
            for offset in requested {
                let revision = try readLegacy(index.entries[offset].link)
                index.summaries[revision.revisionID] = summary(
                    index.entries[offset].link, title: revision.title, pageCount: revision.pageCount,
                    count: revision.strokes.count, stamp: revision.editStamp, savedAt: revision.savedAt
                )
            }
        } else {
            let generation = try generationDirectory(head)
            var baseline = end - 1
            while index.entries[baseline].checkpointDigest == nil {
                guard !index.reachedGenesis || baseline + 1 < index.entries.count else {
                    throw NotebookRepositoryError.corruptData("The committed history has no initial checkpoint.")
                }
                baseline += 1
                try extendIndex(index, through: baseline, head: head)
            }
            let base = index.entries[baseline]
            let event = try readEvent(
                id: base.link.revisionID, digest: base.link.digest, generation: generation
            ).0
            guard let digest = event.checkpointDigest else {
                throw NotebookRepositoryError.corruptData("The history checkpoint is missing.")
            }
            var replay = SummaryReplay(try readCheckpoint(digest, event: event, generation: generation))
            index.summaries[event.revisionID] = summary(
                base.link, title: replay.title, pageCount: replay.pageCount, count: replay.ids.count,
                stamp: event.editStamp, savedAt: event.savedAt, recoverySource: event.recoverySource
            )
            if baseline > start {
                for offset in stride(from: baseline - 1, through: start, by: -1) {
                    let entry = index.entries[offset]
                    let event = try readEvent(
                        id: entry.link.revisionID, digest: entry.link.digest, generation: generation
                    ).0
                    try replay.apply(event.delta)
                    index.summaries[event.revisionID] = summary(
                        entry.link, title: replay.title, pageCount: replay.pageCount, count: replay.ids.count,
                        stamp: event.editStamp, savedAt: event.savedAt, recoverySource: event.recoverySource
                    )
                }
            }
        }
        return requested.compactMap { index.summaries[index.entries[$0].link.revisionID] }
    }

    private func summary(
        _ link: Link, title: String, pageCount: Int, count: Int,
        stamp: NotebookEditStamp?, savedAt: Date, recoverySource: NotebookRecoveryProvenance? = nil
    ) -> NotebookRevisionSummary {
        NotebookRevisionSummary(
            notebookID: notebookID, revisionID: link.revisionID, sequence: link.sequence,
            title: title, pageCount: pageCount, strokeCount: count, editStamp: stamp, savedAt: savedAt,
            recoverySource: recoverySource
        )
    }

    func materializeRevision(
        _ id: UUID, head: Format.Head, index: MetadataIndex
    ) throws -> Format.Materialized {
        let offset = try selectedOffset(id, head: head, index: index)
        let link = index.entries[offset].link
        let selected = Format.Head(
            schemaVersion: head.schemaVersion, notebookID: notebookID,
            revisionID: link.revisionID, revisionDigest: link.digest,
            generationID: head.generationID, migrationReceiptDigest: head.migrationReceiptDigest
        )
        return try current(selected)
    }

    func readAssets(_ state: Format.State) throws -> [NotebookStroke] {
        try validateAssetsDirectory(state)
        var total = 0
        var result: [NotebookStroke] = []
        var dataByDigest: [String: Data] = [:]
        for reference in state.strokes {
            let data: Data
            if let cached = dataByDigest[reference.digest] { data = cached }
            else {
                data = try readAsset(reference)
                dataByDigest[reference.digest] = data
            }
            total += data.count
            guard total <= NotebookRepository.maximumNotebookBytes else {
                throw NotebookRepositoryError.corruptData("The notebook exceeds 64 MiB.")
            }
            result.append(NotebookStroke(id: reference.id, data: data, validatedDigest: reference.digest))
        }
        return result
    }

    func verifyAssets(
        _ state: Format.State, candidates: [String: Data],
        candidateAsset: ((Format.Reference, Data) throws -> Data)? = nil
    ) throws -> Set<String> {
        Set(try verifiedAssetSizes(state, candidates: candidates, candidateAsset: candidateAsset).keys)
    }

    func verifiedAssetSizes(
        _ state: Format.State, candidates: [String: Data],
        candidateAsset: ((Format.Reference, Data) throws -> Data)? = nil
    ) throws -> [String: Int] {
        try validateAssetsDirectory(state)
        var sizes: [String: Int] = [:]
        var total = 0
        for reference in state.strokes {
            if sizes[reference.digest] == nil {
                let data: Data
                if let candidate = candidates[reference.digest], let candidateAsset {
                    data = try candidateAsset(reference, candidate)
                } else {
                    data = try readAsset(reference)
                    if let candidate = candidates[reference.digest], candidate != data {
                        throw NotebookRepositoryError.corruptData("Equal asset digests have different bytes.")
                    }
                }
                sizes[reference.digest] = data.count
            }
            total += sizes[reference.digest] ?? 0
            guard total <= NotebookRepository.maximumNotebookBytes else {
                throw NotebookRepositoryError.sizeLimitExceeded("The notebook exceeds 64 MiB.")
            }
        }
        return sizes
    }

    func readAsset(_ reference: Format.Reference) throws -> Data {
        try auditCancellation?.check()
        auditProgress?(.willReadAsset(reference.digest))
        try auditCancellation?.check()
        let assets = assetDirectory
        try requireDirectory(assets)
        let data = try readMetadataAsset(assets.appendingPathComponent("\(reference.digest).stroke"))
        guard (metrics?.assetDigest(data) ?? Format.digest(data)) == reference.digest else {
            throw NotebookRepositoryError.corruptData("A committed stroke asset failed integrity validation.")
        }
        assetVerificationObserver?(reference.digest)
        return data
    }

    func readEvent(
        id: UUID, digest: String, generation: URL
    ) throws -> (Format.Event, Int) {
        try auditCancellation?.check()
        auditProgress?(.willReadEvent(id))
        try auditCancellation?.check()
        let data = try readMetadata(
            generation.appendingPathComponent("events/\(id.uuidString.lowercased()).json")
        )
        guard Format.digest(data, metrics: metrics) == digest else {
            throw NotebookRepositoryError.corruptData("A committed history event failed integrity validation.")
        }
        let event: Format.Event = try Format.decode(data)
        guard event.schemaVersion == 2 else {
            throw NotebookRepositoryError.unsupportedVersion(event.schemaVersion)
        }
        try Format.validateIdentity(
            notebookID: event.notebookID, revisionID: event.revisionID,
            sequence: event.sequence, parentID: event.parentRevisionID,
            expectedNotebook: notebookID, expectedRevision: id, stamp: event.editStamp, savedAt: event.savedAt
        )
        guard (event.parentRevisionID == nil) == (event.parentDigest == nil),
              event.parentDigest.map(Format.isDigest) ?? true,
              event.checkpointDigest.map(Format.isDigest) ?? true else {
            throw NotebookRepositoryError.corruptData("A history event has invalid digest links.")
        }
        do { try Format.validateRecoverySource(event.recoverySource, notebookID: notebookID) }
        catch { throw NotebookRepositoryError.corruptData("A committed recovery source is invalid.") }
        try Format.validateDeltaShape(event.delta)
        return (event, data.count)
    }

    func readCheckpoint(
        _ digest: String, event: Format.Event, generation: URL
    ) throws -> Format.State {
        try readCheckpointSnapshot(digest, event: event, generation: generation).state
    }

    func readCheckpointSnapshot(
        _ digest: String, event: Format.Event, generation: URL
    ) throws -> (state: Format.State, encodedBytes: Int) {
        try auditCancellation?.check()
        auditProgress?(.willReadCheckpoint(digest))
        try auditCancellation?.check()
        let data = try readMetadata(generation.appendingPathComponent("checkpoints/\(digest).json"))
        guard Format.digest(data, metrics: metrics) == digest else {
            throw NotebookRepositoryError.corruptData("A history checkpoint failed integrity validation.")
        }
        let checkpoint: Format.Checkpoint = try Format.decode(data)
        guard checkpoint.schemaVersion == 2 else {
            throw NotebookRepositoryError.unsupportedVersion(checkpoint.schemaVersion)
        }
        guard checkpoint.notebookID == notebookID, checkpoint.revisionID == event.revisionID,
              checkpoint.sequence == event.sequence else {
            throw NotebookRepositoryError.corruptData("A history checkpoint has inconsistent identities.")
        }
        try Format.validateState(checkpoint.state)
        return (checkpoint.state, data.count)
    }

    func readMetadata(_ url: URL) throws -> Data {
        try auditCancellation?.check()
        guard try NotebookFileSystem.kind(url) != nil else {
            throw NotebookRepositoryError.corruptData("A committed history file is missing.")
        }
        do {
            metrics?.record(\.metadataReadCalls)
            let data = try NotebookFileSystem.read(url, maximumBytes: NotebookRepository.maximumMetadataBytes)
            metrics?.record(\.metadataReadBytes, data.count)
            try auditCancellation?.check()
            return data
        } catch let error as NotebookRepositoryError {
            if case .sizeLimitExceeded = error {
                throw NotebookRepositoryError.corruptData("Committed history metadata exceeds supported bounds.")
            }
            throw error
        }
    }

    func requireDirectory(_ url: URL) throws {
        try auditCancellation?.check()
        guard try NotebookFileSystem.existingDirectory(url) else {
            throw NotebookRepositoryError.corruptData("A committed storage directory is missing.")
        }
    }

    private func readMetadataAsset(_ url: URL) throws -> Data {
        guard try NotebookFileSystem.kind(url) != nil else {
            throw NotebookRepositoryError.corruptData("A committed stroke asset is missing.")
        }
        do {
            metrics?.record(\.assetReadCalls)
            let data = try NotebookFileSystem.read(url, maximumBytes: NotebookRepository.maximumAssetBytes)
            metrics?.record(\.assetReadBytes, data.count)
            try auditCancellation?.check()
            return data
        } catch let error as NotebookRepositoryError {
            if case .sizeLimitExceeded = error {
                throw NotebookRepositoryError.corruptData("A committed stroke asset exceeds supported bounds.")
            }
            throw error
        }
    }

    private func validateLegacy(_ revision: Format.LegacyRevision, id: UUID) throws {
        guard revision.schemaVersion == 1 else {
            throw NotebookRepositoryError.unsupportedVersion(revision.schemaVersion)
        }
        try Format.validateIdentity(
            notebookID: revision.notebookID, revisionID: revision.revisionID,
            sequence: revision.sequence, parentID: revision.parentRevisionID,
            expectedNotebook: notebookID, expectedRevision: id,
            stamp: revision.editStamp, savedAt: revision.savedAt
        )
        try Format.validateState(revision.state)
    }

    private func validateAssetsDirectory(_ state: Format.State) throws {
        let assets = assetDirectory
        guard try NotebookFileSystem.existingDirectory(assets) else {
            if state.strokes.isEmpty { return }
            throw NotebookRepositoryError.corruptData("The committed asset directory is missing.")
        }
    }

    private func verifyDeltaAssets(
        _ delta: Format.Delta, replay: Format.Replay,
        sizes: inout [String: Int], totalBytes: inout Int
    ) throws {
        let removed = delta.removedIDs ?? []
        let updates = delta.upserts ?? []
        guard Set(removed).count == removed.count,
              Set(updates.map(\.id)).count == updates.count,
              Set(removed).isDisjoint(with: updates.map(\.id)) else {
            throw NotebookRepositoryError.corruptData("A history delta contains contradictory asset changes.")
        }
        for id in removed {
            guard let reference = replay.reference(id), let bytes = sizes[reference.digest] else {
                throw NotebookRepositoryError.corruptData("A history delta removes an unverified stroke.")
            }
            totalBytes -= bytes
        }
        for reference in updates {
            guard Format.isDigest(reference.digest) else {
                throw NotebookRepositoryError.corruptData("A history delta has an invalid asset digest.")
            }
            if let previous = replay.reference(reference.id) {
                guard let bytes = sizes[previous.digest] else {
                    throw NotebookRepositoryError.corruptData("A changed historical stroke was not verified.")
                }
                totalBytes -= bytes
            }
            if sizes[reference.digest] == nil {
                sizes[reference.digest] = try readAsset(reference).count
            }
            totalBytes += sizes[reference.digest] ?? 0
        }
        guard (0...NotebookRepository.maximumNotebookBytes).contains(totalBytes) else {
            throw NotebookRepositoryError.corruptData("A historical state exceeds 64 MiB.")
        }
    }

    private func verifyStateAssets(_ state: Format.State, sizes: inout [String: Int]) throws {
        try validateAssetsDirectory(state)
        var total = 0
        for reference in state.strokes {
            if sizes[reference.digest] == nil { sizes[reference.digest] = try readAsset(reference).count }
            total += sizes[reference.digest] ?? 0
            guard total <= NotebookRepository.maximumNotebookBytes else {
                throw NotebookRepositoryError.corruptData("A historical state exceeds 64 MiB.")
            }
        }
    }

    private func addingCredit(_ credit: Int, _ bytes: Int) throws -> Int {
        let (sum, overflow) = credit.addingReportingOverflow(bytes)
        guard !overflow else {
            throw NotebookRepositoryError.sizeLimitExceeded("History byte accounting exceeds supported bounds.")
        }
        return sum
    }
}
