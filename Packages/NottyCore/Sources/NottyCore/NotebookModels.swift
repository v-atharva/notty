import Foundation

public struct NotebookStroke: Sendable, Equatable {
    public let id: UUID
    public let data: Data
    let cachedDigest: String?

    public init(id: UUID, data: Data) {
        self.id = id
        self.data = data
        self.cachedDigest = nil
    }

    init(id: UUID, data: Data, validatedDigest: String) {
        self.id = id
        self.data = data
        self.cachedDigest = validatedDigest
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.data == rhs.data
    }
}

public struct NotebookEditStamp: Codable, Sendable, Equatable {
    public let capturedAt: Date
    public let uptime: TimeInterval
    public let sessionID: UUID

    public init(capturedAt: Date, uptime: TimeInterval, sessionID: UUID) {
        self.capturedAt = capturedAt
        self.uptime = uptime
        self.sessionID = sessionID
    }
}

public struct NotebookContent: Sendable, Equatable {
    public let title: String
    public let pageCount: Int
    public let strokes: [NotebookStroke]
    public let editStamp: NotebookEditStamp?

    public init(
        title: String,
        pageCount: Int,
        strokes: [NotebookStroke],
        editStamp: NotebookEditStamp? = nil
    ) {
        self.title = title
        self.pageCount = pageCount
        self.strokes = strokes
        self.editStamp = editStamp
    }
}

public struct StoredNotebook: Sendable {
    public let id: UUID
    public let revisionID: UUID
    public let sequence: Int
    public let content: NotebookContent
    public let savedAt: Date

    public init(
        id: UUID,
        revisionID: UUID,
        sequence: Int,
        content: NotebookContent,
        savedAt: Date
    ) {
        self.id = id
        self.revisionID = revisionID
        self.sequence = sequence
        self.content = content
        self.savedAt = savedAt
    }
}

public enum NotebookRepositoryError: Error, Sendable, Equatable, LocalizedError {
    case invalidContent(String)
    case corruptData(String)
    case unsupportedVersion(Int)
    case revisionConflict
    case recoveryRequired
    case unsafePath(String)
    case sizeLimitExceeded(String)
    case ioFailure(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidContent(let reason), .corruptData(let reason),
             .unsafePath(let reason), .sizeLimitExceeded(let reason):
            reason
        case .unsupportedVersion(let version):
            "Unsupported notebook format version: \(version)."
        case .revisionConflict:
            "The notebook changed since it was loaded."
        case .recoveryRequired:
            "The notebook needs recovery before it can be opened."
        case .ioFailure(let code):
            "Notebook storage failed with system error \(code)."
        }
    }
}

/// Publication stages available for recovery testing.
public enum NotebookWriteStage: Sendable, Equatable, CaseIterable {
    case assetStaged
    case assetPublished
    case revisionStaged
    case revisionPublished
    case headStaged
    case beforeHeadPublication
    case beforeNotebookPublication
}

public struct NotebookRevisionSummary: Sendable, Equatable {
    public let notebookID: UUID
    public let revisionID: UUID
    public let sequence: Int
    public let title: String
    public let pageCount: Int
    public let strokeCount: Int
    public let editStamp: NotebookEditStamp?
    public let savedAt: Date

    public init(
        notebookID: UUID, revisionID: UUID, sequence: Int, title: String,
        pageCount: Int, strokeCount: Int, editStamp: NotebookEditStamp?, savedAt: Date
    ) {
        self.notebookID = notebookID
        self.revisionID = revisionID
        self.sequence = sequence
        self.title = title
        self.pageCount = pageCount
        self.strokeCount = strokeCount
        self.editStamp = editStamp
        self.savedAt = savedAt
    }
}

public struct NotebookHistoryAudit: Sendable, Equatable {
    public let notebookID: UUID
    public let headRevisionID: UUID
    public let revisionCount: Int
    public let verifiedAssetCount: Int

    public init(notebookID: UUID, headRevisionID: UUID, revisionCount: Int, verifiedAssetCount: Int) {
        self.notebookID = notebookID
        self.headRevisionID = headRevisionID
        self.revisionCount = revisionCount
        self.verifiedAssetCount = verifiedAssetCount
    }
}

public struct NotebookMigrationReceipt: Codable, Sendable, Equatable {
    public let notebookID: UUID
    public let revisionID: UUID
    public let generationID: UUID
    public let revisionCount: Int

    public init(notebookID: UUID, revisionID: UUID, generationID: UUID, revisionCount: Int) {
        self.notebookID = notebookID
        self.revisionID = revisionID
        self.generationID = generationID
        self.revisionCount = revisionCount
    }
}

public enum NotebookMigrationStage: Sendable, Equatable, CaseIterable {
    case legacyHeadPreserved
    case eventPublished
    case checkpointPublished
    case generationValidated
    case beforeGenerationPublication
    case generationPublished
    case headStaged
    case beforeHeadPublication
}
