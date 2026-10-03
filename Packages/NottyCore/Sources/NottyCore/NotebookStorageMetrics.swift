import Foundation

public struct NotebookStorageMetrics: Sendable, Equatable {
    public internal(set) var assetCopiedBytes = 0
    /// Full input visits during bounds validation, ownership and archive preparation.
    public internal(set) var inputReferenceVisits = 0
    public internal(set) var assetHashCalls = 0
    public internal(set) var assetHashBytes = 0
    public internal(set) var metadataHashCalls = 0
    public internal(set) var metadataHashBytes = 0
    public internal(set) var assetReadCalls = 0
    public internal(set) var assetReadBytes = 0
    public internal(set) var metadataReadCalls = 0
    public internal(set) var metadataReadBytes = 0
    public internal(set) var assetWrittenBytes = 0
    public internal(set) var metadataWrittenBytes = 0
    public internal(set) var metadataEncodeCalls = 0
    public internal(set) var metadataEncodedBytes = 0
    public internal(set) var headPublications = 0
    public internal(set) var checkpointEncodings = 0
    public internal(set) var checkpointPublications = 0
    public internal(set) var checkpointWrittenBytes = 0
    /// Reference classifications performed while constructing history deltas.
    public internal(set) var referenceComparisons = 0

    public var totalHashBytes: Int { assetHashBytes + metadataHashBytes }
    public var totalReadBytes: Int { assetReadBytes + metadataReadBytes }
    public var totalWrittenBytes: Int { assetWrittenBytes + metadataWrittenBytes }
}

final class NotebookStorageMetricsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = NotebookStorageMetrics()
    private let parent: NotebookStorageMetricsRecorder?

    init(parent: NotebookStorageMetricsRecorder? = nil) {
        self.parent = parent
    }

    func record(_ key: WritableKeyPath<NotebookStorageMetrics, Int>, _ amount: Int = 1) {
        lock.lock()
        value[keyPath: key] += amount
        lock.unlock()
        parent?.record(key, amount)
    }

    func snapshot() -> NotebookStorageMetrics {
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
