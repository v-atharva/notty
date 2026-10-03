import CryptoKit
import Foundation
import PencilKit

/// Preserves complete ordered unsaved states independently of notebook publication.
public actor NotebookRecoveryStore {
    static let maximumEditCount = 32
    static let maximumStrokeIDs = 20_000
    static let maximumArchiveBytes = 128 * 1_024 * 1_024
    static let maximumBatchBytes = 512 * 1_024 * 1_024
    static let maximumTitleBytes = 4_096
    static let maximumManifestBytes = 2 * 1_024 * 1_024

    private let rootURL: URL
    private let faultInjector: (@Sendable (NotebookRecoveryWriteStage) throws -> Void)?

    public init(rootURL: URL) throws {
        self.rootURL = try Self.prepareRoot(rootURL)
        self.faultInjector = nil
    }

    public init(
        rootURL: URL,
        faultInjector: @escaping @Sendable (NotebookRecoveryWriteStage) throws -> Void
    ) throws {
        self.rootURL = try Self.prepareRoot(rootURL)
        self.faultInjector = faultInjector
    }

    public func preserve(_ batch: NotebookRecoveryBatch) throws -> NotebookRecoveryReceipt {
        try validateBatch(batch)
        let receipt = NotebookRecoveryReceipt(
            id: UUID(),
            notebookID: batch.notebookID,
            editCount: batch.edits.count,
            savedAt: Date()
        )
        let references = batch.edits.map {
            EditReference(
                id: $0.id,
                archiveDigest: Self.digest($0.drawingData),
                archiveBytes: $0.drawingData.count,
                strokeIDs: $0.strokeIDs,
                title: $0.title,
                pageCount: $0.pageCount,
                stamp: $0.stamp
            )
        }
        let manifest = Manifest(
            schemaVersion: 1,
            receiptID: receipt.id,
            notebookID: batch.notebookID,
            baseRevisionID: batch.baseRevisionID,
            savedAt: receipt.savedAt,
            edits: references
        )
        let manifestData = try encodeMetadata(manifest)
        let receiptData = try encodeMetadata(ReceiptRecord(
            schemaVersion: 1,
            id: receipt.id,
            notebookID: receipt.notebookID,
            editCount: receipt.editCount,
            savedAt: receipt.savedAt,
            manifestDigest: Self.digest(manifestData)
        ))
        for edit in batch.edits {
            try validateNativeArchive(
                edit.drawingData, strokeCount: edit.strokeIDs.count, stored: false
            )
        }

        let lock = try NotebookFileSystem.acquireWriterLock(rootURL)
        defer { NotebookFileSystem.releaseWriterLock(lock) }
        try NotebookFileSystem.sweepPrivateTransactions(in: rootURL, prefix: ".recovery-")
        let transaction = rootURL.appendingPathComponent(
            ".recovery-\(UUID().uuidString.lowercased())", isDirectory: true
        )
        try NotebookFileSystem.ensureDirectory(transaction)
        defer {
            try? NotebookFileSystem.removePrivateTransaction(transaction, prefix: ".recovery-")
        }
        let archives = transaction.appendingPathComponent("archives", isDirectory: true)
        try NotebookFileSystem.ensureDirectory(archives)
        for edit in batch.edits {
            try NotebookFileSystem.writeSynchronized(
                edit.drawingData, to: archiveURL(id: edit.id, bundle: transaction)
            )
            try faultInjector?(.archiveSynchronized)
        }
        try NotebookFileSystem.writeSynchronized(
            manifestData, to: transaction.appendingPathComponent("manifest.json")
        )
        try faultInjector?(.manifestSynchronized)
        try NotebookFileSystem.writeSynchronized(
            receiptData, to: transaction.appendingPathComponent("RECEIPT.json")
        )
        try faultInjector?(.receiptSynchronized)
        try faultInjector?(.beforePublication)
        try NotebookFileSystem.publishImmutable(
            transaction, to: bundleURL(id: receipt.id)
        )
        return receipt
    }

    public func load(id: UUID) throws -> NotebookRecoveryBatch {
        let lock = try NotebookFileSystem.acquireWriterLock(rootURL)
        defer { NotebookFileSystem.releaseWriterLock(lock) }
        let (record, manifest, directory) = try readBundle(id: id)
        var edits: [NotebookRecoveryEdit] = []
        edits.reserveCapacity(record.editCount)
        for reference in manifest.edits {
            let data = try readArchive(reference, bundle: directory)
            edits.append(NotebookRecoveryEdit(
                id: reference.id,
                drawingData: data,
                strokeIDs: reference.strokeIDs,
                title: reference.title,
                pageCount: reference.pageCount,
                stamp: reference.stamp
            ))
        }
        return NotebookRecoveryBatch(
            notebookID: manifest.notebookID,
            baseRevisionID: manifest.baseRevisionID,
            edits: edits
        )
    }

    /// Revalidates published copies, reading each archive separately.
    public func list(notebookID: UUID) throws -> [NotebookRecoveryReceipt] {
        let lock = try NotebookFileSystem.acquireWriterLock(rootURL)
        defer { NotebookFileSystem.releaseWriterLock(lock) }
        let entries = try FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil
        )
        var receipts: [NotebookRecoveryReceipt] = []
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent),
                  entry.lastPathComponent == id.uuidString.lowercased() else { continue }
            let (record, manifest, directory) = try readBundle(id: id)
            guard record.notebookID == notebookID else { continue }
            for reference in manifest.edits {
                _ = try readArchive(reference, bundle: directory)
            }
            receipts.append(NotebookRecoveryReceipt(
                id: record.id,
                notebookID: record.notebookID,
                editCount: record.editCount,
                savedAt: record.savedAt
            ))
        }
        return Self.sortedReceipts(receipts)
    }

    /// Reports unavailable bundles without hiding independently validated copies.
    public func scan(notebookID: UUID) throws -> NotebookRecoveryScan {
        let lock = try NotebookFileSystem.acquireWriterLock(rootURL)
        defer { NotebookFileSystem.releaseWriterLock(lock) }
        let entries = try FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil
        )
        var receipts: [NotebookRecoveryReceipt] = []
        var unavailable: [UUID] = []
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent),
                  entry.lastPathComponent == id.uuidString.lowercased() else { continue }
            try requireRoot()
            do {
                let (record, manifest, directory) = try readBundle(id: id)
                for reference in manifest.edits {
                    _ = try readArchive(reference, bundle: directory)
                }
                if record.notebookID == notebookID {
                    receipts.append(NotebookRecoveryReceipt(
                        id: record.id,
                        notebookID: record.notebookID,
                        editCount: record.editCount,
                        savedAt: record.savedAt
                    ))
                }
            } catch {
                try requireRoot()
                unavailable.append(id)
            }
        }
        try requireRoot()
        return NotebookRecoveryScan(
            copies: Self.sortedReceipts(receipts),
            unavailableCopyIDs: unavailable.sorted { $0.uuidString < $1.uuidString }
        )
    }

    private func requireRoot() throws {
        guard try NotebookFileSystem.existingDirectory(rootURL) else {
            throw NotebookRepositoryError.unsafePath("The recovery root is missing.")
        }
    }

    private static func sortedReceipts(
        _ receipts: [NotebookRecoveryReceipt]
    ) -> [NotebookRecoveryReceipt] {
        receipts.sorted {
            if $0.savedAt == $1.savedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.savedAt > $1.savedAt
        }
    }

    private static func prepareRoot(_ url: URL) throws -> URL {
        let root = try NotebookFileSystem.prepareRoot(url)
        let lock = try NotebookFileSystem.acquireWriterLock(root)
        defer { NotebookFileSystem.releaseWriterLock(lock) }
        try NotebookFileSystem.sweepPrivateTransactions(in: root, prefix: ".recovery-")
        return root
    }

    private func bundleURL(id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func archiveURL(id: UUID, bundle: URL) -> URL {
        bundle.appendingPathComponent("archives", isDirectory: true)
            .appendingPathComponent("\(id.uuidString.lowercased()).drawing")
    }

    private func readBundle(id: UUID) throws -> (ReceiptRecord, Manifest, URL) {
        let directory = bundleURL(id: id)
        guard try NotebookFileSystem.existingDirectory(directory) else {
            throw NotebookRepositoryError.corruptData("The preserved recovery copy is missing.")
        }
        let receiptURL = directory.appendingPathComponent("RECEIPT.json")
        guard try NotebookFileSystem.kind(receiptURL) != nil else {
            throw NotebookRepositoryError.corruptData("The recovery receipt is missing.")
        }
        let record: ReceiptRecord = try decodeMetadata(NotebookFileSystem.read(
            receiptURL, maximumBytes: Self.maximumManifestBytes
        ))
        try validateVersion(record.schemaVersion)
        guard record.id == id,
              (1...Self.maximumEditCount).contains(record.editCount),
              record.savedAt.timeIntervalSinceReferenceDate.isFinite,
              Self.isDigest(record.manifestDigest) else {
            throw NotebookRepositoryError.corruptData("The recovery receipt has invalid metadata.")
        }
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard try NotebookFileSystem.kind(manifestURL) != nil else {
            throw NotebookRepositoryError.corruptData("The recovery manifest is missing.")
        }
        let data = try NotebookFileSystem.read(
            manifestURL, maximumBytes: Self.maximumManifestBytes
        )
        guard Self.digest(data) == record.manifestDigest else {
            throw NotebookRepositoryError.corruptData("The recovery manifest failed integrity validation.")
        }
        let manifest: Manifest = try decodeMetadata(data)
        try validateVersion(manifest.schemaVersion)
        guard manifest.receiptID == record.id,
              manifest.notebookID == record.notebookID,
              manifest.savedAt == record.savedAt,
              manifest.edits.count == record.editCount else {
            throw NotebookRepositoryError.corruptData("The recovery copy has inconsistent identities or order metadata.")
        }
        try validateReferences(manifest.edits)
        guard try NotebookFileSystem.existingDirectory(
            directory.appendingPathComponent("archives", isDirectory: true)
        ) else {
            throw NotebookRepositoryError.corruptData("The recovery archive directory is missing.")
        }
        return (record, manifest, directory)
    }

    private func readArchive(_ reference: EditReference, bundle: URL) throws -> Data {
        let url = archiveURL(id: reference.id, bundle: bundle)
        guard try NotebookFileSystem.kind(url) != nil else {
            throw NotebookRepositoryError.corruptData("A preserved recovery archive is missing.")
        }
        let data = try NotebookFileSystem.read(url, maximumBytes: Self.maximumArchiveBytes)
        guard data.count == reference.archiveBytes,
              Self.digest(data) == reference.archiveDigest else {
            throw NotebookRepositoryError.corruptData("A recovery archive failed integrity validation.")
        }
        try validateNativeArchive(data, strokeCount: reference.strokeIDs.count, stored: true)
        return data
    }

    private func validateBatch(_ batch: NotebookRecoveryBatch) throws {
        guard (1...Self.maximumEditCount).contains(batch.edits.count) else {
            throw NotebookRepositoryError.sizeLimitExceeded("A recovery copy supports 1 through 32 pending edits.")
        }
        var editIDs = Set<UUID>()
        var totalBytes = 0
        for edit in batch.edits {
            guard editIDs.insert(edit.id).inserted else {
                throw NotebookRepositoryError.invalidContent("Recovery edit identifiers must be unique.")
            }
            try validateEditMetadata(
                strokeIDs: edit.strokeIDs, title: edit.title,
                pageCount: edit.pageCount, stamp: edit.stamp
            )
            guard !edit.drawingData.isEmpty else {
                throw NotebookRepositoryError.invalidContent("A recovery archive must contain a native drawing representation.")
            }
            guard edit.drawingData.count <= Self.maximumArchiveBytes else {
                throw NotebookRepositoryError.sizeLimitExceeded("A recovery archive exceeds 128 MiB.")
            }
            totalBytes += edit.drawingData.count
            guard totalBytes <= Self.maximumBatchBytes else {
                throw NotebookRepositoryError.sizeLimitExceeded("A recovery copy exceeds 512 MiB.")
            }
        }
    }

    private func validateReferences(_ references: [EditReference]) throws {
        var editIDs = Set<UUID>()
        var totalBytes = 0
        for reference in references {
            guard editIDs.insert(reference.id).inserted,
                  Self.isDigest(reference.archiveDigest),
                  (1...Self.maximumArchiveBytes).contains(reference.archiveBytes) else {
                throw NotebookRepositoryError.corruptData("The recovery manifest has invalid archive references.")
            }
            do {
                try validateEditMetadata(
                    strokeIDs: reference.strokeIDs, title: reference.title,
                    pageCount: reference.pageCount, stamp: reference.stamp
                )
            } catch {
                throw NotebookRepositoryError.corruptData("The recovery manifest has invalid edit metadata.")
            }
            totalBytes += reference.archiveBytes
            guard totalBytes <= Self.maximumBatchBytes else {
                throw NotebookRepositoryError.sizeLimitExceeded("A recovery copy exceeds 512 MiB.")
            }
        }
    }

    private func validateEditMetadata(
        strokeIDs: [UUID], title: String, pageCount: Int, stamp: NotebookEditStamp
    ) throws {
        guard title.utf8.count <= Self.maximumTitleBytes else {
            throw NotebookRepositoryError.sizeLimitExceeded("A recovery title exceeds 4 KiB.")
        }
        guard pageCount > 0,
              stamp.capturedAt.timeIntervalSinceReferenceDate.isFinite,
              stamp.uptime.isFinite, stamp.uptime >= 0 else {
            throw NotebookRepositoryError.invalidContent("Recovery edit metadata is invalid.")
        }
        guard strokeIDs.count <= Self.maximumStrokeIDs else {
            throw NotebookRepositoryError.sizeLimitExceeded("A recovery edit exceeds 20,000 strokes.")
        }
        guard Set(strokeIDs).count == strokeIDs.count else {
            throw NotebookRepositoryError.invalidContent("Recovery stroke identifiers must be unique.")
        }
    }

    private func validateNativeArchive(
        _ data: Data, strokeCount: Int, stored: Bool
    ) throws {
        let isValid: Bool
        do {
            let drawing = try PKDrawing(data: data)
            isValid = drawing.strokes.count == strokeCount
                && drawing.strokes.count <= Self.maximumStrokeIDs
        } catch {
            isValid = false
        }
        guard isValid else {
            if stored {
                throw NotebookRepositoryError.corruptData("A recovery archive has invalid native content or stroke identities.")
            }
            throw NotebookRepositoryError.invalidContent("The recovery archive does not match its stroke identifiers.")
        }
    }

    private func encodeMetadata<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumManifestBytes else {
            throw NotebookRepositoryError.sizeLimitExceeded("Recovery metadata exceeds 2 MiB.")
        }
        return data
    }

    private func decodeMetadata<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw NotebookRepositoryError.corruptData("Recovery metadata is unreadable.") }
    }

    private func validateVersion(_ version: Int) throws {
        guard version == 1 else { throw NotebookRepositoryError.unsupportedVersion(version) }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private struct ReceiptRecord: Codable {
        let schemaVersion: Int
        let id: UUID
        let notebookID: UUID
        let editCount: Int
        let savedAt: Date
        let manifestDigest: String
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        let receiptID: UUID
        let notebookID: UUID
        let baseRevisionID: UUID?
        let savedAt: Date
        let edits: [EditReference]
    }

    private struct EditReference: Codable {
        let id: UUID
        let archiveDigest: String
        let archiveBytes: Int
        let strokeIDs: [UUID]
        let title: String
        let pageCount: Int
        let stamp: NotebookEditStamp
    }
}
