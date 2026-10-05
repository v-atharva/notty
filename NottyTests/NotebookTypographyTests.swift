import CoreText
import SwiftUI
import UIKit
import XCTest
@testable import Notty

@MainActor
final class NotebookTypographyTests: XCTestCase {
    private static let bundledFaces = [
        "BerkeleyMono-Medium",
        "BerkeleyMono-SemiBold",
    ]

    func testBerkeleyMonoFacesShipInTheAppBundle() {
        for face in Self.bundledFaces {
            XCTAssertNotNil(Bundle.main.url(forResource: face, withExtension: "ttf"), "\(face).ttf is missing from the app bundle")
        }
    }

    func testOnlyTheFacesTheThemeUsesAreBundled() {
        XCTAssertNil(Bundle.main.url(forResource: "BerkeleyMono-Regular", withExtension: "ttf"))
        let registered = Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String]
        XCTAssertEqual(registered, Self.bundledFaces.map { "\($0).ttf" })
    }

    func testStatusBarTextIsLightOnTheLeatherBand() async throws {
        XCTAssertNotEqual(Bundle.main.object(forInfoDictionaryKey: "UIViewControllerBasedStatusBarAppearance") as? Bool, false)
        let scene = try NotebookTestFixtures.windowScene()
        NotebookTestFixtures.restoreSceneToolDefaults(for: scene, after: self)
        let previousKeyWindow = scene.keyWindow
        let store = NotebookSceneToolStore.owner(for: scene)
        let originalTool = store.tool
        let originalToolbar = store.toolbar
        let root = NotebookTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let probe = try NotebookStorageProbe(stored: try await NotebookTestFixtures.stored(id: id), recoveryRoot: root)
        let storage = await probe.storage(notebookID: id)
        let session = NotebookSession(notebookID: id, openStorage: { storage })
        await session.load()
        let hosting = StatusBarHostingController(rootView: NotebookScreen(session: session))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        let control = StatusBarHostingController(rootView:
            Color.white.preferredColorScheme(.light).toolbarColorScheme(.light, for: .statusBar)
        )
        window.rootViewController = control
        window.makeKeyAndVisible()
        var mounted: NotebookViewController?
        defer {
            session.flush()
            store.update { $0 = originalTool }
            store.updateToolbar(originalToolbar)
            mounted?.tearDown()
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        try await NotebookTestFixtures.waitUntil {
            control.hasAppeared && scene.statusBarManager?.statusBarStyle == .darkContent
        }
        window.rootViewController = hosting
        hosting.view.layoutIfNeeded()
        try await NotebookTestFixtures.waitUntil {
            mounted = NotebookTestFixtures.notebookController(in: hosting)
            return hosting.hasAppeared && mounted?.isCanvasVisible == true
                && scene.statusBarManager?.statusBarStyle == .lightContent
        }
        XCTAssertEqual(scene.statusBarManager?.statusBarStyle, .lightContent)
        XCTAssertEqual(mounted?.canvasView.traitCollection.userInterfaceStyle, .light)
    }

    func testBerkeleyMonoFacesAreRegisteredAtLaunch() {
        for face in Self.bundledFaces {
            let font = UIFont(name: face, size: 17)
            XCTAssertEqual(font?.fontName, face, "\(face) is not registered through UIAppFonts")
        }
    }

    func testNoteTitleIsSemiBoldBerkeleyMono() {
        let resolved = resolve(NotebookTheme.noteTitle.font, at: .large)
        XCTAssertEqual(postScriptName(of: resolved), "BerkeleyMono-SemiBold")
        XCTAssertEqual(resolved.pointSize, NotebookTheme.noteTitle.pointSize, accuracy: 0.01)
        XCTAssertTrue(resolved.isMonospaced)
    }

    func testWordmarkSharesTheTitleTypewriterFace() {
        let resolved = resolve(NotebookTheme.wordmark.font, at: .large)
        XCTAssertEqual(postScriptName(of: resolved), "BerkeleyMono-Medium")
        XCTAssertEqual(resolved.pointSize, NotebookTheme.wordmark.pointSize, accuracy: 0.01)
        XCTAssertTrue(resolved.isMonospaced)
    }

    func testNoteTitleScalesWithDynamicType() {
        let standard = resolve(NotebookTheme.noteTitle.font, at: .large)
        let small = resolve(NotebookTheme.noteTitle.font, at: .xSmall)
        let accessibility = resolve(NotebookTheme.noteTitle.font, at: .accessibility3)
        XCTAssertLessThan(small.pointSize, standard.pointSize)
        XCTAssertGreaterThan(accessibility.pointSize, standard.pointSize)
        XCTAssertEqual(postScriptName(of: accessibility), "BerkeleyMono-SemiBold", "Scaling keeps the face")
    }

    func testLighterBerkeleyMonoWeightResolvesThroughTheTheme() {
        let label = NotebookTheme.Typeface(postScriptName: "BerkeleyMono-Medium", pointSize: 13, style: .footnote, weight: .medium)
        let standard = resolve(label.font, at: .large)
        XCTAssertEqual(postScriptName(of: standard), "BerkeleyMono-Medium")
        XCTAssertEqual(standard.pointSize, label.pointSize, accuracy: 0.01)
        XCTAssertGreaterThan(resolve(label.font, at: .accessibility3).pointSize, standard.pointSize)
    }

    func testMissingFaceFallsBackToTheMonospacedSystemFont() {
        let missing = NotebookTheme.Typeface(postScriptName: "Missing-Typewriter", pointSize: 17, style: .headline, weight: .semibold)
        let resolved = resolve(missing.font, at: .large)
        XCTAssertTrue(resolved.isMonospaced)
        XCTAssertFalse(postScriptName(of: resolved).hasPrefix("BerkeleyMono"))
        XCTAssertEqual(weightTrait(of: resolved), UIFont.Weight.semibold.rawValue, accuracy: 0.01)
        XCTAssertGreaterThan(resolve(missing.font, at: .accessibility3).pointSize, resolved.pointSize)
    }

    func testControlLabelsKeepTheProportionalSystemFont() {
        let resolved = resolve(NotebookTheme.controlLabel.font, at: .large)
        XCTAssertFalse(resolved.isMonospaced)
        XCTAssertFalse(postScriptName(of: resolved).hasPrefix("BerkeleyMono"))
    }

    private func resolve(_ font: Font, at size: DynamicTypeSize) -> Font.Resolved {
        var environment = EnvironmentValues()
        environment.dynamicTypeSize = size
        return font.resolve(in: environment.fontResolutionContext)
    }

    private func postScriptName(of resolved: Font.Resolved) -> String {
        CTFontCopyPostScriptName(resolved.ctFont) as String
    }

    private func weightTrait(of resolved: Font.Resolved) -> CGFloat {
        let traits = CTFontCopyTraits(resolved.ctFont) as NSDictionary
        return (traits[kCTFontWeightTrait] as? NSNumber).map { CGFloat($0.doubleValue) } ?? .nan
    }
}

@MainActor
private final class StatusBarHostingController<Content: View>: UIHostingController<Content> {
    private(set) var hasAppeared = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
    }
}
