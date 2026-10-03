import Foundation
import NottyCore
import PencilKit
import SwiftUI
import UIKit
import XCTest
@testable import Notty

@MainActor
final class NotebookWritingStatusTests: XCTestCase {
    func testRetryClearsFailedPreservationFeedbackWithoutChangingPendingEdits() async throws {
        let (session, probe, root) = try await makeSession(failure: .storageFull)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = session.makeCanvasSeed()
        session.recordCompletedEdit(
            PKDrawing(strokes: [NotebookTestFixtures.stroke()]), ownerID: seed.ownerID
        )
        await session.waitUntilSettled()
        let pending = session.pendingEdits
        await probe.setPreserveFailure(.storageFull)
        await session.saveRecoveryCopy()
        XCTAssertEqual(session.recoveryFailure, .storageFull)
        XCTAssertNotNil(session.recoveryMessage)
        await probe.setSuspendSave()
        await probe.setSaveFailure(nil)
        let callsBeforeRetry = await probe.saveCalls
        session.retrySave()
        try await waitForSuspendedSave(probe, after: callsBeforeRetry, session: session)
        XCTAssertNil(session.recoveryFailure)
        XCTAssertNil(session.recoveryMessage)
        XCTAssertEqual(session.pendingEdits, pending)
        await probe.releaseSave()
        await session.waitUntilSettled()
        XCTAssertTrue(session.pendingEdits.isEmpty)
        XCTAssertEqual(session.inputGate, .open)
    }

    func testRetryClearsSuccessfulPreservationFeedback() async throws {
        let (session, probe, root) = try await makeSession(failure: .storageFull)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = session.makeCanvasSeed()
        session.recordCompletedEdit(
            PKDrawing(strokes: [NotebookTestFixtures.stroke()]), ownerID: seed.ownerID
        )
        await session.waitUntilSettled()
        await session.saveRecoveryCopy()
        XCTAssertTrue(session.canReopenSaved)
        XCTAssertNotNil(session.recoveryMessage)
        await probe.setSuspendSave()
        await probe.setSaveFailure(nil)
        let callsBeforeRetry = await probe.saveCalls
        session.retrySave()
        try await waitForSuspendedSave(probe, after: callsBeforeRetry, session: session)
        XCTAssertNil(session.recoveryMessage)
        XCTAssertNil(session.recoveryFailure)
        await probe.releaseSave()
        await session.waitUntilSettled()
        XCTAssertTrue(session.pendingEdits.isEmpty)
    }

    func testSaveFailureDoesNotResizeCanvasOrMoveViewport() async throws {
        let (session, probe, root) = try await makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = UIHostingController(rootView: NotebookScreen(session: session))
        let window = makeWindow(hosting)
        defer {
            notebookController(in: hosting)?.tearDown()
            window.isHidden = true
            window.rootViewController = nil
        }
        try await waitForUI { self.notebookController(in: hosting) != nil }
        hosting.view.layoutIfNeeded()
        let controller = try XCTUnwrap(notebookController(in: hosting))
        // This case controls session observations; native callback fixtures exercise the delegate separately.
        controller.canvasView.delegate = nil
        controller.canvasView.setZoomScale(0.75, animated: false)
        controller.canvasView.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
        try await settleLayout(hosting)
        let originalBounds = controller.canvasView.bounds.size
        let originalOffset = controller.canvasView.contentOffset
        let originalZoom = controller.canvasView.zoomScale
        let controllerID = ObjectIdentifier(controller)
        let generation = session.canvasGeneration
        let owner = try XCTUnwrap(session.canvasOwnerID)
        await probe.setSaveFailure(.storageFull)
        session.recordObservation(
            NotebookCanvasObservation(
                generation: 1,
                drawing: PKDrawing(strokes: [NotebookTestFixtures.stroke()]),
                capturedAt: Date(timeIntervalSince1970: 100), uptime: 10
            ), ownerID: owner
        )
        await session.waitUntilSettled()
        try await waitForUI { session.statusModel.state.status == .failed(.storageFull) }
        try await settleLayout(hosting)
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(notebookController(in: hosting))), controllerID)
        XCTAssertEqual(session.canvasGeneration, generation)
        XCTAssertEqual(controller.canvasView.bounds.size.width, originalBounds.width, accuracy: 0.5)
        XCTAssertEqual(controller.canvasView.bounds.size.height, originalBounds.height, accuracy: 0.5)
        XCTAssertEqual(controller.canvasView.contentOffset.x, originalOffset.x, accuracy: 0.5)
        XCTAssertEqual(controller.canvasView.contentOffset.y, originalOffset.y, accuracy: 0.5)
        XCTAssertEqual(controller.canvasView.zoomScale, originalZoom, accuracy: 0.001)
    }

    private func waitForSuspendedSave(
        _ probe: NotebookStorageProbe, after previousCalls: Int, session: NotebookSession
    ) async throws {
        do {
            for _ in 0..<100 {
                if await probe.saveCalls > previousCalls { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("The retried save did not begin within two seconds.")
            throw NotebookSaveFailure.unexpected
        } catch {
            await probe.releaseSave()
            await session.waitUntilSettled()
            throw error
        }
    }

    private func makeSession(
        failure: NotebookSaveFailure? = nil
    ) async throws -> (NotebookSession, NotebookStorageProbe, URL) {
        let id = UUID()
        let root = NotebookTestFixtures.root()
        let stored = try await NotebookTestFixtures.stored(id: id)
        let probe = try NotebookStorageProbe(stored: stored, recoveryRoot: root)
        await probe.setSaveFailure(failure)
        let storage = await probe.storage(notebookID: id)
        let session = NotebookSession(notebookID: id, openStorage: { storage })
        await session.load()
        XCTAssertEqual(session.loadState, .ready)
        return (session, probe, root)
    }

    private func makeWindow(_ hosting: UIViewController) -> UIWindow {
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_024, height: 1_366))
        }
        window.frame = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.layoutIfNeeded()
        return window
    }

    private func notebookController(in controller: UIViewController) -> NotebookViewController? {
        if let notebook = controller as? NotebookViewController { return notebook }
        for child in controller.children {
            if let notebook = notebookController(in: child) { return notebook }
        }
        return nil
    }

    private func settleLayout(_ hosting: UIViewController) async throws {
        try await Task.sleep(for: .milliseconds(100))
        hosting.view.layoutIfNeeded()
    }

    private func waitForUI(_ ready: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Writing status UI did not become ready within two seconds.")
        throw NotebookSaveFailure.unexpected
    }
}
