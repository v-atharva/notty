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
            _ = try history.audit(head)
            return (head, try receipt(head).record.receipt)
        }
        let oldHeadURL = history.directory.appendingPathComponent("HEAD.json")
        let oldHeadData = try history.readMetadata(oldHeadURL)
        guard try history.readHead() == head else { throw NotebookRepositoryError.revisionConflict }
        let links = try history.selectedLinks(head)
        _ = try history.audit(head)
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
        try fault?(.legacyHeadPreserved)
        var parent: Format.Head?
        var previous = Format.State.empty
        var credit = 0
        let writer = NotebookHistoryWriter(
            notebookID: history.notebookID, generationID: generationID, generation: generation,
            writeFault: nil, migrationFault: fault
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
            assetDirectory: history.directory.appendingPathComponent("assets", isDirectory: true)
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
        _ = try staged.audit(anchor)
        try fault?(.generationValidated)
        let publicReceipt = NotebookMigrationReceipt(
            notebookID: history.notebookID, revisionID: anchor.revisionID,
            generationID: generationID, revisionCount: links.count
        )
        let record = Record(
            schemaVersion: 1, receipt: publicReceipt,
            legacyHeadDigest: Format.digest(oldHeadData), anchor: anchor,
            legacyChainDigest: chainDigest(links)
        )
        let recordData = try Format.encode(record)
        try NotebookFileSystem.writeSynchronized(
            recordData, to: stagedGeneration.appendingPathComponent("migration.json")
        )
        let selected = selectedHead(record, digest: Format.digest(recordData))
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
        try NotebookFileSystem.withSynchronizedStage(
            try Format.encode(selected), in: history.directory, head: true
        ) { stage in
            try fault?(.headStaged)
            try fault?(.beforeHeadPublication)
            try NotebookFileSystem.replaceAtomically(stage, destination: oldHeadURL)
        }
        return (selected, publicReceipt)
    }

    func rollback(_ head: Format.Head) throws -> StoredNotebook {
        let stored = try receipt(head)
        guard head == selectedHead(stored.record, digest: stored.digest) else {
            throw NotebookRepositoryError.revisionConflict
        }
        _ = try history.audit(head)
        let legacy: Format.Head = try Format.decode(stored.legacyHeadData)
        guard legacy.schemaVersion == 1 else {
            throw NotebookRepositoryError.corruptData("The retained rollback HEAD is not legacy history.")
        }
        let legacyLinks = try history.selectedLinks(legacy)
        guard legacyLinks.count == stored.record.receipt.revisionCount,
              chainDigest(legacyLinks) == stored.record.legacyChainDigest else {
            throw NotebookRepositoryError.corruptData("Retained legacy history differs from the migration receipt.")
        }
        _ = try history.audit(legacy)
        let current = try history.current(legacy)
        let strokes = try history.readAssets(current.state)
        guard try history.readHead() == head else { throw NotebookRepositoryError.revisionConflict }
        try NotebookFileSystem.withSynchronizedStage(
            stored.legacyHeadData, in: history.directory, head: true
        ) { stage in
            try fault?(.headStaged)
            try fault?(.beforeHeadPublication)
            try NotebookFileSystem.replaceAtomically(
                stage, destination: history.directory.appendingPathComponent("HEAD.json")
            )
        }
        return StoredNotebook(
            id: history.notebookID, revisionID: current.revisionID, sequence: current.sequence,
            content: NotebookContent(
                title: current.state.title, pageCount: current.state.pageCount,
                strokes: strokes, editStamp: current.editStamp
            ),
            savedAt: current.savedAt
        )
    }

    func validateReceipt(_ head: Format.Head) throws {
        if head.migrationReceiptDigest != nil { _ = try receipt(head) }
    }

    private func receipt(_ head: Format.Head) throws -> (
        record: Record, digest: String, legacyHeadData: Data
    ) {
        guard head.schemaVersion == 2, let digest = head.migrationReceiptDigest else {
            throw NotebookRepositoryError.invalidContent("This notebook has no migration receipt.")
        }
        let generation = try history.generationDirectory(head)
        let data = try history.readMetadata(generation.appendingPathComponent("migration.json"))
        guard Format.digest(data) == digest else {
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
              Format.isDigest(record.legacyHeadDigest) else {
            throw NotebookRepositoryError.corruptData("The migration receipt has invalid anchor metadata.")
        }
        let legacyData = try history.readMetadata(generation.appendingPathComponent("legacy-head.json"))
        guard Format.digest(legacyData) == record.legacyHeadDigest else {
            throw NotebookRepositoryError.corruptData("The preserved legacy HEAD failed integrity validation.")
        }
        let legacy: Format.Head = try Format.decode(legacyData)
        guard legacy.schemaVersion == 1, legacy.notebookID == history.notebookID,
              legacy.revisionID == record.anchor.revisionID,
              Format.isDigest(legacy.revisionDigest),
              legacy.generationID == nil, legacy.migrationReceiptDigest == nil else {
            throw NotebookRepositoryError.corruptData("The preserved legacy HEAD has inconsistent identities.")
        }
        let links = try history.selectedLinks(head)
        guard Format.isDigest(record.legacyChainDigest),
              let anchorIndex = links.firstIndex(where: { $0.revisionID == record.anchor.revisionID }),
              anchorIndex + 1 == record.receipt.revisionCount,
              links[anchorIndex].digest == record.anchor.revisionDigest else {
            throw NotebookRepositoryError.corruptData("The migration receipt is not anchored in selected history.")
        }
        return (record, digest, legacyData)
    }

    private func chainDigest(_ links: [NotebookHistory.Link]) -> String {
        var hash = SHA256()
        for link in links {
            hash.update(data: Data("\(link.revisionID.uuidString.lowercased()):\(link.digest)\n".utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func selectedHead(_ record: Record, digest: String) -> Format.Head {
        Format.Head(
            schemaVersion: 2, notebookID: record.anchor.notebookID,
            revisionID: record.anchor.revisionID, revisionDigest: record.anchor.revisionDigest,
            generationID: record.anchor.generationID, migrationReceiptDigest: digest
        )
    }
}
