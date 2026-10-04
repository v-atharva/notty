import CryptoKit
import Foundation

/// Compares complete ordered recovery states without exposing trusted digest input.
public struct NotebookRecoveryStateFingerprint: Sendable, Equatable {
    public let workMetrics: NotebookRecoveryWorkMetrics
    private let value: String

    public init(validating batch: NotebookRecoveryStrokeBatch) throws {
        self = try Self.capture(batch).fingerprint
    }

    private init(value: String, metrics: NotebookRecoveryWorkMetrics) {
        self.value = value
        self.workMetrics = metrics
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.value == rhs.value }

    struct Captured {
        let batch: NotebookRecoveryStrokeBatch
        let assets: [String: Data]
        let fingerprint: NotebookRecoveryStateFingerprint
    }

    private struct BatchHeader: Encodable {
        let notebookID: UUID
        let baseRevisionID: UUID?
        let editCount: Int
    }

    private struct EditHeader: Encodable {
        let id: UUID
        let strokeCount: Int
        let title: String
        let pageCount: Int
        let stamp: NotebookEditStamp
        let recoverySource: NotebookRecoveryProvenance?
    }

    static func capture(
        _ batch: NotebookRecoveryStrokeBatch,
        metrics parent: NotebookRecoveryMetricsRecorder? = nil
    ) throws -> Captured {
        guard (1...32).contains(batch.edits.count) else {
            throw NotebookRepositoryError.sizeLimitExceeded("A recovery copy supports 1 through 32 pending edits.")
        }
        let metrics = NotebookRecoveryMetricsRecorder(parent: parent)
        var editIDs = Set<UUID>()
        var totalBytes = 0
        for edit in batch.edits {
            guard editIDs.insert(edit.id).inserted else {
                throw NotebookRepositoryError.invalidContent("Recovery edit identifiers must be unique.")
            }
            try validateMetadata(
                title: edit.title, pageCount: edit.pageCount, stamp: edit.stamp,
                strokeCount: edit.strokes.count, source: edit.recoverySource,
                notebookID: batch.notebookID
            )
            var strokeIDs = Set<UUID>()
            var bytes = 0
            for stroke in edit.strokes {
                metrics.record(\.inputReferenceVisits)
                guard strokeIDs.insert(stroke.id).inserted, !stroke.data.isEmpty else {
                    throw NotebookRepositoryError.invalidContent("Recovery stroke references are invalid.")
                }
                guard stroke.data.count <= 128 * 1_024 * 1_024 - bytes else {
                    throw NotebookRepositoryError.sizeLimitExceeded("A recovery state exceeds 128 MiB.")
                }
                bytes += stroke.data.count
            }
            guard bytes <= 512 * 1_024 * 1_024 - totalBytes else {
                throw NotebookRepositoryError.sizeLimitExceeded("A recovery copy exceeds 512 MiB.")
            }
            totalBytes += bytes
        }

        var hasher = SHA256()
        var hashedBytes = 0
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func append(_ data: Data) {
            hasher.update(data: data)
            hashedBytes += data.count
        }
        func appendHeader<T: Encodable>(_ value: T) throws {
            let data = try encoder.encode(value)
            metrics.record(\.metadataEncodeCalls)
            metrics.record(\.metadataEncodedBytes, data.count)
            var length = UInt64(data.count).bigEndian
            append(withUnsafeBytes(of: &length) { Data($0) })
            append(data)
        }
        append(Data("NottyRecoveryStates1".utf8))
        try appendHeader(BatchHeader(
            notebookID: batch.notebookID, baseRevisionID: batch.baseRevisionID,
            editCount: batch.edits.count
        ))
        var assets: [String: Data] = [:]
        var edits: [NotebookRecoveryStrokeEdit] = []
        for edit in batch.edits {
            try appendHeader(EditHeader(
                id: edit.id, strokeCount: edit.strokes.count, title: edit.title,
                pageCount: edit.pageCount, stamp: edit.stamp, recoverySource: edit.recoverySource
            ))
            var strokes: [NotebookStroke] = []
            strokes.reserveCapacity(edit.strokes.count)
            for stroke in edit.strokes {
                metrics.record(\.inputReferenceVisits)
                let data: Data
                let digest: String
                if let cached = stroke.cachedDigest {
                    guard NotebookRevisionFormat.isDigest(cached) else {
                        throw NotebookRepositoryError.invalidContent("A recovery archive digest is invalid.")
                    }
                    data = stroke.data
                    digest = cached
                } else {
                    data = stroke.data.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
                    metrics.record(\.assetCopiedBytes, data.count)
                    digest = metrics.assetDigest(data)
                }
                if let existing = assets[digest] {
                    guard existing == data else {
                        throw NotebookRepositoryError.invalidContent("Recovery archive references conflict.")
                    }
                } else { assets[digest] = data }
                var uuid = stroke.id.uuid
                append(withUnsafeBytes(of: &uuid) { Data($0) })
                append(Data(digest.utf8))
                strokes.append(NotebookStroke(id: stroke.id, data: assets[digest]!, validatedDigest: digest))
            }
            edits.append(NotebookRecoveryStrokeEdit(
                id: edit.id, strokes: strokes, title: edit.title, pageCount: edit.pageCount,
                stamp: edit.stamp, recoverySource: edit.recoverySource
            ))
        }
        metrics.record(\.metadataHashCalls)
        metrics.record(\.metadataHashBytes, hashedBytes)
        return Captured(
            batch: NotebookRecoveryStrokeBatch(
                notebookID: batch.notebookID, baseRevisionID: batch.baseRevisionID, edits: edits
            ),
            assets: assets,
            fingerprint: Self(value: NotebookDigest.lowercaseHex(hasher.finalize()), metrics: metrics.snapshot())
        )
    }

    static func validateMetadata(
        title: String, pageCount: Int, stamp: NotebookEditStamp, strokeCount: Int,
        source: NotebookRecoveryProvenance?, notebookID: UUID
    ) throws {
        guard title.utf8.count <= 4_096, strokeCount <= 20_000 else {
            throw NotebookRepositoryError.sizeLimitExceeded("Recovery edit metadata exceeds supported bounds.")
        }
        guard (1...12).contains(pageCount), strokeCount >= 0 else {
            throw NotebookRepositoryError.invalidContent("Recovery edit metadata is invalid.")
        }
        try NotebookRevisionFormat.validateStamp(stamp)
        if let source {
            guard source.notebookID == notebookID else {
                throw NotebookRepositoryError.invalidContent("The recovery source belongs to another notebook.")
            }
            try NotebookRevisionFormat.validateStamp(source.originalStamp)
        }
    }
}
