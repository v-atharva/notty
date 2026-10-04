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
    private let metrics = NotebookRecoveryMetricsRecorder()
    private var assetVerificationObserver: (@Sendable (String) -> Void)?
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

    public func preserve(_ submitted: NotebookRecoveryBatch) throws -> NotebookRecoveryReceipt {
        try validateBatch(submitted)
        let batch = captureLegacy(submitted)
        try validateBatch(batch)
        let receipt = NotebookRecoveryReceipt(
            id: UUID(),
            notebookID: batch.notebookID,
            editCount: batch.edits.count,
            savedAt: Date()
        )
        let references = try batch.edits.map {
            let identityData = try NotebookRecoveryIdentityFormat.encode($0.strokeIDs)
            return EditReference(
                id: $0.id,
                archiveDigest: metrics.assetDigest($0.drawingData),
                archiveBytes: $0.drawingData.count,
                strokeIDs: nil,
                strokeCount: $0.strokeIDs.count,
                strokeIDsDigest: metrics.metadataDigest(identityData),
                title: $0.title,
                pageCount: $0.pageCount,
                stamp: $0.stamp, recoverySource: $0.recoverySource
            )
        }
        let manifest = Manifest(
            schemaVersion: 2,
            receiptID: receipt.id,
            notebookID: batch.notebookID,
            baseRevisionID: batch.baseRevisionID,
            savedAt: receipt.savedAt,
            edits: references
        )
        let manifestData = try encodeMetadata(manifest)
        let receiptData = try encodeMetadata(ReceiptRecord(
            schemaVersion: 2,
            id: receipt.id,
            notebookID: receipt.notebookID,
            editCount: receipt.editCount,
            savedAt: receipt.savedAt,
            manifestDigest: metrics.metadataDigest(manifestData)
        ))
        for edit in batch.edits {
            try validateNativeArchive(
                edit.drawingData, strokeIDs: edit.strokeIDs, stored: false
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
        try NotebookFileSystem.ensureDirectory(transaction.appendingPathComponent("identities", isDirectory: true))
        for edit in batch.edits {
            try writeSynchronized(
                try NotebookRecoveryIdentityFormat.encode(edit.strokeIDs),
                to: identitiesURL(id: edit.id, bundle: transaction)
            )
            try faultInjector?(.identitiesSynchronized)
            try writeSynchronized(
                edit.drawingData, to: archiveURL(id: edit.id, bundle: transaction)
            )
            try faultInjector?(.archiveSynchronized)
        }
        try writeSynchronized(
            manifestData, to: transaction.appendingPathComponent("manifest.json")
        )
        try faultInjector?(.manifestSynchronized)
        try writeSynchronized(
            receiptData, to: transaction.appendingPathComponent("RECEIPT.json")
        )
        try faultInjector?(.receiptSynchronized)
        try faultInjector?(.beforePublication)
        try NotebookFileSystem.publishImmutable(
            transaction, to: bundleURL(id: receipt.id)
        )
        metrics.record(\.publications)
        return receipt
    }


    init(rootURL: URL, assetVerificationObserver: @escaping @Sendable (String) -> Void) throws {
        self.rootURL = try Self.prepareRoot(rootURL)
        self.faultInjector = nil
        self.assetVerificationObserver = assetVerificationObserver
    }

    private var stateFormat: NotebookRecoveryFormat {
        NotebookRecoveryFormat(root: rootURL, metrics: metrics, assetObserver: assetVerificationObserver)
    }

    public func workMetrics() -> NotebookRecoveryWorkMetrics { metrics.snapshot() }

    public func preserveStates(_ batch: NotebookRecoveryStrokeBatch) throws -> NotebookRecoveryReceipt {
        let lock = try NotebookFileSystem.acquireWriterLock(rootURL)
        defer { NotebookFileSystem.releaseWriterLock(lock) }
        return try stateFormat.preserve(batch, fault: faultInjector)
    }

    public func loadStates(id: UUID) throws -> NotebookRecoveryStrokeBatch {
        let lock = try NotebookFileSystem.acquireWriterLock(rootURL)
        defer { NotebookFileSystem.releaseWriterLock(lock) }
        let record = try stateFormat.readReceipt(id)
        if record.schemaVersion == 3 { return try stateFormat.load(record) }
        return try convertLegacy(loadLegacy(id: id))
    }

    public func loadEdit(id: UUID, editID: UUID) throws -> NotebookRecoveredEdit {
        let lock = try NotebookFileSystem.acquireWriterLock(rootURL)
        defer { NotebookFileSystem.releaseWriterLock(lock) }
        let record = try stateFormat.readReceipt(id)
        let batch: NotebookRecoveryStrokeBatch
        if record.schemaVersion == 3 {
            batch = try stateFormat.load(record, editID: editID)
        } else {
            let (_, manifest, directory) = try readBundle(id: id)
            guard let reference = manifest.edits.first(where: { $0.id == editID }) else {
                throw NotebookRepositoryError.invalidContent("The recovery edit is not in this copy.")
            }
            let ids = try readStrokeIDs(reference, schemaVersion: manifest.schemaVersion, bundle: directory)
            let data = try readArchive(reference, strokeIDs: ids, bundle: directory)
            batch = try convertLegacy(NotebookRecoveryBatch(
                notebookID: record.notebookID, baseRevisionID: manifest.baseRevisionID,
                edits: [NotebookRecoveryEdit(
                    id: reference.id, drawingData: data, strokeIDs: ids, title: reference.title,
                    pageCount: reference.pageCount, stamp: reference.stamp, recoverySource: reference.recoverySource
                )]
            ))
        }
        guard let state = batch.edits.first else {
            throw NotebookRepositoryError.corruptData("The selected recovery edit is missing.")
        }
        return NotebookRecoveredEdit(
            state: state,
            source: NotebookRecoveryProvenance(
                notebookID: batch.notebookID, copyID: id, editID: state.id,
                originalStamp: state.stamp, baseRevisionID: batch.baseRevisionID
            )
        )
    }

    /// Verifies receipt and manifest metadata without checking edit files or archives.
    public func inspect(id: UUID) throws -> NotebookRecoveryCopyMetadata {
        let lock = try NotebookFileSystem.acquireWriterLock(rootURL)
        defer { NotebookFileSystem.releaseWriterLock(lock) }
        let record = try stateFormat.readReceipt(id)
        if record.schemaVersion == 3 { return try stateFormat.inspect(record) }
        let (_, manifest, _) = try readBundle(id: id, validateDirectories: false)
        return try NotebookRecoveryCopyMetadata(
            receipt: record.publicValue, baseRevisionID: manifest.baseRevisionID,
            edits: manifest.edits.map {
                NotebookRecoveryEditSummary(
                    id: $0.id, title: $0.title, pageCount: $0.pageCount,
                    strokeCount: try referenceStrokeCount($0, schemaVersion: manifest.schemaVersion),
                    stamp: $0.stamp, recoverySource: $0.recoverySource
                )
            }
        )
    }

    public func load(id: UUID) throws -> NotebookRecoveryBatch {
        let lock = try NotebookFileSystem.acquireWriterLock(rootURL)
        defer { NotebookFileSystem.releaseWriterLock(lock) }
        let record = try stateFormat.readReceipt(id)
        guard record.schemaVersion == 3 else { return try loadLegacy(id: id) }
        let states = try stateFormat.load(record)
        var totalBytes = 0
        let edits = try states.edits.map { edit in
            try autoreleasepool {
                let strokes = try edit.strokes.map { asset in
                    var native = try stateFormat.decodeStroke(asset.data, stored: true)
                    native.id = asset.id
                    return native
                }
                let data = PKDrawing(strokes: strokes).dataRepresentation()
                metrics.record(\.nativeArchiveSerializations)
                metrics.record(\.nativeSerializedBytes, data.count)
                guard data.count <= Self.maximumArchiveBytes,
                      data.count <= Self.maximumBatchBytes - totalBytes else {
                    throw NotebookRepositoryError.sizeLimitExceeded("The recovery state cannot fit the legacy whole-drawing representation.")
                }
                totalBytes += data.count
                return NotebookRecoveryEdit(
                    id: edit.id, drawingData: data, strokeIDs: edit.strokes.map(\.id),
                    title: edit.title, pageCount: edit.pageCount, stamp: edit.stamp,
                    recoverySource: edit.recoverySource
                )
            }
        }
        let batch = NotebookRecoveryBatch(notebookID: states.notebookID, baseRevisionID: states.baseRevisionID, edits: edits)
        try validateBatch(batch)
        return batch
    }

    private func loadLegacy(id: UUID) throws -> NotebookRecoveryBatch {
        let (record, manifest, directory) = try readBundle(id: id)
        var edits: [NotebookRecoveryEdit] = []
        edits.reserveCapacity(record.editCount)
        for reference in manifest.edits {
            let strokeIDs = try readStrokeIDs(reference, schemaVersion: manifest.schemaVersion, bundle: directory)
            let data = try readArchive(reference, strokeIDs: strokeIDs, bundle: directory)
            edits.append(NotebookRecoveryEdit(
                id: reference.id,
                drawingData: data,
                strokeIDs: strokeIDs,
                title: reference.title,
                pageCount: reference.pageCount,
                stamp: reference.stamp, recoverySource: reference.recoverySource
            ))
        }
        return NotebookRecoveryBatch(
            notebookID: manifest.notebookID,
            baseRevisionID: manifest.baseRevisionID,
            edits: edits
        )
    }

    /// Revalidates matching copies only after their receipt establishes notebook attribution.
    public func list(notebookID: UUID) throws -> [NotebookRecoveryReceipt] {
        let lock = try NotebookFileSystem.acquireWriterLock(rootURL)
        defer { NotebookFileSystem.releaseWriterLock(lock) }
        let entries = try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
        var receipts: [NotebookRecoveryReceipt] = []
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent),
                  entry.lastPathComponent == id.uuidString.lowercased() else { continue }
            let record = try stateFormat.readReceipt(id)
            guard record.notebookID == notebookID else { continue }
            try verifyCopy(record)
            receipts.append(record.publicValue)
        }
        try requireRoot()
        return Self.sortedReceipts(receipts)
    }

    /// Separates matching failures from receipts that cannot establish notebook attribution.
    public func scan(notebookID: UUID) throws -> NotebookRecoveryScan {
        let lock = try NotebookFileSystem.acquireWriterLock(rootURL)
        defer { NotebookFileSystem.releaseWriterLock(lock) }
        let entries = try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
        var receipts: [NotebookRecoveryReceipt] = []
        var matching: [NotebookRecoveryScanIssue] = []
        var unattributed: [NotebookRecoveryScanIssue] = []
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent),
                  entry.lastPathComponent == id.uuidString.lowercased() else { continue }
            try requireRoot()
            let record: NotebookRecoveryFormat.Receipt
            do { record = try stateFormat.readReceipt(id) }
            catch {
                try requireRoot()
                unattributed.append(NotebookRecoveryScanIssue(copyID: id, kind: Self.issue(error)))
                continue
            }
            guard record.notebookID == notebookID else { continue }
            do {
                try verifyCopy(record)
                receipts.append(record.publicValue)
            } catch {
                try requireRoot()
                matching.append(NotebookRecoveryScanIssue(copyID: id, kind: Self.issue(error)))
            }
        }
        try requireRoot()
        matching.sort { $0.copyID.uuidString < $1.copyID.uuidString }
        unattributed.sort { $0.copyID.uuidString < $1.copyID.uuidString }
        return NotebookRecoveryScan(
            copies: Self.sortedReceipts(receipts),
            unavailableCopyIDs: matching.filter { $0.kind == .damagedData }.map(\.copyID),
            matchingIssues: matching, unattributedIssues: unattributed
        )
    }

    private func verifyCopy(_ record: NotebookRecoveryFormat.Receipt) throws {
        if record.schemaVersion == 3 { _ = try stateFormat.load(record); return }
        let (_, manifest, directory) = try readBundle(id: record.id)
        for reference in manifest.edits {
            let ids = try readStrokeIDs(reference, schemaVersion: manifest.schemaVersion, bundle: directory)
            _ = try readArchive(reference, strokeIDs: ids, bundle: directory)
        }
    }

    private static func issue(_ error: any Error) -> NotebookRecoveryIssueKind {
        switch error {
        case NotebookRepositoryError.unsupportedVersion(let version): return .unsupportedVersion(version)
        case NotebookRepositoryError.unsafePath: return .unsafePath
        case NotebookRepositoryError.ioFailure(let code): return .ioFailure(code)
        case NotebookRepositoryError.corruptData, NotebookRepositoryError.sizeLimitExceeded,
             NotebookRepositoryError.invalidContent: return .damagedData
        default: return .ioFailure(Int32((error as NSError).code))
        }
    }

    private func writeSynchronized(_ data: Data, to url: URL) throws {
        try NotebookFileSystem.writeSynchronized(data, to: url)
        let asset = url.pathExtension == "drawing"
        metrics.record(asset ? \.assetWriteCalls : \.metadataWriteCalls)
        metrics.record(asset ? \.assetWrittenBytes : \.metadataWrittenBytes, data.count)
    }

    private func captureLegacy(_ batch: NotebookRecoveryBatch) -> NotebookRecoveryBatch {
        NotebookRecoveryBatch(
            notebookID: batch.notebookID, baseRevisionID: batch.baseRevisionID,
            edits: batch.edits.map { edit in
                let data = edit.drawingData.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
                metrics.record(\.assetCopiedBytes, data.count)
                return NotebookRecoveryEdit(
                    id: edit.id, drawingData: data, strokeIDs: edit.strokeIDs, title: edit.title,
                    pageCount: edit.pageCount, stamp: edit.stamp, recoverySource: edit.recoverySource
                )
            }
        )
    }

    private func convertLegacy(_ batch: NotebookRecoveryBatch) throws -> NotebookRecoveryStrokeBatch {
        var totalBytes = 0
        var native: [String: PKStroke] = [:]
        var edits: [NotebookRecoveryStrokeEdit] = []
        for edit in batch.edits {
            guard (1...12).contains(edit.pageCount) else {
                throw NotebookRepositoryError.sizeLimitExceeded("The legacy recovery extent cannot fit the supported state representation.")
            }
            metrics.record(\.nativeArchiveValidations)
            let strokes: [NotebookStroke] = try autoreleasepool {
                let drawing = try PKDrawing(data: edit.drawingData)
                var stateBytes = 0
                var result: [NotebookStroke] = []
                for (source, id) in zip(drawing.strokes, edit.strokeIDs) {
                    let data = PKDrawing(strokes: [source]).dataRepresentation()
                    metrics.record(\.nativeArchiveSerializations)
                    metrics.record(\.nativeSerializedBytes, data.count)
                    guard !data.isEmpty, data.count <= Self.maximumArchiveBytes - stateBytes else {
                        throw NotebookRepositoryError.sizeLimitExceeded("The converted legacy recovery state exceeds 128 MiB.")
                    }
                    stateBytes += data.count
                    let digest = metrics.assetDigest(data)
                    if native[digest] == nil { native[digest] = try stateFormat.decodeStroke(data, stored: true) }
                    result.append(NotebookStroke(id: id, data: data, validatedDigest: digest))
                }
                guard stateBytes <= Self.maximumBatchBytes - totalBytes else {
                    throw NotebookRepositoryError.sizeLimitExceeded("The converted legacy recovery copy exceeds 512 MiB.")
                }
                totalBytes += stateBytes
                return result
            }
            try stateFormat.validateNativeState(strokes, native: native, stored: true)
            edits.append(NotebookRecoveryStrokeEdit(
                id: edit.id, strokes: strokes, title: edit.title, pageCount: edit.pageCount,
                stamp: edit.stamp, recoverySource: edit.recoverySource
            ))
        }
        return NotebookRecoveryStrokeBatch(
            notebookID: batch.notebookID, baseRevisionID: batch.baseRevisionID, edits: edits
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

    private func readBundle(id: UUID, validateDirectories: Bool = true) throws -> (ReceiptRecord, Manifest, URL) {
        let directory = bundleURL(id: id)
        guard try NotebookFileSystem.existingDirectory(directory) else {
            throw NotebookRepositoryError.corruptData("The preserved recovery copy is missing.")
        }
        let receiptURL = directory.appendingPathComponent("RECEIPT.json")
        guard try NotebookFileSystem.kind(receiptURL) != nil else {
            throw NotebookRepositoryError.corruptData("The recovery receipt is missing.")
        }
        let receiptData = try readCommittedFile(receiptURL, maximumBytes: Self.maximumManifestBytes)
        try validateVersion(try decodeMetadata(receiptData, as: SchemaEnvelope.self).schemaVersion)
        let record: ReceiptRecord = try decodeMetadata(receiptData)
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
        let data = try readCommittedFile(manifestURL, maximumBytes: Self.maximumManifestBytes)
        guard metrics.metadataDigest(data) == record.manifestDigest else {
            throw NotebookRepositoryError.corruptData("The recovery manifest failed integrity validation.")
        }
        try validateVersion(try decodeMetadata(data, as: SchemaEnvelope.self).schemaVersion)
        let manifest: Manifest = try decodeMetadata(data)
        guard manifest.schemaVersion == record.schemaVersion,
              manifest.receiptID == record.id,
              manifest.notebookID == record.notebookID,
              manifest.savedAt == record.savedAt,
              manifest.edits.count == record.editCount else {
            throw NotebookRepositoryError.corruptData("The recovery copy has inconsistent identities or order metadata.")
        }
        try validateReferences(manifest.edits, schemaVersion: manifest.schemaVersion)
        do {
            for edit in manifest.edits {
                try NotebookRevisionFormat.validateRecoverySource(edit.recoverySource, notebookID: manifest.notebookID)
            }
        } catch { throw NotebookRepositoryError.corruptData("The recovery source metadata is invalid.") }
        if validateDirectories {
            guard try NotebookFileSystem.existingDirectory(
                directory.appendingPathComponent("archives", isDirectory: true)
            ) else {
                throw NotebookRepositoryError.corruptData("The recovery archive directory is missing.")
            }
        }
        if validateDirectories, manifest.schemaVersion == 2 {
            guard try NotebookFileSystem.existingDirectory(
                directory.appendingPathComponent("identities", isDirectory: true)
            ) else {
                throw NotebookRepositoryError.corruptData("The recovery identity directory is missing.")
            }
        }
        return (record, manifest, directory)
    }

    private func identitiesURL(id: UUID, bundle: URL) -> URL {
        bundle.appendingPathComponent("identities", isDirectory: true)
            .appendingPathComponent("\(id.uuidString.lowercased()).ids")
    }

    private func referenceStrokeCount(_ reference: EditReference, schemaVersion: Int) throws -> Int {
        if schemaVersion == 1 {
            guard let identities = reference.strokeIDs,
                  reference.strokeCount == nil, reference.strokeIDsDigest == nil else {
                throw NotebookRepositoryError.corruptData("Legacy recovery identities have an invalid format.")
            }
            return identities.count
        }
        guard reference.strokeIDs == nil, let count = reference.strokeCount,
              (0...Self.maximumStrokeIDs).contains(count),
              let digest = reference.strokeIDsDigest, Self.isDigest(digest) else {
            throw NotebookRepositoryError.corruptData("Recovery identity references have an invalid format.")
        }
        return count
    }

    private func readStrokeIDs(
        _ reference: EditReference, schemaVersion: Int, bundle: URL
    ) throws -> [UUID] {
        let count = try referenceStrokeCount(reference, schemaVersion: schemaVersion)
        if schemaVersion == 1, let identities = reference.strokeIDs { return identities }
        let url = identitiesURL(id: reference.id, bundle: bundle)
        guard try NotebookFileSystem.kind(url) != nil else {
            throw NotebookRepositoryError.corruptData("A preserved recovery identity file is missing.")
        }
        let data = try readCommittedFile(url, maximumBytes: NotebookRecoveryIdentityFormat.maximumBytes)
        guard data.count == count * NotebookRecoveryIdentityFormat.bytesPerIdentity,
              metrics.metadataDigest(data) == reference.strokeIDsDigest else {
            throw NotebookRepositoryError.corruptData("A recovery identity file failed integrity validation.")
        }
        return try NotebookRecoveryIdentityFormat.decode(data, count: count)
    }

    private func readCommittedFile(_ url: URL, maximumBytes: Int, asset: Bool = false) throws -> Data {
        metrics.record(asset ? \.assetReadCalls : \.metadataReadCalls)
        do {
            let data = try NotebookFileSystem.read(url, maximumBytes: maximumBytes)
            metrics.record(asset ? \.assetReadBytes : \.metadataReadBytes, data.count)
            return data
        }
        catch NotebookRepositoryError.sizeLimitExceeded {
            throw NotebookRepositoryError.corruptData("A preserved recovery file exceeds its supported size.")
        }
    }

    private func readArchive(
        _ reference: EditReference, strokeIDs: [UUID], bundle: URL
    ) throws -> Data {
        let url = archiveURL(id: reference.id, bundle: bundle)
        guard try NotebookFileSystem.kind(url) != nil else {
            throw NotebookRepositoryError.corruptData("A preserved recovery archive is missing.")
        }
        let data = try readCommittedFile(url, maximumBytes: Self.maximumArchiveBytes, asset: true)
        guard data.count == reference.archiveBytes,
              metrics.assetDigest(data) == reference.archiveDigest else {
            throw NotebookRepositoryError.corruptData("A recovery archive failed integrity validation.")
        }
        try validateNativeArchive(data, strokeIDs: strokeIDs, stored: true)
        assetVerificationObserver?(reference.archiveDigest)
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
            try NotebookRevisionFormat.validateRecoverySource(edit.recoverySource, notebookID: batch.notebookID)
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

    private func validateReferences(_ references: [EditReference], schemaVersion: Int) throws {
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
                    strokeCount: try referenceStrokeCount(reference, schemaVersion: schemaVersion),
                    title: reference.title, pageCount: reference.pageCount, stamp: reference.stamp
                )
                if let identities = reference.strokeIDs {
                    guard Set(identities).count == identities.count else {
                        throw NotebookRepositoryError.corruptData("Recovery stroke identifiers must be unique.")
                    }
                }
            } catch {
                throw NotebookRepositoryError.corruptData("The recovery manifest has invalid edit metadata.")
            }
            totalBytes += reference.archiveBytes
            guard totalBytes <= Self.maximumBatchBytes else {
                throw NotebookRepositoryError.corruptData("A preserved recovery copy exceeds 512 MiB.")
            }
        }
    }

    private func validateEditMetadata(
        strokeIDs: [UUID], title: String, pageCount: Int, stamp: NotebookEditStamp
    ) throws {
        try validateEditMetadata(strokeCount: strokeIDs.count, title: title, pageCount: pageCount, stamp: stamp)
        guard Set(strokeIDs).count == strokeIDs.count else {
            throw NotebookRepositoryError.invalidContent("Recovery stroke identifiers must be unique.")
        }
    }

    private func validateEditMetadata(
        strokeCount: Int, title: String, pageCount: Int, stamp: NotebookEditStamp
    ) throws {
        guard title.utf8.count <= Self.maximumTitleBytes else {
            throw NotebookRepositoryError.sizeLimitExceeded("A recovery title exceeds 4 KiB.")
        }
        guard pageCount > 0,
              stamp.capturedAt.timeIntervalSinceReferenceDate.isFinite,
              stamp.uptime.isFinite, stamp.uptime >= 0 else {
            throw NotebookRepositoryError.invalidContent("Recovery edit metadata is invalid.")
        }
        guard (0...Self.maximumStrokeIDs).contains(strokeCount) else {
            throw NotebookRepositoryError.sizeLimitExceeded("A recovery edit exceeds 20,000 strokes.")
        }
    }

    private func validateNativeArchive(
        _ data: Data, strokeIDs: [UUID], stored: Bool
    ) throws {
        metrics.record(\.nativeArchiveValidations)
        metrics.record(\.nativeStateValidations)
        let isValid = autoreleasepool {
            do {
                let drawing = try PKDrawing(data: data)
                guard drawing.strokes.count == strokeIDs.count,
                      drawing.strokes.count <= Self.maximumStrokeIDs else { return false }
                let strokes = zip(drawing.strokes, strokeIDs).map { source, identity in
                    var stroke = source
                    stroke.id = identity
                    return stroke
                }
                return PKDrawing(strokes: strokes).strokes.map(\.id) == strokeIDs
            } catch {
                return false
            }
        }
        guard isValid else {
            if stored {
                throw NotebookRepositoryError.corruptData("A recovery archive cannot restore its ordered stroke identities.")
            }
            throw NotebookRepositoryError.invalidContent("The recovery archive cannot restore its ordered stroke identities.")
        }
    }

    private func encodeMetadata<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        metrics.record(\.metadataEncodeCalls)
        metrics.record(\.metadataEncodedBytes, data.count)
        guard data.count <= Self.maximumManifestBytes else {
            throw NotebookRepositoryError.sizeLimitExceeded("Recovery metadata exceeds 2 MiB.")
        }
        return data
    }

    private func decodeMetadata<T: Decodable>(_ data: Data, as type: T.Type = T.self) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw NotebookRepositoryError.corruptData("Recovery metadata is unreadable.") }
    }

    private func validateVersion(_ version: Int) throws {
        guard version == 1 || version == 2 else { throw NotebookRepositoryError.unsupportedVersion(version) }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private struct SchemaEnvelope: Decodable {
        let schemaVersion: Int
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
        let strokeIDs: [UUID]?
        let strokeCount: Int?
        let strokeIDsDigest: String?
        let title: String
        let pageCount: Int
        let stamp: NotebookEditStamp
        let recoverySource: NotebookRecoveryProvenance?
    }
}
