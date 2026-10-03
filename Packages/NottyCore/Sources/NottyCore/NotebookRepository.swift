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
        let lock = try NotebookFileSystem.acquireWriterLock(rootURL)
        defer { NotebookFileSystem.releaseWriterLock(lock) }
        let directory = notebookDirectory(id: id)
        guard try NotebookFileSystem.existingDirectory(directory) else { return nil }
        let history = historyStore(id: id, directory: directory)
        guard let head = try history.readHead() else { throw NotebookRepositoryError.recoveryRequired }
        _ = try history.audit(head)
        try migrationStore(history).validateReceipt(head)
        let current = try history.current(head)
        let notebook = storedNotebook(current, id: id, strokes: try history.readAssets(current.state))
        maintainNotebook(id: id, directory: directory, head: head)
        return notebook
    }

    public func history(
        id: UUID, beforeRevisionID: UUID? = nil, limit: Int = 50
    ) throws -> [NotebookRevisionSummary] {
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
        let lock = try NotebookFileSystem.acquireWriterLock(rootURL)
        defer { NotebookFileSystem.releaseWriterLock(lock) }
        let (history, head) = try selectedHistory(id: id)
        _ = try history.audit(head)
        try migrationStore(history).validateReceipt(head)
        let revision = try history.materializeRevision(revisionID, head: head)
        return storedNotebook(revision, id: id, strokes: try history.readAssets(revision.state))
    }

    public func auditHistory(id: UUID) throws -> NotebookHistoryAudit {
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
        var published = false
        defer {
            if !published {
                maintainedNotebookIDs.remove(id)
                privateMaintenanceRequired = true
            }
        }
        try validateContent(content)
        let prepared = try prepareAssets(content.strokes)
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
        var currentHead: Format.Head?
        if isCreating {
            guard expectedRevisionID == nil else { throw NotebookRepositoryError.revisionConflict }
            directory = rootURL.appendingPathComponent(
                ".creation-\(UUID().uuidString.lowercased())", isDirectory: true
            )
            try NotebookFileSystem.ensureDirectory(directory)
            currentHead = nil
        } else {
            guard try NotebookFileSystem.existingDirectory(destination) else {
                throw NotebookRepositoryError.unsafePath("The notebook directory is missing.")
            }
            directory = destination
            guard let head = try historyStore(id: id, directory: directory).readHead() else {
                throw NotebookRepositoryError.recoveryRequired
            }
            currentHead = head
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
        guard currentHead?.revisionID == expectedRevisionID else {
            throw NotebookRepositoryError.revisionConflict
        }
        let history = historyStore(id: id, directory: directory)
        if let head = currentHead, head.schemaVersion == 1 {
            currentHead = try migrationStore(history).migrate(head).0
            maintainedNotebookIDs.remove(id)
        }
        let assetsDirectory = directory.appendingPathComponent("assets", isDirectory: true)
        try NotebookFileSystem.ensureDirectory(assetsDirectory)
        var previous = Format.State.empty
        var sequence = 1
        var credit = 0
        // These verification receipts apply only to this locked publication.
        var verifiedDigests = Set<String>()
        if let head = currentHead {
            try migrationStore(history).validateReceipt(head)
            let current = try history.current(head)
            verifiedDigests = try history.verifyAssets(current.state, candidates: prepared.dataByDigest) {
                reference, candidate in
                try verifyCandidateAsset(reference, candidate: candidate, directory: directory)
            }
            guard current.sequence < Int.max else {
                throw NotebookRepositoryError.corruptData("The notebook revision sequence is exhausted.")
            }
            previous = current.state
            sequence = current.sequence + 1
            credit = current.checkpointCredit
            maintainNotebook(id: id, directory: directory, head: head)
        }
        for reference in prepared.references {
            guard !verifiedDigests.contains(reference.digest) else { continue }
            guard let candidate = prepared.dataByDigest[reference.digest] else {
                throw NotebookRepositoryError.corruptData("A prepared stroke asset is missing.")
            }
            let asset = assetsDirectory.appendingPathComponent("\(reference.digest).stroke")
            if try NotebookFileSystem.kind(asset) != nil {
                _ = try verifyCandidateAsset(reference, candidate: candidate, directory: directory)
            } else {
                try NotebookFileSystem.withSynchronizedStage(candidate, in: assetsDirectory) { stage in
                    try faultInjector?(.assetStaged)
                    try NotebookFileSystem.publishImmutable(stage, to: asset)
                    try faultInjector?(.assetPublished)
                }
            }
            verifiedDigests.insert(reference.digest)
        }
        let generationID = currentHead?.generationID ?? UUID()
        let historyDirectory = directory.appendingPathComponent("history", isDirectory: true)
        try NotebookFileSystem.ensureDirectory(historyDirectory)
        let generation = historyDirectory.appendingPathComponent(
            generationID.uuidString.lowercased(), isDirectory: true
        )
        try NotebookFileSystem.ensureDirectory(generation)
        let state = Format.State(title: content.title, pageCount: content.pageCount, strokes: prepared.references)
        let revisionID = UUID()
        let savedAt = Date()
        let writer = NotebookHistoryWriter(
            notebookID: id, generationID: generationID, generation: generation,
            writeFault: faultInjector, migrationFault: nil
        )
        let head = try writer.append(
            state: state, previous: previous, parent: currentHead, revisionID: revisionID,
            sequence: sequence, stamp: content.editStamp, savedAt: savedAt, credit: credit
        ).head
        try NotebookFileSystem.withSynchronizedStage(
            try Format.encode(head), in: directory, head: true
        ) { stage in
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
        published = true
        return StoredNotebook(
            id: id, revisionID: revisionID, sequence: sequence, content: content, savedAt: savedAt
        )
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
            directory: directory, notebookID: id, assetVerificationObserver: assetVerificationObserver
        )
    }

    private func migrationStore(_ history: NotebookHistory) -> NotebookHistoryMigration {
        NotebookHistoryMigration(
            root: rootURL, history: history, fault: migrationFaultInjector,
            maintenanceObserver: maintenanceObserver
        )
    }

    private func verifyCandidateAsset(
        _ reference: Format.Reference, candidate: Data, directory: URL
    ) throws -> Data {
        guard candidate.count <= Self.maximumAssetBytes, Format.digest(candidate) == reference.digest else {
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
                let existing = try NotebookFileSystem.read(asset, maximumBytes: Self.maximumAssetBytes)
                if existing == candidate {
                    assetVerificationObserver?(reference.digest)
                    return existing
                }
            } catch let error as NotebookRepositoryError {
                guard case .sizeLimitExceeded = error else { throw error }
            }
        }
        // A verified candidate restores every reference to this content-addressed asset.
        try NotebookFileSystem.withSynchronizedStage(candidate, in: assets) { stage in
            try faultInjector?(.assetStaged)
            if let kind = try NotebookFileSystem.kind(asset) {
                guard kind == .regularFile else {
                    throw NotebookRepositoryError.unsafePath("An asset repair destination has an unsafe file type.")
                }
                try NotebookFileSystem.replaceAtomically(stage, destination: asset)
            } else {
                try NotebookFileSystem.publishImmutable(stage, to: asset)
            }
            maintenanceObserver(.repairedAsset)
            try faultInjector?(.assetPublished)
        }
        assetVerificationObserver?(reference.digest)
        return candidate
    }

    private func prepareAssets(
        _ strokes: [NotebookStroke]
    ) throws -> (references: [Format.Reference], dataByDigest: [String: Data]) {
        var references: [Format.Reference] = []
        references.reserveCapacity(strokes.count)
        var dataByDigest: [String: Data] = [:]
        for stroke in strokes {
            let digest = Format.digest(stroke.data)
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
