import Foundation

struct NotebookHistoryWriter {
    typealias Format = NotebookRevisionFormat

    let notebookID: UUID
    let generationID: UUID
    let generation: URL
    let writeFault: (@Sendable (NotebookWriteStage) throws -> Void)?
    let migrationFault: (@Sendable (NotebookMigrationStage) throws -> Void)?

    func append(
        state: Format.State, previous: Format.State, parent: Format.Head?,
        revisionID: UUID, sequence: Int, stamp: NotebookEditStamp?, savedAt: Date, credit: Int
    ) throws -> (head: Format.Head, credit: Int) {
        let delta = try Format.delta(from: previous, to: state)
        let checkpoint = Format.Checkpoint(
            schemaVersion: 2, notebookID: notebookID, revisionID: revisionID, sequence: sequence, state: state
        )
        let checkpointData = try Format.encode(checkpoint)
        func event(_ digest: String?) -> Format.Event {
            Format.Event(
                schemaVersion: 2, notebookID: notebookID, revisionID: revisionID,
                parentRevisionID: parent?.revisionID, parentDigest: parent?.revisionDigest,
                sequence: sequence, delta: delta, editStamp: stamp, savedAt: savedAt, checkpointDigest: digest
            )
        }
        let plain = try Format.encode(event(nil))
        let (available, overflow) = credit.addingReportingOverflow(plain.count)
        guard !overflow else {
            throw NotebookRepositoryError.sizeLimitExceeded("History byte accounting exceeds supported bounds.")
        }
        let shouldCheckpoint = sequence == 1 || available >= checkpointData.count
        let checkpointDigest = shouldCheckpoint ? Format.digest(checkpointData) : nil
        if let checkpointDigest {
            let checkpoints = generation.appendingPathComponent("checkpoints", isDirectory: true)
            try NotebookFileSystem.ensureDirectory(checkpoints)
            let destination = checkpoints.appendingPathComponent("\(checkpointDigest).json")
            if try NotebookFileSystem.kind(destination) != nil {
                let existing = try NotebookFileSystem.read(
                    destination, maximumBytes: NotebookRepository.maximumMetadataBytes
                )
                guard existing == checkpointData else {
                    throw NotebookRepositoryError.corruptData("An immutable checkpoint has different bytes.")
                }
            } else {
                try NotebookFileSystem.withSynchronizedStage(checkpointData, in: checkpoints) {
                    try NotebookFileSystem.publishImmutable($0, to: destination)
                }
            }
            try migrationFault?(.checkpointPublished)
        }
        let data = try Format.encode(event(checkpointDigest))
        let events = generation.appendingPathComponent("events", isDirectory: true)
        try NotebookFileSystem.ensureDirectory(events)
        try NotebookFileSystem.withSynchronizedStage(data, in: events) { stage in
            try writeFault?(.revisionStaged)
            try NotebookFileSystem.publishImmutable(
                stage, to: events.appendingPathComponent("\(revisionID.uuidString.lowercased()).json")
            )
            try writeFault?(.revisionPublished)
            try migrationFault?(.eventPublished)
        }
        let (newCredit, finalOverflow) = credit.addingReportingOverflow(data.count)
        guard !finalOverflow else {
            throw NotebookRepositoryError.sizeLimitExceeded("History byte accounting exceeds supported bounds.")
        }
        return (
            Format.Head(
                schemaVersion: 2, notebookID: notebookID, revisionID: revisionID,
                revisionDigest: Format.digest(data), generationID: generationID,
                migrationReceiptDigest: parent?.migrationReceiptDigest
            ),
            shouldCheckpoint ? 0 : newCredit
        )
    }
}
