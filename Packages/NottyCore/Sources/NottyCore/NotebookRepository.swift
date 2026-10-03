import CryptoKit
import Foundation

/// Stores immutable stroke assets and revision manifests beneath an atomic HEAD.
///
/// File synchronization and atomic publication protect the process-crash boundary.
/// Directory durability during device power loss is not guaranteed by this contract.
public actor NotebookRepository {
    // These bounds protect the prototype; they do not define final notebook capacity.
    static let maximumStrokeCount = 10_000
    static let maximumAssetBytes = 10 * 1_024 * 1_024
    static let maximumMetadataBytes = 2 * 1_024 * 1_024
    static let maximumNotebookBytes = 64 * 1_024 * 1_024
    static let maximumTitleBytes = 4_096

    private let rootURL: URL
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
            in: root, prefix: ".creation-", observer: observer
        )
        return root
    }

    public func load(id: UUID) throws -> StoredNotebook? {
        guard try NotebookFileSystem.existingDirectory(rootURL) else {
            throw NotebookRepositoryError.unsafePath("The notebook storage directory is missing.")
        }
        let lock = try NotebookFileSystem.acquireWriterLock(rootURL)
        defer { NotebookFileSystem.releaseWriterLock(lock) }
        let directory = notebookDirectory(id: id)
        guard try NotebookFileSystem.existingDirectory(directory) else { return nil }
        guard let head = try readHead(id: id, directory: directory) else {
            throw NotebookRepositoryError.recoveryRequired
        }
        let revision = try readRevision(head: head, directory: directory)
        let strokes = try readAssets(revision: revision, directory: directory)
        let notebook = storedNotebook(revision: revision, strokes: strokes)
        maintainNotebook(id: id, directory: directory)
        return notebook
    }

    public func save(
        id: UUID,
        content: NotebookContent,
        expectedRevisionID: UUID?
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
                in: rootURL, prefix: ".creation-", observer: maintenanceObserver
            )
            privateMaintenanceRequired = false
        }
        let destination = notebookDirectory(id: id)
        let isCreating = try NotebookFileSystem.kind(destination) == nil
        let directory: URL
        let currentHead: Head?
        if isCreating {
            guard expectedRevisionID == nil else {
                throw NotebookRepositoryError.revisionConflict
            }
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
            guard let head = try readHead(id: id, directory: directory) else {
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
        let assetsDirectory = directory.appendingPathComponent("assets", isDirectory: true)
        let revisionsDirectory = directory.appendingPathComponent("revisions", isDirectory: true)
        try NotebookFileSystem.ensureDirectory(assetsDirectory)
        try NotebookFileSystem.ensureDirectory(revisionsDirectory)
        guard currentHead?.revisionID == expectedRevisionID else {
            throw NotebookRepositoryError.revisionConflict
        }

        var sequence = 1
        // Verification receipts are valid only within this locked save.
        var verifiedDigests = Set<String>()
        if let currentHead {
            let current = try readRevision(head: currentHead, directory: directory)
            verifiedDigests = try verifyAssets(
                revision: current, directory: directory, candidates: prepared.dataByDigest
            )
            guard current.sequence < Int.max else {
                throw NotebookRepositoryError.corruptData("The notebook revision sequence is exhausted.")
            }
            sequence = current.sequence + 1
            maintainNotebook(id: id, directory: directory)
        }

        for reference in prepared.references {
            let digest = reference.digest
            guard !verifiedDigests.contains(digest) else { continue }
            guard let candidate = prepared.dataByDigest[digest] else {
                throw NotebookRepositoryError.corruptData("A prepared stroke asset is missing.")
            }
            let destination = assetURL(digest: digest, directory: directory)
            if try NotebookFileSystem.kind(destination) != nil {
                let existing = try NotebookFileSystem.read(
                    destination, maximumBytes: Self.maximumAssetBytes
                )
                guard Self.digest(existing) == digest, existing == candidate else {
                    throw NotebookRepositoryError.corruptData("A stored stroke asset failed integrity validation.")
                }
                assetVerificationObserver?(digest)
            } else {
                try NotebookFileSystem.withSynchronizedStage(candidate, in: assetsDirectory) { stage in
                    try faultInjector?(.assetStaged)
                    try NotebookFileSystem.publishImmutable(stage, to: destination)
                    try faultInjector?(.assetPublished)
                }
            }
            verifiedDigests.insert(digest)
        }

        let revision = Revision(
            schemaVersion: 1,
            notebookID: id,
            revisionID: UUID(),
            parentRevisionID: currentHead?.revisionID,
            sequence: sequence,
            title: content.title,
            pageCount: content.pageCount,
            strokes: prepared.references,
            editStamp: content.editStamp,
            savedAt: Date()
        )
        let revisionData = try encodeMetadata(revision)
        try NotebookFileSystem.withSynchronizedStage(revisionData, in: revisionsDirectory) { stage in
            try faultInjector?(.revisionStaged)
            try NotebookFileSystem.publishImmutable(
                stage, to: revisionURL(id: revision.revisionID, directory: directory)
            )
            try faultInjector?(.revisionPublished)
        }

        let head = Head(
            schemaVersion: 1,
            notebookID: id,
            revisionID: revision.revisionID,
            revisionDigest: Self.digest(revisionData)
        )
        try NotebookFileSystem.withSynchronizedStage(
            try encodeMetadata(head), in: directory, head: true
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
        }

        if isCreating { maintainedNotebookIDs.insert(id) }
        published = true
        return storedNotebook(revision: revision, strokes: content.strokes)
    }

    // Only successful maintenance consumes admission; publication alone does not.
    private func maintainNotebook(id: UUID, directory: URL) {
        guard !maintainedNotebookIDs.contains(id) else { return }
        do {
            try maintenanceFaultInjector?()
            try NotebookFileSystem.sweepNotebookStages(
                in: directory, observer: maintenanceObserver
            )
            maintainedNotebookIDs.insert(id)
        } catch {
            maintenanceObserver(.failed(NotebookFileSystem.maintenanceFailure(for: error)))
        }
    }

    private func notebookDirectory(id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func assetURL(digest: String, directory: URL) -> URL {
        directory.appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent("\(digest).stroke")
    }

    private func revisionURL(id: UUID, directory: URL) -> URL {
        directory.appendingPathComponent("revisions", isDirectory: true)
            .appendingPathComponent("\(id.uuidString.lowercased()).json")
    }

    private func readHead(id: UUID, directory: URL) throws -> Head? {
        let url = directory.appendingPathComponent("HEAD.json")
        guard try NotebookFileSystem.kind(url) != nil else { return nil }
        let data = try NotebookFileSystem.read(url, maximumBytes: Self.maximumMetadataBytes)
        let head: Head = try decodeMetadata(data)
        try validateVersion(head.schemaVersion)
        guard head.notebookID == id, Self.isDigest(head.revisionDigest) else {
            throw NotebookRepositoryError.corruptData("The notebook HEAD has invalid identifiers or a digest.")
        }
        return head
    }

    private func readRevision(head: Head, directory: URL) throws -> Revision {
        let revisionsDirectory = directory.appendingPathComponent("revisions", isDirectory: true)
        guard try NotebookFileSystem.existingDirectory(revisionsDirectory) else {
            throw NotebookRepositoryError.corruptData("The committed revision directory is missing.")
        }
        let url = revisionURL(id: head.revisionID, directory: directory)
        guard try NotebookFileSystem.kind(url) != nil else {
            throw NotebookRepositoryError.corruptData("The committed revision is missing.")
        }
        let data = try NotebookFileSystem.read(url, maximumBytes: Self.maximumMetadataBytes)
        guard Self.digest(data) == head.revisionDigest else {
            throw NotebookRepositoryError.corruptData("The committed revision failed integrity validation.")
        }
        let revision: Revision = try decodeMetadata(data)
        try validateVersion(revision.schemaVersion)
        guard revision.notebookID == head.notebookID,
              revision.revisionID == head.revisionID,
              revision.sequence > 0,
              revision.savedAt.timeIntervalSinceReferenceDate.isFinite,
              (revision.sequence == 1) == (revision.parentRevisionID == nil),
              revision.parentRevisionID != revision.revisionID else {
            throw NotebookRepositoryError.corruptData("The committed revision has inconsistent metadata.")
        }
        guard (1...12).contains(revision.pageCount),
              revision.title.utf8.count <= Self.maximumTitleBytes,
              revision.strokes.count <= Self.maximumStrokeCount else {
            throw NotebookRepositoryError.corruptData("The committed revision exceeds the supported content bounds.")
        }
        do {
            try validateEditStamp(revision.editStamp)
        } catch {
            throw NotebookRepositoryError.corruptData("The committed edit timestamp is invalid.")
        }
        var identifiers = Set<UUID>()
        for reference in revision.strokes {
            guard identifiers.insert(reference.id).inserted, Self.isDigest(reference.digest) else {
                throw NotebookRepositoryError.corruptData("The committed revision contains invalid stroke references.")
            }
        }
        return revision
    }

    private func readAssets(revision: Revision, directory: URL) throws -> [NotebookStroke] {
        try validateAssetsDirectory(revision: revision, directory: directory)
        var totalBytes = 0
        var strokes: [NotebookStroke] = []
        strokes.reserveCapacity(revision.strokes.count)
        for reference in revision.strokes {
            let data = try readAsset(reference: reference, directory: directory)
            totalBytes += data.count
            guard totalBytes <= Self.maximumNotebookBytes else {
                throw NotebookRepositoryError.sizeLimitExceeded("The notebook exceeds the prototype memory bound.")
            }
            strokes.append(NotebookStroke(id: reference.id, data: data))
        }
        return strokes
    }

    private func verifyAssets(
        revision: Revision,
        directory: URL,
        candidates: [String: Data]
    ) throws -> Set<String> {
        try validateAssetsDirectory(revision: revision, directory: directory)
        var byteCounts: [String: Int] = [:]
        var totalBytes = 0
        for reference in revision.strokes {
            if byteCounts[reference.digest] == nil {
                let data = try readAsset(reference: reference, directory: directory)
                if let candidate = candidates[reference.digest], candidate != data {
                    throw NotebookRepositoryError.corruptData("Stroke archives with the same digest have different bytes.")
                }
                byteCounts[reference.digest] = data.count
            }
            guard let byteCount = byteCounts[reference.digest] else {
                throw NotebookRepositoryError.corruptData("A verified stroke asset is missing.")
            }
            totalBytes += byteCount
            guard totalBytes <= Self.maximumNotebookBytes else {
                throw NotebookRepositoryError.sizeLimitExceeded("The notebook exceeds the prototype memory bound.")
            }
        }
        return Set(byteCounts.keys)
    }

    private func prepareAssets(
        _ strokes: [NotebookStroke]
    ) throws -> (references: [StrokeReference], dataByDigest: [String: Data]) {
        var references: [StrokeReference] = []
        references.reserveCapacity(strokes.count)
        var dataByDigest: [String: Data] = [:]
        for stroke in strokes {
            let digest = Self.digest(stroke.data)
            if let existing = dataByDigest[digest], existing != stroke.data {
                throw NotebookRepositoryError.invalidContent("Stroke archives with the same digest must have identical bytes.")
            }
            dataByDigest[digest] = stroke.data
            references.append(StrokeReference(id: stroke.id, digest: digest))
        }
        return (references, dataByDigest)
    }

    private func validateAssetsDirectory(revision: Revision, directory: URL) throws {
        let assets = directory.appendingPathComponent("assets", isDirectory: true)
        guard try NotebookFileSystem.existingDirectory(assets) else {
            if revision.strokes.isEmpty { return }
            throw NotebookRepositoryError.corruptData("The committed stroke asset directory is missing.")
        }
    }

    private func readAsset(reference: StrokeReference, directory: URL) throws -> Data {
        let url = assetURL(digest: reference.digest, directory: directory)
        guard try NotebookFileSystem.kind(url) != nil else {
            throw NotebookRepositoryError.corruptData("A committed stroke asset is missing.")
        }
        let data = try NotebookFileSystem.read(url, maximumBytes: Self.maximumAssetBytes)
        guard Self.digest(data) == reference.digest else {
            throw NotebookRepositoryError.corruptData("A committed stroke asset failed integrity validation.")
        }
        assetVerificationObserver?(reference.digest)
        return data
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

    private func validateVersion(_ version: Int) throws {
        guard version == 1 else { throw NotebookRepositoryError.unsupportedVersion(version) }
    }

    private func encodeMetadata<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumMetadataBytes else {
            throw NotebookRepositoryError.sizeLimitExceeded("Notebook metadata exceeds 2 MiB.")
        }
        return data
    }

    private func decodeMetadata<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw NotebookRepositoryError.corruptData("Notebook metadata is unreadable.")
        }
    }

    private func storedNotebook(revision: Revision, strokes: [NotebookStroke]) -> StoredNotebook {
        StoredNotebook(
            id: revision.notebookID,
            revisionID: revision.revisionID,
            sequence: revision.sequence,
            content: NotebookContent(
                title: revision.title, pageCount: revision.pageCount, strokes: strokes,
                editStamp: revision.editStamp
            ),
            savedAt: revision.savedAt
        )
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private struct Head: Codable {
        let schemaVersion: Int
        let notebookID: UUID
        let revisionID: UUID
        let revisionDigest: String
    }

    private struct StrokeReference: Codable {
        let id: UUID
        let digest: String
    }

    private struct Revision: Codable {
        let schemaVersion: Int
        let notebookID: UUID
        let revisionID: UUID
        let parentRevisionID: UUID?
        let sequence: Int
        let title: String
        let pageCount: Int
        let strokes: [StrokeReference]
        let editStamp: NotebookEditStamp?
        let savedAt: Date
    }
}
