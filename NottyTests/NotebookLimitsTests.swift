import NottyCore
import PencilKit
import SwiftUI
import UIKit
import XCTest
@testable import Notty

@MainActor
final class NotebookLimitsTests: XCTestCase {
    func testNativeCountWarningKeepsCanvasAndEveryOfferedState() async throws {
        let id = UUID()
        let root = NotebookTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let stored = try await NotebookTestFixtures.stored(id: id)
        let probe = try NotebookStorageProbe(stored: stored, recoveryRoot: root)
        let storage = await probe.storage(notebookID: id)
        let session = NotebookSession(notebookID: id, openStorage: { storage })
        await session.load()
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let hosting = UIHostingController(rootView: NotebookScreen(session: session))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer {
            session.flush()
            window.isHidden = true
            window.rootViewController = nil
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while session.canvasOwnerID == nil {
            guard ContinuousClock.now < deadline else { throw FixtureFailure.readiness }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(100))
        hosting.view.layoutIfNeeded()
        let owner = try XCTUnwrap(session.canvasOwnerID)
        let controller = try XCTUnwrap(notebookController(in: hosting))
        // These two states are controlled offers; native callback fixtures are tested separately.
        controller.canvasView.delegate = nil
        let firstGeneration = (controller.captureBarrier()?.generation ?? 0) + 1
        await session.waitUntilSettled()
        let generation = session.canvasGeneration
        let screenBefore = session.renderDiagnostics.screenBodyCount
        let canvasBefore = session.renderDiagnostics.canvasUpdateCount
        let native = NotebookTestFixtures.stroke()
        let strokes = (0..<9_000).map { _ in
            var copy = native
            copy.id = UUID()
            return copy
        }
        session.recordObservation(
            NotebookCanvasObservation(generation: firstGeneration, drawing: PKDrawing(strokes: Array(strokes.prefix(8_999))),
                capturedAt: Date(timeIntervalSince1970: 1), uptime: 1), ownerID: owner
        )
        XCTAssertEqual(session.limitsModel.state.strokeCount, 8_999)
        XCTAssertFalse(session.limitsModel.state.isNearLimit)
        session.recordObservation(
            NotebookCanvasObservation(generation: firstGeneration + 1, drawing: PKDrawing(strokes: strokes),
                capturedAt: Date(timeIntervalSince1970: 2), uptime: 2), ownerID: owner
        )
        XCTAssertEqual(session.limitsModel.state.strokeCount, 9_000)
        XCTAssertTrue(session.limitsModel.state.isNearLimit)
        let pending = session.pendingEdits
        XCTAssertEqual(pending.map { $0.snapshot.drawing.strokes.count }, [8_999, 9_000])
        XCTAssertEqual(session.inputGate, .open)
        await session.waitUntilSettled()
        try await Task.sleep(for: .milliseconds(100))
        hosting.view.layoutIfNeeded()
        XCTAssertEqual(session.canvasGeneration, generation)
        XCTAssertEqual(session.renderDiagnostics.screenBodyCount, screenBefore)
        XCTAssertEqual(session.renderDiagnostics.canvasUpdateCount, canvasBefore)
        XCTAssertTrue(session.limitsModel.state.isNearLimit)
        let saved = try await storage.load()
        XCTAssertEqual(saved?.content.strokes.map(\.id), strokes.map(\.id))
        XCTAssertEqual(saved?.content.editStamp, pending.last?.stamp)
    }

    func testEncodedByteWarningHasTheExactNinetyPercentBoundary() {
        let model = NotebookLimitsPresentationModel()
        let identity = UUID()
        let installation = UUID()
        model.beginSnapshot(identity: identity, installation: installation, strokeCount: 8)
        model.recordEncodedBytes(60_397_977, identity: identity, installation: installation)
        XCTAssertFalse(model.state.isNearLimit)
        model.recordEncodedBytes(60_397_978, identity: identity, installation: installation)
        XCTAssertTrue(model.state.isNearLimit)
    }

    func testOldSnapshotAndInstallationCannotDisplayStaleEncodedBytes() {
        let model = NotebookLimitsPresentationModel()
        let oldIdentity = UUID()
        let currentIdentity = UUID()
        let oldInstallation = UUID()
        let installation = UUID()
        model.beginSnapshot(identity: oldIdentity, installation: oldInstallation, strokeCount: 8)
        model.recordEncodedBytes(60_397_978, identity: oldIdentity, installation: oldInstallation)
        XCTAssertTrue(model.state.isNearLimit)
        model.beginSnapshot(identity: currentIdentity, installation: installation, strokeCount: 1)
        XCTAssertNil(model.state.encodedBytes)
        model.recordEncodedBytes(60_397_978, identity: oldIdentity, installation: installation)
        model.recordEncodedBytes(60_397_978, identity: currentIdentity, installation: oldInstallation)
        XCTAssertNil(model.state.encodedBytes)
        XCTAssertFalse(model.state.isNearLimit)
        model.recordEncodedBytes(512, identity: currentIdentity, installation: installation)
        XCTAssertEqual(model.state.encodedBytes, 512)
    }

    func testSuccessfulEncodingReportsTheCurrentSavedArchiveBytes() async throws {
        let id = UUID()
        let root = NotebookTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let stored = try await NotebookTestFixtures.stored(id: id)
        let probe = try NotebookStorageProbe(stored: stored, recoveryRoot: root)
        let storage = await probe.storage(notebookID: id)
        let session = NotebookSession(notebookID: id, openStorage: { storage })
        await session.load()
        let seed = session.makeCanvasSeed()
        session.attachCanvas(ownerID: seed.ownerID, observations: { nil })
        let drawing = PKDrawing(strokes: [NotebookTestFixtures.stroke(), NotebookTestFixtures.stroke(x: 120)])
        session.recordObservation(
            NotebookCanvasObservation(generation: 1, drawing: drawing,
                capturedAt: Date(timeIntervalSince1970: 1), uptime: 1), ownerID: seed.ownerID
        )
        XCTAssertNil(session.limitsModel.state.encodedBytes)
        await session.waitUntilSettled()
        let loaded = try await storage.load()
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(session.limitsModel.state.encodedBytes, saved.content.strokes.reduce(0) { $0 + $1.data.count })
        XCTAssertEqual(session.limitsModel.state.strokeCount, 2)
        XCTAssertFalse(session.limitsModel.state.isNearLimit)
    }

    private func notebookController(in controller: UIViewController) -> NotebookViewController? {
        if let notebook = controller as? NotebookViewController { return notebook }
        for child in controller.children {
            if let notebook = notebookController(in: child) { return notebook }
        }
        return nil
    }

    private enum FixtureFailure: Error { case readiness }
}
