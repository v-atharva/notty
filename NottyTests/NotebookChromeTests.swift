import Combine
import NottyCore
import PencilKit
import SwiftUI
import UIKit
import XCTest
@testable import Notty

@MainActor
final class NotebookChromeTests: XCTestCase {
    private static let increased = UITraitCollection(accessibilityContrast: .high)
    private static let standard = UITraitCollection(accessibilityContrast: .normal)

    // MARK: - Dual tones

    /// Every tone with an Increase Contrast value, with both values as section 2 of the visual
    /// spec gives them.
    private static let dualTones: [(String, NotebookTheme.Tone, [CGFloat], [CGFloat])] = [
        ("paperEdge", NotebookTheme.paperEdge, [0.47, 0.40, 0.31, 0.65], [0.17, 0.16, 0.15, 1]),
        ("paperDivider", NotebookTheme.paperDivider, [0.47, 0.40, 0.31, 0.30], [0.47, 0.40, 0.31, 0.55]),
        ("panelLowerEdge", NotebookTheme.panelLowerEdge, [0.776, 0.765, 0.729, 1], [0.333, 0.318, 0.294, 1]),
        ("selectedWell", NotebookTheme.selectedWell, [0.765, 0.749, 0.706, 1], [0.678, 0.659, 0.616, 1]),
        ("divider", NotebookTheme.divider, [0.722, 0.702, 0.659, 1], [0.427, 0.408, 0.380, 1]),
        ("glyphSecondary", NotebookTheme.glyphSecondary, [0.314, 0.298, 0.275, 1], [0.17, 0.16, 0.15, 1]),
        ("disabledGlyph", NotebookTheme.disabledGlyph, [0.506, 0.490, 0.459, 1], [0.408, 0.392, 0.365, 1]),
        ("controlTint", NotebookTheme.controlTint, [0.36, 0.29, 0.22, 1], [0.255, 0.20, 0.145, 1]),
        ("cautionGlyph", NotebookTheme.cautionGlyph, [0.478, 0.235, 0.020, 1], [0.416, 0.204, 0.016, 1]),
        ("alertGlyph", NotebookTheme.alertGlyph, [0.565, 0.149, 0.114, 1], [0.490, 0.122, 0.094, 1]),
        ("accentFill", NotebookTheme.accentFill, [0.431, 0.439, 0.784, 1], [0.384, 0.392, 0.741, 1]),
        ("accentGlyph", NotebookTheme.accentGlyph, [0.047, 0.051, 0.176, 1], [1, 1, 1, 1]),
        ("accentRim", NotebookTheme.accentRim, [0.345, 0.353, 0.659, 1], [0.333, 0.318, 0.294, 1]),
    ]

    func testDualTonesResolveTheirIncreasedValueUnderIncreaseContrast() async throws {
        let hosting = AppearanceTrackingController()
        hosting.traitOverrides.accessibilityContrast = .high
        let window = try NotebookTestFixtures.window(showing: hosting, width: 320)
        defer { close(window) }
        try await NotebookTestFixtures.waitUntilAppeared(hosting)
        XCTAssertEqual(hosting.traitCollection.accessibilityContrast, .high)

        for (name, tone, standard, increased) in Self.dualTones {
            assertComponents(of: tone.uiColor.resolvedColor(with: hosting.traitCollection), equal: increased, name)
            assertComponents(of: tone.uiColor.resolvedColor(with: Self.increased), equal: increased, name)
            assertComponents(of: tone.uiColor.resolvedColor(with: Self.standard), equal: standard, name)
        }
    }

    func testLayersResolveDualTonesForTheTraitsTheyAreDrawnIn() {
        for (name, tone, standard, increased) in Self.dualTones {
            assertComponents(of: UIColor(cgColor: tone.cgColor(for: Self.increased)), equal: increased, name)
            assertComponents(of: UIColor(cgColor: tone.cgColor(for: Self.standard)), equal: standard, name)
        }
        assertComponents(
            of: UIColor(cgColor: NotebookTheme.paperIvory.cgColor(for: Self.increased)), equal: [0.98, 0.96, 0.91, 1],
            "A single-value tone is the same under Increase Contrast."
        )
    }

    func testSwiftUIFillsFollowIncreaseContrast() async throws {
        let fill = Rectangle().fill(NotebookTheme.divider.color).ignoresSafeArea()
        let centre = CGPoint(x: Self.renderSize.width / 2, y: Self.renderSize.height / 2)
        let increased = try await rendered(fill, contrast: .high, at: [centre])
        let standard = try await rendered(fill, contrast: .normal, at: [centre])
        assertPixel(increased[0], equals: [0.427, 0.408, 0.380], "the hosted fill takes the increased divider")
        assertPixel(standard[0], equals: [0.722, 0.702, 0.659], "the hosted fill keeps the standard divider")
    }

    func testShellTurnsFlatUnderIncreaseContrast() async throws {
        let bleed = NotebookTheme.shellShadowBleed
        let shell = NotebookPanelShell().padding(bleed).ignoresSafeArea()
        // A quarter and three quarters of the way down the shell, clear of its edges.
        let height = Self.renderSize.height - 2 * bleed
        let points = [0.25, 0.75].map { CGPoint(x: Self.renderSize.width / 2, y: bleed + height * $0) }
        let flat = try await rendered(shell, contrast: .high, at: points)
        let shaded = try await rendered(shell, contrast: .normal, at: points)
        for pixel in flat {
            assertPixel(pixel, equals: [0.918, 0.906, 0.882], "a flat panel surface")
        }
        assertPixel(shaded[0], equals: [0.933, 0.922, 0.900], "a quarter of the way down the gradient")
        assertPixel(shaded[1], equals: [0.902, 0.891, 0.865], "three quarters of the way down the gradient")
    }

    // MARK: - Baked shell shadow

    func testShellShadowIsBakedOncePerRadiusWithATwoPointStretchableMiddle() throws {
        let bleed = NotebookTheme.shellShadowBleed
        for (radius, side) in [(CGFloat(20), CGFloat(66)), (16, 58)] {
            let image = NotebookMaterials.shellShadow(cornerRadius: radius)
            XCTAssertTrue(NotebookMaterials.shellShadow(cornerRadius: radius) === image, "Baked once per radius.")
            XCTAssertEqual(image.size, CGSize(width: side, height: side))
            XCTAssertEqual(image.scale, 2)
            XCTAssertEqual(image.resizingMode, .stretch)
            let cap = bleed + radius
            XCTAssertEqual(image.capInsets, UIEdgeInsets(top: cap, left: cap, bottom: cap, right: cap))
            XCTAssertEqual(side - 2 * cap, 2, "Only a two-point middle stretches.")

            let pixels = try RenderedPixels(try XCTUnwrap(image.cgImage), scale: image.scale)
            func alpha(atY y: CGFloat) -> UInt8 { pixels.rgba(at: CGPoint(x: side / 2, y: y))[3] }
            XCTAssertEqual(alpha(atY: side / 2), 0, "The shell's own area is cleared.")
            XCTAssertLessThan(alpha(atY: 0.25), 3, "The shadow fades out within the bleed above.")
            XCTAssertLessThan(alpha(atY: side - 0.25), 3, "The shadow fades out within the bleed below.")
            let above = alpha(atY: bleed - 1)
            let below = alpha(atY: side - bleed + 1)
            XCTAssertGreaterThan(below, above, "The shadow falls below the shell.")
            XCTAssertLessThanOrEqual(below, UInt8(255 * NotebookTheme.shellShadow.opacity), "No darker than the shadow's opacity.")
            XCTAssertGreaterThan(alpha(atY: side - bleed + 6), 1, "The blur reaches well into the bleed.")
        }
    }

    // MARK: - Contrast

    /// Every text pair of section 8.1 reaches 4.5:1 and every glyph and essential mark of
    /// section 8.2 reaches 3:1, computed from the theme's own values.
    func testChromePairsMeetTheirContrastMinimums() {
        let paper = color(NotebookTheme.paperIvory)
        let stone = color(NotebookTheme.backdropStone)
        let tray = color(NotebookTheme.trayFill)
        let well = color(NotebookTheme.selectedWell)
        let surface = color(NotebookTheme.panelSurface)
        let top = color(NotebookTheme.panelTop)
        let bottom = color(NotebookTheme.panelBottom)
        let glyph = color(NotebookTheme.glyph)
        let secondary = color(NotebookTheme.glyphSecondary)
        let caution = color(NotebookTheme.cautionGlyph)
        let alert = color(NotebookTheme.alertGlyph)
        let accent = color(NotebookTheme.accentFill)
        // Reference points on the shell gradient: the centres of the rail's rows, and the middle.
        let firstRow = shell(at: 0.24)
        let secondRow = shell(at: 0.76)
        let centre = shell(at: 0.5)
        let pressedTray = blend(well, NotebookTheme.pressedTrayOpacity, over: tray)

        let text: [(String, EditorInkColor, EditorInkColor)] = [
            ("note title in the tray", glyph, tray),
            ("note title in a pressed tray", glyph, pressedTray),
            ("readout caption", secondary, tray),
            ("pressed readout caption", secondary, pressedTray),
            ("caution caption", caution, tray),
            ("pressed caution caption", caution, pressedTray),
            ("alert caption", alert, tray),
            ("pressed alert caption", alert, pressedTray),
            ("nameplate", secondary, centre),
            ("nameplate at the shell's bottom", secondary, bottom),
            ("SOON label", secondary, firstRow),
            ("preset label", glyph, secondRow),
            ("label in a selected well", glyph, well),
            ("secondary text in a selected well", secondary, well),
            ("popover headline", glyph, surface),
            ("popover body and section label", secondary, surface),
            ("popover text button", color(NotebookTheme.controlTint), surface),
            ("primary key label", paper, glyph),
            ("secondary key label", glyph, centre),
            ("loading caption", secondary, paper),
            ("card title", glyph, top),
            ("recovery card text", glyph, bottom),
        ]
        for (name, foreground, background) in text {
            assertContrast(foreground, background, atLeast: 4.5, name)
        }

        var marks: [(String, EditorInkColor, EditorInkColor)] = [
            ("tool glyph", glyph, firstRow),
            ("tool glyph at the shell's bottom", glyph, bottom),
            ("glyph and mark bar in a well", glyph, well),
            ("accent glyph", color(NotebookTheme.accentGlyph), accent),
            ("accent key on the header", accent, centre),
            ("accent key at the shell's bottom", accent, bottom),
            ("grip ridges", secondary, centre),
            ("near-limit gauge", caution, tray),
            ("reveal-tab chevron", secondary, blend(surface, NotebookTheme.revealTabOpacity, over: paper)),
            ("paused glyph", blend(glyph, NotebookTheme.disabledOpacity, over: bottom), bottom),
            ("dock outline on paper", blend(glyph, NotebookTheme.dockSlotOutlineOpacity, over: paper), paper),
            ("dock outline on stone", blend(glyph, NotebookTheme.dockSlotOutlineOpacity, over: stone), stone),
            ("placeholder on the rail", color(NotebookTheme.disabledGlyph), firstRow),
            ("placeholder on a popover", color(NotebookTheme.disabledGlyph), surface),
        ]
        for fill in [NotebookTheme.dockSlotOpaqueFill, NotebookTheme.dockSlotTargetedOpaqueFill, NotebookTheme.dockSlotLandingOpaqueFill] {
            let opaque = color(fill)
            marks.append(("dock outline on an opaque fill", blend(glyph, NotebookTheme.dockSlotOutlineOpacity, over: opaque), opaque))
        }
        for ink in EditorInkCatalog.swatches + EditorInkCatalog.presets.map(\.color) {
            marks.append(("swatch \(ink)", ink, secondRow))
        }
        for (name, foreground, background) in marks {
            assertContrast(foreground, background, atLeast: 3, name)
        }
    }

    /// The pairs of section 8.3 that Increase Contrast exists to lift.
    func testIncreaseContrastPairsMeetTheirMinimums() {
        let high = UIAccessibilityContrast.high
        let paper = color(NotebookTheme.paperIvory, high)
        let stone = color(NotebookTheme.backdropStone, high)
        let tray = color(NotebookTheme.trayFill, high)
        let surface = color(NotebookTheme.panelSurface, high)
        let glyph = color(NotebookTheme.glyph, high)
        let outline = color(NotebookTheme.panelLowerEdge, high)
        let accent = color(NotebookTheme.accentFill, high)

        let text: [(String, EditorInkColor, EditorInkColor)] = [
            ("label in a selected well", glyph, color(NotebookTheme.selectedWell, high)),
            ("placeholder", color(NotebookTheme.disabledGlyph, high), surface),
            ("caution caption", color(NotebookTheme.cautionGlyph, high), tray),
            ("alert caption", color(NotebookTheme.alertGlyph, high), tray),
            ("popover text button", color(NotebookTheme.controlTint, high), surface),
            ("secondary text reads as glyph", color(NotebookTheme.glyphSecondary, high), surface),
        ]
        for (name, foreground, background) in text {
            assertContrast(foreground, background, atLeast: 4.5, name)
        }

        let marks: [(String, EditorInkColor, EditorInkColor)] = [
            ("shell outline on paper", outline, paper),
            ("shell outline on stone", outline, stone),
            ("tray outline", outline, tray),
            ("chip outline", outline, surface),
            ("divider", color(NotebookTheme.divider, high), surface),
            ("accent glyph", color(NotebookTheme.accentGlyph, high), accent),
            ("accent key", accent, surface),
            ("paused glyph", blend(glyph, NotebookTheme.disabledOpacityIncreased, over: surface), surface),
            ("page edge", color(NotebookTheme.paperEdge, high), stone),
            ("dock outline", glyph, paper),
        ]
        for (name, foreground, background) in marks {
            assertContrast(foreground, background, atLeast: 3, name)
        }
    }

    // MARK: - Recesses, dividers and labels

    func testRecessesTradeTheirLitLipForAnOutlineUnderIncreaseContrast() async throws {
        let size = Self.renderSize
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let lowerEdge = CGPoint(x: size.width / 2, y: size.height - 0.25)

        let well = NotebookRecessedWell(shape: Rectangle()).ignoresSafeArea()
        let litWell = try await rendered(well, contrast: .normal, at: [lowerEdge, centre])
        let outlinedWell = try await rendered(well, contrast: .high, at: [lowerEdge, centre])
        XCTAssertGreaterThan(luminance(litWell[0]), 0.7, "A well's lower lip catches the light: \(litWell[0])")
        assertPixel(outlinedWell[0], equals: [0.17, 0.16, 0.15], "a glyph outline in place of the lip")
        assertPixel(litWell[1], equals: [0.765, 0.749, 0.706], "the standard well tone")
        assertPixel(outlinedWell[1], equals: [0.678, 0.659, 0.616], "the well tone darkens by itself")

        // Inside the top edge the standard tray is in its inner shadow; under Increase Contrast it
        // is flat, clear of the outline along the edge.
        let tray = NotebookRecessedTray().ignoresSafeArea()
        let litTray = try await rendered(tray, contrast: .normal, at: [lowerEdge, CGPoint(x: centre.x, y: 1.5)])
        let outlinedTray = try await rendered(tray, contrast: .high, at: [lowerEdge, CGPoint(x: centre.x, y: 2.5)])
        XCTAssertGreaterThan(luminance(litTray[0]), 0.7, "The tray's lower lip catches the light: \(litTray[0])")
        assertPixel(outlinedTray[0], equals: [0.333, 0.318, 0.294], "a dark outline in place of the lip")
        assertPixel(outlinedTray[1], equals: [0.827, 0.812, 0.776], "no inner shadow under Increase Contrast")
        XCTAssertLessThan(
            luminance(litTray[1]), color(NotebookTheme.trayFill).relativeLuminance - 0.02,
            "The standard tray sinks under an inner shadow: \(litTray[1])"
        )
    }

    func testDividersAreSingleHairlinesOfTheirSpecifiedLength() throws {
        let vertical = UIHostingController(rootView: NotebookChromeDivider(axis: .vertical))
        XCTAssertEqual(
            vertical.sizeThatFits(in: CGSize(width: 500, height: 500)), CGSize(width: 9, height: 24),
            "A 1 by 24 point hairline with 4 points either side."
        )
        XCTAssertEqual(
            2 * NotebookTheme.itemSpacing + 2 * NotebookTheme.dividerPadding + NotebookTheme.dividerThickness, 13,
            "Groups sit 13 points apart, key edge to key edge."
        )
        let horizontal = UIHostingController(rootView: NotebookChromeDivider(axis: .horizontal))
        XCTAssertEqual(horizontal.sizeThatFits(in: CGSize(width: 300, height: 500)), CGSize(width: 300, height: 1))

        let width: CGFloat = 200
        let pixels = try RenderedPixels(rendering: NotebookChromeDivider(axis: .horizontal)
            .frame(width: width)
            .background(NotebookTheme.paperIvory.color))
        let paper: [CGFloat] = [0.98, 0.96, 0.91]
        let line: [CGFloat] = [0.722, 0.702, 0.659]
        for x in [CGFloat(0.25), 11.75, width - 11.75, width - 0.25] {
            assertPixel(pixels.rgba(at: CGPoint(x: x, y: 0.5)), equals: paper, "the seam stops 12 points short at x \(x)")
        }
        for x in [CGFloat(12.25), width / 2, width - 12.25] {
            assertPixel(pixels.rgba(at: CGPoint(x: x, y: 0.5)), equals: line, "the seam at x \(x)")
        }
    }

    func testSectionLabelsAreTrackedCapitals() throws {
        let label = NotebookSectionLabel("Pens")
        let capitals = Text("PENS")
            .notebookTypeface(NotebookTheme.sectionLabel)
            .foregroundStyle(NotebookTheme.glyphSecondary.color)
        let asTyped = Text("Pens")
            .notebookTypeface(NotebookTheme.sectionLabel)
            .foregroundStyle(NotebookTheme.glyphSecondary.color)
        let drawn = try RenderedPixels(rendering: label)
        let drawnInCapitals = try RenderedPixels(rendering: capitals)
        let drawnAsTyped = try RenderedPixels(rendering: asTyped)
        XCTAssertEqual(drawn.rgba, drawnInCapitals.rgba, "Drawn in capitals.")
        XCTAssertNotEqual(drawn.rgba, drawnAsTyped.rgba)

        func width<Content: View>(_ content: Content) -> CGFloat {
            UIHostingController(rootView: content.fixedSize()).sizeThatFits(in: CGSize(width: 1_000, height: 1_000)).width
        }
        let tracking = NotebookTheme.sectionLabel.tracking
        XCTAssertEqual(tracking, 1)
        let spread = width(label) - width(Text("PENS").font(NotebookTheme.sectionLabel.font))
        XCTAssertGreaterThanOrEqual(spread, 3 * tracking - 0.5, "Tracked between its four letters.")
        XCTAssertLessThanOrEqual(spread, 4 * tracking + 0.5)
    }

    // MARK: - Keys

    func testAPressedKeyDropsItsLabelByThePressTravel() throws {
        func firstDarkRow(pressed: Bool) throws -> CGFloat {
            let key = NotebookKey(label: Self.keyLabel, isSelected: false, isPressed: pressed, shape: .well)
                .background(NotebookTheme.panelSurface.color)
            let pixels = try RenderedPixels(rendering: key)
            let row = stride(from: CGFloat(0.25), to: pixels.size.height, by: 0.5).first {
                luminance(pixels.rgba(at: CGPoint(x: pixels.size.width / 2, y: $0))) < 0.1
            }
            return try XCTUnwrap(row, "The label was not drawn.")
        }
        let pressed = try firstDarkRow(pressed: true)
        let resting = try firstDarkRow(pressed: false)
        XCTAssertEqual(NotebookTheme.pressTravel, 1)
        XCTAssertEqual(pressed - resting, NotebookTheme.pressTravel, accuracy: 0.01)
    }

    func testAPressedReadoutSinksLessThanAPressedKey() throws {
        func centre(_ shape: NotebookKeyStyle.Outline) throws -> [UInt8] {
            let background = NotebookKeyStyle.Background(shape: shape, isSelected: false, isPressed: true, isFocused: false)
                .frame(width: 80, height: 44)
                .background(NotebookTheme.trayFill.color)
            return try RenderedPixels(rendering: background).rgba(at: CGPoint(x: 40, y: 22))
        }
        let tray = color(NotebookTheme.trayFill)
        let well = color(NotebookTheme.selectedWell)
        let readout = try centre(.readout)
        let key = try centre(.well)
        assertPixel(readout, equals: components(blend(well, 0.35, over: tray)), "a readout pressed at 0.35")
        assertPixel(key, equals: components(blend(well, 0.5, over: tray)), "a key pressed at 0.5")
    }

    func testASelectedReadoutLightsACellInsideTheTraysCorners() throws {
        let key = NotebookKey(
            label: Color.clear.frame(width: 120, height: NotebookTheme.trayHeight), isSelected: true, isPressed: false,
            shape: .readout
        )
        .background(NotebookTheme.trayFill.color)
        let pixels = try RenderedPixels(rendering: key)
        let tray: [CGFloat] = [0.827, 0.812, 0.776]
        let middle = NotebookTheme.trayHeight / 2
        let inset = NotebookTheme.readoutInset
        XCTAssertEqual(inset, 2)
        XCTAssertEqual(NotebookTheme.trayCornerRadius - inset, 10, "The cell's corners are concentric with the tray's.")
        assertPixel(pixels.rgba(at: CGPoint(x: inset - 0.25, y: middle)), equals: tray, "the cell starts 2 points in")
        assertPixel(pixels.rgba(at: CGPoint(x: inset + 0.25, y: inset + 0.25)), equals: tray, "the cell's corners are rounded")
        let cell = pixels.rgba(at: CGPoint(x: 6, y: middle))
        XCTAssertLessThan(luminance(cell), color(NotebookTheme.trayFill).relativeLuminance - 0.05, "The cell is sunk: \(cell)")
    }

    func testADisabledKeyDrawsNoWellPressOrSelection() throws {
        func centre(selected: Bool, pressed: Bool, disabled: Bool) throws -> [UInt8] {
            let key = NotebookKey(label: Self.keyLabel, isSelected: selected, isPressed: pressed, shape: .well)
                .background(NotebookTheme.panelSurface.color)
                .disabled(disabled)
            // Beside the label, where only the key's background shows.
            return try RenderedPixels(rendering: key).rgba(at: CGPoint(x: 8, y: 22))
        }
        let surface: [CGFloat] = [0.918, 0.906, 0.882]
        let selected = try centre(selected: true, pressed: false, disabled: false)
        let selectedDisabled = try centre(selected: true, pressed: false, disabled: true)
        let pressedDisabled = try centre(selected: false, pressed: true, disabled: true)
        assertPixel(selected, equals: [0.765, 0.749, 0.706], "a selected key's well")
        assertPixel(selectedDisabled, equals: surface, "no well while disabled")
        assertPixel(pressedDisabled, equals: surface, "no press while disabled")
    }

    // MARK: - Status card

    func testStatusCardsTakeTheirSpecifiedWidths() {
        let wide = CGSize(width: 1_000, height: 1_000)
        let loading = UIHostingController(rootView: NotebookStatusCard(loading: "Opening notebook"))
        XCTAssertEqual(loading.sizeThatFits(in: wide).width, NotebookTheme.statusCardWidth, accuracy: 0.5)
        let message = UIHostingController(rootView: NotebookStatusCard(title: "Couldn't open notebook", message: "Try again.") {
            Button("Try opening again") {}
        })
        XCTAssertEqual(message.sizeThatFits(in: wide).width, NotebookTheme.statusCardMaxWidth, accuracy: 0.5)
        XCTAssertEqual(message.sizeThatFits(in: CGSize(width: 300, height: 1_000)).width, 300, accuracy: 0.5)
    }

    func testStatusCardDrawsItsPrimaryActionAboveItsSecondaryActions() throws {
        let width: CGFloat = 400
        let bleed = NotebookTheme.shellShadowBleed
        let card = NotebookStatusCard(title: "Couldn't open notebook", message: "The notebook could not be read.") {
            Button("Try opening again") {}
        } secondary: {
            Button("Start new notebook") {}
        }
        .frame(width: width)
        .padding(bleed)
        let pixels = try RenderedPixels(rendering: card)
        // Sample each key beside its centred label, from the card's bottom up.
        let x = bleed + NotebookTheme.detailPadding + NotebookTheme.actionKeyPadding / 2
        let secondaryY = pixels.size.height - bleed - NotebookTheme.detailPadding - NotebookTheme.actionKeyHeight / 2
        let primaryY = secondaryY - NotebookTheme.actionKeyHeight - NotebookTheme.sectionSpacing
        let primary = pixels.rgba(at: CGPoint(x: x, y: primaryY))
        let secondary = pixels.rgba(at: CGPoint(x: x, y: secondaryY))
        XCTAssertLessThan(luminance(primary), 0.1, "The primary action is the dark key: \(primary)")
        XCTAssertGreaterThan(luminance(secondary), 0.7, "A secondary action is a light key: \(secondary)")
    }

    // MARK: - Action keys

    func testActionKeysDropTheirLabelAndShadeTheirFaceWhilePressed() throws {
        func render(_ kind: NotebookActionKeyStyle.Kind, pressed: Bool) throws -> RenderedPixels {
            let key = NotebookActionKey(label: Self.keyLabel, kind: kind, isPressed: pressed)
                .frame(width: 200)
                .background(NotebookTheme.panelSurface.color)
            return try RenderedPixels(rendering: key)
        }
        /// The first row of the label's mark down the key's centre.
        func markTop(_ pixels: RenderedPixels, light: Bool) throws -> CGFloat {
            let row = stride(from: CGFloat(0.25), to: pixels.size.height, by: 0.5).first {
                let value = luminance(pixels.rgba(at: CGPoint(x: 100, y: $0)))
                return light ? value > 0.8 : value < 0.1
            }
            return try XCTUnwrap(row, "The label was not drawn.")
        }
        let surface = color(NotebookTheme.panelSurface)
        let glyph = color(NotebookTheme.glyph)
        let face = CGPoint(x: 20, y: NotebookTheme.actionKeyHeight / 2)

        let primary = try render(.primary, pressed: false)
        let pressedPrimary = try render(.primary, pressed: true)
        XCTAssertEqual(NotebookTheme.actionKeyPressedOpacity, 0.85)
        assertPixel(primary.rgba(at: face), equals: components(glyph), "a resting primary key")
        assertPixel(
            pressedPrimary.rgba(at: face), equals: components(blend(glyph, 0.85, over: surface)),
            "a pressed primary key"
        )
        let primaryTravel = try markTop(pressedPrimary, light: true) - markTop(primary, light: true)
        XCTAssertEqual(primaryTravel, NotebookTheme.pressTravel, accuracy: 0.01)

        let secondary = try render(.secondary, pressed: false)
        let pressedSecondary = try render(.secondary, pressed: true)
        let middle = shell(at: 0.5)
        assertPixel(secondary.rgba(at: face), equals: components(middle), "a resting secondary key shows the shell")
        let well = color(NotebookTheme.selectedWell)
        assertPixel(
            pressedSecondary.rgba(at: face), equals: components(blend(well, 0.5, over: middle)),
            "a pressed secondary key sinks into the pressed well"
        )
        let secondaryTravel = try markTop(pressedSecondary, light: false) - markTop(secondary, light: false)
        XCTAssertEqual(secondaryTravel, NotebookTheme.pressTravel, accuracy: 0.01)
    }

    /// A disabled key dims to 0.55, or 0.70 under Increase Contrast, and the secondary key turns
    /// flat with an outline under Increase Contrast.
    func testActionKeysDimWhenDisabledAndTurnFlatUnderIncreaseContrast() async throws {
        func key(_ kind: NotebookActionKeyStyle.Kind, disabled: Bool) -> some View {
            NotebookActionKey(label: Self.keyLabel, kind: kind, isPressed: false)
                .disabled(disabled)
                .frame(width: Self.renderSize.width)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NotebookTheme.panelSurface.color)
                .ignoresSafeArea()
        }
        let surface = color(NotebookTheme.panelSurface)
        let glyph = color(NotebookTheme.glyph)
        let face = CGPoint(x: 20, y: Self.renderSize.height / 2)
        let border = CGPoint(x: 0.25, y: Self.renderSize.height / 2)

        for (contrast, opacity) in [(UIAccessibilityContrast.normal, 0.55), (.high, 0.70)] {
            let name = contrast == .high ? "increased contrast" : "standard contrast"
            let disabled = try await rendered(key(.primary, disabled: true), contrast: contrast, at: [face])
            assertPixel(
                disabled[0], equals: components(blend(glyph, opacity, over: surface)), "\(name): a disabled primary key"
            )
        }
        XCTAssertEqual(NotebookTheme.disabledOpacity, 0.55)
        XCTAssertEqual(NotebookTheme.disabledOpacityIncreased, 0.70)

        let flat = try await rendered(key(.secondary, disabled: false), contrast: .high, at: [face, border])
        assertPixel(flat[0], equals: components(surface), "a flat secondary face")
        assertPixel(flat[1], equals: components(color(NotebookTheme.panelLowerEdge, .high)), "its dark outline")
        let shaded = try await rendered(key(.secondary, disabled: false), contrast: .normal, at: [face])
        assertPixel(shaded[0], equals: components(shell(at: 0.5)), "the shaded face at standard contrast")
    }

    // MARK: - Shell shadow in place

    /// The shell draws its baked shadow outside its own bounds, falling below it, and keeps it
    /// under Increase Contrast.
    func testPanelShellCastsItsBakedShadowOutsideItsBoundsUnderEveryContrast() async throws {
        // A 120 x 60 shell centred in the render: x 40...160, y 30...90.
        let shell = NotebookPanelShell()
            .frame(width: 120, height: 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(NotebookTheme.paperIvory.color)
            .ignoresSafeArea()
        let below = CGPoint(x: 100, y: 93)
        let above = CGPoint(x: 100, y: 27)
        let beyond = CGPoint(x: 100, y: 90 + NotebookTheme.shellShadowBleed + 4)
        for contrast in [UIAccessibilityContrast.normal, .high] {
            let pixels = try await rendered(shell, contrast: contrast, at: [below, above, beyond])
            let name = contrast == .high ? "increased contrast" : "standard contrast"
            assertPixel(pixels[2], equals: [0.98, 0.96, 0.91], "\(name): paper beyond the bleed")
            XCTAssertLessThan(
                luminance(pixels[0]), luminance(pixels[2]) - 0.02, "\(name): shadow below the shell \(pixels[0])"
            )
            XCTAssertLessThan(luminance(pixels[0]), luminance(pixels[1]), "\(name): the shadow falls below the shell")
        }
    }

    // MARK: - Status veil

    /// Black status-bar text over the veil above charcoal ink, the one section 8.1 pair that
    /// depends on the veil's opacity.
    func testStatusBarTextOnTheVeilOverCharcoalInkMeetsItsContrast() throws {
        let charcoal = try XCTUnwrap(EditorInkCatalog.presets.first { $0.id == "charcoal-monoline" }).color
        let veil = blend(color(NotebookTheme.paperIvory), Double(NotebookTheme.statusVeilOpacity), over: charcoal)
        let black = EditorInkColor(red: 0, green: 0, blue: 0)
        XCTAssertEqual(NotebookTheme.statusVeilOpacity, 0.94)
        XCTAssertEqual(black.contrastRatio(against: veil), 17.33, accuracy: 0.01)
        assertContrast(black, veil, atLeast: 4.5, "status-bar text on the veil over charcoal ink")
    }

    // MARK: - Seams

    func testToolsHiddenPublishesOnlyRealChanges() {
        let store = NotebookTestFixtures.toolStore()
        var published: [Bool] = []
        let subscription = store.$areToolsHidden.dropFirst().sink { published.append($0) }
        defer { subscription.cancel() }
        XCTAssertFalse(store.areToolsHidden)

        store.setToolsHidden(false)
        store.revealTools()
        XCTAssertEqual(published, [], "Showing tools that already show publishes nothing.")
        store.setToolsHidden(true)
        store.setToolsHidden(true)
        XCTAssertTrue(store.areToolsHidden)
        XCTAssertEqual(published, [true])
        store.revealTools()
        store.revealTools()
        XCTAssertFalse(store.areToolsHidden)
        XCTAssertEqual(published, [true, false])
    }

    func testTopReservationMovesTheToolbarAndTheCanvasChromeByExactlyTheReservation() async throws {
        let reservation: CGFloat = 62
        let plain: ReservedHostLayout = try await withReservedHost(topReservation: 0) { host in
            let layout = try host.layout()
            XCTAssertEqual(layout.strip.minY, host.dockedFrame(below: 0).minY, accuracy: 0.5, "No reservation lays out as before.")
            XCTAssertEqual(layout.contentInset.top, layout.obstruction.top, accuracy: 0.5, "Without safe areas, no reservation adds no chrome.")
            return layout
        }

        try await withReservedHost(topReservation: reservation) { reserved in
            let layout = try reserved.layout()
            XCTAssertEqual(layout.strip.minY - plain.strip.minY, reservation, accuracy: 0.5)
            XCTAssertEqual(layout.strip.minX, plain.strip.minX, accuracy: 0.5)
            XCTAssertEqual(layout.strip.minY, reserved.dockedFrame(below: reservation).minY, accuracy: 0.5)
            XCTAssertEqual(layout.obstruction, plain.obstruction, "The toolbar covers as much of the area below the reservation.")
            XCTAssertEqual(layout.contentInset.top - plain.contentInset.top, reservation, accuracy: 0.5)
            XCTAssertEqual(reserved.canvasFrame, reserved.host.bounds, "The canvas still runs under the reserved header.")

            reserved.model.topReservation = 0
            try await NotebookTestFixtures.waitUntil {
                abs(reserved.controller.canvasView.contentInset.top - plain.contentInset.top) < 0.5
                    && abs((reserved.firstStripFrame?.minY ?? 0) - plain.strip.minY) < 0.5
            }
            XCTAssertEqual(reserved.store.overlayObstruction, plain.obstruction)
        }
    }

    /// The notebook screen's host runs the canvas under the status bar and home indicator. The
    /// reservation starts at the top safe area, for the toolbar and the canvas chrome alike, and
    /// is counted once.
    func testTopReservationStartsAtTheSafeAreaOfAHostExtendingTheCanvasUnderChrome() async throws {
        let extra = UIEdgeInsets(top: 40, left: 0, bottom: 20, right: 0)
        for reservation in [CGFloat(0), 62] {
            try await withReservedHost(topReservation: reservation, additionalSafeArea: extra) { host in
                let safe = host.safeArea
                let message = "Reservation \(reservation), safe area \(safe)"
                XCTAssertGreaterThanOrEqual(safe.top, extra.top, message)
                XCTAssertGreaterThanOrEqual(safe.bottom, extra.bottom, message)
                let layout = try host.layout()
                XCTAssertEqual(host.canvasFrame, host.host.bounds, "The canvas runs under the system chrome. \(message)")
                XCTAssertEqual(layout.strip.minY, safe.top + reservation + EditorToolbarLayout.margin, accuracy: 0.5, message)
                XCTAssertEqual(layout.strip.minY, host.dockedFrame(below: reservation).minY, accuracy: 0.5, message)
                XCTAssertEqual(layout.contentInset.top, safe.top + reservation + layout.obstruction.top, accuracy: 0.5, message)
                XCTAssertEqual(layout.contentInset.bottom, safe.bottom + layout.obstruction.bottom, accuracy: 0.5, message)
            }
        }
    }

    // MARK: - Helpers

    /// Mounts a host with a docked toolbar over a canvas, runs `body` and tears the host down,
    /// so one host never outlives its part of a test. With `additionalSafeArea`, the host honours
    /// the safe area and runs the canvas under it, as the notebook screen does; without, it
    /// ignores safe areas.
    private func withReservedHost<Result>(
        topReservation: CGFloat, additionalSafeArea: UIEdgeInsets? = nil,
        _ body: (ReservedHostFixture) async throws -> Result
    ) async throws -> Result {
        let store = NotebookTestFixtures.toolStore()
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        let model = ReservationModel(topReservation: topReservation)
        let extendsCanvas = additionalSafeArea != nil
        let hosting = UIHostingController(rootView: ReservedToolbarHost(
            model: model, store: store, controller: controller, extendsCanvasUnderChrome: extendsCanvas
        ))
        if let additionalSafeArea {
            hosting.additionalSafeAreaInsets = additionalSafeArea
        } else {
            hosting.safeAreaRegions = []
        }
        let window = try NotebookTestFixtures.window(showing: hosting)
        let fixture = ReservedHostFixture(
            hosting: hosting, window: window, controller: controller, store: store, model: model,
            honoursSafeArea: extendsCanvas
        )
        defer { fixture.close() }
        try await NotebookTestFixtures.waitUntil {
            let chromeTop = fixture.safeArea.top + topReservation
            return controller.isCanvasVisible && store.isToolbarAvailable && controller.canvasView.bounds.height > 0
                && store.overlayObstruction.top > 0 && fixture.firstStripFrame != nil
                && controller.canvasView.contentInset.top >= store.overlayObstruction.top + chromeTop - 0.5
        }
        return try await body(fixture)
    }

    private static let renderSize = CGSize(width: 200, height: 120)

    /// A 44 point key face with a small dark mark at its centre in the key's glyph colour.
    private static var keyLabel: some View {
        ZStack {
            Color.clear
            Rectangle().frame(width: 10, height: 10)
        }
        .frame(width: NotebookTheme.controlSize, height: NotebookTheme.controlSize)
    }

    /// The colours at `points` of `content`, hosted in a window with the given contrast.
    private func rendered<Content: View>(
        _ content: Content, contrast: UIAccessibilityContrast, at points: [CGPoint]
    ) async throws -> [[UInt8]] {
        let hosting = AppearanceTrackingHostingController(rootView: content)
        hosting.traitOverrides.accessibilityContrast = contrast
        hosting.safeAreaRegions = []
        let window = try NotebookTestFixtures.window(showing: hosting, width: Self.renderSize.width)
        window.frame = CGRect(origin: .zero, size: Self.renderSize)
        defer { close(window) }
        try await NotebookTestFixtures.waitUntil {
            hosting.hasAppeared && hosting.traitCollection.accessibilityContrast == contrast
        }
        let view = try XCTUnwrap(hosting.view)
        view.layoutIfNeeded()
        // At the display's own scale, as resampling would ring at hard edges such as outlines.
        let scale = window.traitCollection.displayScale
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let pixels = try RenderedPixels(try XCTUnwrap(image.cgImage), scale: scale)
        return points.map { pixels.rgba(at: $0) }
    }

    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func assertComponents(
        of color: UIColor, equal expected: [CGFloat], _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha), message, file: file, line: line)
        for (actual, value) in zip([red, green, blue, alpha], expected) {
            XCTAssertEqual(actual, value, accuracy: 0.001, message, file: file, line: line)
        }
    }

    private func assertPixel(
        _ pixel: [UInt8], equals expected: [CGFloat], _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for (actual, value) in zip(pixel.prefix(3), expected) {
            XCTAssertEqual(Double(actual), Double(value * 255), accuracy: 2, "\(message): \(pixel)", file: file, line: line)
        }
    }

    private func assertContrast(
        _ foreground: EditorInkColor, _ background: EditorInkColor, atLeast minimum: Double, _ name: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let ratio = foreground.contrastRatio(against: background)
        XCTAssertGreaterThanOrEqual(ratio, minimum, "\(name): \(ratio.formatted(.number.precision(.fractionLength(2)))):1", file: file, line: line)
    }

    /// The tone as it resolves under `contrast`, kept with its alpha.
    private func color(_ tone: NotebookTheme.Tone, _ contrast: UIAccessibilityContrast = .normal) -> EditorInkColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        tone.uiColor.resolvedColor(with: UITraitCollection(accessibilityContrast: contrast))
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return EditorInkColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// The shell gradient at `fraction` of its height.
    private func shell(at fraction: Double) -> EditorInkColor {
        let top = color(NotebookTheme.panelTop)
        let bottom = color(NotebookTheme.panelBottom)
        return EditorInkColor(
            red: top.red + (bottom.red - top.red) * fraction,
            green: top.green + (bottom.green - top.green) * fraction,
            blue: top.blue + (bottom.blue - top.blue) * fraction
        )
    }

    private func blend(_ color: EditorInkColor, _ opacity: Double, over background: EditorInkColor) -> EditorInkColor {
        EditorInkColor(
            red: color.red * opacity + background.red * (1 - opacity),
            green: color.green * opacity + background.green * (1 - opacity),
            blue: color.blue * opacity + background.blue * (1 - opacity)
        )
    }

    private func components(_ color: EditorInkColor) -> [CGFloat] {
        [color.red, color.green, color.blue].map { CGFloat($0) }
    }

    private func luminance(_ pixel: [UInt8]) -> Double {
        EditorInkColor(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
            .relativeLuminance
    }
}

@MainActor
private final class ReservationModel: ObservableObject {
    @Published var topReservation: CGFloat

    init(topReservation: CGFloat) {
        self.topReservation = topReservation
    }
}

private struct ReservedToolbarHost: View {
    @ObservedObject var model: ReservationModel
    let store: NotebookSceneToolStore
    let controller: NotebookViewController
    let extendsCanvasUnderChrome: Bool

    var body: some View {
        NotebookToolbarHost(
            store: store, extendsCanvasUnderChrome: extendsCanvasUnderChrome, topReservation: model.topReservation
        ) {
            ChromedNotebookController(controller: controller)
        }
        .environment(\.horizontalSizeClass, .regular)
    }
}

/// Mounts a controller and hands it the chrome the host measures, as the notebook canvas does.
private struct ChromedNotebookController: UIViewControllerRepresentable {
    let controller: NotebookViewController

    func makeUIViewController(context: Context) -> NotebookViewController { controller }

    func updateUIViewController(_ controller: NotebookViewController, context: Context) {
        controller.applyChrome(context.environment.notebookCanvasChrome)
    }
}

/// What a mounted host laid out: its first strip, the canvas insets and the toolbar's obstruction.
private struct ReservedHostLayout {
    let strip: CGRect
    let contentInset: UIEdgeInsets
    let obstruction: UIEdgeInsets
}

@MainActor
private struct ReservedHostFixture {
    let hosting: UIViewController
    let window: UIWindow
    let controller: NotebookViewController
    let store: NotebookSceneToolStore
    let model: ReservationModel
    let honoursSafeArea: Bool

    var host: UIView { hosting.view }

    /// The safe area the host lays its controls out in; none when it ignores safe areas.
    var safeArea: UIEdgeInsets { honoursSafeArea ? host.safeAreaInsets : .zero }

    var canvasFrame: CGRect { controller.view.convert(controller.view.bounds, to: host) }

    /// The toolbar's first scrolling strip, which starts at the toolbar's top edge.
    var firstStripFrame: CGRect? {
        func collect(_ view: UIView) -> [UIScrollView] {
            if view === controller.view { return [] }
            let own = (view as? UIScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap(collect)
        }
        return collect(host).map { $0.convert($0.bounds, to: host) }.min { $0.minY < $1.minY }
    }

    func layout() throws -> ReservedHostLayout {
        ReservedHostLayout(
            strip: try XCTUnwrap(firstStripFrame), contentInset: controller.canvasView.contentInset,
            obstruction: store.overlayObstruction
        )
    }

    /// Where the docked toolbar belongs in the host's safe area less `reservation` at the top.
    func dockedFrame(below reservation: CGFloat) -> CGRect {
        var area = host.bounds.inset(by: safeArea)
        area.origin.y += reservation
        area.size.height -= reservation
        let composition = NotebookToolbarComposition(preferences: store.toolbar, horizontalSizeClass: .regular)
        return EditorToolbarLayout.frame(
            for: store.toolbar.placement, size: composition.toolbarSize(forHostWidth: area.width), in: area
        )
    }

    func close() {
        controller.tearDown()
        window.isHidden = true
        window.rootViewController = nil
    }
}
