import CryptoKit
import Foundation
import NottyCore
import PencilKit

struct NotebookDrawingSnapshot: Sendable, Equatable {
    let drawing: PKDrawing
    let pageCount: Int
    let title: String
    let identity: UUID
    let recoverySource: NotebookRecoveryProvenance?

    init(
        drawing: PKDrawing, pageCount: Int, title: String, identity: UUID = UUID(),
        recoverySource: NotebookRecoveryProvenance? = nil
    ) {
        self.drawing = drawing
        self.pageCount = pageCount
        self.title = title
        self.identity = identity
        self.recoverySource = recoverySource
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity == rhs.identity && lhs.pageCount == rhs.pageCount && lhs.title == rhs.title
            && lhs.recoverySource == rhs.recoverySource
    }
}

struct NotebookRecoveryFingerprint: Sendable, Equatable {
    struct Edit: Sendable, Equatable {
        let id: UUID
        let archiveDigest: Data
        let strokeIDs: [UUID]
        let title: String
        let pageCount: Int
        let stamp: NotebookEditStamp
        let recoverySource: NotebookRecoveryProvenance?
    }

    let notebookID: UUID
    let baseRevisionID: UUID?
    let edits: [Edit]
}

struct NotebookEncodedRecoveryStates: Sendable {
    let strokeBatch: NotebookRecoveryStrokeBatch
    let fingerprint: NotebookRecoveryStateFingerprint
}

actor NotebookRecoveryCodec {
    private let stateCodec = InkCodec(profile: .recovery)
    private(set) var legacySerializedDrawingCount = 0
    private(set) var legacyHashedArchiveBytes = 0

    static let maximumEditCount = 32
    static let maximumStrokeCount = 20_000
    static let maximumArchiveBytes = 128 * 1_024 * 1_024
    static let maximumBatchBytes = 512 * 1_024 * 1_024

    func encode(
        notebookID: UUID,
        baseRevisionID: UUID?,
        edits: [NotebookPendingEdit<NotebookDrawingSnapshot>]
    ) throws -> NotebookRecoveryBatch {
        try validateMetadata(edits, notebookID: notebookID)
        var archived: [NotebookRecoveryEdit] = []
        var totalBytes = 0
        for edit in edits {
            let snapshot = edit.snapshot
            let identities = snapshot.drawing.strokes.map(\.id)
            let data = snapshot.drawing.dataRepresentation()
            legacySerializedDrawingCount += 1
            guard data.count <= Self.maximumArchiveBytes,
                  data.count <= Self.maximumBatchBytes - totalBytes else {
                throw NotebookSaveFailure.contentLimit
            }
            totalBytes += data.count
            archived.append(NotebookRecoveryEdit(
                id: edit.id, drawingData: data, strokeIDs: identities,
                title: snapshot.title, pageCount: snapshot.pageCount, stamp: edit.stamp,
                recoverySource: snapshot.recoverySource
            ))
        }
        return NotebookRecoveryBatch(
            notebookID: notebookID, baseRevisionID: baseRevisionID, edits: archived
        )
    }

    func fingerprint(_ batch: NotebookRecoveryBatch) -> NotebookRecoveryFingerprint {
        legacyHashedArchiveBytes += batch.edits.reduce(0) { $0 + $1.drawingData.count }
        return NotebookRecoveryFingerprint(
            notebookID: batch.notebookID,
            baseRevisionID: batch.baseRevisionID,
            edits: batch.edits.map { edit in
                NotebookRecoveryFingerprint.Edit(
                    id: edit.id,
                    archiveDigest: Data(SHA256.hash(data: edit.drawingData)),
                    strokeIDs: edit.strokeIDs, title: edit.title,
                    pageCount: edit.pageCount, stamp: edit.stamp,
                    recoverySource: edit.recoverySource
                )
            }
        )
    }

    func encodeStates(
        notebookID: UUID,
        baseRevisionID: UUID?,
        edits: [NotebookPendingEdit<NotebookDrawingSnapshot>]
    ) async throws -> NotebookEncodedRecoveryStates {
        try validateMetadata(edits, notebookID: notebookID)
        var states: [NotebookRecoveryStrokeEdit] = []
        states.reserveCapacity(edits.count)
        var totalBytes = 0
        for edit in edits {
            let snapshot = edit.snapshot
            let strokes = try await stateCodec.encode(snapshot.drawing)
            let bytes = strokes.reduce(0) { $0 + $1.data.count }
            guard bytes <= Self.maximumBatchBytes - totalBytes else {
                throw NotebookSaveFailure.contentLimit
            }
            totalBytes += bytes
            states.append(NotebookRecoveryStrokeEdit(
                id: edit.id, strokes: strokes, title: snapshot.title,
                pageCount: snapshot.pageCount, stamp: edit.stamp,
                recoverySource: snapshot.recoverySource
            ))
        }
        let batch = NotebookRecoveryStrokeBatch(
            notebookID: notebookID, baseRevisionID: baseRevisionID, edits: states
        )
        return NotebookEncodedRecoveryStates(
            strokeBatch: batch,
            fingerprint: try NotebookRecoveryStateFingerprint(validating: batch)
        )
    }

    private func validateMetadata(
        _ edits: [NotebookPendingEdit<NotebookDrawingSnapshot>], notebookID: UUID
    ) throws {
        guard !edits.isEmpty, Set(edits.map(\.id)).count == edits.count else {
            throw NotebookSaveFailure.invalidContent
        }
        guard edits.count <= Self.maximumEditCount else {
            throw NotebookSaveFailure.contentLimit
        }
        for edit in edits {
            let snapshot = edit.snapshot
            guard snapshot.drawing.strokes.count <= Self.maximumStrokeCount,
                  snapshot.title.utf8.count <= 4 * 1_024 else {
                throw NotebookSaveFailure.contentLimit
            }
            guard (1...12).contains(snapshot.pageCount),
                  Set(snapshot.drawing.strokes.map(\.id)).count == snapshot.drawing.strokes.count,
                  validStamp(edit.stamp) else {
                throw NotebookSaveFailure.invalidContent
            }
            if let source = snapshot.recoverySource {
                guard source.notebookID == notebookID, validStamp(source.originalStamp) else {
                    throw NotebookSaveFailure.invalidContent
                }
            }
        }
    }

    private func validStamp(_ stamp: NotebookEditStamp) -> Bool {
        stamp.capturedAt.timeIntervalSinceReferenceDate.isFinite
            && stamp.uptime.isFinite && stamp.uptime >= 0
    }

    func decodeSelected(_ recovered: NotebookRecoveredEdit) async throws -> PKDrawing {
        let drawing = try await stateCodec.decode(recovered.state.strokes)
        guard drawing.strokes.map(\.id) == recovered.state.strokes.map(\.id) else {
            throw NotebookSaveFailure.corruptData
        }
        return drawing
    }

    func stateWorkMetrics() async -> InkCodec.WorkMetrics {
        await stateCodec.workMetrics
    }

    func decode(_ edit: NotebookRecoveryEdit) throws -> PKDrawing {
        guard edit.strokeIDs.count <= Self.maximumStrokeCount,
              edit.drawingData.count <= Self.maximumArchiveBytes,
              Set(edit.strokeIDs).count == edit.strokeIDs.count else {
            throw NotebookSaveFailure.corruptData
        }
        let drawing = try PKDrawing(data: edit.drawingData)
        guard drawing.strokes.count == edit.strokeIDs.count else {
            throw NotebookSaveFailure.corruptData
        }
        let strokes = zip(drawing.strokes, edit.strokeIDs).map { source, identity in
            var stroke = source
            stroke.id = identity
            return stroke
        }
        let restored = PKDrawing(strokes: strokes)
        guard restored.strokes.map(\.id) == edit.strokeIDs else {
            throw NotebookSaveFailure.corruptData
        }
        return restored
    }
}
