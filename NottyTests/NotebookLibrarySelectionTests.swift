import Foundation
import NottyCore
import PencilKit
import XCTest
@testable import Notty

@MainActor
final class NotebookLibrarySelectionTests: XCTestCase {
    func testEmptyLibraryPublishesANewNotebookBeforeSelectingIt() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let newID = UUID()
        let model = NotebookLibraryModel(
            openLibrary: { fixture.library }, makeNotebookID: { newID }
        )
        await model.load()
        let session = try selectedSession(model)
        XCTAssertEqual(session.notebookID, newID)
        await session.load()
        XCTAssertEqual(session.loadState, .ready)
        let opening = try await fixture.repository.open(id: newID)
        XCTAssertEqual(opening?.notebook.id, newID)
        let selection = try await fixture.library.readSelection(legacyNotebookID: NotebookSession.defaultNotebookID)
        guard case .selected(let id, _) = selection else { return XCTFail("The published note must be selected.") }
        XCTAssertEqual(id, newID)
    }

    func testExistingLegacyNoteIsOpenedWithoutCreatingAnotherNotebook() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let original = try await fixture.seed(NotebookSession.defaultNotebookID)
        let before = try fixture.snapshot(fixture.notes)
        let model = NotebookLibraryModel(openLibrary: { fixture.library })
        await model.load()
        let session = try selectedSession(model)
        await session.load()
        XCTAssertEqual(session.loadState, .ready)
        XCTAssertEqual(session.notebookID, original.id)
        XCTAssertEqual(try fixture.snapshot(fixture.notes), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.notes.appendingPathComponent("SELECTION.json").path))
    }

    func testInvalidPointerBlocksCreationAndRetainsEveryFile() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        _ = try await fixture.seed(NotebookSession.defaultNotebookID)
        try Data("invalid selection".utf8).write(to: fixture.notes.appendingPathComponent("SELECTION.json"))
        let before = try fixture.snapshot(fixture.root)
        let model = NotebookLibraryModel(openLibrary: { fixture.library })
        await model.load()
        guard case .failed = model.state else { return XCTFail("An invalid pointer must block opening.") }
        await model.startNewNotebook()
        XCTAssertEqual(try fixture.snapshot(fixture.root), before)
    }

    func testMissingSelectedDirectoryDoesNotRecreateBlankAtItsIdentity() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let missingID = UUID()
        let selected = try await fixture.library.readSelection(legacyNotebookID: NotebookSession.defaultNotebookID)
        guard case .empty(let token) = selected else { return XCTFail("The fixture must begin empty.") }
        _ = try await fixture.library.createAndSelectNotebook(
            id: missingID, expectedSelection: token, stamp: NotebookTestFixtures.stamp(1)
        )
        try FileManager.default.removeItem(at: fixture.noteURL(missingID))
        let before = try fixture.snapshot(fixture.root)
        let newID = UUID()
        let model = NotebookLibraryModel(openLibrary: { fixture.library }, makeNotebookID: { newID })
        await model.load()
        let old = try selectedSession(model)
        await old.load()
        guard case .failed = old.loadState else { return XCTFail("A missing selected note must fail opening.") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.noteURL(missingID).path))
        XCTAssertEqual(try fixture.snapshot(fixture.root), before)
        await model.startNewNotebook()
        let fresh = try selectedSession(model)
        XCTAssertEqual(fresh.notebookID, newID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.noteURL(missingID).path))
    }

    func testFailedSelectionKeepsDamagedNoteAndRecoveryBytes() async throws {
        let fixture = try LibraryFixture(selectionFailure: true)
        defer { fixture.remove() }
        let oldID = NotebookSession.defaultNotebookID
        _ = try await fixture.seed(oldID)
        try Data("damaged".utf8).write(to: fixture.noteURL(oldID).appendingPathComponent("HEAD.json"))
        _ = try await fixture.preserve(id: oldID)
        let oldBytes = try fixture.snapshot(fixture.noteURL(oldID))
        let copyBytes = try fixture.snapshot(fixture.copies)
        let newID = UUID()
        let model = NotebookLibraryModel(openLibrary: { fixture.library }, makeNotebookID: { newID })
        await model.load()
        let oldSession = try selectedSession(model)
        await oldSession.load()
        guard case .failed = oldSession.loadState else { return XCTFail("The damaged note must fail opening.") }
        await model.startNewNotebook()
        XCTAssertTrue(try selectedSession(model) === oldSession)
        XCTAssertNotNil(model.creationFailure)
        XCTAssertEqual(try fixture.snapshot(fixture.noteURL(oldID)), oldBytes)
        XCTAssertEqual(try fixture.snapshot(fixture.copies), copyBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.noteURL(newID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.notes.appendingPathComponent("SELECTION.json").path))
        await oldSession.load()
        guard case .failed = oldSession.loadState else { return XCTFail("A failed transition must release retry admission.") }
    }

    func testRetryOpeningCannotRaceASelectedNotebookTransition() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let oldID = NotebookSession.defaultNotebookID
        _ = try await fixture.seed(oldID)
        try Data("damaged".utf8).write(to: fixture.noteURL(oldID).appendingPathComponent("HEAD.json"))
        let oldBytes = try fixture.snapshot(fixture.noteURL(oldID))
        let gate = LibrarySelectionGate()
        let newID = UUID()
        let model = NotebookLibraryModel(
            openLibrary: { fixture.library }, makeNotebookID: { newID },
            beforeSelection: { await gate.suspend() }
        )
        await model.load()
        let old = try selectedSession(model)
        await old.load()
        let task = Task { await model.startNewNotebook() }
        do {
            try await waitUntil { await gate.entered }
            await old.load()
            guard case .failed = old.loadState else { throw FixtureFailure.unexpectedState }
            XCTAssertTrue(try selectedSession(model) === old)
            XCTAssertTrue(model.isCreating)
            await gate.release()
            await task.value
        } catch {
            await gate.release()
            await task.value
            throw error
        }
        XCTAssertEqual(try selectedSession(model).notebookID, newID)
        XCTAssertEqual(try fixture.snapshot(fixture.noteURL(oldID)), oldBytes)
        XCTAssertTrue(old.pendingEdits.isEmpty)
    }

    func testNewCanvasOwnerDuringTransitionRejectsSelectionAndKeepsOldSession() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        _ = try await fixture.seed(NotebookSession.defaultNotebookID)
        try Data("damaged".utf8).write(to: fixture.noteURL(NotebookSession.defaultNotebookID).appendingPathComponent("HEAD.json"))
        let gate = LibrarySelectionGate()
        let model = NotebookLibraryModel(
            openLibrary: { fixture.library }, beforeSelection: { await gate.suspend() }
        )
        await model.load()
        let old = try selectedSession(model)
        await old.load()
        let task = Task { await model.startNewNotebook() }
        do {
            try await waitUntil { await gate.entered }
            let seed = old.makeCanvasSeed()
            old.attachCanvas(ownerID: seed.ownerID, observations: { nil })
            await gate.release()
            await task.value
        } catch {
            await gate.release()
            await task.value
            throw error
        }
        XCTAssertTrue(try selectedSession(model) === old)
        XCTAssertEqual(model.creationFailure, .revisionConflict)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.notes.appendingPathComponent("SELECTION.json").path))
    }

    func testActiveNativeToolRejectsNewNotebookBeforeAnyPublication() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        _ = try await fixture.seed(NotebookSession.defaultNotebookID)
        try Data("damaged".utf8).write(to: fixture.noteURL(NotebookSession.defaultNotebookID).appendingPathComponent("HEAD.json"))
        let model = NotebookLibraryModel(openLibrary: { fixture.library })
        await model.load()
        let old = try selectedSession(model)
        await old.load()
        let seed = old.makeCanvasSeed()
        old.attachCanvas(ownerID: seed.ownerID, observations: { nil }, controls: NotebookCanvasControls(
            undo: {}, redo: {}, setPaletteSuppressed: { _ in }, applyPageCount: { _ in },
            currentAvailability: { NotebookUndoAvailability(canUndo: false, canRedo: false, isUsingTool: true) }
        ))
        let before = try fixture.snapshot(fixture.root)
        await model.startNewNotebook()
        XCTAssertTrue(try selectedSession(model) === old)
        XCTAssertEqual(try fixture.snapshot(fixture.root), before)
        XCTAssertFalse(model.isCreating)
    }

    private func selectedSession(_ model: NotebookLibraryModel) throws -> NotebookSession {
        guard case .notebook(let session) = model.state else { throw FixtureFailure.unexpectedState }
        return session
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw FixtureFailure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private enum FixtureFailure: Error { case unexpectedState, timeout }
}

private struct LibraryFixture: Sendable {
    let root: URL
    let notes: URL
    let copies: URL
    let repository: NotebookRepository
    let recovery: NotebookRecoveryStore
    let library: NotebookLibraryAccess

    init(selectionFailure: Bool = false) throws {
        root = NotebookTestFixtures.root()
        notes = root.appendingPathComponent("notes", isDirectory: true)
        copies = root.appendingPathComponent("copies", isDirectory: true)
        repository = try NotebookRepository(rootURL: notes, selectionFaultInjector: { stage in
            if selectionFailure && stage == .beforeSelectionPublication {
                throw NotebookRepositoryError.ioFailure(5)
            }
        })
        recovery = try NotebookRecoveryStore(rootURL: copies)
        library = NotebookLibraryAccess(
            libraryRoot: notes, recoveryRoot: copies, repository: repository, recoveryStore: recovery
        )
    }

    func seed(_ id: UUID) async throws -> StoredNotebook {
        try await repository.save(
            id: id, content: NotebookContent(title: "Retained note", pageCount: 3, strokes: [],
                                            editStamp: NotebookTestFixtures.stamp(0)),
            expectedRevisionID: nil
        )
    }

    func preserve(id: UUID) async throws -> NotebookRecoveryReceipt {
        let strokes = try await InkCodec().encode(PKDrawing(strokes: [NotebookTestFixtures.stroke()]))
        return try await recovery.preserveStates(NotebookRecoveryStrokeBatch(
            notebookID: id, edits: [NotebookRecoveryStrokeEdit(
                id: UUID(), strokes: strokes, title: "Retained recovery", pageCount: 3,
                stamp: NotebookTestFixtures.stamp(4)
            )]
        ))
    }

    func noteURL(_ id: UUID) -> URL { notes.appendingPathComponent(id.uuidString.lowercased()) }
    func remove() { try? FileManager.default.removeItem(at: root) }

    func snapshot(_ directory: URL) throws -> [String: Data] {
        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [:] }
        var result: [String: Data] = [:]
        for case let item as URL in enumerator {
            let file = item.standardizedFileURL.resolvingSymlinksInPath()
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let prefix = base.path + "/"
                guard file.path.hasPrefix(prefix) else { throw NotebookSaveFailure.unsafeStorage }
                result[String(file.path.dropFirst(prefix.count))] = try Data(contentsOf: file)
            }
        }
        return result
    }
}

private actor LibrarySelectionGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        let waiting = continuation
        continuation = nil
        waiting?.resume()
    }
}
