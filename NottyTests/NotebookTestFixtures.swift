import Foundation
import NottyCore
import PencilKit
import SwiftUI
import UIKit
import XCTest
@testable import Notty

enum NotebookTestFixtures {
    static func stroke(id: UUID = UUID(), x: CGFloat = 20) -> PKStroke {
        let points = (0..<4).map { index in
            PKStrokePoint(
                location: CGPoint(x: x + CGFloat(index) * 10, y: 40),
                timeOffset: Double(index) * 0.02,
                size: CGSize(width: 3, height: 3),
                opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
            )
        }
        var stroke = PKStroke(
            ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_000))
        )
        stroke.id = id
        return stroke
    }

    /// A tool store backed by its own defaults suite, so tests never change the host app's
    /// settings and never see each other's. The suite is emptied and deleted when the test ends.
    @MainActor
    static func toolStore() -> NotebookSceneToolStore {
        let suite = temporaryDefaultsSuite()
        return NotebookSceneToolStore(identifier: suite, defaults: UserDefaults(suiteName: suite)!)
    }

    /// The name of an empty defaults suite, distinct from every other suite handed out in
    /// the current test, that is emptied and deleted when the test ends.
    @MainActor
    static func temporaryDefaultsSuite() -> String {
        TemporaryDefaultsSuites.shared.next()
    }

    /// Restores the host app's stored tool and toolbar settings for `scene` when `testCase`
    /// ends, for tests that must use the scene-owned store.
    @MainActor
    static func restoreSceneToolDefaults(for scene: UIWindowScene, after testCase: XCTestCase) {
        let keys = [
            "notty.editor.tool." + scene.session.persistentIdentifier,
            NotebookSceneToolStore.lastToolDefaultsKey,
            NotebookSceneToolStore.toolbarDefaultsKey
        ]
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        testCase.addTeardownBlock {
            for (key, value) in saved {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
    }

    static func stamp(_ index: Int) -> NotebookEditStamp {
        NotebookEditStamp(
            capturedAt: Date(timeIntervalSince1970: Double(index)),
            uptime: Double(index) / 10,
            sessionID: UUID(uuidString: "6435D7F3-7945-475B-8A86-9A66B8DF32AD")!
        )
    }

    static func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    static func stored(drawing: PKDrawing = PKDrawing(), id: UUID) async throws -> StoredNotebook {
        StoredNotebook(
            id: id, revisionID: UUID(), sequence: 1,
            content: NotebookContent(
                title: "Notebook", pageCount: 3, strokes: try await InkCodec().encode(drawing)
            ),
            savedAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}

// MARK: - Windows and waiting

extension NotebookTestFixtures {
    /// How long a hosted test waits for asynchronous work before failing. History audits run on a
    /// utility-priority queue and can stall for many seconds behind other work on a busy host;
    /// waits return as soon as their condition holds, so only a hang reaches this ceiling. It stays
    /// below CI's 60-second per-test allowance so a hang reports its own condition.
    static let readinessTimeout: TimeInterval = 30

    @MainActor
    static func windowScene() throws -> UIWindowScene {
        try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    }

    /// Shows `root` in a new window on the host's scene, laid out and key.
    @MainActor
    static func window(showing root: UIViewController, width: CGFloat = 1_024) throws -> UIWindow {
        let window = UIWindow(windowScene: try windowScene())
        window.frame = CGRect(x: 0, y: 0, width: width, height: 1_366)
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.view.layoutIfNeeded()
        return window
    }

    /// Polls `ready` on the main actor until it holds, failing the test after `seconds`.
    @MainActor
    static func waitUntil(
        seconds: TimeInterval = readinessTimeout, file: StaticString = #filePath, line: UInt = #line,
        _ ready: @MainActor () async -> Bool
    ) async throws {
        try await waitForValue(seconds: seconds, file: file, line: line) { await ready() ? () : nil }
    }

    /// Polls `value` on the main actor until it produces a result, failing the test after `seconds`.
    @MainActor
    @discardableResult
    static func waitForValue<Value>(
        seconds: TimeInterval = readinessTimeout, file: StaticString = #filePath, line: UInt = #line,
        _ value: @MainActor () async -> Value?
    ) async throws -> Value {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while true {
            if let result = await value() { return result }
            guard ContinuousClock.now < deadline else {
                XCTFail("The condition did not hold within \(seconds.formatted()) seconds.", file: file, line: line)
                throw NotebookFixtureFailure.timeout
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor
    static func notebookController(in controller: UIViewController) -> NotebookViewController? {
        if let notebook = controller as? NotebookViewController { return notebook }
        return controller.children.lazy.compactMap { notebookController(in: $0) }.first
    }

    @MainActor
    static func navigationController(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { navigationController(in: $0) }.first
    }

    /// The view a touch at `point`, in `view`'s coordinates, reaches in its window.
    @MainActor
    static func hit(_ point: CGPoint, in view: UIView) -> UIView {
        guard let window = (view as? UIWindow) ?? view.window else { return view }
        return window.hitTest(view.convert(point, to: window), with: nil) ?? window
    }

    /// A notebook canvas inside the toolbar host, shown in its own window and ready for input.
    @MainActor
    static func mountToolbarHost(
        store: NotebookSceneToolStore? = nil, horizontalSizeClass: UserInterfaceSizeClass = .regular,
        width: CGFloat = 1_024
    ) async throws -> NotebookToolbarHostFixture {
        let store = store ?? toolStore()
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        let hosting = UIHostingController(
            rootView: NotebookToolbarHost(store: store) { MountedNotebookController(controller: controller) }
                .environment(\.horizontalSizeClass, horizontalSizeClass)
        )
        hosting.safeAreaRegions = []
        let window = try Self.window(showing: hosting, width: width)
        let fixture = NotebookToolbarHostFixture(hosting: hosting, window: window, controller: controller, store: store)
        do {
            try await waitUntil {
                controller.isCanvasVisible && store.isToolbarAvailable && controller.canvasView.isFirstResponder
                    && controller.canvasView.bounds.height > 0
            }
        } catch {
            fixture.close()
            throw error
        }
        return fixture
    }
}

enum NotebookFixtureFailure: Error {
    case timeout
}

/// Mounts an existing controller so tests can inspect it inside SwiftUI.
struct MountedNotebookController: UIViewControllerRepresentable {
    let controller: NotebookViewController

    func makeUIViewController(context: Context) -> NotebookViewController { controller }

    func updateUIViewController(_ controller: NotebookViewController, context: Context) {}
}

@MainActor
struct NotebookToolbarHostFixture {
    let hosting: UIViewController
    let window: UIWindow
    let controller: NotebookViewController
    let store: NotebookSceneToolStore

    var host: UIView { hosting.view }

    /// The view a touch at `point`, in the host's coordinates, reaches.
    func hit(_ point: CGPoint) -> UIView {
        NotebookTestFixtures.hit(point, in: host)
    }

    /// The canvas controller's frame in the host's coordinates.
    var canvasFrame: CGRect { frame(of: controller.view) }

    /// The toolbar's scrolling strips, top to bottom.
    var strips: [UIScrollView] {
        func collect(_ view: UIView) -> [UIScrollView] {
            if view === controller.view { return [] }
            let own = (view as? UIScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap(collect)
        }
        return collect(host).sorted { frame(of: $0).minY < frame(of: $1).minY }
    }

    func frame(of view: UIView) -> CGRect {
        view.convert(view.bounds, to: host)
    }

    func close() {
        hosting.presentedViewController?.dismiss(animated: false)
        controller.tearDown()
        window.isHidden = true
        window.rootViewController = nil
    }
}

// MARK: - Pixels

/// An image redrawn into premultiplied sRGB bytes, so values compare with sRGB theme colours.
struct RenderedPixels {
    let width: Int
    let height: Int
    let scale: CGFloat
    let rgba: [UInt8]

    init(_ image: CGImage, scale: CGFloat) throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drawn, "The image could not be redrawn into sRGB.")
        width = image.width
        height = image.height
        self.scale = scale
        rgba = bytes
    }

    /// Renders a SwiftUI view at twice its point size.
    @MainActor
    init<Content: View>(rendering content: Content) throws {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        try self.init(try XCTUnwrap(renderer.cgImage), scale: 2)
    }

    var size: CGSize { CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale) }
    var alpha: [UInt8] { stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] } }

    /// The pixel under `point`, given in points.
    func rgba(at point: CGPoint) -> [UInt8] {
        let offset = (Int(point.y * scale) * width + Int(point.x * scale)) * 4
        return Array(rgba[offset..<offset + 4])
    }
}

/// Hands out defaults suites for one test at a time and deletes them when it finishes.
/// The preferences system can write an emptied suite back to disk when the process exits,
/// so names are reused from test to test to keep any such files to a fixed few.
@MainActor
private final class TemporaryDefaultsSuites: NSObject, XCTestObservation {
    static let shared: TemporaryDefaultsSuites = {
        let suites = TemporaryDefaultsSuites()
        XCTestObservationCenter.shared.addTestObserver(suites)
        return suites
    }()

    private var handedOut = 0

    func next() -> String {
        let name = "notty.tests.defaults.\(handedOut)"
        handedOut += 1
        // A run that stopped early may have left values behind.
        UserDefaults.standard.removePersistentDomain(forName: name)
        return name
    }

    nonisolated func testCaseDidFinish(_ testCase: XCTestCase) {
        MainActor.assumeIsolated { removeAll() }
    }

    private func removeAll() {
        let preferences = URL.libraryDirectory.appending(path: "Preferences", directoryHint: .isDirectory)
        for index in 0..<handedOut {
            let name = "notty.tests.defaults.\(index)"
            UserDefaults.standard.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: preferences.appending(path: name + ".plist"))
        }
        handedOut = 0
    }
}

actor NotebookStorageProbe {
    let recovery: NotebookRecoveryStore
    private var stored: StoredNotebook?
    private var saveFailure: NotebookSaveFailure?
    private var loadFailure: NotebookSaveFailure?
    private var preserveFailure: NotebookSaveFailure?
    private var suspendSave = false
    private var saveContinuation: CheckedContinuation<Void, Never>?
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []
    private var suspendLoad = false
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var suspendPreserve = false
    private var preserveContinuation: CheckedContinuation<Void, Never>?
    private var preserveWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var saveCalls = 0
    private(set) var preserveCalls = 0
    private(set) var preservedBatch: NotebookRecoveryBatch?

    init(stored: StoredNotebook?, recoveryRoot: URL) throws {
        self.stored = stored
        recovery = try NotebookRecoveryStore(rootURL: recoveryRoot)
    }

    func setSaveFailure(_ failure: NotebookSaveFailure?) { saveFailure = failure }
    func setLoadFailure(_ failure: NotebookSaveFailure?) { loadFailure = failure }
    func setPreserveFailure(_ failure: NotebookSaveFailure?) { preserveFailure = failure }
    func setSuspendSave() { suspendSave = true }
    func setSuspendLoad() { suspendLoad = true }
    func setSuspendPreserve() { suspendPreserve = true }

    func storage(notebookID: UUID) -> NotebookStorage {
        NotebookStorage(
            load: { try await self.load() },
            save: { try await self.save($0, revision: $1, notebookID: notebookID) },
            preserve: { try await self.preserve($0) },
            listRecovery: { try await self.recovery.scan(notebookID: notebookID) },
            loadRecovery: { try await self.recovery.load(id: $0) }
        )
    }

    private func load() async throws -> StoredNotebook? {
        if suspendLoad {
            await withCheckedContinuation { continuation in
                loadContinuation = continuation
                let waiters = loadWaiters
                loadWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        if let loadFailure { throw loadFailure }
        return stored
    }

    func waitForLoad() async {
        if loadContinuation != nil { return }
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    func releaseLoad() {
        suspendLoad = false
        let continuation = loadContinuation
        loadContinuation = nil
        continuation?.resume()
    }

    private func save(_ content: NotebookContent, revision: UUID?, notebookID: UUID) async throws -> StoredNotebook {
        saveCalls += 1
        if suspendSave {
            await withCheckedContinuation { continuation in
                saveContinuation = continuation
                let waiters = saveWaiters
                saveWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        if let saveFailure { throw saveFailure }
        let next = StoredNotebook(
            id: notebookID, revisionID: UUID(), sequence: (stored?.sequence ?? 0) + 1,
            content: content, savedAt: Date()
        )
        stored = next
        return next
    }

    func waitForSave() async {
        if saveContinuation != nil { return }
        await withCheckedContinuation { saveWaiters.append($0) }
    }

    func releaseSave(suspendNext: Bool = false) {
        suspendSave = suspendNext
        let continuation = saveContinuation
        saveContinuation = nil
        continuation?.resume()
    }

    private func preserve(_ batch: NotebookRecoveryBatch) async throws -> NotebookRecoveryReceipt {
        preserveCalls += 1
        if let preserveFailure { throw preserveFailure }
        preservedBatch = batch
        if suspendPreserve {
            await withCheckedContinuation { continuation in
                preserveContinuation = continuation
                let waiters = preserveWaiters
                preserveWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        return try await recovery.preserve(batch)
    }

    func waitForPreserve() async {
        if preserveContinuation != nil { return }
        await withCheckedContinuation { preserveWaiters.append($0) }
    }

    func releasePreserve() {
        suspendPreserve = false
        let continuation = preserveContinuation
        preserveContinuation = nil
        continuation?.resume()
    }
}
