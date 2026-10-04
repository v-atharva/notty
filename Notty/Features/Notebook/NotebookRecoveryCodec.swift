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

    static let maximumEditCount = 32
    static let maximumStrokeCount = 20_000
    static let maximumArchiveBytes = 128 * 1_024 * 1_024
    static let maximumBatchBytes = 512 * 1_024 * 1_024

    func encode(
        notebookID: UUID,
        baseRevisionID: UUID?,
        edits: [NotebookPendingEdit<NotebookDrawingSnapshot>]
    ) throws -> NotebookRecoveryBatch {
        guard !edits.isEmpty, edits.count <= Self.maximumEditCount else {
            throw NotebookSaveFailure.contentLimit
        }
        var archived: [NotebookRecoveryEdit] = []
        var totalBytes = 0
        for edit in edits {
            let snapshot = edit.snapshot
            guard snapshot.drawing.strokes.count <= Self.maximumStrokeCount else {
                throw NotebookSaveFailure.contentLimit
            }
            let identities = snapshot.drawing.strokes.map(\.id)
            guard Set(identities).count == identities.count,
                  snapshot.pageCount > 0,
                  snapshot.title.utf8.count <= 4 * 1_024 else {
                throw NotebookSaveFailure.contentLimit
            }
            let data = snapshot.drawing.dataRepresentation()
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
        NotebookRecoveryFingerprint(
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
        guard !edits.isEmpty, edits.count <= Self.maximumEditCount,
              Set(edits.map(\.id)).count == edits.count else {
            throw NotebookSaveFailure.contentLimit
        }
        for edit in edits {
            let snapshot = edit.snapshot
            guard snapshot.drawing.strokes.count <= Self.maximumStrokeCount,
                  (1...12).contains(snapshot.pageCount),
                  snapshot.title.utf8.count <= 4 * 1_024 else {
                throw NotebookSaveFailure.contentLimit
            }
        }
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
