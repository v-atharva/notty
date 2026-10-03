import CryptoKit
import Foundation

enum NotebookRevisionFormat {
    struct Head: Codable, Equatable {
        let schemaVersion: Int
        let notebookID: UUID
        let revisionID: UUID
        let revisionDigest: String
        let generationID: UUID?
        let migrationReceiptDigest: String?
    }

    struct Reference: Codable, Equatable {
        let id: UUID
        let digest: String
    }

    struct State: Codable, Equatable {
        var title: String
        var pageCount: Int
        var strokes: [Reference]

        static let empty = State(title: "", pageCount: 1, strokes: [])
    }

    struct LegacyRevision: Codable {
        let schemaVersion: Int
        let notebookID: UUID
        let revisionID: UUID
        let parentRevisionID: UUID?
        let sequence: Int
        let title: String
        let pageCount: Int
        let strokes: [Reference]
        let editStamp: NotebookEditStamp?
        let savedAt: Date

        var state: State { State(title: title, pageCount: pageCount, strokes: strokes) }
    }

    struct Placement: Codable, Equatable {
        let id: UUID
        let index: Int
    }

    struct Delta: Codable {
        let removedIDs: [UUID]?
        let upserts: [Reference]?
        let placements: [Placement]?
        let replacementOrder: [UUID]?
        let titleChange: String?
        let pageCountChange: Int?
    }

    struct Event: Codable {
        let schemaVersion: Int
        let notebookID: UUID
        let revisionID: UUID
        let parentRevisionID: UUID?
        let parentDigest: String?
        let sequence: Int
        let delta: Delta
        let editStamp: NotebookEditStamp?
        let savedAt: Date
        let checkpointDigest: String?
    }

    struct Checkpoint: Codable {
        let schemaVersion: Int
        let notebookID: UUID
        let revisionID: UUID
        let sequence: Int
        let state: State
    }

    struct Materialized {
        let revisionID: UUID
        let sequence: Int
        let editStamp: NotebookEditStamp?
        let savedAt: Date
        let state: State
        let checkpointCredit: Int
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= NotebookRepository.maximumMetadataBytes else {
            throw NotebookRepositoryError.sizeLimitExceeded("Notebook metadata exceeds 2 MiB.")
        }
        return data
    }

    static func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw NotebookRepositoryError.corruptData("Notebook metadata is unreadable.") }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func validateStamp(_ stamp: NotebookEditStamp?) throws {
        guard let stamp else { return }
        guard stamp.capturedAt.timeIntervalSinceReferenceDate.isFinite,
              stamp.uptime.isFinite, stamp.uptime >= 0 else {
            throw NotebookRepositoryError.invalidContent("The notebook edit timestamp is invalid.")
        }
    }

    static func validateState(_ state: State) throws {
        guard (1...12).contains(state.pageCount),
              state.title.utf8.count <= NotebookRepository.maximumTitleBytes,
              state.strokes.count <= NotebookRepository.maximumStrokeCount else {
            throw NotebookRepositoryError.corruptData("The notebook state exceeds supported bounds.")
        }
        var ids = Set<UUID>()
        for reference in state.strokes {
            guard ids.insert(reference.id).inserted, isDigest(reference.digest) else {
                throw NotebookRepositoryError.corruptData("The notebook state has invalid stroke references.")
            }
        }
    }

    static func validateIdentity(
        notebookID: UUID, revisionID: UUID, sequence: Int, parentID: UUID?,
        expectedNotebook: UUID, expectedRevision: UUID, stamp: NotebookEditStamp?, savedAt: Date
    ) throws {
        guard notebookID == expectedNotebook, revisionID == expectedRevision,
              sequence > 0, savedAt.timeIntervalSinceReferenceDate.isFinite,
              (sequence == 1) == (parentID == nil), parentID != revisionID else {
            throw NotebookRepositoryError.corruptData("A committed revision has inconsistent metadata.")
        }
        do { try validateStamp(stamp) }
        catch { throw NotebookRepositoryError.corruptData("A committed edit timestamp is invalid.") }
    }

    static func delta(from old: State, to new: State) throws -> Delta {
        let oldByID = Dictionary(uniqueKeysWithValues: old.strokes.map { ($0.id, $0.digest) })
        let newIDs = Set(new.strokes.map(\.id))
        let removed = old.strokes.filter { !newIDs.contains($0.id) }.map(\.id)
        let upserts = new.strokes.filter { oldByID[$0.id] != $0.digest }
        var order = old.strokes.filter { newIDs.contains($0.id) }.map(\.id)
        order.append(contentsOf: upserts.filter { oldByID[$0.id] == nil }.map(\.id))
        let target = new.strokes.map(\.id)
        var moves: [Placement] = []
        if order != target {
            for index in target.indices where order[index] != target[index] {
                guard let source = order.firstIndex(of: target[index]) else {
                    throw NotebookRepositoryError.invalidContent("The requested stroke order is inconsistent.")
                }
                let id = order.remove(at: source)
                order.insert(id, at: index)
                moves.append(Placement(id: id, index: index))
            }
        }
        var useReplacement = false
        if !moves.isEmpty { useReplacement = try encode(moves).count > encode(target).count }
        return Delta(
            removedIDs: removed.isEmpty ? nil : removed,
            upserts: upserts.isEmpty ? nil : upserts,
            placements: moves.isEmpty || useReplacement ? nil : moves,
            replacementOrder: useReplacement ? target : nil,
            titleChange: old.title == new.title ? nil : new.title,
            pageCountChange: old.pageCount == new.pageCount ? nil : new.pageCount
        )
    }

    static func apply(_ delta: Delta, to old: State) throws -> State {
        let removed = delta.removedIDs ?? []
        let updates = delta.upserts ?? []
        let moves = delta.placements ?? []
        guard Set(removed).count == removed.count,
              Set(updates.map(\.id)).count == updates.count,
              Set(moves.map(\.id)).count == moves.count,
              Set(removed).isDisjoint(with: updates.map(\.id)),
              delta.replacementOrder == nil || moves.isEmpty else {
            throw NotebookRepositoryError.corruptData("A history delta contains contradictory operations.")
        }
        var references = old.strokes
        let existingIDs = Set(references.map(\.id))
        guard Set(removed).isSubset(of: existingIDs) else {
            throw NotebookRepositoryError.corruptData("A history delta removes missing strokes.")
        }
        let removedSet = Set(removed)
        references.removeAll { removedSet.contains($0.id) }
        var positions = Dictionary(uniqueKeysWithValues: references.enumerated().map { ($0.element.id, $0.offset) })
        for update in updates {
            guard isDigest(update.digest) else {
                throw NotebookRepositoryError.corruptData("A history delta has an invalid asset digest.")
            }
            if let index = positions[update.id] {
                references[index] = update
            } else {
                positions[update.id] = references.count
                references.append(update)
            }
        }
        for move in moves {
            guard references.indices.contains(move.index),
                  let index = references.firstIndex(where: { $0.id == move.id }) else {
                throw NotebookRepositoryError.corruptData("A history delta has an invalid placement.")
            }
            let reference = references.remove(at: index)
            references.insert(reference, at: move.index)
        }
        if let order = delta.replacementOrder {
            guard order.count == references.count, Set(order).count == order.count,
                  Set(order) == Set(references.map(\.id)) else {
                throw NotebookRepositoryError.corruptData("A history delta has an invalid replacement order.")
            }
            let byID = Dictionary(uniqueKeysWithValues: references.map { ($0.id, $0) })
            references = try order.map {
                guard let reference = byID[$0] else {
                    throw NotebookRepositoryError.corruptData("A reordered stroke is missing.")
                }
                return reference
            }
        }
        let state = State(
            title: delta.titleChange ?? old.title,
            pageCount: delta.pageCountChange ?? old.pageCount, strokes: references
        )
        try validateState(state)
        return state
    }
}
