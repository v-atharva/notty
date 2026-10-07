import NottyCore
import PencilKit
import SwiftUI
import UIKit
import XCTest
@testable import Notty

/// Deleting a page from the Notebook menu: the page filling most of the view goes, with its ink,
/// and the later pages move up to close the gap. The deletion is one edit through the session's
/// saves, kept in the notebook's history, and one undo restores the exact paper. These tests open
/// a real notebook repository on the notebook screen, at the 12.9-inch iPad's portrait size.
@MainActor
final class NotebookPageDeletionTests: XCTestCase {
    private static var pageHeight: CGFloat { CGFloat(NotebookPaperMetrics.geometry.pageHeight) }

    // MARK: - Deleting

    /// Deleting page 7 of 12 removes the ink on it, moves the ink of pages 8 to 12 up by one page
    /// and leaves pages 1 to 6 untouched. The paper loses a page, and the page that followed takes
    /// the deleted page's place on screen.
    func testDeletingThePageUnderViewRemovesItsInkAndMovesTheLaterPagesUp() async throws {
        let notebook = try await mount()
        defer { notebook.close() }
        let controller = notebook.controller
        let canvas = controller.canvasView
        let session = notebook.session
        notebook.showTop(ofPage: 6)
        let offset = canvas.contentOffset
        let before = canvas.drawing
        let target = try XCTUnwrap(session.pageDeletionTarget())
        XCTAssertEqual(target, NotebookPageDeletionTarget(page: 6, pageCount: 12))
        XCTAssertTrue(session.pendingEdits.isEmpty)

        XCTAssertTrue(session.deletePage(target))

        XCTAssertEqual(controller.pageCount, 11)
        XCTAssertEqual(session.pageCount, 11)
        let ids = canvas.drawing.strokes.map(\.id)
        XCTAssertEqual(ids, notebook.strokes.filter { $0.page != 6 }.map(\.stroke.id),
            "Page 7's ink goes; every other stroke keeps its place in the drawing and its identity.")
        for placed in notebook.strokes where placed.page != 6 {
            let stroke = try XCTUnwrap(canvas.drawing.strokes.first { $0.id == placed.stroke.id })
            let shift: CGFloat = placed.page > 6 ? -Self.pageHeight : 0
            XCTAssertEqual(stroke.renderBounds.minY, placed.stroke.renderBounds.minY + shift, accuracy: 1,
                "The stroke on page \(placed.page + 1)")
            XCTAssertEqual(stroke.renderBounds.minX, placed.stroke.renderBounds.minX, accuracy: 1)
        }
        XCTAssertNotEqual(canvas.drawing, before)

        // The paper is a page shorter, with one divider fewer and its edge a page higher.
        let scale = canvas.zoomScale
        XCTAssertEqual(canvas.contentSize.height, 11 * Self.pageHeight * scale, accuracy: 0.5)
        XCTAssertEqual(controller.paperView.boundaryLayers.count, 10)
        XCTAssertEqual(controller.paperView.edgeLayer.position.y, 11 * Self.pageHeight, accuracy: 0.01)
        XCTAssertEqual(controller.paperView.belowPaperLayer.frame.minY, 11 * Self.pageHeight, accuracy: 0.01)

        XCTAssertEqual(canvas.contentOffset, offset, "Page 8 comes to where page 7 was, with no jump.")
        XCTAssertEqual(controller.mostVisiblePage, 6)

        let edits = session.pendingEdits
        XCTAssertEqual(edits.count, 1, "The deletion is one edit.")
        XCTAssertEqual(edits.first?.snapshot.pageCount, 11)
        XCTAssertEqual(edits.first?.snapshot.drawing.strokes.map(\.id), ids)
        XCTAssertEqual(session.limitsModel.state.strokeCount, ids.count)
        XCTAssertEqual(session.gateModel.state.pageCount, 11)
    }

    /// Deleting the last page while the end of the paper is in view leaves the end of the page
    /// before it in view, never the top of the notebook. A notebook at the page limit offers
    /// Add page again once it is below the limit, on the end card and in the menu.
    func testDeletingTheLastPageKeepsTheEndInViewAndReopensAddPage() async throws {
        let notebook = try await mount()
        defer { notebook.close() }
        let controller = notebook.controller
        let canvas = controller.canvasView
        let session = notebook.session
        notebook.revealEndCard()
        XCTAssertTrue(controller.isEndCardRevealed)
        XCTAssertEqual(controller.endOfNotebookCard.addPage, .limitReached)
        XCTAssertFalse(NotebookMenu.canAddPage(session.gateModel.state))
        let target = try XCTUnwrap(session.pageDeletionTarget())
        XCTAssertEqual(target.page, 11)

        XCTAssertTrue(session.deletePage(target))

        XCTAssertEqual(session.pageCount, 11)
        XCTAssertEqual(canvas.contentOffset.y, Self.endOffset(of: canvas), accuracy: 0.5,
            "The paper rests at its new end.")
        XCTAssertGreaterThan(canvas.contentOffset.y, 9 * Self.pageHeight * canvas.zoomScale)
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.endOfNotebookCard.addPage, .available)
        XCTAssertFalse(controller.endOfNotebookCard.isHidden, "The card stays under the new last page.")
        XCTAssertTrue(NotebookMenu.canAddPage(session.gateModel.state))
        session.extendPaper()
        XCTAssertEqual(session.pageCount, 12)
        XCTAssertEqual(controller.pageCount, 12)
    }

    // MARK: - Undo and redo

    /// One undo restores the exact drawing and page count, from the header's key, and redo
    /// deletes the page again; Command-Z and Shift-Command-Z, through the canvas, do the same.
    /// Each step is an edit of its own, and the keys' availability follows.
    func testOneUndoRestoresTheExactPaperAndRedoDeletesThePageAgain() async throws {
        let notebook = try await mount()
        defer { notebook.close() }
        let controller = notebook.controller
        let canvas = controller.canvasView
        let session = notebook.session
        let manager = try XCTUnwrap(canvas.undoManager)
        notebook.showTop(ofPage: 3)
        let offset = canvas.contentOffset
        let before = canvas.drawing
        XCTAssertTrue(session.deletePage(try XCTUnwrap(session.pageDeletionTarget())))
        let after = canvas.drawing
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Delete Page")
        XCTAssertTrue(session.commandModel.state.canUndo)
        XCTAssertFalse(session.commandModel.state.canRedo)

        session.undo()
        XCTAssertEqual(canvas.drawing, before, "The exact drawing returns.")
        XCTAssertEqual(canvas.drawing.strokes.map(\.id), before.strokes.map(\.id))
        XCTAssertEqual(canvas.drawing.strokes.map(\.transform), before.strokes.map(\.transform))
        XCTAssertEqual(controller.pageCount, 12)
        XCTAssertEqual(session.pageCount, 12)
        XCTAssertEqual(controller.paperView.boundaryLayers.count, 11)
        XCTAssertEqual(canvas.contentSize.height, 12 * Self.pageHeight * canvas.zoomScale, accuracy: 0.5)
        XCTAssertEqual(canvas.contentOffset, offset, "Page 4 comes back where it was.")
        XCTAssertEqual(manager.redoMenuItemTitle, "Redo Delete Page")
        XCTAssertFalse(session.commandModel.state.canUndo)
        XCTAssertTrue(session.commandModel.state.canRedo)

        session.redo()
        XCTAssertEqual(canvas.drawing, after)
        XCTAssertEqual(session.pageCount, 11)
        XCTAssertTrue(session.commandModel.state.canUndo)
        XCTAssertFalse(session.commandModel.state.canRedo)

        XCTAssertTrue(canvas.isFirstResponder)
        XCTAssertTrue(UIApplication.shared.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil, for: nil))
        XCTAssertEqual(canvas.drawing, before)
        XCTAssertEqual(session.pageCount, 12)
        XCTAssertTrue(UIApplication.shared.sendAction(NSSelectorFromString("redo:"), to: nil, from: nil, for: nil))
        XCTAssertEqual(canvas.drawing, after)
        XCTAssertEqual(session.pageCount, 11)

        XCTAssertEqual(session.pendingEdits.map(\.snapshot.pageCount), [11, 12, 11, 12, 11],
            "The deletion, each undo and each redo are edits of their own.")
        XCTAssertEqual(session.pendingEdits.map { $0.snapshot.drawing.strokes.map(\.id) }, [
            after, before, after, before, after,
        ].map { $0.strokes.map(\.id) })
    }

    /// The canvas's earlier actions, PencilKit's own for each stroke, are cleared as the page is
    /// deleted: after the one undo that restores the paper nothing is left to undo, so none of
    /// them can ever run against the paper the deletion left. An action recorded in the same turn
    /// as the deletion is cleared as well. A hosted test cannot draw a stroke for PencilKit to
    /// record, so a registered action stands in for one; clearing the stack takes every action,
    /// whatever its target.
    func testActionsRecordedBeforeTheDeletionCanNeverRunAfterIt() async throws {
        let notebook = try await mount()
        defer { notebook.close() }
        let controller = notebook.controller
        let canvas = controller.canvasView
        let session = notebook.session
        let manager = try XCTUnwrap(canvas.undoManager)
        let earlier = StaleStrokeAction(canvas: canvas)
        earlier.register(on: manager)
        await NotebookTestFixtures.drainMainQueue()
        XCTAssertTrue(session.commandModel.state.canUndo)
        earlier.register(on: manager)
        notebook.showTop(ofPage: 2)
        let before = canvas.drawing

        XCTAssertTrue(session.deletePage(try XCTUnwrap(session.pageDeletionTarget())))
        session.undo()
        XCTAssertEqual(canvas.drawing, before)
        XCTAssertEqual(session.pageCount, 12)
        XCTAssertFalse(manager.canUndo, "Nothing older than the deletion is left.")
        XCTAssertFalse(session.commandModel.state.canUndo)
        session.undo()
        XCTAssertFalse(canvas.canPerformAction(NSSelectorFromString("undo:"), withSender: nil), "Command-Z has nothing to undo.")
        await NotebookTestFixtures.drainMainQueue()
        XCTAssertEqual(earlier.runs, 0)
        XCTAssertEqual(canvas.drawing, before)
        XCTAssertEqual(session.pageCount, 12)

        session.redo()
        await NotebookTestFixtures.drainMainQueue()
        session.undo()
        XCTAssertEqual(canvas.drawing, before)
        XCTAssertEqual(earlier.runs, 0)
    }

    /// A page added after the deletion, with a stroke written on it, survives undoing both and
    /// redoing both: the redo of the deletion keeps the added page, so the stroke comes back on
    /// the paper, on the page it was written on, and is saved so. A registered action stands in
    /// for PencilKit's own for the stroke.
    func testRedoingADeletionKeepsThePageAddedAfterItAndTheInkWrittenThere() async throws {
        let notebook = try await mount()
        defer { notebook.close() }
        let controller = notebook.controller
        let canvas = controller.canvasView
        let session = notebook.session
        let manager = try XCTUnwrap(canvas.undoManager)
        notebook.showTop(ofPage: 6)
        let before = canvas.drawing
        XCTAssertTrue(session.deletePage(try XCTUnwrap(session.pageDeletionTarget())))
        let after = canvas.drawing
        await NotebookTestFixtures.drainMainQueue()
        session.extendPaper()
        XCTAssertEqual(controller.pageCount, 12)
        var stroke = NotebookTestFixtures.stroke(x: 400)
        stroke.transform = CGAffineTransform(translationX: 0, y: 11.5 * Self.pageHeight)
        let written = StrokeAddition(canvas: canvas, stroke: stroke)
        written.perform(on: manager)
        await NotebookTestFixtures.drainMainQueue()
        let grown = canvas.drawing
        XCTAssertEqual(grown.strokes.map(\.id), after.strokes.map(\.id) + [stroke.id])

        session.undo()
        Self.assertSameInk(canvas.drawing, after)
        session.undo()
        XCTAssertEqual(canvas.drawing, before)
        XCTAssertEqual(session.pageCount, 12)
        session.redo()
        Self.assertSameInk(canvas.drawing, after)
        XCTAssertEqual(controller.pageCount, 12, "The page added after the deletion comes back with it.")
        XCTAssertEqual(session.pageCount, 12)
        session.redo()
        Self.assertSameInk(canvas.drawing, grown)
        XCTAssertEqual(controller.pageCount, 12)
        XCTAssertEqual(session.pageCount, 12)
        let restored = try XCTUnwrap(canvas.drawing.strokes.first { $0.id == stroke.id })
        XCTAssertLessThan(restored.renderBounds.maxY, CGFloat(controller.pageCount) * Self.pageHeight,
            "The stroke lies on the paper.")
        XCTAssertEqual(NotebookPaperMetrics.geometry.page(holding: Double(restored.renderBounds.midY), pageCount: 12), 11)
        XCTAssertEqual(canvas.contentSize.height, 12 * Self.pageHeight * canvas.zoomScale, accuracy: 0.5)
        XCTAssertEqual(written.runs, 2)

        await session.waitUntilSettled()
        let loaded = try await NotebookRepository(rootURL: notebook.libraryRoot).load(id: notebook.id)
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.content.pageCount, 12)
        XCTAssertEqual(saved.content.strokes.map(\.id), grown.strokes.map(\.id))

        session.undo()
        session.undo()
        XCTAssertEqual(canvas.drawing, before)
        XCTAssertEqual(session.pageCount, 12)
        XCTAssertFalse(session.commandModel.state.canUndo)
    }

    /// Pages added after a deletion, or after its undo, are not the deletion's to take away: the
    /// undo gives back only the deleted page and the redo takes only that page again, within the
    /// page limit. Each drawing returns exactly.
    func testPagesAddedAroundADeletionStayThroughItsUndoAndRedo() async throws {
        let notebook = try await mount()
        defer { notebook.close() }
        let controller = notebook.controller
        let canvas = controller.canvasView
        let session = notebook.session
        for _ in 0..<2 {
            notebook.showTop(ofPage: 3)
            XCTAssertTrue(session.deletePage(try XCTUnwrap(session.pageDeletionTarget())))
            await NotebookTestFixtures.drainMainQueue()
        }
        let tenPages = canvas.drawing
        notebook.showTop(ofPage: 3)
        XCTAssertTrue(session.deletePage(try XCTUnwrap(session.pageDeletionTarget())))
        let ninePages = canvas.drawing
        XCTAssertEqual(session.pageCount, 9)
        await NotebookTestFixtures.drainMainQueue()

        session.extendPaper()
        XCTAssertEqual(session.pageCount, 10)
        session.undo()
        XCTAssertEqual(canvas.drawing, tenPages)
        XCTAssertEqual(session.pageCount, 11, "The deleted page returns beside the page added after it.")
        XCTAssertEqual(controller.pageCount, 11)
        XCTAssertEqual(controller.paperView.boundaryLayers.count, 10)

        session.extendPaper()
        XCTAssertEqual(session.pageCount, 12)
        session.redo()
        XCTAssertEqual(canvas.drawing, ninePages)
        XCTAssertEqual(session.pageCount, 11, "Only the deleted page goes again.")
        XCTAssertEqual(controller.pageCount, 11)

        session.undo()
        XCTAssertEqual(canvas.drawing, tenPages)
        XCTAssertEqual(session.pageCount, 12, "Held to the page limit.")
        XCTAssertEqual(controller.pageCount, 12)

        await session.waitUntilSettled()
        let loaded = try await NotebookRepository(rootURL: notebook.libraryRoot).load(id: notebook.id)
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.content.pageCount, 12)
        XCTAssertEqual(saved.content.strokes.map(\.id), tenPages.strokes.map(\.id))
    }

    // MARK: - Saving

    /// The deletion is saved as a revision of its own: the notebook reopens with eleven pages and
    /// the moved ink, the revision before still holds twelve pages and the deleted ink, and the
    /// history check on reopening covers both.
    func testTheDeletionIsSavedAsARevisionAndTheHistoryKeepsThePaperBeforeIt() async throws {
        let notebook = try await mount()
        defer { notebook.close() }
        let session = notebook.session
        notebook.showTop(ofPage: 4)
        let deleted = notebook.strokes.filter { $0.page == 4 }.map(\.stroke.id)
        XCTAssertFalse(deleted.isEmpty)
        XCTAssertTrue(session.deletePage(try XCTUnwrap(session.pageDeletionTarget())))
        let remaining = notebook.controller.canvasView.drawing.strokes.map(\.id)
        await session.waitUntilSettled()
        XCTAssertEqual(session.pendingEdits.count, 0)
        guard case .saved = session.saveState else { return XCTFail("\(session.saveState)") }

        let repository = try NotebookRepository(rootURL: notebook.libraryRoot)
        let loaded = try await repository.load(id: notebook.id)
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.content.pageCount, 11)
        XCTAssertEqual(saved.content.strokes.map(\.id), remaining)
        let history = try await repository.history(id: notebook.id)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.first?.revisionID, saved.revisionID)
        let previous = try await repository.loadRevision(id: notebook.id, revisionID: try XCTUnwrap(history.last).revisionID)
        XCTAssertEqual(previous.content.pageCount, 12)
        XCTAssertEqual(previous.content.strokes.map(\.id), notebook.strokes.map(\.stroke.id),
            "The revision before the deletion keeps every stroke, the deleted ones included.")

        let reopened = NotebookSession(notebookID: notebook.id, openStorage: { [library = notebook.library, id = notebook.id] in
            await library.storage(notebookID: id)
        })
        await reopened.load()
        XCTAssertEqual(reopened.loadState, .ready)
        try await NotebookTestFixtures.waitUntil { reopened.integrityModel.state == .verified(revisions: 2) }
        XCTAssertEqual(reopened.pageCount, 11)
        XCTAssertEqual(reopened.workingDrawing.strokes.map(\.id), remaining)
        for placed in notebook.strokes where placed.page > 4 {
            let stroke = try XCTUnwrap(reopened.workingDrawing.strokes.first { $0.id == placed.stroke.id })
            XCTAssertEqual(stroke.renderBounds.minY, placed.stroke.renderBounds.minY - Self.pageHeight, accuracy: 1)
        }
    }

    /// A deletion that cannot be saved waits like any edit and goes into a recovery copy with its
    /// page count, while the saved notebook keeps its twelve pages.
    func testADeletionThatCannotBeSavedGoesIntoARecoveryCopy() async throws {
        let notebook = try await mount()
        defer { notebook.close() }
        let session = notebook.session
        await notebook.saves.fail(true)
        notebook.showTop(ofPage: 1)
        XCTAssertTrue(session.deletePage(try XCTUnwrap(session.pageDeletionTarget())))
        let remaining = notebook.controller.canvasView.drawing.strokes.count
        try await NotebookTestFixtures.waitUntil { session.canPreserveRecovery }
        XCTAssertEqual(session.inputGate, .failed)
        XCTAssertEqual(session.pendingEdits.map(\.snapshot.pageCount), [11])

        await session.saveRecoveryCopy()
        await session.refreshRecoveryCopies()
        let copy = try XCTUnwrap(session.recoveryCopies.first)
        let metadata = try await session.inspectRecoveryCopy(id: copy.id)
        XCTAssertEqual(metadata.edits.map(\.pageCount), [11])
        XCTAssertEqual(metadata.edits.map(\.strokeCount), [remaining])
        let loaded = try await NotebookRepository(rootURL: notebook.libraryRoot).load(id: notebook.id)
        XCTAssertEqual(loaded?.content.pageCount, 12)
        await notebook.saves.fail(false)
    }

    // MARK: - When deletion is unavailable

    /// No page can be deleted while writing is paused for any reason, during a stroke, from a
    /// single page, from a notebook still opening, or for a page count that has changed since
    /// the page was offered.
    func testDeletionIsUnavailableWhileWritingIsPausedOrAStrokeIsUnderWay() async throws {
        typealias Gate = NotebookCanvasGateModel.State
        typealias Commands = NotebookCanvasCommandModel.State
        let target = NotebookPageDeletionTarget(page: 4, pageCount: 12)
        let idle = Commands(canUndo: false, canRedo: false, isUsingTool: false, canOpenRecoveryCopies: true)
        let stroking = Commands(canUndo: false, canRedo: false, isUsingTool: true, canOpenRecoveryCopies: false)
        XCTAssertTrue(NotebookMenu.canDeletePage(target, gate: Gate(pageCount: 12, inputGate: .open), commands: idle))
        for gate in [NotebookInputGate.capacity, .failed, .recovering, .readOnly] {
            XCTAssertFalse(NotebookMenu.canDeletePage(target, gate: Gate(pageCount: 12, inputGate: gate), commands: idle),
                "\(gate)")
        }
        XCTAssertFalse(NotebookMenu.canDeletePage(target, gate: Gate(pageCount: 12, inputGate: .open), commands: stroking))
        XCTAssertFalse(NotebookMenu.canDeletePage(target, gate: Gate(pageCount: 11, inputGate: .open), commands: idle))
        XCTAssertFalse(NotebookMenu.canDeletePage(
            NotebookPageDeletionTarget(page: 0, pageCount: 1), gate: Gate(pageCount: 1, inputGate: .open), commands: idle
        ))
        XCTAssertFalse(NotebookMenu.canDeletePage(nil, gate: Gate(pageCount: 12, inputGate: .open), commands: idle))

        let opening = NotebookSession()
        XCTAssertNil(opening.pageDeletionTarget())
        XCTAssertFalse(opening.deletePage(NotebookPageDeletionTarget(page: 0, pageCount: 3)))

        let notebook = try await mount()
        defer { notebook.close() }
        let controller = notebook.controller
        let canvas = controller.canvasView
        let session = notebook.session
        let drawing = canvas.drawing
        controller.canvasViewDidBeginUsingTool(canvas)
        XCTAssertFalse(controller.canDeletePage)
        XCTAssertFalse(session.deletePage(target), "Never during a stroke.")
        controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertFalse(session.deletePage(NotebookPageDeletionTarget(page: 4, pageCount: 11)), "A stale page count.")
        for gate in [NotebookInputGate.capacity, .failed, .recovering, .readOnly] {
            controller.setInputGate(gate)
            XCTAssertFalse(controller.deletePage(4), "\(gate)")
        }
        controller.setInputGate(.open)
        XCTAssertEqual(canvas.drawing, drawing)
        XCTAssertEqual(session.pageCount, 12)
        XCTAssertTrue(session.pendingEdits.isEmpty)
        XCTAssertTrue(controller.canDeletePage)

        let single = NotebookViewController(pageCount: 1, initialDrawing: PKDrawing(), toolStore: NotebookTestFixtures.toolStore())
        single.onPaperReplacement = { _, _ in .open }
        let window = try NotebookTestFixtures.window(showing: single)
        defer {
            single.tearDown()
            window.isHidden = true
            window.rootViewController = nil
        }
        try await NotebookTestFixtures.waitUntil { single.isCanvasVisible }
        XCTAssertFalse(single.canDeletePage)
        XCTAssertFalse(single.deletePage(0))
        XCTAssertEqual(single.pageCount, 1)
    }

    // MARK: - The menu and the alert

    /// "Delete this page…" offers the page under view, read by VoiceOver with its number. Choosing
    /// it closes the menu and deletes nothing; once the menu has gone an alert asks to confirm,
    /// with the header and tools held in sight from the request until the alert closes.
    func testTheMenuOffersThePageUnderViewAndAnAlertConfirmsTheDeletion() async throws {
        let notebook = try await mount()
        defer { notebook.close() }
        let session = notebook.session
        let chrome = session.writingChrome
        let prompt = session.pageDeletionPrompt
        notebook.showTop(ofPage: 6)
        let target = try XCTUnwrap(session.pageDeletionTarget())
        XCTAssertEqual(NotebookMenuActions.deletionLabel(for: target), "Delete page 7")
        XCTAssertEqual(NotebookMenuActions.deletionLabel(for: nil), "Delete this page")
        var closes = 0
        let menu = NotebookMenu(
            session: session, chrome: chrome, gate: session.gateModel, commands: session.commandModel,
            hostWidth: 1_024, sizeClass: .regular, offersRedo: false, close: { closes += 1 }, openRecoveryCopies: {},
            pageToDelete: target
        )
        XCTAssertTrue(NotebookMenu.canDeletePage(target, gate: session.gateModel.state, commands: session.commandModel.state))

        menu.deletePage()
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(prompt.target, target)
        XCTAssertFalse(prompt.isPresented, "Nothing opens while the menu is still leaving.")
        XCTAssertEqual(session.pageCount, 12, "Nothing is deleted before the alert confirms it.")
        try await NotebookTestFixtures.waitUntil { chrome.state.pins.contains(.presentation) }

        prompt.menuDidDisappear()
        let alert = try await NotebookTestFixtures.waitForValue {
            notebook.hosting.presentedViewController as? UIAlertController
        }
        XCTAssertEqual(alert.title, "Delete page 7 of 12?")
        XCTAssertEqual(alert.message, "Its writing will be removed. You can undo this right away.")
        XCTAssertEqual(alert.actions.map(\.title), ["Delete Page", "Cancel"])
        XCTAssertEqual(alert.actions.map(\.style), [.destructive, .cancel])
        XCTAssertEqual(alert.actions.map(\.isEnabled), [true, true])
        XCTAssertTrue(chrome.state.pins.contains(.presentation))

        prompt.confirm(target)
        XCTAssertEqual(session.pageCount, 11)
        prompt.setPresented(false)
        try await NotebookTestFixtures.waitUntil { notebook.hosting.presentedViewController == nil }
        try await NotebookTestFixtures.waitUntil { !chrome.state.pins.contains(.presentation) }
        XCTAssertNil(prompt.target)
        prompt.menuDidDisappear()
        XCTAssertFalse(prompt.isPresented, "A menu closed for anything else opens no alert.")
    }

    /// A page that can no longer be deleted by the time the alert opens, here because the page
    /// count changed after the menu asked, is offered with Delete Page disabled and a message
    /// saying why. Confirming regardless, as a notebook that changes while the alert is open
    /// allows, deletes nothing.
    func testTheAlertOffersNoDeletionThatCanNoLongerBeMade() async throws {
        let notebook = try await mount()
        defer { notebook.close() }
        let session = notebook.session
        let prompt = session.pageDeletionPrompt
        notebook.showTop(ofPage: 6)
        let target = try XCTUnwrap(session.pageDeletionTarget())
        prompt.request(target)
        notebook.showTop(ofPage: 2)
        XCTAssertTrue(session.deletePage(try XCTUnwrap(session.pageDeletionTarget())))
        let drawing = notebook.controller.canvasView.drawing

        prompt.menuDidDisappear()
        let alert = try await NotebookTestFixtures.waitForValue {
            notebook.hosting.presentedViewController as? UIAlertController
        }
        XCTAssertEqual(alert.title, "Delete page 7 of 12?")
        XCTAssertEqual(alert.message, "Writing paused or the notebook changed, so the page can't be deleted now.")
        XCTAssertEqual(alert.actions.map(\.title), ["Delete Page", "Cancel"])
        XCTAssertEqual(alert.actions.map(\.isEnabled), [false, true])

        prompt.confirm(target)
        XCTAssertEqual(session.pageCount, 11)
        XCTAssertEqual(notebook.controller.canvasView.drawing, drawing, "Nothing more is deleted.")
        XCTAssertEqual(NotebookPageDeletionPrompt.refusalAnnouncement(for: target), "Page 7 wasn't deleted")
        prompt.setPresented(false)
        try await NotebookTestFixtures.waitUntil { notebook.hosting.presentedViewController == nil }
        try await NotebookTestFixtures.waitUntil { !session.writingChrome.state.pins.contains(.presentation) }
    }

    /// A request whose alert never opened is dropped when the menu opens again, or when the canvas
    /// it was made on goes: no alert opens for it later, and the header and tools are released.
    func testARequestWhoseAlertNeverOpenedIsWithdrawn() async throws {
        let notebook = try await mount()
        defer { notebook.close() }
        let session = notebook.session
        let chrome = session.writingChrome
        let prompt = session.pageDeletionPrompt
        notebook.showTop(ofPage: 6)
        let target = try XCTUnwrap(session.pageDeletionTarget())
        prompt.request(target)
        try await NotebookTestFixtures.waitUntil { chrome.state.pins.contains(.presentation) }

        XCTAssertEqual(NotebookMenuKey.pageToDelete(openingMenuOver: session), target)
        XCTAssertNil(prompt.target)
        try await NotebookTestFixtures.waitUntil { !chrome.state.pins.contains(.presentation) }
        prompt.menuDidDisappear()
        XCTAssertFalse(prompt.isPresented)

        prompt.request(target)
        XCTAssertEqual(prompt.target, target)
        notebook.controller.tearDown()
        try await NotebookTestFixtures.waitUntil { prompt.target == nil }
        prompt.menuDidDisappear()
        XCTAssertFalse(prompt.isPresented)
        try await NotebookTestFixtures.waitUntil { !chrome.state.pins.contains(.presentation) }
        XCTAssertNil(notebook.hosting.presentedViewController)
        XCTAssertEqual(session.pageCount, 12)
    }

    /// The row draws its glyph in the alert tone while a page can be deleted, and in the disabled
    /// tone otherwise.
    func testTheDeletionRowDrawsInTheAlertToneOnlyWhileAvailable() throws {
        let session = NotebookSession()
        let gate = NotebookCanvasGateModel()
        let target = NotebookPageDeletionTarget(page: 2, pageCount: 5)
        func glyph(pageCount: Int, gate inputGate: NotebookInputGate) throws -> [CGFloat] {
            gate.update(pageCount: pageCount, inputGate: inputGate)
            let width = NotebookTheme.popoverWidth - 2 * NotebookTheme.popoverPadding
            let pixels = try RenderedPixels(rendering:
                NotebookMenuActions(
                    session: session, gate: gate, commands: session.commandModel, offersRedo: false,
                    addPage: {}, openRecoveryCopies: {}, pageToDelete: target
                )
                .frame(width: width)
                .background(NotebookTheme.panelSurface.color)
            )
            // The second row's glyph column.
            let top = NotebookTheme.menuRowHeight + NotebookTheme.itemSpacing
            var darkest: (luminance: CGFloat, rgb: [CGFloat]) = (2, [])
            for y in stride(from: top + 4, to: top + NotebookTheme.menuRowHeight - 4, by: 0.5) {
                for x in stride(from: NotebookTheme.menuGlyphInset, to: NotebookTheme.menuGlyphInset + 24, by: 0.5) {
                    let pixel = pixels.rgba(at: CGPoint(x: x, y: y)).map { CGFloat($0) / 255 }
                    let luminance = 0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2]
                    if luminance < darkest.luminance { darkest = (luminance, Array(pixel.prefix(3))) }
                }
            }
            return darkest.rgb
        }
        func rgb(_ tone: NotebookTheme.Tone) -> [CGFloat] {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
            tone.uiColor.getRed(&red, green: &green, blue: &blue, alpha: nil)
            return [red, green, blue]
        }
        for (drawn, expected) in zip(try glyph(pageCount: 5, gate: .open), rgb(NotebookTheme.alertGlyph)) {
            XCTAssertEqual(drawn, expected, accuracy: 0.04)
        }
        for (pageCount, inputGate) in [(5, NotebookInputGate.capacity), (1, .open), (4, .open)] {
            for (drawn, expected) in zip(try glyph(pageCount: pageCount, gate: inputGate), rgb(NotebookTheme.disabledGlyph)) {
                XCTAssertEqual(drawn, expected, accuracy: 0.04, "\(pageCount) pages, \(inputGate)")
            }
        }
    }

    /// A canvas update from a view built before the deletion applies the session's page count, so
    /// it never grows the deleted page back.
    func testAnUpdateFromBeforeTheDeletionNeverGrowsThePaperBack() async throws {
        let notebook = try await mount()
        defer { notebook.close() }
        let controller = notebook.controller
        let session = notebook.session
        let stale = NotebookCanvas(session: session)
        XCTAssertEqual(stale.pageCount, 12)
        notebook.showTop(ofPage: 8)
        XCTAssertTrue(session.deletePage(try XCTUnwrap(session.pageDeletionTarget())))
        stale.update(controller, chrome: controller.chrome, toolbarStore: notebook.store)
        XCTAssertEqual(controller.pageCount, 11)
        XCTAssertEqual(controller.canvasView.contentSize.height,
            11 * Self.pageHeight * controller.canvasView.zoomScale, accuracy: 0.5)
        XCTAssertEqual(session.pendingEdits.map(\.snapshot.pageCount), [11])
    }

    // MARK: - Fixtures

    private struct PlacedStroke {
        let page: Int
        let stroke: PKStroke
    }

    @MainActor
    private struct MountedNotebook {
        let id: UUID
        let libraryRoot: URL
        let library: NotebookLibraryAccess
        let saves: SaveSwitch
        let strokes: [PlacedStroke]
        let hosting: AppearanceTrackingHostingController<NotebookScreen>
        let window: UIWindow
        let session: NotebookSession
        let store: NotebookSceneToolStore
        let controller: NotebookViewController

        /// Rests the top of `page`, counted from zero, at the top of the visible area.
        func showTop(ofPage page: Int) {
            let canvas = controller.canvasView
            let y = CGFloat(page) * NotebookPageDeletionTests.pageHeight * canvas.zoomScale - canvas.contentInset.top
            canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: y), animated: false)
        }

        /// Pulls the page from rest at its end past the threshold and lets it settle lifted over the card.
        func revealEndCard() {
            let canvas = controller.canvasView
            let end = NotebookPageDeletionTests.endOffset(of: canvas)
            canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: end), animated: false)
            controller.scrollViewWillBeginDragging(canvas)
            canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: end + 100), animated: false)
            var target = CGPoint(x: canvas.contentOffset.x, y: end)
            controller.scrollViewWillEndDragging(canvas, withVelocity: CGPoint(x: 0, y: 0.5), targetContentOffset: &target)
            canvas.setContentOffset(target, animated: false)
            controller.scrollViewDidEndDecelerating(canvas)
            controller.view.layoutIfNeeded()
        }

        /// Retires the canvas before the screen goes, as the app does before it replaces a
        /// notebook, so the session hears the canvas leave outside SwiftUI's update.
        func close() {
            session.flush()
            controller.tearDown()
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    /// Fails every save while on, for a notebook whose edits must wait.
    private actor SaveSwitch {
        private(set) var isFailing = false

        func fail(_ failing: Bool) { isFailing = failing }
    }

    /// A twelve-page notebook in a real repository with two strokes on each page, open on the
    /// notebook screen with its history checked.
    private func mount() async throws -> MountedNotebook {
        let id = UUID()
        let root = NotebookTestFixtures.root()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent("library", isDirectory: true)
        let library = NotebookLibraryAccess(
            libraryRoot: libraryRoot, recoveryRoot: root.appendingPathComponent("recovery", isDirectory: true)
        )
        let strokes = (0..<12).flatMap { page in
            [0.3, 0.75].map { fraction in
                var stroke = NotebookTestFixtures.stroke(x: 120 + 300 * fraction)
                stroke.transform = CGAffineTransform(translationX: 0, y: (CGFloat(page) + fraction) * Self.pageHeight - 40)
                return PlacedStroke(page: page, stroke: stroke)
            }
        }
        _ = try await NotebookRepository(rootURL: libraryRoot).save(
            id: id,
            content: NotebookContent(
                title: "Lecture notes", pageCount: 12,
                strokes: try await InkCodec().encode(PKDrawing(strokes: strokes.map(\.stroke))),
                editStamp: NotebookTestFixtures.stamp(1)
            ),
            expectedRevisionID: nil
        )
        let saves = SaveSwitch()
        let base = await library.storage(notebookID: id)
        let storage = NotebookStorage(
            load: base.load, save: base.save, preserve: base.preserve, listRecovery: base.listRecovery,
            loadRecovery: base.loadRecovery, storageMetrics: base.storageMetrics, openForEditing: base.openForEditing,
            captureHistoryPin: base.captureHistoryPin, auditHistory: base.auditHistory,
            recoveryStates: base.recoveryStates, inspectRecovery: base.inspectRecovery,
            loadRecoveryEdit: base.loadRecoveryEdit,
            saveBatch: { edits, revision in
                if await saves.isFailing { throw NotebookSaveFailure.storageUnavailable }
                return try await base.saveBatch(edits, revision)
            }
        )
        let session = NotebookSession(notebookID: id, openStorage: { storage })
        let scene = try NotebookTestFixtures.windowScene()
        NotebookTestFixtures.restoreSceneToolDefaults(for: scene, after: self)
        let store = NotebookSceneToolStore.owner(for: scene)
        let toolbar = store.toolbar
        let tool = store.tool
        addTeardownBlock { @MainActor in
            store.update { $0 = tool }
            store.updateToolbar(toolbar)
            store.setToolsHidden(false)
        }
        store.updateToolbar(.standard)
        let previousKeyWindow = scene.keyWindow
        addTeardownBlock { @MainActor in previousKeyWindow?.makeKey() }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)
        let hosting = AppearanceTrackingHostingController(rootView: NotebookScreen(session: session))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        do {
            try await NotebookTestFixtures.waitUntilAppeared(hosting)
            let controller = try await NotebookTestFixtures.waitForValue { () -> NotebookViewController? in
                guard let controller = NotebookTestFixtures.notebookController(in: hosting),
                      controller.isCanvasVisible, store.isToolbarAvailable, store.overlayObstruction.top > 0,
                      controller.canvasView.contentInset.top > 0, controller.canvasView.isFirstResponder,
                      session.integrityModel.state == .verified(revisions: 1) else { return nil }
                return controller
            }
            hosting.view.layoutIfNeeded()
            return MountedNotebook(
                id: id, libraryRoot: libraryRoot, library: library, saves: saves, strokes: strokes,
                hosting: hosting, window: window, session: session, store: store, controller: controller
            )
        } catch {
            session.flush()
            window.isHidden = true
            window.rootViewController = nil
            throw error
        }
    }

    /// The same strokes, in the same order and places: a drawing an action rebuilds stroke by
    /// stroke is a new drawing value with the same ink.
    private static func assertSameInk(
        _ drawing: PKDrawing, _ expected: PKDrawing, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(drawing.strokes.map(\.id), expected.strokes.map(\.id), file: file, line: line)
        XCTAssertEqual(drawing.strokes.map(\.transform), expected.strokes.map(\.transform), file: file, line: line)
        XCTAssertEqual(drawing.strokes.map(\.renderBounds), expected.strokes.map(\.renderBounds), file: file, line: line)
    }

    private static func endOffset(of canvas: UIScrollView) -> CGFloat {
        max(-canvas.contentInset.top, canvas.contentSize.height - canvas.bounds.height + canvas.contentInset.bottom)
    }
}

/// Stands in for one of PencilKit's own stroke actions on the canvas's undo stack: run against the
/// paper a page deletion left, it would put back a drawing from before the deletion.
@MainActor
private final class StaleStrokeAction {
    private weak var canvas: PKCanvasView?
    private let stale: PKDrawing
    private(set) var runs = 0

    init(canvas: PKCanvasView) {
        self.canvas = canvas
        stale = canvas.drawing
    }

    func register(on manager: UndoManager) {
        manager.registerUndo(withTarget: self) { action in
            action.runs += 1
            action.canvas?.drawing = action.stale
        }
    }
}

/// Stands in for PencilKit's own action for a stroke drawn on the canvas: it adds the stroke, its
/// undo takes the stroke away and registers the redo that puts it back.
@MainActor
private final class StrokeAddition {
    private weak var canvas: PKCanvasView?
    private let stroke: PKStroke
    private(set) var runs = 0

    init(canvas: PKCanvasView, stroke: PKStroke) {
        self.canvas = canvas
        self.stroke = stroke
    }

    func perform(on manager: UndoManager) {
        runs += 1
        canvas?.drawing.strokes.append(stroke)
        manager.registerUndo(withTarget: self) { [weak manager] addition in
            guard let manager else { return }
            addition.canvas?.drawing.strokes.removeAll { $0.id == addition.stroke.id }
            manager.registerUndo(withTarget: addition) { [weak manager] addition in
                guard let manager else { return }
                addition.perform(on: manager)
            }
        }
    }
}
