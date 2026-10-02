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

    public init(rootURL: URL) throws {
        self.rootURL = try NotebookFileSystem.prepareRoot(rootURL)
        self.faultInjector = nil
    }

    /// Creates a repository with deterministic publication faults for recovery tests.
    public init(
        rootURL: URL,
        faultInjector: @escaping @Sendable (NotebookWriteStage) throws -> Void
    ) throws {
        self.rootURL = try NotebookFileSystem.prepareRoot(rootURL)
        self.faultInjector = faultInjector
    }

    public func load(id: UUID) throws -> StoredNotebook? {
        let directory = notebookDirectory(id: id)
        guard try NotebookFileSystem.existingDirectory(directory) else { return nil }
        guard let head = try readHead(id: id, directory: directory) else { return nil }
        let revision = try readRevision(head: head, directory: directory)
        let strokes = try readAssets(revision: revision, directory: directory)
        return storedNotebook(revision: revision, strokes: strokes)
    }

    public func save(
        id: UUID,
        content: NotebookContent,
        expectedRevisionID: UUID?
    ) throws -> StoredNotebook {
        try validateContent(content)
        let lock = try NotebookFileSystem.acquireWriterLock(rootURL)
        defer { NotebookFileSystem.releaseWriterLock(lock) }

        let directory = notebookDirectory(id: id)
        try NotebookFileSystem.ensureDirectory(directory)
        let assetsDirectory = directory.appendingPathComponent("assets", isDirectory: true)
        let revisionsDirectory = directory.appendingPathComponent("revisions", isDirectory: true)
        try NotebookFileSystem.ensureDirectory(assetsDirectory)
        try NotebookFileSystem.ensureDirectory(revisionsDirectory)

        let currentHead = try readHead(id: id, directory: directory)
        guard currentHead?.revisionID == expectedRevisionID else {
            throw NotebookRepositoryError.revisionConflict
        }

        var sequence = 1
        if let currentHead {
            let current = try readRevision(head: currentHead, directory: directory)
            try verifyAssets(revision: current, directory: directory)
            guard current.sequence < Int.max else {
                throw NotebookRepositoryError.corruptData("The notebook revision sequence is exhausted.")
            }
            sequence = current.sequence + 1
        }

        var references: [StrokeReference] = []
        references.reserveCapacity(content.strokes.count)
        for stroke in content.strokes {
            let digest = Self.digest(stroke.data)
            let destination = assetURL(digest: digest, directory: directory)
            if try NotebookFileSystem.kind(destination) != nil {
                let existing = try NotebookFileSystem.read(
                    destination, maximumBytes: Self.maximumAssetBytes
                )
                guard Self.digest(existing) == digest, existing == stroke.data else {
                    throw NotebookRepositoryError.corruptData("A stored stroke asset failed integrity validation.")
                }
            } else {
                let stage = assetsDirectory.appendingPathComponent(".\(UUID().uuidString).tmp")
                try NotebookFileSystem.writeSynchronized(stroke.data, to: stage)
                try faultInjector?(.assetStaged)
                try NotebookFileSystem.publishImmutable(stage, to: destination)
                try faultInjector?(.assetPublished)
            }
            references.append(StrokeReference(id: stroke.id, digest: digest))
        }

        let revision = Revision(
            schemaVersion: 1,
            notebookID: id,
            revisionID: UUID(),
            parentRevisionID: currentHead?.revisionID,
            sequence: sequence,
            title: content.title,
            pageCount: content.pageCount,
            strokes: references,
            editStamp: content.editStamp,
            savedAt: Date()
        )
        let revisionData = try encodeMetadata(revision)
        let revisionStage = revisionsDirectory.appendingPathComponent(".\(UUID().uuidString).tmp")
        try NotebookFileSystem.writeSynchronized(revisionData, to: revisionStage)
        try faultInjector?(.revisionStaged)
        try NotebookFileSystem.publishImmutable(
            revisionStage,
            to: revisionURL(id: revision.revisionID, directory: directory)
        )
        try faultInjector?(.revisionPublished)

        let head = Head(
            schemaVersion: 1,
            notebookID: id,
            revisionID: revision.revisionID,
            revisionDigest: Self.digest(revisionData)
        )
        let headStage = directory.appendingPathComponent(".head-\(UUID().uuidString).tmp")
        try NotebookFileSystem.writeSynchronized(try encodeMetadata(head), to: headStage)
        try faultInjector?(.headStaged)
        try faultInjector?(.beforeHeadPublication)
        try NotebookFileSystem.replaceAtomically(
            headStage, destination: directory.appendingPathComponent("HEAD.json")
        )

        return storedNotebook(revision: revision, strokes: content.strokes)
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
        try validateEditStamp(revision.editStamp)
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

    private func verifyAssets(revision: Revision, directory: URL) throws {
        try validateAssetsDirectory(revision: revision, directory: directory)
        var totalBytes = 0
        for reference in revision.strokes {
            let data = try readAsset(reference: reference, directory: directory)
            totalBytes += data.count
            guard totalBytes <= Self.maximumNotebookBytes else {
                throw NotebookRepositoryError.sizeLimitExceeded("The notebook exceeds the prototype memory bound.")
            }
        }
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
