import CryptoKit
import Foundation
import NottyCore
import PencilKit

struct NotebookDrawingSnapshot: Sendable, Equatable {
    let drawing: PKDrawing
    let pageCount: Int
    let title: String
}

struct NotebookRecoveryFingerprint: Sendable, Equatable {
    struct Edit: Sendable, Equatable {
        let id: UUID
        let archiveDigest: Data
        let strokeIDs: [UUID]
        let title: String
        let pageCount: Int
        let stamp: NotebookEditStamp
    }

    let notebookID: UUID
    let baseRevisionID: UUID?
    let edits: [Edit]
}

actor NotebookRecoveryCodec {
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
                title: snapshot.title, pageCount: snapshot.pageCount, stamp: edit.stamp
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
                    pageCount: edit.pageCount, stamp: edit.stamp
                )
            }
        )
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
