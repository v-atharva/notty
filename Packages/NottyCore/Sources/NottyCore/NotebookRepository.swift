import Foundation

/// Stores immutable stroke assets and authenticated edit history beneath an atomic HEAD.
///
/// File synchronization and atomic publication protect the process-crash boundary.
/// Directory durability during device power loss is not guaranteed by this contract.
public actor NotebookRepository {
    private typealias Format = NotebookRevisionFormat
    // These bounds protect the prototype; they do not define final notebook capacity.
    static let maximumStrokeCount = 10_000
    static let maximumAssetBytes = 10 * 1_024 * 1_024
    static let maximumMetadataBytes = 2 * 1_024 * 1_024
    static let maximumNotebookBytes = 64 * 1_024 * 1_024
    static let maximumTitleBytes = 4_096

    private struct ValidatedGeneration {
        let snapshot: NotebookHistory.HeadSnapshot
        let current: Format.Materialized
        let verifiedSizes: [String: Int]
        let checkpointSize: Format.CheckpointSize
    }

    private struct PreparedContent {
        let edit: NotebookSaveEdit
        let references: [Format.Reference]
        let dataByDigest: [String: Data]
    }

    private let metrics = NotebookStorageMetricsRecorder()
    private var validatedGenerations: [UUID: ValidatedGeneration] = [:]
    private let rootURL: URL
    private let migrationFaultInjector: (@Sendable (NotebookMigrationStage) throws -> Void)?
    private let faultInjector: (@Sendable (NotebookWriteStage) throws -> Void)?
    private let assetVerificationObserver: (@Sendable (String) -> Void)?
    private let maintenanceObserver: NotebookFileSystem.MaintenanceObserver
    private let maintenanceDiagnostics: NotebookFileSystem.MaintenanceDiagnostics
    private let maintenanceFaultInjector: (@Sendable () throws -> Void)?
    private var maintainedNotebookIDs = Set<UUID>()
    private var privateMaintenanceRequired = false

    public init(rootURL: URL) throws {
        let diagnostics = NotebookFileSystem.MaintenanceDiagnostics()
        let observer = Self.makeMaintenanceObserver(diagnostics: diagnostics)
        self.rootURL = try Self.prepareRoot(rootURL, observer: observer)
        self.maintenanceDiagnostics = diagnostics
        self.faultInjector = nil
        self.assetVerificationObserver = nil
        self.maintenanceObserver = observer
        self.maintenanceFaultInjector = nil
        self.migrationFaultInjector = nil
    }

    /// Creates a repository with deterministic publication faults for recovery tests.
    public init(
        rootURL: URL,
        faultInjector: @escaping @Sendable (NotebookWriteStage) throws -> Void
    ) throws {
        let diagnostics = NotebookFileSystem.MaintenanceDiagnostics()
        let observer = Self.makeMaintenanceObserver(diagnostics: diagnostics)
        self.rootURL = try Self.prepareRoot(rootURL, observer: observer)
        self.maintenanceDiagnostics = diagnostics
        self.faultInjector = faultInjector
        self.assetVerificationObserver = nil
        self.maintenanceObserver = observer
        self.maintenanceFaultInjector = nil
        self.migrationFaultInjector = nil
    }

    init(
        rootURL: URL,
        assetVerificationObserver: @escaping @Sendable (String) -> Void
    ) throws {
        let diagnostics = NotebookFileSystem.MaintenanceDiagnostics()
        let observer = Self.makeMaintenanceObserver(diagnostics: diagnostics)
        self.rootURL = try Self.prepareRoot(rootURL, observer: observer)
        self.maintenanceDiagnostics = diagnostics
        self.faultInjector = nil
        self.assetVerificationObserver = assetVerificationObserver
        self.maintenanceObserver = observer
        self.maintenanceFaultInjector = nil
        self.migrationFaultInjector = nil
    }

    init(
        rootURL: URL,
        faultInjector: (@Sendable (NotebookWriteStage) throws -> Void)? = nil,
        maintenanceObserver: @escaping NotebookFileSystem.MaintenanceObserver,
        maintenanceFaultInjector: (@Sendable () throws -> Void)? = nil
    ) throws {
        let diagnostics = NotebookFileSystem.MaintenanceDiagnostics()
        let observer = Self.makeMaintenanceObserver(
            diagnostics: diagnostics, observer: maintenanceObserver
        )
        self.rootURL = try Self.prepareRoot(rootURL, observer: observer)
        self.maintenanceDiagnostics = diagnostics
        self.faultInjector = faultInjector
        self.assetVerificationObserver = nil
        self.maintenanceObserver = observer
        self.maintenanceFaultInjector = maintenanceFaultInjector
        self.migrationFaultInjector = nil
    }

    /// Creates a repository with deterministic schema migration faults.
    public init(
        rootURL: URL,
        migrationFaultInjector: @escaping @Sendable (NotebookMigrationStage) throws -> Void
    ) throws {
        let diagnostics = NotebookFileSystem.MaintenanceDiagnostics()
        let observer = Self.makeMaintenanceObserver(diagnostics: diagnostics)
        self.rootURL = try Self.prepareRoot(rootURL, observer: observer)
        self.maintenanceDiagnostics = diagnostics
        self.faultInjector = nil
        self.migrationFaultInjector = migrationFaultInjector
        self.assetVerificationObserver = nil
        self.maintenanceObserver = observer
        self.maintenanceFaultInjector = nil
    }

    public func storageMetrics() -> NotebookStorageMetrics { metrics.snapshot() }

    func maintenanceReport() -> [NotebookFileSystem.MaintenanceEvent: Int] {
        maintenanceDiagnostics.snapshot()
    }

    private static func makeMaintenanceObserver(
        diagnostics: NotebookFileSystem.MaintenanceDiagnostics,
        observer: NotebookFileSystem.MaintenanceObserver? = nil
    ) -> NotebookFileSystem.MaintenanceObserver {
        { event in
            diagnostics.record(event)
            observer?(event)
        }
    }

    private static func prepareRoot(
        _ rootURL: URL,
        observer: NotebookFileSystem.MaintenanceObserver? = nil
    ) throws -> URL {
        let root = try NotebookFileSystem.prepareRoot(rootURL)
        let lock = try NotebookFileSystem.acquireWriterLock(root)
        defer { NotebookFileSystem.releaseWriterLock(lock) }
        try NotebookFileSystem.sweepPrivateTransactions(
            in: root, prefix: ".creation-", additionalPrefixes: [".migration-"], observer: observer
        )
        return root
    }

    /// Audits all selected historical metadata and assets before returning current content.
    public func load(id: UUID) throws -> StoredNotebook? {
        validatedGenerations.removeValue(forKey: id)
        let lock = try NotebookFileSystem.acquireWriterLock(rootURL)
        defer { NotebookFileSystem.releaseWriterLock(lock) }
        let directory = notebookDirectory(id: id)
        guard try NotebookFileSystem.existingDirectory(directory) else { return nil }
        let history = historyStore(id: id, directory: directory)
        guard let snapshot = try history.readHeadSnapshot() else {
            throw NotebookRepositoryError.recoveryRequired
        }
        _ = try history.audit(snapshot.head)
        try migrationStore(history).validateReceipt(snapshot.head)
        let current = try history.current(snapshot.head)
        let strokes = try history.readAssets(current.state)
        let checkpointSize = try Format.CheckpointSize(title: current.state.title, metrics: metrics)
        var sizes: [String: Int] = [:]
        for (reference, stroke) in zip(current.state.strokes, strokes) {
            sizes[reference.digest] = stroke.data.count
        }
        let notebook = storedNotebook(current, id: id, strokes: strokes)
        validatedGenerations[id] = ValidatedGeneration(
            snapshot: snapshot, current: current, verifiedSizes: sizes, checkpointSize: checkpointSize
        )
        maintainNotebook(id: id, directory: directory, head: snapshot.head)
        return notebook
    }

    public func history(
        id: UUID, beforeRevisionID: UUID? = nil, limit: Int = 50
    ) throws -> [NotebookRevisionSummary] {
        validatedGenerations.removeValue(forKey: id)
        guard (1...200).contains(limit) else {
            throw NotebookRepositoryError.invalidContent("History limits must be between 1 and 200.")
        }
        let lock = try NotebookFileSystem.acquireWriterLock(rootURL)
        defer { NotebookFileSystem.releaseWriterLock(lock) }
        let (history, head) = try selectedHistory(id: id)
        let result = try history.audit(head, beforeRevisionID: beforeRevisionID, summaryLimit: limit)
        try migrationStore(history).validateReceipt(head)
        return result.summaries
    }

    public func loadRevision(id: UUID, revisionID: UUID) throws -> StoredNotebook {
        validatedGenerations.removeValue(forKey: id)
        let lock = try NotebookFileSystem.acquireWriterLock(rootURL)
        defer { NotebookFileSystem.releaseWriterLock(lock) }
        let (history, head) = try selectedHistory(id: id)
        _ = try history.audit(head)
        try migrationStore(history).validateReceipt(head)
        let revision = try history.materializeRevision(revisionID, head: head)
        return storedNotebook(revision, id: id, strokes: try history.readAssets(revision.state))
    }

    public func auditHistory(id: UUID) throws -> NotebookHistoryAudit {
        validatedGenerations.removeValue(forKey: id)
        let lock = try NotebookFileSystem.acquireWriterLock(rootURL)
        defer { NotebookFileSystem.releaseWriterLock(lock) }
        let (history, head) = try selectedHistory(id: id)
        let result = try history.audit(head)
        try migrationStore(history).validateReceipt(head)
        return result.report
    }

    public func migrateHistory(
        id: UUID, expectedRevisionID: UUID
    ) throws -> NotebookMigrationReceipt {
        validatedGenerations.removeValue(forKey: id)
        let lock = try NotebookFileSystem.acquireWriterLock(rootURL)
        defer { NotebookFileSystem.releaseWriterLock(lock) }
        let (history, head) = try selectedHistory(id: id)
        guard head.revisionID == expectedRevisionID else { throw NotebookRepositoryError.revisionConflict }
        defer { maintainedNotebookIDs.remove(id) }
        return try migrationStore(history).migrate(head).1
    }

    public func rollbackMigration(
        id: UUID, expectedRevisionID: UUID
    ) throws -> StoredNotebook {
        validatedGenerations.removeValue(forKey: id)
        let lock = try NotebookFileSystem.acquireWriterLock(rootURL)
        defer { NotebookFileSystem.releaseWriterLock(lock) }
        let (history, head) = try selectedHistory(id: id)
        guard head.revisionID == expectedRevisionID else { throw NotebookRepositoryError.revisionConflict }
        defer { maintainedNotebookIDs.remove(id) }
        return try migrationStore(history).rollback(head)
    }

    public func save(
        id: UUID, content: NotebookContent, expectedRevisionID: UUID?
    ) throws -> StoredNotebook {
        let result = try saveBatch(
            id: id, edits: [NotebookSaveEdit(id: UUID(), content: content)],
            expectedRevisionID: expectedRevisionID
        )
        guard let committed = result.committed.first else {
            throw result.rejection?.error ?? NotebookRepositoryError.invalidContent("No notebook edit was accepted.")
        }
        return StoredNotebook(
            id: id, revisionID: committed.revisionID, sequence: committed.sequence,
            content: content, savedAt: committed.savedAt
        )
    }

    /// Publishes an ordered prefix of at most eight edits beneath one atomic HEAD.
    ///
    /// Content rejection acknowledges the valid prefix. Transaction errors before
    /// HEAD publication acknowledge none. A byte-budget boundary leaves a healthy tail.
    public func saveBatch(
        id: UUID, edits: [NotebookSaveEdit], expectedRevisionID: UUID?
    ) throws -> NotebookBatchSaveResult {
        var published = false
        defer {
            if !published {
                validatedGenerations.removeValue(forKey: id)
                maintainedNotebookIDs.remove(id)
                privateMaintenanceRequired = true
            }
        }
        guard !edits.isEmpty else {
            throw NotebookRepositoryError.invalidContent("A save batch must contain an edit.")
        }
        var candidates: [PreparedContent] = []
        var rejection: NotebookBatchFailure?
        var editIDs = Set<UUID>()
        for (index, edit) in edits.prefix(8).enumerated() {
            do {
                guard editIDs.insert(edit.id).inserted else {
                    throw NotebookRepositoryError.invalidContent("Save edit identifiers must be unique.")
                }
                try validateContent(edit.content)
                let prepared = try prepareAssets(edit.content.strokes)
                candidates.append(PreparedContent(
                    edit: edit, references: prepared.references, dataByDigest: prepared.dataByDigest
                ))
            } catch let error as NotebookRepositoryError {
                rejection = NotebookBatchFailure(index: index, editID: edit.id, error: error)
                break
            }
        }
        guard !candidates.isEmpty else {
            return NotebookBatchSaveResult(committed: [], rejection: rejection)
        }
        let lock = try NotebookFileSystem.acquireWriterLock(rootURL)
        defer { NotebookFileSystem.releaseWriterLock(lock) }
        if privateMaintenanceRequired {
            try NotebookFileSystem.sweepPrivateTransactions(
                in: rootURL, prefix: ".creation-", additionalPrefixes: [".migration-"],
                observer: maintenanceObserver
            )
            privateMaintenanceRequired = false
        }
        let destination = notebookDirectory(id: id)
        let isCreating = try NotebookFileSystem.kind(destination) == nil
        let directory: URL
        var snapshot: NotebookHistory.HeadSnapshot?
        if isCreating {
            guard expectedRevisionID == nil else { throw NotebookRepositoryError.revisionConflict }
            directory = rootURL.appendingPathComponent(
                ".creation-\(UUID().uuidString.lowercased())", isDirectory: true
            )
            try NotebookFileSystem.ensureDirectory(directory)
        } else {
            guard try NotebookFileSystem.existingDirectory(destination) else {
                throw NotebookRepositoryError.unsafePath("The notebook directory is missing.")
            }
            directory = destination
            snapshot = try historyStore(id: id, directory: directory).readHeadSnapshot()
            guard snapshot != nil else { throw NotebookRepositoryError.recoveryRequired }
        }
        defer {
            if isCreating {
                do {
                    try NotebookFileSystem.removePrivateTransaction(
                        directory, prefix: ".creation-", observer: maintenanceObserver
                    )
                } catch {
                    maintenanceObserver(.failed(NotebookFileSystem.maintenanceFailure(for: error)))
                }
            }
        }
        guard snapshot?.head.revisionID == expectedRevisionID else {
            throw NotebookRepositoryError.revisionConflict
        }
        let history = historyStore(id: id, directory: directory)
        if let head = snapshot?.head, head.schemaVersion == 1 {
            _ = try migrationStore(history).migrate(head)
            validatedGenerations.removeValue(forKey: id)
            maintainedNotebookIDs.remove(id)
            guard let migratedSnapshot = try history.readHeadSnapshot() else {
                throw NotebookRepositoryError.recoveryRequired
            }
            snapshot = migratedSnapshot
        }
        let cached = validatedGenerations[id]
        let canReuse = snapshot.map {
            cached?.snapshot.head == $0.head && cached?.snapshot.digest == $0.digest
        } ?? false
        if !canReuse { validatedGenerations.removeValue(forKey: id) }
        var previous: Format.State
        var sequence: Int
        var credit: Int
        var verifiedSizes: [String: Int]
        var checkpointSize: Format.CheckpointSize
        if canReuse, let cached {
            previous = cached.current.state
            sequence = cached.current.sequence
            credit = cached.current.checkpointCredit
            verifiedSizes = cached.verifiedSizes
            checkpointSize = cached.checkpointSize
        } else if let head = snapshot?.head {
            try migrationStore(history).validateReceipt(head)
            let current = try history.current(head)
            previous = current.state
            sequence = current.sequence
            credit = current.checkpointCredit
            verifiedSizes = [:]
            checkpointSize = try Format.CheckpointSize(title: previous.title, metrics: metrics)
        } else {
            previous = .empty
            sequence = 0
            credit = 0
            verifiedSizes = [:]
            checkpointSize = try Format.CheckpointSize(title: previous.title, metrics: metrics)
        }

        let baselineState = previous
        let generationID = snapshot?.head.generationID ?? UUID()
        let historyDirectory = directory.appendingPathComponent("history", isDirectory: true)
        try NotebookFileSystem.ensureDirectory(historyDirectory)
        let generation = historyDirectory.appendingPathComponent(
            generationID.uuidString.lowercased(), isDirectory: true
        )
        try NotebookFileSystem.ensureDirectory(generation)
        let writer = NotebookHistoryWriter(
            notebookID: id, generationID: generationID, generation: generation,
            writeFault: faultInjector, migrationFault: nil, metrics: metrics
        )
        var parent = snapshot?.head
        var publications: [NotebookHistoryWriter.Prepared] = []
        var receipts: [NotebookCommittedEdit] = []
        var acceptedCandidates: [String: Data] = [:]
        var introducedBytes = 0
        var finalStamp: NotebookEditStamp?
        var finalSavedAt = Date()
        for (index, candidate) in candidates.enumerated() {
            var newBytes = 0
            for (digest, data) in candidate.dataByDigest
                where verifiedSizes[digest] == nil && acceptedCandidates[digest] == nil {
                newBytes += data.count
            }
            // Every individual state is bounded; additional states may require another transaction.
            if !publications.isEmpty, introducedBytes + newBytes > Self.maximumNotebookBytes {
                rejection = nil
                break
            }
            guard sequence < Int.max else {
                throw NotebookRepositoryError.corruptData("The notebook revision sequence is exhausted.")
            }
            let state = Format.State(
                title: candidate.edit.content.title, pageCount: candidate.edit.content.pageCount,
                strokes: candidate.references
            )
            do {
                for (digest, data) in candidate.dataByDigest {
                    if let existing = acceptedCandidates[digest], existing != data {
                        throw NotebookRepositoryError.invalidContent("Equal stroke digests must have identical bytes.")
                    }
                }
                let size = previous.title == state.title
                    ? checkpointSize : try Format.CheckpointSize(title: state.title, metrics: metrics)
                let savedAt = Date()
                let prepared = try writer.prepare(
                    state: state, previous: previous, parent: parent, revisionID: UUID(),
                    sequence: sequence + 1, stamp: candidate.edit.content.editStamp,
                    savedAt: savedAt, credit: credit, checkpointSize: size
                )
                publications.append(prepared)
                receipts.append(NotebookCommittedEdit(
                    editID: candidate.edit.id, revisionID: prepared.head.revisionID,
                    sequence: sequence + 1, savedAt: savedAt
                ))
                for (digest, data) in candidate.dataByDigest {
                    acceptedCandidates[digest] = data
                }
                introducedBytes += newBytes
                previous = state
                sequence += 1
                credit = prepared.credit
                parent = prepared.head
                checkpointSize = size
                finalStamp = candidate.edit.content.editStamp
                finalSavedAt = savedAt
            } catch let error as NotebookRepositoryError {
                switch error {
                case .invalidContent, .sizeLimitExceeded:
                    rejection = NotebookBatchFailure(index: index, editID: candidate.edit.id, error: error)
                default:
                    throw error
                }
                break
            }
        }
        guard let finalPublication = publications.last else {
            return NotebookBatchSaveResult(committed: [], rejection: rejection)
        }

        let assetsDirectory = directory.appendingPathComponent("assets", isDirectory: true)
        try NotebookFileSystem.ensureDirectory(assetsDirectory)
        if !canReuse, snapshot != nil {
            verifiedSizes = try history.verifiedAssetSizes(
                baselineState, candidates: acceptedCandidates
            ) { reference, candidate in
                try self.verifyCandidateAsset(reference, candidate: candidate, directory: directory)
            }
        }
        for (digest, candidate) in acceptedCandidates {
            guard verifiedSizes[digest] == nil else { continue }
            let reference = Format.Reference(id: UUID(), digest: digest)
            _ = try verifyCandidateAsset(
                reference, candidate: candidate, directory: directory, repairMissing: false
            )
            verifiedSizes[digest] = candidate.count
        }
        if let head = snapshot?.head { maintainNotebook(id: id, directory: directory, head: head) }
        for publication in publications { try writer.publish(publication) }

        let headData = try Format.encode(finalPublication.head, metrics: metrics)
        let finalSnapshot = NotebookHistory.HeadSnapshot(
            head: finalPublication.head, digest: Format.digest(headData, metrics: metrics)
        )
        let finalGeneration = ValidatedGeneration(
            snapshot: finalSnapshot,
            current: Format.Materialized(
                revisionID: finalPublication.head.revisionID, sequence: sequence,
                editStamp: finalStamp, savedAt: finalSavedAt, state: previous, checkpointCredit: credit
            ),
            verifiedSizes: verifiedSizes, checkpointSize: checkpointSize
        )
        let outcome = NotebookBatchSaveResult(committed: receipts, rejection: rejection)
        try NotebookFileSystem.withSynchronizedStage(headData, in: directory, head: true) { stage in
            metrics.record(\.metadataWrittenBytes, headData.count)
            try faultInjector?(.headStaged)
            try faultInjector?(.beforeHeadPublication)
            try NotebookFileSystem.replaceAtomically(
                stage, destination: directory.appendingPathComponent("HEAD.json")
            )
        }
        if isCreating {
            try faultInjector?(.beforeNotebookPublication)
            try NotebookFileSystem.publishImmutable(directory, to: destination)
            maintainedNotebookIDs.insert(id)
        }
        metrics.record(\.headPublications)
        if rejection == nil { validatedGenerations[id] = finalGeneration }
        else { validatedGenerations.removeValue(forKey: id) }
        published = true
        return outcome
    }

    private func maintainNotebook(id: UUID, directory: URL, head: Format.Head) {
        guard !maintainedNotebookIDs.contains(id) else { return }
        do {
            try maintenanceFaultInjector?()
            var locations: [(URL, NotebookFileSystem.MaintenanceLocation)] = []
            if head.schemaVersion == 2 {
                let generation = try historyStore(id: id, directory: directory).generationDirectory(head)
                locations = [
                    (generation, .historyGeneration),
                    (generation.appendingPathComponent("events", isDirectory: true), .events),
                    (generation.appendingPathComponent("checkpoints", isDirectory: true), .checkpoints)
                ]
            }
            try NotebookFileSystem.sweepNotebookStages(
                in: directory, observer: maintenanceObserver, additionalLocations: locations
            )
            maintainedNotebookIDs.insert(id)
        } catch {
            maintenanceObserver(.failed(NotebookFileSystem.maintenanceFailure(for: error)))
        }
    }

    private func selectedHistory(id: UUID) throws -> (NotebookHistory, Format.Head) {
        let directory = notebookDirectory(id: id)
        guard try NotebookFileSystem.existingDirectory(directory) else {
            throw NotebookRepositoryError.invalidContent("The notebook is not committed.")
        }
        let history = historyStore(id: id, directory: directory)
        guard let head = try history.readHead() else { throw NotebookRepositoryError.recoveryRequired }
        return (history, head)
    }

    private func notebookDirectory(id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func historyStore(id: UUID, directory: URL) -> NotebookHistory {
        NotebookHistory(
            directory: directory, notebookID: id, assetVerificationObserver: assetVerificationObserver,
            metrics: metrics
        )
    }

    private func migrationStore(_ history: NotebookHistory) -> NotebookHistoryMigration {
        NotebookHistoryMigration(
            root: rootURL, history: history, fault: migrationFaultInjector,
            maintenanceObserver: maintenanceObserver
        )
    }

    private func verifyCandidateAsset(
        _ reference: Format.Reference, candidate: Data, directory: URL, repairMissing: Bool = true
    ) throws -> Data {
        guard candidate.count <= Self.maximumAssetBytes else {
            throw NotebookRepositoryError.invalidContent("Candidate archive bytes do not match their digest.")
        }
        let assets = directory.appendingPathComponent("assets", isDirectory: true)
        guard try NotebookFileSystem.existingDirectory(assets) else {
            throw NotebookRepositoryError.corruptData("The committed asset directory is missing.")
        }
        let asset = assets.appendingPathComponent("\(reference.digest).stroke")
        let existingKind = try NotebookFileSystem.kind(asset)
        guard existingKind == nil || existingKind == .regularFile else {
            throw NotebookRepositoryError.unsafePath("A stored stroke asset has an unsafe file type.")
        }
        if existingKind == .regularFile {
            do {
                metrics.record(\.assetReadCalls)
                let existing = try NotebookFileSystem.read(asset, maximumBytes: Self.maximumAssetBytes)
                metrics.record(\.assetReadBytes, existing.count)
                if existing == candidate {
                    assetVerificationObserver?(reference.digest)
                    return existing
                }
            } catch let error as NotebookRepositoryError {
                guard case .sizeLimitExceeded = error else { throw error }
            }
        }
        // Preparation binds immutable candidate bytes to this digest before repair.
        // Replacing an asset restores every reference to its content address.
        try NotebookFileSystem.withSynchronizedStage(candidate, in: assets) { stage in
            metrics.record(\.assetWrittenBytes, candidate.count)
            try faultInjector?(.assetStaged)
            if let kind = try NotebookFileSystem.kind(asset) {
                guard kind == .regularFile else {
                    throw NotebookRepositoryError.unsafePath("An asset repair destination has an unsafe file type.")
                }
                try NotebookFileSystem.replaceAtomically(stage, destination: asset)
            } else {
                try NotebookFileSystem.publishImmutable(stage, to: asset)
            }
            if existingKind != nil || repairMissing { maintenanceObserver(.repairedAsset) }
            try faultInjector?(.assetPublished)
        }
        if existingKind != nil || repairMissing { assetVerificationObserver?(reference.digest) }
        return candidate
    }

    private func prepareAssets(
        _ strokes: [NotebookStroke]
    ) throws -> (references: [Format.Reference], dataByDigest: [String: Data]) {
        var references: [Format.Reference] = []
        references.reserveCapacity(strokes.count)
        var dataByDigest: [String: Data] = [:]
        for stroke in strokes {
            let digest = stroke.cachedDigest ?? metrics.assetDigest(stroke.data)
            guard Format.isDigest(digest) else {
                throw NotebookRepositoryError.invalidContent("A stroke archive has invalid digest metadata.")
            }
            if let existing = dataByDigest[digest], existing != stroke.data {
                throw NotebookRepositoryError.invalidContent("Equal stroke digests must have identical bytes.")
            }
            dataByDigest[digest] = stroke.data
            references.append(Format.Reference(id: stroke.id, digest: digest))
        }
        return (references, dataByDigest)
    }

    private func validateContent(_ content: NotebookContent) throws {
        try validateEditStamp(content.editStamp)
        guard (1...12).contains(content.pageCount) else {
            throw NotebookRepositoryError.invalidContent("The prototype supports 1 through 12 paper sections.")
        }
        guard content.title.utf8.count <= Self.maximumTitleBytes,
              content.strokes.count <= Self.maximumStrokeCount else {
            throw NotebookRepositoryError.sizeLimitExceeded("The notebook exceeds the prototype metadata bounds.")
        }
        var identifiers = Set<UUID>()
        var totalBytes = 0
        for stroke in content.strokes {
            guard identifiers.insert(stroke.id).inserted else {
                throw NotebookRepositoryError.invalidContent("Stroke identifiers must be unique.")
            }
            guard stroke.data.count <= Self.maximumAssetBytes else {
                throw NotebookRepositoryError.sizeLimitExceeded("A stroke asset exceeds 10 MiB.")
            }
            totalBytes += stroke.data.count
            guard totalBytes <= Self.maximumNotebookBytes else {
                throw NotebookRepositoryError.sizeLimitExceeded("The notebook exceeds the prototype memory bound.")
            }
        }
    }

    private func validateEditStamp(_ stamp: NotebookEditStamp?) throws {
        guard let stamp else { return }
        guard stamp.capturedAt.timeIntervalSinceReferenceDate.isFinite,
              stamp.uptime.isFinite, stamp.uptime >= 0 else {
            throw NotebookRepositoryError.invalidContent("The notebook edit timestamp is invalid.")
        }
    }

    private func storedNotebook(
        _ revision: Format.Materialized, id: UUID, strokes: [NotebookStroke]
    ) -> StoredNotebook {
        StoredNotebook(
            id: id, revisionID: revision.revisionID, sequence: revision.sequence,
            content: NotebookContent(
                title: revision.state.title, pageCount: revision.state.pageCount,
                strokes: strokes, editStamp: revision.editStamp
            ),
            savedAt: revision.savedAt
        )
    }
}
