import Foundation

public struct NotebookRecoveryEdit: Sendable, Equatable {
    public let id: UUID
    public let drawingData: Data
    public let strokeIDs: [UUID]
    public let title: String
    public let pageCount: Int
    public let stamp: NotebookEditStamp

    public init(
        id: UUID,
        drawingData: Data,
        strokeIDs: [UUID],
        title: String,
        pageCount: Int,
        stamp: NotebookEditStamp
    ) {
        self.id = id
        self.drawingData = drawingData
        self.strokeIDs = strokeIDs
        self.title = title
        self.pageCount = pageCount
        self.stamp = stamp
    }
}

public struct NotebookRecoveryBatch: Sendable, Equatable {
    public let notebookID: UUID
    public let baseRevisionID: UUID?
    public let edits: [NotebookRecoveryEdit]

    public init(notebookID: UUID, baseRevisionID: UUID?, edits: [NotebookRecoveryEdit]) {
        self.notebookID = notebookID
        self.baseRevisionID = baseRevisionID
        self.edits = edits
    }
}

public struct NotebookRecoveryReceipt: Sendable, Equatable {
    public let id: UUID
    public let notebookID: UUID
    public let editCount: Int
    public let savedAt: Date

    public init(id: UUID, notebookID: UUID, editCount: Int, savedAt: Date) {
        self.id = id
        self.notebookID = notebookID
        self.editCount = editCount
        self.savedAt = savedAt
    }
}

public struct NotebookRecoveryScan: Sendable, Equatable {
    public let copies: [NotebookRecoveryReceipt]
    public let unavailableCopyIDs: [UUID]

    public init(copies: [NotebookRecoveryReceipt], unavailableCopyIDs: [UUID]) {
        self.copies = copies
        self.unavailableCopyIDs = unavailableCopyIDs
    }
}

public enum NotebookRecoveryWriteStage: Sendable, Equatable, CaseIterable {
    case archiveSynchronized
    case manifestSynchronized
    case receiptSynchronized
    case beforePublication
    case identitiesSynchronized
}
