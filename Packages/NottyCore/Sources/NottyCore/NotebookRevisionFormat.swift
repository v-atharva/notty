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

    private struct Envelope: Decodable { let schemaVersion: Int }

    static func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            let decoder = JSONDecoder()
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard envelope.schemaVersion == 1 || envelope.schemaVersion == 2 else {
                throw NotebookRepositoryError.unsupportedVersion(envelope.schemaVersion)
            }
            return try decoder.decode(T.self, from: data)
        } catch let error as NotebookRepositoryError {
            throw error
        } catch {
            throw NotebookRepositoryError.corruptData("Notebook metadata is unreadable.")
        }
    }

    static func digest(_ data: Data) -> String {
        NotebookDigest.sha256(data)
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

    /// Mutates a single ordered state during audit without copying every historic drawing.
    final class Replay {
        private var order: [UUID]
        private var references: [UUID: Reference]
        private(set) var title: String
        private(set) var pageCount: Int

        init(_ state: State = .empty) {
            title = state.title
            pageCount = state.pageCount
            order = state.strokes.map(\.id)
            references = Dictionary(uniqueKeysWithValues: state.strokes.map { ($0.id, $0) })
        }

        var count: Int { order.count }
        var state: State {
            State(title: title, pageCount: pageCount, strokes: order.compactMap { references[$0] })
        }

        func reference(_ id: UUID) -> Reference? { references[id] }

        func apply(_ delta: Delta) throws {
            let removed = delta.removedIDs ?? []
            let updates = delta.upserts ?? []
            let moves = delta.placements ?? []
            let removedSet = Set(removed)
            guard removedSet.count == removed.count,
                  Set(updates.map(\.id)).count == updates.count,
                  Set(moves.map(\.id)).count == moves.count,
                  removedSet.isDisjoint(with: updates.map(\.id)),
                  delta.replacementOrder == nil || moves.isEmpty,
                  removed.allSatisfy({ references[$0] != nil }) else {
                throw NotebookRepositoryError.corruptData("A history delta contains contradictory operations.")
            }
            if !removed.isEmpty {
                order.removeAll { removedSet.contains($0) }
                for id in removed { references.removeValue(forKey: id) }
            }
            for update in updates {
                guard isDigest(update.digest) else {
                    throw NotebookRepositoryError.corruptData("A history delta has an invalid asset digest.")
                }
                if references[update.id] == nil { order.append(update.id) }
                references[update.id] = update
            }
            for move in moves {
                guard order.indices.contains(move.index),
                      let source = order.firstIndex(of: move.id) else {
                    throw NotebookRepositoryError.corruptData("A history delta has an invalid placement.")
                }
                let id = order.remove(at: source)
                order.insert(id, at: move.index)
            }
            if let replacement = delta.replacementOrder {
                guard replacement.count == order.count, Set(replacement).count == replacement.count,
                      replacement.allSatisfy({ references[$0] != nil }) else {
                    throw NotebookRepositoryError.corruptData("A history delta has an invalid replacement order.")
                }
                order = replacement
            }
            title = delta.titleChange ?? title
            pageCount = delta.pageCountChange ?? pageCount
            guard (1...12).contains(pageCount), title.utf8.count <= NotebookRepository.maximumTitleBytes,
                  order.count <= NotebookRepository.maximumStrokeCount else {
                throw NotebookRepositoryError.corruptData("The notebook state exceeds supported bounds.")
            }
        }
    }

    static func apply(_ delta: Delta, to old: State) throws -> State {
        let replay = Replay(old)
        try replay.apply(delta)
        return replay.state
    }
}
