import Foundation
import Darwin

public enum NotebookSaveFailure: Error, Sendable, Equatable {
    case contentLimit
    case revisionConflict
    case corruptData
    case unsupportedFormat
    case unsafeStorage
    case storageFull
    case storageUnavailable
    case invalidContent
    case unexpected

    public var canRetry: Bool {
        self == .storageFull || self == .storageUnavailable
    }

    public var title: String {
        switch self {
        case .contentLimit: "Notebook save limit reached"
        case .revisionConflict: "Saved notebook changed"
        case .corruptData: "Saved data needs recovery"
        case .unsupportedFormat: "Notebook format unavailable"
        case .unsafeStorage: "Storage location needs attention"
        case .storageFull: "Storage is full"
        case .storageUnavailable: "Storage is unavailable"
        case .invalidContent: "Changes need a recovery copy"
        case .unexpected: "Couldn't save changes"
        }
    }

    public var message: String {
        switch self {
        case .contentLimit:
            "These changes exceed the current notebook save limit. Preserve a recovery copy before reopening saved work."
        case .revisionConflict:
            "The saved notebook has a different revision. Preserve your waiting edits before reopening it."
        case .corruptData:
            "The saved files could not be verified. Your waiting edits remain here; preserve a recovery copy."
        case .unsupportedFormat:
            "This version cannot read the saved format. Preserve your waiting edits before opening it in a compatible version."
        case .unsafeStorage:
            "The storage path cannot be used safely. Preserve a copy in the recovery location before checking the saved files."
        case .storageFull:
            "Free some device storage, then retry. Your waiting edits remain here. A recovery copy also needs free space."
        case .storageUnavailable:
            "Unlock the device or restore access to its storage, then retry. Your waiting edits remain here."
        case .invalidContent:
            "These changes cannot be written to the notebook safely. Preserve a recovery copy before reopening saved work."
        case .unexpected:
            "Your waiting edits remain here. Preserve a recovery copy before reopening saved work."
        }
    }

    public static func classify(_ error: any Error) -> Self {
        if let failure = error as? Self { return failure }
        if let error = error as? NotebookRepositoryError {
            switch error {
            case .sizeLimitExceeded: return .contentLimit
            case .revisionConflict: return .revisionConflict
            case .corruptData, .recoveryRequired: return .corruptData
            case .unsupportedVersion: return .unsupportedFormat
            case .unsafePath: return .unsafeStorage
            case .invalidContent: return .invalidContent
            case .ioFailure(let code): return classifyPOSIX(code)
            }
        }
        if let error = error as? InkCodec.CodecError {
            switch error {
            case .tooManyStrokes, .oversizedStrokeArchive, .oversizedDrawingArchive:
                return .contentLimit
            case .invalidSingleStrokeArchive, .invalidRestoredStrokeIdentity: return .corruptData
            case .duplicateStrokeID, .invalidMaskGeometry: return .invalidContent
            }
        }
        return classifyNSError(error as NSError, depth: 0)
    }

    private static func classifyPOSIX(_ code: Int32) -> Self {
        switch code {
        case ENOSPC, EDQUOT: .storageFull
        case ELOOP: .unsafeStorage
        case EROFS, EACCES, EPERM, EIO, EINTR, EAGAIN, EBUSY, ENFILE, EMFILE,
             ENOENT, ENOTDIR, ENODEV: .storageUnavailable
        default: .unexpected
        }
    }

    private static func classifyNSError(_ error: NSError, depth: Int) -> Self {
        guard depth < 8 else { return .unexpected }
        if error.domain == NSPOSIXErrorDomain {
            return classifyPOSIX(Int32(clamping: error.code))
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            let cause = classifyNSError(underlying, depth: depth + 1)
            if cause != .unexpected { return cause }
        }
        guard error.domain == NSCocoaErrorDomain else { return .unexpected }
        switch error.code {
        case CocoaError.fileWriteOutOfSpace.rawValue: return .storageFull
        case CocoaError.fileReadCorruptFile.rawValue: return .corruptData
        case CocoaError.fileReadNoPermission.rawValue,
             CocoaError.fileWriteNoPermission.rawValue,
             CocoaError.fileWriteVolumeReadOnly.rawValue,
             CocoaError.fileReadNoSuchFile.rawValue,
             CocoaError.fileNoSuchFile.rawValue: return .storageUnavailable
        default: return .unexpected
        }
    }
}
