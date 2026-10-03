import Foundation

struct NotebookHistoryWriter {
    typealias Format = NotebookRevisionFormat

    struct Prepared {
        let head: Format.Head
        let credit: Int
        let eventData: Data
        let checkpointData: Data?
        let checkpointDigest: String?
    }

    let notebookID: UUID
    let generationID: UUID
    let generation: URL
    let writeFault: (@Sendable (NotebookWriteStage) throws -> Void)?
    let migrationFault: (@Sendable (NotebookMigrationStage) throws -> Void)?
    var metrics: NotebookStorageMetricsRecorder? = nil

    func prepare(
        state: Format.State, previous: Format.State, parent: Format.Head?,
        revisionID: UUID, sequence: Int, stamp: NotebookEditStamp?, savedAt: Date, credit: Int,
        checkpointSize: Format.CheckpointSize
    ) throws -> Prepared {
        let delta = try Format.delta(from: previous, to: state, metrics: metrics)
        func event(_ digest: String?) -> Format.Event {
            Format.Event(
                schemaVersion: 2, notebookID: notebookID, revisionID: revisionID,
                parentRevisionID: parent?.revisionID, parentDigest: parent?.revisionDigest,
                sequence: sequence, delta: delta, editStamp: stamp, savedAt: savedAt, checkpointDigest: digest
            )
        }
        let plain = try Format.encode(event(nil), metrics: metrics)
        let (available, overflow) = credit.addingReportingOverflow(plain.count)
        guard !overflow else {
            throw NotebookRepositoryError.sizeLimitExceeded("History byte accounting exceeds supported bounds.")
        }
        let estimatedBytes = try checkpointSize.bytes(
            strokeCount: state.strokes.count, pageCount: state.pageCount, sequence: sequence
        )
        let shouldCheckpoint = sequence == 1 || available >= estimatedBytes
        let checkpointData: Data?
        let checkpointDigest: String?
        if shouldCheckpoint {
            metrics?.record(\.checkpointEncodings)
            let data = try Format.encode(Format.Checkpoint(
                schemaVersion: 2, notebookID: notebookID, revisionID: revisionID, sequence: sequence, state: state
            ), metrics: metrics)
            guard data.count == estimatedBytes, sequence == 1 || available >= data.count else {
                throw NotebookRepositoryError.invalidContent("Checkpoint byte accounting differs from its encoded size.")
            }
            checkpointData = data
            checkpointDigest = Format.digest(data, metrics: metrics)
        } else {
            checkpointData = nil
            checkpointDigest = nil
        }
        let data = try checkpointDigest.map { try Format.encode(event($0), metrics: metrics) } ?? plain
        let (newCredit, finalOverflow) = credit.addingReportingOverflow(data.count)
        guard !finalOverflow else {
            throw NotebookRepositoryError.sizeLimitExceeded("History byte accounting exceeds supported bounds.")
        }
        return Prepared(
            head: Format.Head(
                schemaVersion: 2, notebookID: notebookID, revisionID: revisionID,
                revisionDigest: Format.digest(data, metrics: metrics), generationID: generationID,
                migrationReceiptDigest: parent?.migrationReceiptDigest
            ),
            credit: shouldCheckpoint ? 0 : newCredit, eventData: data,
            checkpointData: checkpointData, checkpointDigest: checkpointDigest
        )
    }

    func publish(_ prepared: Prepared) throws {
        if let data = prepared.checkpointData, let digest = prepared.checkpointDigest {
            let checkpoints = generation.appendingPathComponent("checkpoints", isDirectory: true)
            try NotebookFileSystem.ensureDirectory(checkpoints)
            let destination = checkpoints.appendingPathComponent("\(digest).json")
            if try NotebookFileSystem.kind(destination) != nil {
                let existing = try NotebookFileSystem.read(
                    destination, maximumBytes: NotebookRepository.maximumMetadataBytes
                )
                metrics?.record(\.metadataReadCalls)
                metrics?.record(\.metadataReadBytes, existing.count)
                guard existing == data else {
                    throw NotebookRepositoryError.corruptData("An immutable checkpoint has different bytes.")
                }
            } else {
                try NotebookFileSystem.withSynchronizedStage(data, in: checkpoints) { stage in
                    metrics?.record(\.metadataWrittenBytes, data.count)
                    metrics?.record(\.checkpointWrittenBytes, data.count)
                    try NotebookFileSystem.publishImmutable(stage, to: destination)
                    metrics?.record(\.checkpointPublications)
                }
            }
            try migrationFault?(.checkpointPublished)
        }
        let events = generation.appendingPathComponent("events", isDirectory: true)
        try NotebookFileSystem.ensureDirectory(events)
        try NotebookFileSystem.withSynchronizedStage(prepared.eventData, in: events) { stage in
            metrics?.record(\.metadataWrittenBytes, prepared.eventData.count)
            try writeFault?(.revisionStaged)
            try NotebookFileSystem.publishImmutable(
                stage, to: events.appendingPathComponent("\(prepared.head.revisionID.uuidString.lowercased()).json")
            )
            try writeFault?(.revisionPublished)
            try migrationFault?(.eventPublished)
        }
    }

    func append(
        state: Format.State, previous: Format.State, parent: Format.Head?,
        revisionID: UUID, sequence: Int, stamp: NotebookEditStamp?, savedAt: Date, credit: Int
    ) throws -> (head: Format.Head, credit: Int) {
        let prepared = try prepare(
            state: state, previous: previous, parent: parent, revisionID: revisionID,
            sequence: sequence, stamp: stamp, savedAt: savedAt, credit: credit,
            checkpointSize: Format.CheckpointSize(title: state.title, metrics: metrics)
        )
        try publish(prepared)
        return (prepared.head, prepared.credit)
    }
}
