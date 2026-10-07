import Foundation
import NottyCore
import PencilKit
import SwiftUI
import UIKit
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

    func testEmptyLibraryShowsFirstNotebookCreationInsteadOfRecovery() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let gate = LibrarySelectionGate()
        let newID = UUID()
        let model = NotebookLibraryModel(
            openLibrary: { fixture.library }, makeNotebookID: { newID },
            beforeSelection: { await gate.suspend() }
        )
        let task = Task { await model.load() }
        do {
            try await NotebookTestFixtures.waitUntil { await gate.entered }
            guard case .creatingFirstNotebook = model.state else { throw FixtureFailure.unexpectedState }
            XCTAssertTrue(model.isCreating)
            await gate.release()
            await task.value
        } catch {
            await gate.release()
            await task.value
            throw error
        }
        XCTAssertEqual(try selectedSession(model).notebookID, newID)
    }

    func testFailedFirstNotebookCreationOffersRetryWithoutRecoveryWording() async throws {
        let fixture = try LibraryFixture(selectionFailure: true)
        defer { fixture.remove() }
        let model = NotebookLibraryModel(openLibrary: { fixture.library })
        await model.load()
        guard case .creatingFirstNotebook = model.state else {
            return XCTFail("A failed first creation must stay on its own screen.")
        }
        XCTAssertNotNil(model.creationFailure)
        XCTAssertFalse(model.isCreating)
        model.dismissCreationFailure()
        XCTAssertNotNil(model.creationFailure, "Only the banner over an open notebook can be dismissed.")
        await model.retry()
        guard case .recoveryRequired = model.state else {
            return XCTFail("An unselected published note must require recovery, not promotion.")
        }
    }

    func testLibraryStatusSymbolsExistInTheSystemSet() {
        XCTAssertNotNil(UIImage(systemName: "exclamationmark.triangle"))
    }

    func testLaunchScreenIsPaperIvoryInEveryAppearance() throws {
        let launch = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UILaunchScreen") as? [String: Any])
        XCTAssertEqual(launch["UIColorName"] as? String, "LaunchBackground")
        let color = try XCTUnwrap(UIColor(named: "LaunchBackground", in: .main, compatibleWith: nil))
        let light = components(of: color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)))
        XCTAssertEqual(components(of: color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))), light)
        for (actual, expected) in zip(light, components(of: NotebookTheme.paperIvory.uiColor)) {
            XCTAssertEqual(actual, expected, accuracy: 1 / 255)
        }
    }

    func testLibraryHostStaysLightOnPaperInADarkWindow() async throws {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "UIUserInterfaceStyle") as? String, "Light")
        let gate = LibrarySelectionGate()
        let model = NotebookLibraryModel(openLibrary: {
            await gate.suspend()
            throw NotebookSaveFailure.storageUnavailable
        })
        let window = UIWindow(windowScene: try NotebookTestFixtures.windowScene())
        window.frame = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)
        window.overrideUserInterfaceStyle = .dark
        let control = AppearanceTrackingHostingController(rootView: Color.clear)
        window.rootViewController = control
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await NotebookTestFixtures.waitUntilAppeared(control)
        // The window must outrank the app's light style, or the checks below prove nothing.
        XCTAssertEqual(control.traitCollection.userInterfaceStyle, .dark)
        let hosting = AppearanceTrackingHostingController(rootView: NotebookLibraryHost(model: model))
        window.rootViewController = hosting
        hosting.view.layoutIfNeeded()
        do {
            try await NotebookTestFixtures.waitUntilAppeared(hosting)
            try await NotebookTestFixtures.waitUntil { await gate.entered }
            guard case .loading = model.state else { throw FixtureFailure.unexpectedState }
            try await assertLightPaper(hosting, card: NotebookTheme.statusCardWidth)
        } catch {
            await gate.release()
            throw error
        }
        await gate.release()
        try await NotebookTestFixtures.waitUntil {
            if case .failed = model.state { return true }
            return false
        }
        try await assertLightPaper(hosting, card: NotebookTheme.statusCardMaxWidth, primaryKey: true)
    }

    /// While the first notebook is created, the host shows a light loading card on the paper,
    /// whatever the window's appearance.
    func testCreatingTheFirstNotebookShowsALightLoadingCardInADarkWindow() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let gate = LibrarySelectionGate()
        let model = NotebookLibraryModel(
            openLibrary: { fixture.library }, beforeSelection: { await gate.suspend() }
        )
        // Creation is held before the host appears, so the host's own load call finds it started.
        let task = Task { await model.load() }
        let window = UIWindow(windowScene: try NotebookTestFixtures.windowScene())
        window.frame = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)
        window.overrideUserInterfaceStyle = .dark
        do {
            try await NotebookTestFixtures.waitUntil { await gate.entered }
            guard case .creatingFirstNotebook = model.state, model.creationFailure == nil else {
                throw FixtureFailure.unexpectedState
            }
            let hosting = AppearanceTrackingHostingController(rootView: NotebookLibraryHost(model: model))
            window.rootViewController = hosting
            window.makeKeyAndVisible()
            try await NotebookTestFixtures.waitUntilAppeared(hosting)
            try await assertLightPaper(hosting, card: NotebookTheme.statusCardWidth)
        } catch {
            window.isHidden = true
            window.rootViewController = nil
            await gate.release()
            await task.value
            throw error
        }
        window.isHidden = true
        window.rootViewController = nil
        await gate.release()
        await task.value
        XCTAssertNotNil(try? selectedSession(model), "The first notebook is created once released.")
    }

    /// The first-notebook failure and the recovery-required screens are light cards with a
    /// dark primary key on the paper, whatever the window's appearance.
    func testLibraryFailureAndRecoveryCardsStayLightInADarkWindow() async throws {
        let fixture = try LibraryFixture(selectionFailure: true)
        defer { fixture.remove() }
        let model = NotebookLibraryModel(openLibrary: { fixture.library })
        await model.load()
        guard case .creatingFirstNotebook = model.state, model.creationFailure != nil else {
            return XCTFail("The first creation must fail.")
        }
        let window = UIWindow(windowScene: try NotebookTestFixtures.windowScene())
        window.frame = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)
        window.overrideUserInterfaceStyle = .dark
        let hosting = AppearanceTrackingHostingController(rootView: NotebookLibraryHost(model: model))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await NotebookTestFixtures.waitUntilAppeared(hosting)
        try await assertLightPaper(hosting, card: NotebookTheme.statusCardMaxWidth, primaryKey: true)

        await model.retry()
        guard case .recoveryRequired = model.state else { return XCTFail("An unselected note must require recovery.") }
        try await assertLightPaper(hosting, card: NotebookTheme.statusCardMaxWidth, primaryKey: true)
    }

    /// The banner shown when a new notebook could not be selected is a light card centred at the
    /// bottom of the screen, 12 points above the home indicator, whatever the window's appearance.
    /// Over the notebook opened again it stays clear of the header and the home indicator, and its
    /// dismiss key clears the notice and leaves the open notebook as it was.
    func testSelectionFailureBannerIsALightCardClearOfTheHeaderAndTheHomeIndicator() async throws {
        let fixture = try LibraryFixture(selectionFailure: true)
        defer { fixture.remove() }
        let oldID = NotebookSession.defaultNotebookID
        _ = try await fixture.seed(oldID)
        let head = fixture.noteURL(oldID).appendingPathComponent("HEAD.json")
        let intact = try Data(contentsOf: head)
        try Data("damaged".utf8).write(to: head)
        let model = NotebookLibraryModel(openLibrary: { fixture.library })
        await model.load()
        let session = try selectedSession(model)
        NotebookTestFixtures.restoreSceneToolDefaults(for: try NotebookTestFixtures.windowScene(), after: self)
        let window = UIWindow(windowScene: try NotebookTestFixtures.windowScene())
        window.frame = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)
        window.overrideUserInterfaceStyle = .dark
        let hosting = AppearanceTrackingHostingController(rootView: NotebookLibraryHost(model: model))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer {
            session.flush()
            window.isHidden = true
            window.rootViewController = nil
        }
        try await NotebookTestFixtures.waitUntilAppeared(hosting)
        // The screen opens the note itself; the new notebook is offered once that has failed.
        try await NotebookTestFixtures.waitUntil {
            if case .failed = session.loadState { return true }
            return false
        }
        await model.startNewNotebook()
        XCTAssertNotNil(model.creationFailure)
        let view = try XCTUnwrap(hosting.view)
        try await NotebookTestFixtures.waitUntil { view.traitCollection.userInterfaceStyle == .light }
        let pixels = try render(view)
        let paper = components(of: NotebookTheme.paperIvory.uiColor).map { Int(($0 * 255).rounded()) }
        let lift = NotebookTheme.sectionSpacing
        // Up the middle of the banner, from the safe area through the banner.
        let bottom = view.bounds.height - view.safeAreaInsets.bottom
        let rows = (1...Int(lift) + 80).map {
            pixels.rgba(at: CGPoint(x: view.bounds.midX + 60, y: bottom - CGFloat($0))).map(Int.init)
        }
        // Paper up to the shadow the card casts; the card's lower edge is darker than that shadow.
        let shadow = try XCTUnwrap(rows.firstIndex { zip($0, paper).contains { abs($0 - $1) > 4 } }, "A card lies at the bottom.")
        let inset = try XCTUnwrap((shadow..<min(shadow + 20, rows.count)).min { luminance(rows[$0]) < luminance(rows[$1]) })
        XCTAssertEqual(CGFloat(inset), lift, accuracy: 3, "The banner sits 12 points above the home indicator.")
        let light = rows[inset...].prefix(30).filter { luminance($0) > 0.7 }
        XCTAssertGreaterThan(light.count, 20, "The banner is light: \(rows[inset])")

        // The dismiss key's glyph sits at the banner's trailing end, on a row inside its bottom padding.
        let edgeRow = bottom - CGFloat(inset) - 3
        let maximumHalfWidth = NotebookTheme.statusCardMaxWidth / 2
        let trailing = try XCTUnwrap(
            stride(from: view.bounds.midX + maximumHalfWidth, to: view.bounds.midX, by: -1).first { x in
                let pixel = pixels.rgba(at: CGPoint(x: x, y: edgeRow)).map(Int.init)
                return luminance(pixel) > 0.7 && zip(pixel, paper).contains { abs($0 - $1) > 4 }
            },
            "The banner's trailing edge."
        )
        let key = NotebookTheme.controlSize
        let glyph = (Int(trailing - key * 3 / 4)..<Int(trailing - key / 4)).flatMap { x in
            (Int(bottom) - inset - 60..<Int(bottom) - inset).map { pixels.rgba(at: CGPoint(x: x, y: $0)).map(Int.init) }
        }
        XCTAssertGreaterThan(glyph.filter { luminance($0) < 0.3 }.count, 5, "The banner has a dismiss key.")

        // Opened again, the notebook shows its header, here scrolled to the end of the paper.
        try intact.write(to: head)
        await session.load()
        var controller: NotebookViewController?
        var header: NotebookHeaderHostController?
        try await NotebookTestFixtures.waitUntil {
            controller = NotebookTestFixtures.notebookController(in: hosting)
            header = NotebookHeaderTests.headerHost(in: hosting)
            // Once the history check is done, its readout no longer spins.
            guard case .verified = session.integrityModel.state else { return false }
            return session.loadState == .ready && controller?.isCanvasVisible == true
                && header?.headerView.bounds.width ?? 0 > 0
        }
        let canvas = try XCTUnwrap(controller).canvasView
        let end = canvas.contentSize.height - canvas.bounds.height + canvas.contentInset.bottom
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: end), animated: false)
        view.layoutIfNeeded()
        XCTAssertNotNil(model.creationFailure, "The banner stays over the notebook opened again.")
        let covered = try render(view)
        model.dismissCreationFailure()
        XCTAssertNil(model.creationFailure, "The dismiss key clears the notice.")
        XCTAssertTrue(try selectedSession(model) === session, "The open notebook stays.")
        let uncovered = try render(view)

        // The banner and its shadow are all the dismissal changes.
        var banner = CGRect.null
        for y in stride(from: CGFloat(0.5), to: view.bounds.height, by: 2) {
            for x in stride(from: CGFloat(0.5), to: view.bounds.width, by: 2) {
                let point = CGPoint(x: x, y: y)
                if covered.rgba(at: point) != uncovered.rgba(at: point) {
                    banner = banner.union(CGRect(origin: point, size: .zero))
                }
            }
        }
        XCTAssertFalse(banner.isNull, "The banner lies over the notebook.")
        XCTAssertEqual(banner.midX, view.bounds.midX, accuracy: 3, "The banner is centred.")
        let headerFrame = try XCTUnwrap(header).view.convert(try XCTUnwrap(header).view.bounds, to: view)
        XCTAssertGreaterThan(banner.minY, headerFrame.maxY, "The banner is clear of the header.")
        XCTAssertLessThan(
            banner.maxY, view.bounds.height - view.safeAreaInsets.bottom, "The banner is clear of the home indicator."
        )
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
        _ = try await fixture.library.readSelection(legacyNotebookID: NotebookSession.defaultNotebookID)
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
        let head = fixture.noteURL(oldID).appendingPathComponent("HEAD.json")
        let healthyHead = try Data(contentsOf: head)
        try Data("damaged".utf8).write(to: head)
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
            try await NotebookTestFixtures.waitUntil { await gate.entered }
            try healthyHead.write(to: head)
            let repairedBytes = try fixture.snapshot(fixture.noteURL(oldID))
            await old.load()
            guard case .failed = old.loadState else { throw FixtureFailure.unexpectedState }
            XCTAssertTrue(try selectedSession(model) === old)
            XCTAssertTrue(model.isCreating)
            XCTAssertEqual(try fixture.snapshot(fixture.noteURL(oldID)), repairedBytes)
            await gate.release()
            await task.value
        } catch {
            await gate.release()
            await task.value
            throw error
        }
        XCTAssertEqual(try selectedSession(model).notebookID, newID)
        XCTAssertEqual(try Data(contentsOf: head), healthyHead)
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
            try await NotebookTestFixtures.waitUntil { await gate.entered }
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

    func testLibraryRetryCannotReplaceAReadySessionWithAcceptedPendingWork() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        _ = try await fixture.seed(NotebookSession.defaultNotebookID)
        let model = NotebookLibraryModel(openLibrary: { fixture.library })
        await model.load()
        let session = try selectedSession(model)
        await session.load()
        let seed = session.makeCanvasSeed()
        session.attachCanvas(ownerID: seed.ownerID, observations: { nil })
        let drawing = PKDrawing(strokes: [NotebookTestFixtures.stroke()])
        session.recordObservation(
            NotebookCanvasObservation(generation: 1, drawing: drawing,
                                      capturedAt: Date(timeIntervalSince1970: 80), uptime: 80),
            ownerID: seed.ownerID
        )
        let accepted = try XCTUnwrap(session.pendingEdits.first)
        XCTAssertEqual(session.pendingEdits.map(\.id), [accepted.id])
        await model.retry()
        XCTAssertTrue(try selectedSession(model) === session)
        await session.waitUntilSettled()
        let loaded = try await fixture.repository.load(id: session.notebookID)
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.content.editStamp, accepted.stamp)
        XCTAssertEqual(saved.content.strokes.map(\.id), drawing.strokes.map(\.id))
        XCTAssertEqual(session.loadState, .ready)
    }

    private func selectedSession(_ model: NotebookLibraryModel) throws -> NotebookSession {
        guard case .notebook(let session) = model.state else { throw FixtureFailure.unexpectedState }
        return session
    }

    /// Waits for the light appearance, then checks that opposite corners of the window show the
    /// paper and that a light status card of width `card` lies centred on it, with a dark primary
    /// key when `primaryKey` is set.
    private func assertLightPaper(
        _ hosting: UIViewController, card: CGFloat, primaryKey: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        try await NotebookTestFixtures.waitUntil(file: file, line: line) {
            hosting.traitCollection.userInterfaceStyle == .light
        }
        let view = try XCTUnwrap(hosting.view)
        let pixels = try render(view)
        let paper = components(of: NotebookTheme.paperIvory.uiColor).map { Int(($0 * 255).rounded()) }
        for point in [CGPoint(x: 4, y: 4), CGPoint(x: view.bounds.maxX - 4, y: view.bounds.maxY - 4)] {
            let rendered = pixels.rgba(at: point).map(Int.init)
            for (actual, expected) in zip(rendered, paper) {
                XCTAssertEqual(actual, expected, accuracy: 2, "\(rendered) at \(point)", file: file, line: line)
            }
        }
        // A column just inside the card's leading padding, clear of centred text.
        let x = view.bounds.midX - card / 2 + NotebookTheme.detailPadding / 2
        let column = (0..<Int(view.bounds.height)).map { pixels.rgba(at: CGPoint(x: x, y: CGFloat($0))).map(Int.init) }
        let shell = column.filter { pixel in
            luminance(pixel) > 0.7 && zip(pixel, paper).contains { abs($0 - $1) > 4 }
        }
        XCTAssertGreaterThan(shell.count, 40, "A light card lies on the paper.", file: file, line: line)
        guard primaryKey else { return }
        let keyX = view.bounds.midX - card / 2 + NotebookTheme.detailPadding + NotebookTheme.actionKeyPadding / 2
        var run = 0, longest = 0
        for y in 0..<Int(view.bounds.height) {
            run = luminance(pixels.rgba(at: CGPoint(x: keyX, y: CGFloat(y))).map(Int.init)) < 0.1 ? run + 1 : 0
            longest = max(longest, run)
        }
        XCTAssertGreaterThanOrEqual(
            longest, Int(NotebookTheme.actionKeyHeight) - 4, "The primary action is a dark key.", file: file, line: line
        )
    }

    /// The view as drawn on screen, at one pixel per point.
    private func render(_ view: UIView) throws -> RenderedPixels {
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        return try RenderedPixels(try XCTUnwrap(image.cgImage), scale: 1)
    }

    private func luminance(_ pixel: [Int]) -> Double {
        EditorInkColor(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
            .relativeLuminance
    }

    private func components(of color: UIColor) -> [CGFloat] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha]
    }

    private enum FixtureFailure: Error { case unexpectedState }
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
        var enumerationError: (any Error)?
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isRegularFileKey],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else { throw NotebookSaveFailure.storageUnavailable }
        var result: [String: Data] = [:]
        for case let item as URL in enumerator {
            let file = item.standardizedFileURL.resolvingSymlinksInPath()
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let prefix = base.path + "/"
                guard file.path.hasPrefix(prefix) else { throw NotebookSaveFailure.unsafeStorage }
                result[String(file.path.dropFirst(prefix.count))] = try Data(contentsOf: file)
            }
        }
        if let enumerationError { throw enumerationError }
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
