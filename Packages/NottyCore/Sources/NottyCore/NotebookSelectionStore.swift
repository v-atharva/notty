import Foundation

struct NotebookSelectionStore {
    private struct Pointer: Codable {
        let schemaVersion: Int
        let notebookID: UUID
    }
    private struct Envelope: Decodable { let schemaVersion: Int }

    let notesRoot: URL
    let repositoryID: UUID
    let metrics: NotebookStorageMetricsRecorder
    let fault: (@Sendable (NotebookSelectionWriteStage) throws -> Void)?

    private var pointerURL: URL { notesRoot.appendingPathComponent("SELECTION.json") }

    func read(legacyNotebookID: UUID, recoveryRootURL: URL) throws -> NotebookSelectionState {
        let recoveryRoot = try pairedRoot(recoveryRootURL)
        return try NotebookFileSystem.withWriterLocks([notesRoot, recoveryRoot]) {
            if let data = try readPointer() {
                return .selected(
                    notebookID: try decodePointer(data),
                    token: token(recoveryRoot: recoveryRoot, data: data, absence: nil)
                )
            }
            let legacy = notesRoot.appendingPathComponent(legacyNotebookID.uuidString.lowercased())
            if try NotebookFileSystem.existingDirectory(legacy) {
                return .selected(
                    notebookID: legacyNotebookID,
                    token: token(recoveryRoot: recoveryRoot, data: nil, absence: .legacy(legacyNotebookID))
                )
            }
            let absent: NotebookSelectionToken.Absence = try isEmpty(recoveryRoot: recoveryRoot)
                ? .empty : .recoveryRequired
            let selectionToken = token(recoveryRoot: recoveryRoot, data: nil, absence: absent)
            return absent == .empty ? .empty(token: selectionToken) : .recoveryRequired(token: selectionToken)
        }
    }

    func select(
        pin: NotebookHistoryPin, expected: NotebookSelectionToken,
        validateTarget: () throws -> Void
    ) throws -> NotebookSelectionState {
        guard expected.repositoryID == repositoryID, expected.notesRoot == notesRoot,
              pin.repositoryID == repositoryID, pin.root == notesRoot else {
            throw NotebookRepositoryError.invalidContent("The selection belongs to another repository.")
        }
        let recoveryRoot = try pairedRoot(expected.recoveryRoot)
        guard recoveryRoot == expected.recoveryRoot else {
            throw NotebookRepositoryError.revisionConflict
        }
        return try NotebookFileSystem.withWriterLocks([notesRoot, recoveryRoot]) {
            try checkExpected(expected)
            if expected.absence == .empty {
                guard try isEmpty(recoveryRoot: recoveryRoot, targetID: pin.notebookID) else {
                    throw NotebookRepositoryError.revisionConflict
                }
            }
            try validateTarget()
            let data = try NotebookRevisionFormat.encode(
                Pointer(schemaVersion: 1, notebookID: pin.notebookID), metrics: metrics
            )
            guard data.count <= 4_096 else {
                throw NotebookRepositoryError.sizeLimitExceeded("Notebook selection metadata exceeds supported bounds.")
            }
            let result = NotebookSelectionState.selected(
                notebookID: pin.notebookID,
                token: token(recoveryRoot: recoveryRoot, data: data, absence: nil)
            )
            try NotebookFileSystem.withSynchronizedStage(data, in: notesRoot) { stage in
                metrics.record(\.metadataWrittenBytes, data.count)
                try fault?(.selectionSynchronized)
                metrics.record(\.metadataReadCalls)
                let staged = try NotebookFileSystem.read(stage, maximumBytes: 4_096)
                metrics.record(\.metadataReadBytes, staged.count)
                guard staged == data else {
                    throw NotebookRepositoryError.corruptData("The notebook selection stage changed.")
                }
                try fault?(.beforeSelectionPublication)
                try checkExpected(expected)
                if expected.absence == .empty {
                    guard try isEmpty(
                        recoveryRoot: recoveryRoot, targetID: pin.notebookID, stageName: stage.lastPathComponent
                    ) else { throw NotebookRepositoryError.revisionConflict }
                }
                try NotebookFileSystem.replaceAtomically(stage, destination: pointerURL)
            }
            return result
        }
    }

    private func checkExpected(_ expected: NotebookSelectionToken) throws {
        guard try readPointer() == expected.pointerData else {
            throw NotebookRepositoryError.revisionConflict
        }
    }

    private func token(
        recoveryRoot: URL, data: Data?, absence: NotebookSelectionToken.Absence?
    ) -> NotebookSelectionToken {
        NotebookSelectionToken(
            repositoryID: repositoryID, notesRoot: notesRoot,
            recoveryRoot: recoveryRoot, pointerData: data, absence: absence
        )
    }

    private func pairedRoot(_ recoveryURL: URL) throws -> URL {
        guard recoveryURL.isFileURL else {
            throw NotebookRepositoryError.unsafePath("Recovery storage requires a file URL.")
        }
        func overlaps(_ lhs: URL, _ rhs: URL) -> Bool {
            lhs.path == rhs.path || lhs.path.hasPrefix(rhs.path + "/") || rhs.path.hasPrefix(lhs.path + "/")
        }
        guard !overlaps(notesRoot, recoveryURL.standardizedFileURL) else {
            throw NotebookRepositoryError.unsafePath("Notebook and recovery storage must have separate roots.")
        }
        let prospective = try prospectiveRoot(recoveryURL)
        guard !overlaps(notesRoot, prospective) else {
            throw NotebookRepositoryError.unsafePath("Notebook and recovery storage must have separate roots.")
        }
        let recoveryRoot = try NotebookFileSystem.prepareRoot(recoveryURL)
        guard !overlaps(notesRoot, recoveryRoot) else {
            throw NotebookRepositoryError.unsafePath("Notebook and recovery storage must have separate roots.")
        }
        return recoveryRoot
    }

    private func prospectiveRoot(_ url: URL) throws -> URL {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while try NotebookFileSystem.kind(existing) == nil {
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else {
                throw NotebookRepositoryError.unsafePath("The recovery storage ancestor is missing.")
            }
            missing.append(existing.lastPathComponent)
            existing = parent
        }
        if missing.isEmpty {
            guard try NotebookFileSystem.kind(existing) == .directory else {
                throw NotebookRepositoryError.unsafePath("Recovery storage must use a directory without a symbolic link.")
            }
        }
        var candidate = existing.resolvingSymlinksInPath()
        guard try NotebookFileSystem.kind(candidate) == .directory else {
            throw NotebookRepositoryError.unsafePath("The recovery storage ancestor is not a directory.")
        }
        for component in missing.reversed() {
            candidate.appendPathComponent(component, isDirectory: true)
        }
        return candidate
    }

    private func isEmpty(
        recoveryRoot: URL, targetID: UUID? = nil, stageName: String? = nil
    ) throws -> Bool {
        var excluded: [String: NotebookFileSystem.ItemKind] = [:]
        if let targetID { excluded[targetID.uuidString.lowercased()] = .directory }
        if let stageName { excluded[stageName] = .regularFile }
        let retainedNotes = try NotebookFileSystem.hasRetainedEntries(in: notesRoot, excluding: excluded)
        if retainedNotes { return false }
        return try !NotebookFileSystem.hasRetainedEntries(in: recoveryRoot)
    }

    private func readPointer() throws -> Data? {
        guard let kind = try NotebookFileSystem.kind(pointerURL) else { return nil }
        guard kind == .regularFile else {
            throw NotebookRepositoryError.unsafePath("The notebook selection has an unsafe file type.")
        }
        metrics.record(\.metadataReadCalls)
        do {
            let data = try NotebookFileSystem.read(pointerURL, maximumBytes: 4_096)
            metrics.record(\.metadataReadBytes, data.count)
            _ = try decodePointer(data)
            return data
        } catch NotebookRepositoryError.sizeLimitExceeded {
            throw NotebookRepositoryError.corruptData("Notebook selection metadata exceeds supported bounds.")
        }
    }

    private func decodePointer(_ data: Data) throws -> UUID {
        do {
            let decoder = JSONDecoder()
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard envelope.schemaVersion == 1 else {
                throw NotebookRepositoryError.unsupportedVersion(envelope.schemaVersion)
            }
            return try decoder.decode(Pointer.self, from: data).notebookID
        } catch let error as NotebookRepositoryError { throw error }
        catch { throw NotebookRepositoryError.corruptData("The notebook selection is unreadable.") }
    }
}
