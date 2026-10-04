import CryptoKit
import Foundation

struct NotebookHistoryMigration {
    typealias Format = NotebookRevisionFormat

    private struct Record: Codable {
        let schemaVersion: Int
        let receipt: NotebookMigrationReceipt
        let legacyHeadDigest: String
        let anchor: Format.Head
        let legacyChainDigest: String
    }

    let root: URL
    let history: NotebookHistory
    let fault: (@Sendable (NotebookMigrationStage) throws -> Void)?
    let maintenanceObserver: NotebookFileSystem.MaintenanceObserver

    func migrate(_ head: Format.Head) throws -> (Format.Head, NotebookMigrationReceipt) {
        if head.schemaVersion == 2 {
            let audit = try history.audit(head)
            return (head, try receipt(head, links: audit.links).record.receipt)
        }
        let oldHeadURL = history.directory.appendingPathComponent("HEAD.json")
        let oldHeadData = try history.readMetadata(oldHeadURL)
        guard try history.readHead() == head else { throw NotebookRepositoryError.revisionConflict }
        let links = try history.selectedLinks(head)
        _ = try history.audit(head, links: links)
        let generationID = UUID()
        let transaction = root.appendingPathComponent(".migration-\(UUID().uuidString.lowercased())", isDirectory: true)
        try NotebookFileSystem.ensureDirectory(transaction)
        defer {
            do {
                try NotebookFileSystem.removePrivateTransaction(
                    transaction, prefix: ".migration-", observer: maintenanceObserver
                )
            } catch {
                maintenanceObserver(.failed(NotebookFileSystem.maintenanceFailure(for: error)))
            }
        }
        let generation = transaction.appendingPathComponent("generation", isDirectory: true)
        try NotebookFileSystem.ensureDirectory(generation)
        try NotebookFileSystem.ensureDirectory(generation.appendingPathComponent("events", isDirectory: true))
        try NotebookFileSystem.ensureDirectory(generation.appendingPathComponent("checkpoints", isDirectory: true))
        try NotebookFileSystem.writeSynchronized(
            oldHeadData, to: generation.appendingPathComponent("legacy-head.json")
        )
        history.metrics?.record(\.metadataWrittenBytes, oldHeadData.count)
        try fault?(.legacyHeadPreserved)
        var parent: Format.Head?
        var previous = Format.State.empty
        var credit = 0
        let writer = NotebookHistoryWriter(
            notebookID: history.notebookID, generationID: generationID, generation: generation,
            writeFault: nil, migrationFault: fault, metrics: history.metrics
        )
        for link in links {
            let legacy = try history.readLegacy(link)
            let result = try writer.append(
                state: legacy.state, previous: previous, parent: parent,
                revisionID: legacy.revisionID, sequence: legacy.sequence,
                stamp: legacy.editStamp, savedAt: legacy.savedAt, credit: credit
            )
            parent = result.head
            credit = result.credit
            previous = legacy.state
        }
        guard let anchor = parent else {
            throw NotebookRepositoryError.corruptData("The selected legacy history is empty.")
        }
        // Validate the private generation before making it selectable.
        let stagedDirectory = transaction.appendingPathComponent("notebook", isDirectory: true)
        try NotebookFileSystem.ensureDirectory(stagedDirectory)
        let stagedHistory = stagedDirectory.appendingPathComponent("history", isDirectory: true)
        try NotebookFileSystem.ensureDirectory(stagedHistory)
        let stagedGeneration = stagedHistory.appendingPathComponent(
            generationID.uuidString.lowercased(), isDirectory: true
        )
        try NotebookFileSystem.publishImmutable(generation, to: stagedGeneration)
        let staged = NotebookHistory(
            directory: stagedDirectory, notebookID: history.notebookID, assetVerificationObserver: nil,
            assetDirectory: history.directory.appendingPathComponent("assets", isDirectory: true), metrics: history.metrics
        )
        var state = Format.State.empty
        for link in links {
            let legacy = try history.readLegacy(link)
            let eventURL = stagedGeneration.appendingPathComponent("events/\(link.revisionID.uuidString.lowercased()).json")
            let data = try staged.readMetadata(eventURL)
            let event: Format.Event = try Format.decode(data)
            state = try Format.apply(event.delta, to: state)
            guard state == legacy.state, event.revisionID == legacy.revisionID,
                  event.sequence == legacy.sequence, event.editStamp == legacy.editStamp,
                  event.savedAt == legacy.savedAt else {
                throw NotebookRepositoryError.corruptData("Migrated history differs from its retained legacy state.")
            }
            if let digest = event.checkpointDigest {
                guard try staged.readCheckpoint(digest, event: event, generation: stagedGeneration) == state else {
                    throw NotebookRepositoryError.corruptData("A migrated checkpoint differs from its event.")
                }
            }
        }
        // Asset verification uses the original immutable assets, never copied drawing snapshots.
        let stagedLinks = try staged.selectedLinks(anchor)
        guard stagedLinks.count == links.count else {
            throw NotebookRepositoryError.corruptData("The migrated history has a different event count.")
        }
        _ = try staged.audit(anchor, links: stagedLinks)
        try fault?(.generationValidated)
        let publicReceipt = NotebookMigrationReceipt(
            notebookID: history.notebookID, revisionID: anchor.revisionID,
            generationID: generationID, revisionCount: links.count
        )
        let record = Record(
            schemaVersion: 1, receipt: publicReceipt,
            legacyHeadDigest: Format.digest(oldHeadData, metrics: history.metrics), anchor: anchor,
            legacyChainDigest: chainDigest(links)
        )
        let recordData = try Format.encode(record, metrics: history.metrics)
        try NotebookFileSystem.writeSynchronized(
            recordData, to: stagedGeneration.appendingPathComponent("migration.json")
        )
        history.metrics?.record(\.metadataWrittenBytes, recordData.count)
        let selected = selectedHead(record, digest: Format.digest(recordData, metrics: history.metrics))
        let destinationRoot = history.directory.appendingPathComponent("history", isDirectory: true)
        try NotebookFileSystem.ensureDirectory(destinationRoot)
        let destination = destinationRoot.appendingPathComponent(
            generationID.uuidString.lowercased(), isDirectory: true
        )
        try fault?(.beforeGenerationPublication)
        try NotebookFileSystem.publishImmutable(stagedGeneration, to: destination)
        try fault?(.generationPublished)
        guard try history.readHead() == head,
              try history.readMetadata(oldHeadURL) == oldHeadData else {
            throw NotebookRepositoryError.revisionConflict
        }
        let selectedData = try Format.encode(selected, metrics: history.metrics)
        try NotebookFileSystem.withSynchronizedStage(
            selectedData, in: history.directory, head: true
        ) { stage in
            history.metrics?.record(\.metadataWrittenBytes, selectedData.count)
            try fault?(.headStaged)
            try fault?(.beforeHeadPublication)
            try NotebookFileSystem.replaceAtomically(stage, destination: oldHeadURL)
            history.metrics?.record(\.headPublications)
        }
        return (selected, publicReceipt)
    }

    func rollback(_ head: Format.Head) throws -> StoredNotebook {
        let audit = try history.audit(head)
        let stored = try receipt(head, links: audit.links)
        guard head == selectedHead(stored.record, digest: stored.digest) else {
            throw NotebookRepositoryError.revisionConflict
        }
        let legacy: Format.Head = try Format.decode(stored.legacyHeadData)
        guard legacy.schemaVersion == 1 else {
            throw NotebookRepositoryError.corruptData("The retained rollback HEAD is not legacy history.")
        }
        let legacyLinks = try history.selectedLinks(legacy)
        guard legacyLinks.count == stored.record.receipt.revisionCount,
              chainDigest(legacyLinks) == stored.record.legacyChainDigest else {
            throw NotebookRepositoryError.corruptData("Retained legacy history differs from the migration receipt.")
        }
        _ = try history.audit(legacy, links: legacyLinks)
        let current = try history.current(legacy)
        let strokes = try history.readAssets(current.state)
        guard try history.readHead() == head else { throw NotebookRepositoryError.revisionConflict }
        try NotebookFileSystem.withSynchronizedStage(
            stored.legacyHeadData, in: history.directory, head: true
        ) { stage in
            history.metrics?.record(\.metadataWrittenBytes, stored.legacyHeadData.count)
            try fault?(.headStaged)
            try fault?(.beforeHeadPublication)
            try NotebookFileSystem.replaceAtomically(
                stage, destination: history.directory.appendingPathComponent("HEAD.json")
            )
            history.metrics?.record(\.headPublications)
        }
        return StoredNotebook(
            id: history.notebookID, revisionID: current.revisionID, sequence: current.sequence,
            content: NotebookContent(
                title: current.state.title, pageCount: current.state.pageCount,
                strokes: strokes, editStamp: current.editStamp, recoverySource: current.recoverySource
            ),
            savedAt: current.savedAt
        )
    }

    func validateReceipt(_ head: Format.Head, links: [NotebookHistory.Link]? = nil) throws {
        if head.migrationReceiptDigest != nil {
            _ = try receipt(head, links: try links ?? history.selectedLinks(head))
        }
    }

    /// Checks the bounded receipt record; selected ancestry belongs to the full audit.
    func validateReceiptRecord(_ head: Format.Head, selectedSequence: Int? = nil) throws {
        guard head.migrationReceiptDigest != nil else { return }
        let stored = try receiptRecord(head)
        let anchor = stored.record.anchor
        let generation = try history.generationDirectory(head)
        let (anchorEvent, _) = try history.readEvent(
            id: anchor.revisionID, digest: anchor.revisionDigest, generation: generation
        )
        let sequence: Int
        if let selectedSequence { sequence = selectedSequence }
        else if head.revisionID == anchor.revisionID { sequence = anchorEvent.sequence }
        else {
            sequence = try history.readEvent(
                id: head.revisionID, digest: head.revisionDigest, generation: generation
            ).0.sequence
        }
        guard anchorEvent.sequence == stored.record.receipt.revisionCount,
              sequence >= anchorEvent.sequence,
              sequence != anchorEvent.sequence || (
                head.revisionID == anchor.revisionID && head.revisionDigest == anchor.revisionDigest
              ) else {
            throw NotebookRepositoryError.corruptData("The migration receipt has inconsistent anchor sequence.")
        }
    }

    private func receipt(_ head: Format.Head, links: [NotebookHistory.Link]) throws -> (
        record: Record, digest: String, legacyHeadData: Data
    ) {
        let stored = try receiptRecord(head)
        let record = stored.record
        guard let anchorIndex = links.firstIndex(where: { $0.revisionID == record.anchor.revisionID }),
              anchorIndex + 1 == record.receipt.revisionCount,
              links[anchorIndex].sequence == record.receipt.revisionCount,
              links[anchorIndex].digest == record.anchor.revisionDigest else {
            throw NotebookRepositoryError.corruptData("The migration receipt is not anchored in selected history.")
        }
        return stored
    }

    private func receiptRecord(_ head: Format.Head) throws -> (
        record: Record, digest: String, legacyHeadData: Data
    ) {
        guard head.schemaVersion == 2, let digest = head.migrationReceiptDigest else {
            throw NotebookRepositoryError.invalidContent("This notebook has no migration receipt.")
        }
        let generation = try history.generationDirectory(head)
        let data = try history.readMetadata(generation.appendingPathComponent("migration.json"))
        guard Format.digest(data, metrics: history.metrics) == digest else {
            throw NotebookRepositoryError.corruptData("The migration receipt failed integrity validation.")
        }
        let record: Record = try Format.decode(data)
        guard record.schemaVersion == 1,
              record.receipt.notebookID == history.notebookID,
              record.receipt.generationID == head.generationID,
              record.receipt.revisionID == record.anchor.revisionID,
              record.receipt.revisionCount > 0,
              record.anchor.schemaVersion == 2, record.anchor.notebookID == history.notebookID,
              record.anchor.generationID == head.generationID,
              record.anchor.migrationReceiptDigest == nil,
              Format.isDigest(record.anchor.revisionDigest),
              Format.isDigest(record.legacyHeadDigest), Format.isDigest(record.legacyChainDigest) else {
            throw NotebookRepositoryError.corruptData("The migration receipt has invalid anchor metadata.")
        }
        let legacyData = try history.readMetadata(generation.appendingPathComponent("legacy-head.json"))
        guard Format.digest(legacyData, metrics: history.metrics) == record.legacyHeadDigest else {
            throw NotebookRepositoryError.corruptData("The preserved legacy HEAD failed integrity validation.")
        }
        let legacy: Format.Head = try Format.decode(legacyData)
        guard legacy.schemaVersion == 1, legacy.notebookID == history.notebookID,
              legacy.revisionID == record.anchor.revisionID,
              Format.isDigest(legacy.revisionDigest),
              legacy.generationID == nil, legacy.migrationReceiptDigest == nil else {
            throw NotebookRepositoryError.corruptData("The preserved legacy HEAD has inconsistent identities.")
        }
        return (record, digest, legacyData)
    }

    private func chainDigest(_ links: [NotebookHistory.Link]) -> String {
        var hash = SHA256()
        history.metrics?.record(\.metadataHashCalls)
        for link in links {
            let data = Data("\(link.revisionID.uuidString.lowercased()):\(link.digest)\n".utf8)
            history.metrics?.record(\.metadataHashBytes, data.count)
            hash.update(data: data)
        }
        return NotebookDigest.lowercaseHex(hash.finalize())
    }

    private func selectedHead(_ record: Record, digest: String) -> Format.Head {
        Format.Head(
            schemaVersion: 2, notebookID: record.anchor.notebookID,
            revisionID: record.anchor.revisionID, revisionDigest: record.anchor.revisionDigest,
            generationID: record.anchor.generationID, migrationReceiptDigest: digest
        )
    }
}
