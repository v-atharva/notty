import Foundation

public struct NotebookRecoveryEdit: Sendable, Equatable {
    public let id: UUID
    public let drawingData: Data
    public let strokeIDs: [UUID]
    public let title: String
    public let pageCount: Int
    public let stamp: NotebookEditStamp
    public let recoverySource: NotebookRecoveryProvenance?

    public init(
        id: UUID,
        drawingData: Data,
        strokeIDs: [UUID],
        title: String,
        pageCount: Int,
        stamp: NotebookEditStamp,
        recoverySource: NotebookRecoveryProvenance? = nil
    ) {
        self.id = id
        self.drawingData = drawingData
        self.strokeIDs = strokeIDs
        self.title = title
        self.pageCount = pageCount
        self.stamp = stamp
        self.recoverySource = recoverySource
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
    public let matchingIssues: [NotebookRecoveryScanIssue]
    public let unattributedIssues: [NotebookRecoveryScanIssue]

    public init(
        copies: [NotebookRecoveryReceipt], unavailableCopyIDs: [UUID],
        matchingIssues: [NotebookRecoveryScanIssue] = [],
        unattributedIssues: [NotebookRecoveryScanIssue] = []
    ) {
        self.copies = copies
        self.unavailableCopyIDs = unavailableCopyIDs
        self.matchingIssues = matchingIssues
        self.unattributedIssues = unattributedIssues
    }
}

public enum NotebookRecoveryWriteStage: Sendable, Equatable, CaseIterable {
    case archiveSynchronized
    case manifestSynchronized
    case receiptSynchronized
    case beforePublication
    case identitiesSynchronized
}

public struct NotebookRecoveryProvenance: Codable, Sendable, Equatable {
    public let notebookID: UUID
    public let copyID: UUID
    public let editID: UUID
    public let originalStamp: NotebookEditStamp
    public let baseRevisionID: UUID?

    public init(
        notebookID: UUID, copyID: UUID, editID: UUID,
        originalStamp: NotebookEditStamp, baseRevisionID: UUID? = nil
    ) {
        self.notebookID = notebookID
        self.copyID = copyID
        self.editID = editID
        self.originalStamp = originalStamp
        self.baseRevisionID = baseRevisionID
    }
}

public struct NotebookRecoveryStrokeEdit: Sendable, Equatable {
    public let id: UUID
    public let strokes: [NotebookStroke]
    public let title: String
    public let pageCount: Int
    public let stamp: NotebookEditStamp
    public let recoverySource: NotebookRecoveryProvenance?

    public init(
        id: UUID, strokes: [NotebookStroke], title: String, pageCount: Int,
        stamp: NotebookEditStamp, recoverySource: NotebookRecoveryProvenance? = nil
    ) {
        self.id = id
        self.strokes = strokes
        self.title = title
        self.pageCount = pageCount
        self.stamp = stamp
        self.recoverySource = recoverySource
    }
}

public struct NotebookRecoveryStrokeBatch: Sendable, Equatable {
    public let notebookID: UUID
    public let baseRevisionID: UUID?
    public let edits: [NotebookRecoveryStrokeEdit]

    public init(
        notebookID: UUID, baseRevisionID: UUID? = nil,
        edits: [NotebookRecoveryStrokeEdit]
    ) {
        self.notebookID = notebookID
        self.baseRevisionID = baseRevisionID
        self.edits = edits
    }
}

public struct NotebookRecoveredEdit: Sendable, Equatable {
    public let state: NotebookRecoveryStrokeEdit
    public let source: NotebookRecoveryProvenance

    init(state: NotebookRecoveryStrokeEdit, source: NotebookRecoveryProvenance) {
        self.state = state
        self.source = source
    }
}

public struct NotebookRecoveryEditSummary: Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let pageCount: Int
    public let strokeCount: Int
    public let stamp: NotebookEditStamp
    public let recoverySource: NotebookRecoveryProvenance?
}

public struct NotebookRecoveryCopyMetadata: Sendable, Equatable {
    public let receipt: NotebookRecoveryReceipt
    public let baseRevisionID: UUID?
    public let edits: [NotebookRecoveryEditSummary]
}

public enum NotebookRecoveryIssueKind: Sendable, Equatable {
    case damagedData
    case unsupportedVersion(Int)
    case unsafePath
    case ioFailure(Int32)
}

public struct NotebookRecoveryScanIssue: Sendable, Equatable {
    public let copyID: UUID
    public let kind: NotebookRecoveryIssueKind

    public init(copyID: UUID, kind: NotebookRecoveryIssueKind) {
        self.copyID = copyID
        self.kind = kind
    }
}
