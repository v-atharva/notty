import Foundation

struct NotebookHistory {
    typealias Format = NotebookRevisionFormat

    struct Link {
        let revisionID: UUID
        let digest: String
        let sequence: Int
    }

    struct AuditResult {
        let report: NotebookHistoryAudit
        let summaries: [NotebookRevisionSummary]
    }

    let directory: URL
    let notebookID: UUID
    let assetVerificationObserver: (@Sendable (String) -> Void)?
    private let assetDirectory: URL

    init(
        directory: URL, notebookID: UUID,
        assetVerificationObserver: (@Sendable (String) -> Void)?,
        assetDirectory: URL? = nil
    ) {
        self.directory = directory
        self.notebookID = notebookID
        self.assetVerificationObserver = assetVerificationObserver
        self.assetDirectory = assetDirectory ?? directory.appendingPathComponent("assets", isDirectory: true)
    }

    func readHead() throws -> Format.Head? {
        let url = directory.appendingPathComponent("HEAD.json")
        guard try NotebookFileSystem.kind(url) != nil else { return nil }
        let head: Format.Head = try Format.decode(readMetadata(url))
        guard head.schemaVersion == 1 || head.schemaVersion == 2 else {
            throw NotebookRepositoryError.unsupportedVersion(head.schemaVersion)
        }
        guard head.notebookID == notebookID, Format.isDigest(head.revisionDigest),
              (head.schemaVersion == 2) == (head.generationID != nil),
              head.migrationReceiptDigest.map(Format.isDigest) ?? true,
              head.schemaVersion == 2 || head.migrationReceiptDigest == nil else {
            throw NotebookRepositoryError.corruptData("The notebook HEAD has invalid metadata.")
        }
        return head
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
                actualDigest = Format.digest(data)
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
        guard Format.digest(data) == link.digest else {
            throw NotebookRepositoryError.corruptData("Legacy history changed during validation.")
        }
        let revision: Format.LegacyRevision = try Format.decode(data)
        try validateLegacy(revision, id: link.revisionID)
        return revision
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
                    state: replay.state, checkpointCredit: credit
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
        summaryLimit: Int = 0
    ) throws -> AuditResult {
        let links = try selectedLinks(head)
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
            let stamp: NotebookEditStamp?
            let savedAt: Date
            if let generation {
                let (event, bytes) = try readEvent(id: link.revisionID, digest: link.digest, generation: generation)
                try verifyDeltaAssets(event.delta, replay: replay, sizes: &sizes, totalBytes: &totalBytes)
                try replay.apply(event.delta)
                credit = try addingCredit(credit, bytes)
                if let checkpoint = event.checkpointDigest {
                    let checkpointState = try readCheckpoint(checkpoint, event: event, generation: generation)
                    guard checkpointState == replay.state else {
                        throw NotebookRepositoryError.corruptData("A history checkpoint does not match its event replay.")
                    }
                    let checkpointBytes = try readMetadata(
                        generation.appendingPathComponent("checkpoints/\(checkpoint).json")
                    ).count
                    guard event.sequence == 1 || credit >= checkpointBytes else {
                        throw NotebookRepositoryError.corruptData("A checkpoint exceeds its accumulated byte credit.")
                    }
                    credit = 0
                } else if event.sequence == 1 {
                    throw NotebookRepositoryError.corruptData("The initial history checkpoint is missing.")
                }
                stamp = event.editStamp
                savedAt = event.savedAt
            } else {
                let revision = try readLegacy(link)
                replay = Format.Replay(revision.state)
                try verifyStateAssets(revision.state, sizes: &sizes)
                stamp = revision.editStamp
                savedAt = revision.savedAt
            }
            if summaryLimit > 0, (lowerBound..<upperBound).contains(index) {
                summaries.append(NotebookRevisionSummary(
                    notebookID: notebookID, revisionID: link.revisionID, sequence: link.sequence,
                    title: replay.title, pageCount: replay.pageCount, strokeCount: replay.count,
                    editStamp: stamp, savedAt: savedAt
                ))
            }
        }
        return AuditResult(
            report: NotebookHistoryAudit(
                notebookID: notebookID, headRevisionID: head.revisionID,
                revisionCount: links.count, verifiedAssetCount: sizes.count
            ),
            summaries: summaries.reversed()
        )
    }

    func materializeRevision(_ id: UUID, head: Format.Head) throws -> Format.Materialized {
        let links = try selectedLinks(head)
        guard let link = links.first(where: { $0.revisionID == id }) else {
            throw NotebookRepositoryError.invalidContent("The requested revision is not committed.")
        }
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
        for reference in state.strokes {
            let data = try readAsset(reference)
            total += data.count
            guard total <= NotebookRepository.maximumNotebookBytes else {
                throw NotebookRepositoryError.sizeLimitExceeded("The notebook exceeds 64 MiB.")
            }
            result.append(NotebookStroke(id: reference.id, data: data))
        }
        return result
    }

    func verifyAssets(_ state: Format.State, candidates: [String: Data]) throws -> Set<String> {
        try validateAssetsDirectory(state)
        var sizes: [String: Int] = [:]
        var total = 0
        for reference in state.strokes {
            if sizes[reference.digest] == nil {
                let data = try readAsset(reference)
                if let candidate = candidates[reference.digest], candidate != data {
                    throw NotebookRepositoryError.corruptData("Equal asset digests have different bytes.")
                }
                sizes[reference.digest] = data.count
            }
            total += sizes[reference.digest] ?? 0
            guard total <= NotebookRepository.maximumNotebookBytes else {
                throw NotebookRepositoryError.sizeLimitExceeded("The notebook exceeds 64 MiB.")
            }
        }
        return Set(sizes.keys)
    }

    func readAsset(_ reference: Format.Reference) throws -> Data {
        let assets = assetDirectory
        try requireDirectory(assets)
        let data = try readMetadataAsset(assets.appendingPathComponent("\(reference.digest).stroke"))
        guard Format.digest(data) == reference.digest else {
            throw NotebookRepositoryError.corruptData("A committed stroke asset failed integrity validation.")
        }
        assetVerificationObserver?(reference.digest)
        return data
    }

    func readEvent(
        id: UUID, digest: String, generation: URL
    ) throws -> (Format.Event, Int) {
        let data = try readMetadata(
            generation.appendingPathComponent("events/\(id.uuidString.lowercased()).json")
        )
        guard Format.digest(data) == digest else {
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
        return (event, data.count)
    }

    func readCheckpoint(
        _ digest: String, event: Format.Event, generation: URL
    ) throws -> Format.State {
        let data = try readMetadata(generation.appendingPathComponent("checkpoints/\(digest).json"))
        guard Format.digest(data) == digest else {
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
        return checkpoint.state
    }

    func readMetadata(_ url: URL) throws -> Data {
        guard try NotebookFileSystem.kind(url) != nil else {
            throw NotebookRepositoryError.corruptData("A committed history file is missing.")
        }
        do {
            return try NotebookFileSystem.read(url, maximumBytes: NotebookRepository.maximumMetadataBytes)
        } catch let error as NotebookRepositoryError {
            if case .sizeLimitExceeded = error {
                throw NotebookRepositoryError.corruptData("Committed history metadata exceeds supported bounds.")
            }
            throw error
        }
    }

    func requireDirectory(_ url: URL) throws {
        guard try NotebookFileSystem.existingDirectory(url) else {
            throw NotebookRepositoryError.corruptData("A committed storage directory is missing.")
        }
    }

    private func readMetadataAsset(_ url: URL) throws -> Data {
        guard try NotebookFileSystem.kind(url) != nil else {
            throw NotebookRepositoryError.corruptData("A committed stroke asset is missing.")
        }
        do {
            return try NotebookFileSystem.read(url, maximumBytes: NotebookRepository.maximumAssetBytes)
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
