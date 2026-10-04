import Foundation
import PencilKit

struct NotebookRecoveryFormat {
    static let maximumMetadataBytes = 2 * 1_024 * 1_024
    static let maximumStateBytes = 128 * 1_024 * 1_024
    static let maximumBatchBytes = 512 * 1_024 * 1_024
    static let bytesPerReference = 48

    struct Receipt: Codable {
        let schemaVersion: Int
        let id: UUID
        let notebookID: UUID
        let editCount: Int
        let savedAt: Date
        let manifestDigest: String

        var publicValue: NotebookRecoveryReceipt {
            NotebookRecoveryReceipt(id: id, notebookID: notebookID, editCount: editCount, savedAt: savedAt)
        }
    }

    struct Manifest: Codable {
        let schemaVersion: Int
        let receiptID: UUID
        let notebookID: UUID
        let baseRevisionID: UUID?
        let savedAt: Date
        let edits: [Edit]
    }

    struct Edit: Codable {
        let id: UUID
        let referenceDigest: String
        let strokeCount: Int
        let logicalBytes: Int
        let title: String
        let pageCount: Int
        let stamp: NotebookEditStamp
        let recoverySource: NotebookRecoveryProvenance?
    }

    struct Reference { let id: UUID; let digest: String }
    private struct Envelope: Decodable { let schemaVersion: Int }

    let root: URL
    let metrics: NotebookRecoveryMetricsRecorder
    var assetObserver: (@Sendable (String) -> Void)? = nil

    func directory(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    func readReceipt(_ id: UUID) throws -> Receipt {
        let bundle = directory(id)
        guard try NotebookFileSystem.existingDirectory(bundle) else {
            throw NotebookRepositoryError.corruptData("The recovery copy is missing.")
        }
        let data = try readMetadata(bundle.appendingPathComponent("RECEIPT.json"))
        let version = try decode(data, as: Envelope.self).schemaVersion
        guard (1...3).contains(version) else { throw NotebookRepositoryError.unsupportedVersion(version) }
        let receipt: Receipt = try decode(data)
        guard receipt.schemaVersion == version, receipt.id == id,
              (1...32).contains(receipt.editCount), receipt.savedAt.timeIntervalSinceReferenceDate.isFinite,
              NotebookRevisionFormat.isDigest(receipt.manifestDigest) else {
            throw NotebookRepositoryError.corruptData("The recovery receipt has invalid metadata.")
        }
        return receipt
    }

    func readManifest(_ receipt: Receipt) throws -> Manifest {
        guard receipt.schemaVersion == 3 else {
            throw NotebookRepositoryError.unsupportedVersion(receipt.schemaVersion)
        }
        let data = try readMetadata(directory(receipt.id).appendingPathComponent("manifest.json"))
        guard metrics.metadataDigest(data) == receipt.manifestDigest else {
            throw NotebookRepositoryError.corruptData("The recovery manifest failed integrity validation.")
        }
        let version = try decode(data, as: Envelope.self).schemaVersion
        guard version == 3 else { throw NotebookRepositoryError.unsupportedVersion(version) }
        let manifest: Manifest = try decode(data)
        guard manifest.schemaVersion == receipt.schemaVersion, manifest.receiptID == receipt.id,
              manifest.notebookID == receipt.notebookID, manifest.savedAt == receipt.savedAt,
              manifest.edits.count == receipt.editCount else {
            throw NotebookRepositoryError.corruptData("The recovery copy has inconsistent metadata.")
        }
        var ids = Set<UUID>()
        var total = 0
        for edit in manifest.edits {
            guard ids.insert(edit.id).inserted, NotebookRevisionFormat.isDigest(edit.referenceDigest),
                  (0...Self.maximumStateBytes).contains(edit.logicalBytes),
                  edit.logicalBytes <= Self.maximumBatchBytes - total else {
                throw NotebookRepositoryError.corruptData("The recovery references exceed supported bounds.")
            }
            do {
                try NotebookRecoveryStateFingerprint.validateMetadata(
                    title: edit.title, pageCount: edit.pageCount, stamp: edit.stamp,
                    strokeCount: edit.strokeCount, source: edit.recoverySource,
                    notebookID: manifest.notebookID
                )
            } catch { throw NotebookRepositoryError.corruptData("The recovery edit metadata is invalid.") }
            total += edit.logicalBytes
        }
        return manifest
    }

    func inspect(_ receipt: Receipt) throws -> NotebookRecoveryCopyMetadata {
        let manifest = try readManifest(receipt)
        return NotebookRecoveryCopyMetadata(
            receipt: receipt.publicValue, baseRevisionID: manifest.baseRevisionID,
            edits: manifest.edits.map {
                NotebookRecoveryEditSummary(
                    id: $0.id, title: $0.title, pageCount: $0.pageCount, strokeCount: $0.strokeCount,
                    stamp: $0.stamp, recoverySource: $0.recoverySource
                )
            }
        )
    }

    func load(_ receipt: Receipt, editID: UUID? = nil) throws -> NotebookRecoveryStrokeBatch {
        let manifest = try readManifest(receipt)
        let selected: [Edit]
        if let editID {
            guard let edit = manifest.edits.first(where: { $0.id == editID }) else {
                throw NotebookRepositoryError.invalidContent("The recovery edit is not in this copy.")
            }
            selected = [edit]
        } else { selected = manifest.edits }
        let bundle = directory(receipt.id)
        guard try NotebookFileSystem.existingDirectory(bundle.appendingPathComponent("references")),
              try NotebookFileSystem.existingDirectory(bundle.appendingPathComponent("assets")) else {
            throw NotebookRepositoryError.corruptData("The recovery reference or asset directory is missing.")
        }
        var assets: [String: Data] = [:]
        var native: [String: PKStroke] = [:]
        var edits: [NotebookRecoveryStrokeEdit] = []
        for edit in selected {
            let data = try readMetadata(referenceURL(edit.id, bundle: bundle))
            guard data.count == edit.strokeCount * Self.bytesPerReference,
                  metrics.metadataDigest(data) == edit.referenceDigest else {
                throw NotebookRepositoryError.corruptData("A recovery reference file failed integrity validation.")
            }
            let references = try Self.decodeReferences(data, count: edit.strokeCount)
            var logicalBytes = 0
            var strokes: [NotebookStroke] = []
            for reference in references {
                metrics.record(\.inputReferenceVisits)
                if assets[reference.digest] == nil {
                    let data = try readAsset(assetURL(reference.digest, bundle: bundle))
                    guard !data.isEmpty, metrics.assetDigest(data) == reference.digest else {
                        throw NotebookRepositoryError.corruptData("A recovery archive failed integrity validation.")
                    }
                    assets[reference.digest] = data
                    native[reference.digest] = try decodeStroke(data, stored: true)
                    assetObserver?(reference.digest)
                }
                let data = assets[reference.digest]!
                guard data.count <= Self.maximumStateBytes - logicalBytes else {
                    throw NotebookRepositoryError.corruptData("A recovery state exceeds 128 MiB.")
                }
                logicalBytes += data.count
                strokes.append(NotebookStroke(id: reference.id, data: data, validatedDigest: reference.digest))
            }
            guard logicalBytes == edit.logicalBytes else {
                throw NotebookRepositoryError.corruptData("A recovery state's logical size differs from its manifest.")
            }
            try validateNativeState(strokes, native: native, stored: true)
            edits.append(NotebookRecoveryStrokeEdit(
                id: edit.id, strokes: strokes, title: edit.title, pageCount: edit.pageCount,
                stamp: edit.stamp, recoverySource: edit.recoverySource
            ))
        }
        return NotebookRecoveryStrokeBatch(
            notebookID: manifest.notebookID, baseRevisionID: manifest.baseRevisionID, edits: edits
        )
    }

    func preserve(
        _ batch: NotebookRecoveryStrokeBatch,
        fault: (@Sendable (NotebookRecoveryWriteStage) throws -> Void)?
    ) throws -> NotebookRecoveryReceipt {
        let captured = try NotebookRecoveryStateFingerprint.capture(batch, metrics: metrics)
        var native: [String: PKStroke] = [:]
        for (digest, data) in captured.assets { native[digest] = try decodeStroke(data, stored: false) }
        for edit in captured.batch.edits { try validateNativeState(edit.strokes, native: native, stored: false) }
        let receipt = NotebookRecoveryReceipt(
            id: UUID(), notebookID: batch.notebookID, editCount: batch.edits.count, savedAt: Date()
        )
        var referenceData: [UUID: Data] = [:]
        let edits = captured.batch.edits.map { edit -> Edit in
            let data = Self.encodeReferences(edit.strokes)
            referenceData[edit.id] = data
            return Edit(
                id: edit.id, referenceDigest: metrics.metadataDigest(data),
                strokeCount: edit.strokes.count, logicalBytes: edit.strokes.reduce(0) { $0 + $1.data.count },
                title: edit.title, pageCount: edit.pageCount, stamp: edit.stamp, recoverySource: edit.recoverySource
            )
        }
        let manifestData = try encode(Manifest(
            schemaVersion: 3, receiptID: receipt.id, notebookID: receipt.notebookID,
            baseRevisionID: batch.baseRevisionID, savedAt: receipt.savedAt, edits: edits
        ))
        let receiptData = try encode(Receipt(
            schemaVersion: 3, id: receipt.id, notebookID: receipt.notebookID,
            editCount: receipt.editCount, savedAt: receipt.savedAt,
            manifestDigest: metrics.metadataDigest(manifestData)
        ))
        try NotebookFileSystem.sweepPrivateTransactions(in: root, prefix: ".recovery-")
        let transaction = root.appendingPathComponent(".recovery-\(UUID().uuidString.lowercased())")
        try NotebookFileSystem.ensureDirectory(transaction)
        defer { try? NotebookFileSystem.removePrivateTransaction(transaction, prefix: ".recovery-") }
        try NotebookFileSystem.ensureDirectory(transaction.appendingPathComponent("assets"))
        try NotebookFileSystem.ensureDirectory(transaction.appendingPathComponent("references"))
        for (digest, data) in captured.assets {
            try writeAsset(data, to: assetURL(digest, bundle: transaction))
            try fault?(.archiveSynchronized)
        }
        for edit in captured.batch.edits {
            try writeMetadata(referenceData[edit.id]!, to: referenceURL(edit.id, bundle: transaction))
            try fault?(.identitiesSynchronized)
        }
        try writeMetadata(manifestData, to: transaction.appendingPathComponent("manifest.json"))
        try fault?(.manifestSynchronized)
        try writeMetadata(receiptData, to: transaction.appendingPathComponent("RECEIPT.json"))
        try fault?(.receiptSynchronized)
        try fault?(.beforePublication)
        try NotebookFileSystem.publishImmutable(transaction, to: directory(receipt.id))
        metrics.record(\.publications)
        return receipt
    }

    func decodeStroke(_ data: Data, stored: Bool) throws -> PKStroke {
        metrics.record(\.nativeArchiveValidations)
        do {
            return try autoreleasepool {
                let drawing = try PKDrawing(data: data)
                guard drawing.strokes.count == 1 else {
                    throw NotebookRepositoryError.invalidContent("A recovery stroke archive must contain exactly one stroke.")
                }
                return drawing.strokes[0]
            }
        } catch {
            if stored { throw NotebookRepositoryError.corruptData("A recovery stroke archive is invalid.") }
            throw NotebookRepositoryError.invalidContent("A recovery stroke archive is invalid.")
        }
    }

    func validateNativeState(_ strokes: [NotebookStroke], native: [String: PKStroke], stored: Bool) throws {
        metrics.record(\.nativeStateValidations)
        let valid = autoreleasepool {
            let assigned: [PKStroke] = strokes.map {
                var stroke = native[$0.cachedDigest!]!
                stroke.id = $0.id
                return stroke
            }
            return PKDrawing(strokes: assigned).strokes.map(\.id) == strokes.map(\.id)
        }
        guard valid else {
            if stored { throw NotebookRepositoryError.corruptData("Recovery ordered stroke identities cannot be restored.") }
            throw NotebookRepositoryError.invalidContent("Recovery ordered stroke identities cannot be restored.")
        }
    }

    private func referenceURL(_ id: UUID, bundle: URL) -> URL {
        bundle.appendingPathComponent("references/\(id.uuidString.lowercased()).refs")
    }

    private func assetURL(_ digest: String, bundle: URL) -> URL {
        bundle.appendingPathComponent("assets/\(digest).stroke")
    }

    static func encodeReferences(_ strokes: [NotebookStroke]) -> Data {
        var data = Data()
        data.reserveCapacity(strokes.count * bytesPerReference)
        for stroke in strokes {
            var id = stroke.id.uuid
            data.append(withUnsafeBytes(of: &id) { Data($0) })
            let hex = Array(stroke.cachedDigest!.utf8)
            for offset in stride(from: 0, to: 64, by: 2) {
                func nibble(_ x: UInt8) -> UInt8 { x <= 57 ? x - 48 : x - 87 }
                data.append(nibble(hex[offset]) << 4 | nibble(hex[offset + 1]))
            }
        }
        return data
    }

    static func decodeReferences(_ data: Data, count: Int) throws -> [Reference] {
        guard data.count == count * bytesPerReference, (0...20_000).contains(count) else {
            throw NotebookRepositoryError.corruptData("Recovery stroke references have an invalid length.")
        }
        let bytes = Array(data)
        var result: [Reference] = []
        var ids = Set<UUID>()
        for index in 0..<count {
            let p = index * bytesPerReference
            let id = UUID(uuid: (
                bytes[p], bytes[p+1], bytes[p+2], bytes[p+3], bytes[p+4], bytes[p+5], bytes[p+6], bytes[p+7],
                bytes[p+8], bytes[p+9], bytes[p+10], bytes[p+11], bytes[p+12], bytes[p+13], bytes[p+14], bytes[p+15]
            ))
            guard ids.insert(id).inserted else {
                throw NotebookRepositoryError.corruptData("Recovery stroke identities are duplicated.")
            }
            result.append(Reference(id: id, digest: NotebookDigest.lowercaseHex(bytes[(p+16)..<(p+48)])))
        }
        return result
    }

    func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        metrics.record(\.metadataEncodeCalls)
        metrics.record(\.metadataEncodedBytes, data.count)
        guard data.count <= Self.maximumMetadataBytes else {
            throw NotebookRepositoryError.sizeLimitExceeded("Recovery metadata exceeds 2 MiB.")
        }
        return data
    }

    func decode<T: Decodable>(_ data: Data, as type: T.Type = T.self) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw NotebookRepositoryError.corruptData("Recovery metadata is unreadable.") }
    }

    func readMetadata(_ url: URL) throws -> Data { try read(url, limit: Self.maximumMetadataBytes, asset: false) }
    func readAsset(_ url: URL) throws -> Data { try read(url, limit: Self.maximumStateBytes, asset: true) }

    private func read(_ url: URL, limit: Int, asset: Bool) throws -> Data {
        metrics.record(asset ? \.assetReadCalls : \.metadataReadCalls)
        guard try NotebookFileSystem.kind(url) != nil else {
            throw NotebookRepositoryError.corruptData("A preserved recovery file is missing.")
        }
        do {
            let data = try NotebookFileSystem.read(url, maximumBytes: limit)
            metrics.record(asset ? \.assetReadBytes : \.metadataReadBytes, data.count)
            return data
        } catch NotebookRepositoryError.sizeLimitExceeded {
            throw NotebookRepositoryError.corruptData("A preserved recovery file exceeds supported bounds.")
        }
    }

    func writeMetadata(_ data: Data, to url: URL) throws { try write(data, to: url, asset: false) }
    func writeAsset(_ data: Data, to url: URL) throws { try write(data, to: url, asset: true) }

    private func write(_ data: Data, to url: URL, asset: Bool) throws {
        try NotebookFileSystem.writeSynchronized(data, to: url)
        metrics.record(asset ? \.assetWriteCalls : \.metadataWriteCalls)
        metrics.record(asset ? \.assetWrittenBytes : \.metadataWrittenBytes, data.count)
    }
}
