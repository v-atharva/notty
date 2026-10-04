import Foundation

public struct NotebookRecoveryWorkMetrics: Sendable, Equatable {
    public internal(set) var assetCopiedBytes = 0
    public internal(set) var inputReferenceVisits = 0
    public internal(set) var assetHashCalls = 0
    public internal(set) var assetHashBytes = 0
    public internal(set) var assetReadCalls = 0
    public internal(set) var assetReadBytes = 0
    public internal(set) var assetWriteCalls = 0
    public internal(set) var assetWrittenBytes = 0
    public internal(set) var metadataHashCalls = 0
    public internal(set) var metadataHashBytes = 0
    public internal(set) var metadataReadCalls = 0
    public internal(set) var metadataReadBytes = 0
    public internal(set) var metadataWriteCalls = 0
    public internal(set) var metadataWrittenBytes = 0
    public internal(set) var metadataEncodeCalls = 0
    public internal(set) var metadataEncodedBytes = 0
    public internal(set) var nativeArchiveValidations = 0
    public internal(set) var nativeStateValidations = 0
    public internal(set) var nativeArchiveSerializations = 0
    public internal(set) var nativeSerializedBytes = 0
    public internal(set) var publications = 0

    public var totalHashBytes: Int { assetHashBytes + metadataHashBytes }
    public var totalReadBytes: Int { assetReadBytes + metadataReadBytes }
    public var totalWrittenBytes: Int { assetWrittenBytes + metadataWrittenBytes }
}

final class NotebookRecoveryMetricsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = NotebookRecoveryWorkMetrics()
    private let parent: NotebookRecoveryMetricsRecorder?

    init(parent: NotebookRecoveryMetricsRecorder? = nil) { self.parent = parent }

    func record(_ key: WritableKeyPath<NotebookRecoveryWorkMetrics, Int>, _ amount: Int = 1) {
        lock.lock()
        value[keyPath: key] += amount
        lock.unlock()
        parent?.record(key, amount)
    }

    func snapshot() -> NotebookRecoveryWorkMetrics {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func assetDigest(_ data: Data) -> String {
        record(\.assetHashCalls)
        record(\.assetHashBytes, data.count)
        return NotebookDigest.sha256(data)
    }

    func metadataDigest(_ data: Data) -> String {
        record(\.metadataHashCalls)
        record(\.metadataHashBytes, data.count)
        return NotebookDigest.sha256(data)
    }
}
