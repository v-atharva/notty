import Combine
import NottyCore
import PencilKit
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import XCTest
@testable import Notty

@MainActor
final class NotebookColorPickerScreenTests: XCTestCase {
    // MARK: - Layout

    func testPickerAndScratchpadSitSideBySideInPortraitAndLandscape() {
        let toastRoom: CGFloat = 46
        for size in [
            CGSize(width: 1_024, height: 1_366), CGSize(width: 1_366, height: 1_024),
            CGSize(width: 834, height: 1_210), CGSize(width: 1_210, height: 834)
        ] {
            let content = Self.content(in: size)
            let layout = NotebookColorPickerLayout(
                content: content, pickerHeight: { _ in 450 }, pickerMinimumHeight: 350, toastRoom: toastRoom, hintHeight: 18
            )
            XCTAssertEqual(layout.arrangement, .sideBySide, "\(size)")
            XCTAssertEqual(layout.centredPicker.midX, content.midX, accuracy: 0.5, "\(size)")
            XCTAssertEqual(layout.centredPicker.size, layout.picker.size, "The picker only moves; it never resizes.")
            XCTAssertEqual(layout.centredPicker.minY, layout.picker.minY, "Side by side, the picker glides straight left.")
            XCTAssertLessThan(layout.picker.minX, layout.centredPicker.minX)
            XCTAssertEqual(layout.scratchpad.minX - layout.picker.maxX, NotebookTheme.colorScreenCardGap, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(layout.scratchpad.width, NotebookTheme.scratchpadMinimumWidth)
            XCTAssertEqual(layout.scratchpad.height, layout.picker.height)
            XCTAssertGreaterThanOrEqual(layout.scratchpad.minY - content.minY, toastRoom, "Room for the toast above.")
            XCTAssertEqual(layout.hint.minY - layout.picker.maxY, NotebookTheme.colorScreenHintGap, accuracy: 0.5,
                           "The hint lies under the cards.")
            XCTAssertEqual(layout.hint.midX, content.midX, accuracy: 0.5)
            for frame in [layout.centredPicker, layout.picker, layout.scratchpad, layout.hint] {
                XCTAssertTrue(content.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(frame) in \(size)")
            }
            XCTAssertEqual(layout.picker.minX - content.minX, content.maxX - layout.scratchpad.maxX, accuracy: 0.5,
                           "The pair is centred.")
            XCTAssertEqual(layout.picker.minY - toastRoom - content.minY, content.maxY - layout.hint.maxY, accuracy: 0.5,
                           "The toast's room, the cards and the hint are centred together.")
        }
    }

    func testANarrowWindowStacksTheScratchpadUnderThePicker() {
        let toastRoom: CGFloat = 46
        for size in [CGSize(width: 375, height: 1_024), CGSize(width: 507, height: 1_024)] {
            let content = Self.content(in: size)
            let layout = NotebookColorPickerLayout(
                content: content, pickerHeight: { _ in 420 }, pickerMinimumHeight: 240, toastRoom: toastRoom, hintHeight: 18
            )
            XCTAssertEqual(layout.arrangement, .stacked, "\(size)")
            XCTAssertEqual(layout.centredPicker.size, layout.picker.size)
            XCTAssertEqual(layout.centredPicker.minX, layout.picker.minX, "Stacked, the picker glides straight up.")
            XCTAssertLessThan(layout.picker.minY, layout.centredPicker.minY)
            XCTAssertGreaterThanOrEqual(layout.scratchpad.minY - layout.picker.maxY, toastRoom - 0.5,
                                        "The toast rests between the cards.")
            XCTAssertGreaterThanOrEqual(layout.scratchpad.height, NotebookTheme.scratchpadMinimumHeight)
            XCTAssertGreaterThanOrEqual(layout.hint.minY, layout.scratchpad.maxY)
            for frame in [layout.centredPicker, layout.picker, layout.scratchpad, layout.hint] {
                XCTAssertTrue(content.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(frame) in \(size)")
            }
        }
        let short = NotebookColorPickerLayout(
            content: CGRect(x: 24, y: 48, width: 327, height: 500), pickerHeight: { _ in 420 }, pickerMinimumHeight: 240,
            toastRoom: toastRoom, hintHeight: 18
        )
        XCTAssertEqual(short.picker.height, 260, "A short window shortens the picker, down to its minimum, ...")
        XCTAssertEqual(short.scratchpad.height, NotebookTheme.scratchpadMinimumHeight,
                       "... never the scratchpad below its minimum.")
        XCTAssertLessThanOrEqual(short.hint.maxY, 548.5, "The hint keeps its room on a short window.")
    }

    func testAShortWindowShrinksTheSquareToItsMinimumAndKeepsTheFieldsInSight() {
        let toastRoom: CGFloat = 46
        let hintRoom = 18 + NotebookTheme.colorScreenHintGap
        func layout(_ content: CGRect) -> NotebookColorPickerLayout {
            NotebookColorPickerLayout(
                content: content, pickerHeight: { _ in 450 }, pickerMinimumHeight: 350, toastRoom: toastRoom, hintHeight: 18
            )
        }
        let roomy = CGRect(x: 24, y: 48, width: 1_160, height: 500)
        XCTAssertEqual(layout(roomy).picker.height, roomy.height - toastRoom - hintRoom, "The square gives way first.")
        XCTAssertTrue(roomy.contains(layout(roomy).picker))

        // A small iPad in landscape with the keyboard docked: too short for even the minimum.
        let cramped = CGRect(x: 24, y: 48, width: 1_085, height: 280)
        let beside = layout(cramped)
        XCTAssertEqual(beside.arrangement, .sideBySide)
        XCTAssertEqual(beside.picker.height, 350, "The square never shrinks past its minimum.")
        XCTAssertEqual(beside.scratchpad.height, 350)
        XCTAssertEqual(beside.centredPicker.minY, beside.picker.minY)
        XCTAssertEqual(beside.picker.maxY, cramped.maxY - hintRoom, accuracy: 0.5,
                       "The fields keep their place above the keyboard or the shades, ...")
        XCTAssertEqual(beside.hint.maxY, cramped.maxY, accuracy: 0.5)
        XCTAssertLessThan(beside.picker.minY, cramped.minY, "... and the cards run past the top instead.")

        let narrow = CGRect(x: 24, y: 48, width: 327, height: 400)
        let stacked = layout(narrow)
        XCTAssertEqual(stacked.arrangement, .stacked)
        XCTAssertEqual(stacked.picker.height, 350)
        XCTAssertEqual(stacked.hint.maxY, narrow.maxY, accuracy: 0.5, "Stacked cards keep their lower edge too.")
    }

    // MARK: - Presentation

    func testScreenCoversTheWindowAtOnceWithoutASlide() async throws {
        let rig = try await ColorScreenRig.mount()
        defer { rig.close() }
        rig.trigger.isPresented = true
        let presented = try await NotebookTestFixtures.waitForValue { rig.hosting.presentedViewController }
        XCTAssertEqual(presented.modalPresentationStyle, .overFullScreen)
        try await NotebookTestFixtures.waitUntil { presented.view.window != nil }
        XCTAssertEqual(presented.view.frame, rig.window.bounds, "It never starts below the screen.")
        XCTAssertNil(presented.view.layer.animation(forKey: "position"), "No slide from the bottom.")
        XCTAssertEqual(presented.view.backgroundColor ?? .clear, .clear,
                       "The cover is clear, so the screen fades in over the notebook rather than a blank sheet.")
        let screen = try await rig.open()

        XCTAssertEqual(screen.view.convert(screen.view.bounds, to: rig.window), rig.window.bounds)
        XCTAssertTrue(rig.store.isToolbarAvailable, "The notebook beneath keeps its tools, so the screen stays open.")
        XCTAssertTrue(rig.controller.isCanvasVisible)
        XCTAssertTrue(screen.view.accessibilityViewIsModal, "VoiceOver stays on the screen, not the notebook beneath.")
        XCTAssertTrue(screen.isFirstResponder, "Keyboard commands reach the screen, not the notebook beneath.")
        XCTAssertEqual(screen.view.backgroundColor, NotebookTheme.backdropStone.uiColor)
        XCTAssertEqual(screen.view.subviews, [screen.scratchpad.view, screen.panel, screen.toast.view, screen.exitHint, screen.shadeBar],
                       "The panel, the scratchpad, the toast, the hint and the shades: no Done or Cancel keys.")
        XCTAssertEqual(screen.exitHint.text, "Tap anywhere to exit")
        XCTAssertEqual(screen.exitHint.textColor, NotebookTheme.glyphSecondary.uiColor)
        XCTAssertTrue(screen.exitHint.adjustsFontForContentSizeCategory)
        XCTAssertGreaterThan(screen.exitHint.frame.minY, screen.panel.frame.maxY, "The hint sits under the cards.")
        XCTAssertLessThanOrEqual(screen.exitHint.frame.maxY, screen.shadeBar.frame.minY, "And above the shades.")
    }

    func testScreenFadesInAsTheShadeBarRises() async throws {
        let rig = try await ColorScreenRig.mount()
        defer { rig.close() }
        let screen = try await rig.open()
        for reduceMotion in [false, true] {
            screen.view.layer.removeAllAnimations()
            screen.shadeBar.layer.removeAllAnimations()
            screen.prefersCrossFade = { reduceMotion }
            screen.enter()
            let fade = try XCTUnwrap(screen.view.layer.animation(forKey: "opacity") as? CABasicAnimation, "reduceMotion: \(reduceMotion)")
            XCTAssertEqual(fade.duration, NotebookTheme.colorScreenEntranceDuration, accuracy: 0.001)
            XCTAssertEqual(screen.view.alpha, 1)
            let rise = screen.shadeBar.layer.animation(forKey: "transform") as? CASpringAnimation
            if reduceMotion {
                XCTAssertNil(rise, "Under Reduce Motion the bar only fades in with the screen.")
            } else {
                let rise = try XCTUnwrap(rise, "The shade bar eases in from the bottom on a spring.")
                XCTAssertEqual(rise.perceptualDuration, NotebookTheme.shadeBarEntranceDuration, accuracy: 0.05)
                let start = try XCTUnwrap(rise.fromValue as? NSValue).caTransform3DValue
                XCTAssertEqual(start.m42, screen.shadeBar.bounds.height, accuracy: 0.5, "It starts wholly below the screen.")
            }
            XCTAssertEqual(screen.shadeBar.transform, .identity)
        }
    }

    func testScreenPinsTheWritingChromeWhileOpen() async throws {
        let rig = try await ColorScreenRig.mount()
        defer { rig.close() }
        let chromeRig = try await NotebookChromeRig(store: rig.store)
        XCTAssertFalse(chromeRig.chrome.isPresenting)

        let screen = try await rig.open()
        XCTAssertTrue(chromeRig.chrome.isPresenting)

        screen.leave()
        try await rig.waitUntilClosed()
        XCTAssertFalse(chromeRig.chrome.isPresenting)
    }

    /// The custom colour well sits on the rail's glass, which the cover inherits and SwiftUI hands
    /// on to the SwiftUI views the screen hosts, as it hosts its toast. The screen is matte, so a
    /// key hosted there takes the recessed well for its selection, as in the popovers, rather
    /// than a lens of glass.
    func testTheScreenOpenedFromTheRailsGlassKeepsItsKeysMatte() async throws {
        let rig = try await ColorScreenRig.mount(presentsFromGlass: true)
        defer { rig.close() }
        let screen = try await rig.open()
        let probe = HostedKeyProbe()
        let key = UIHostingController(rootView: HostedKeyProbe.Key(probe: probe))
        key.view.backgroundColor = .clear
        screen.addChild(key)
        screen.view.addSubview(key.view)
        key.view.frame = CGRect(x: 40, y: 40, width: HostedKeyProbe.side, height: HostedKeyProbe.side)
        key.didMove(toParent: screen)
        defer {
            key.willMove(toParent: nil)
            key.view.removeFromSuperview()
            key.removeFromParent()
        }
        try await NotebookTestFixtures.waitUntil { probe.isOnGlass != nil }
        XCTAssertEqual(probe.isOnGlass, false, "The screen's SwiftUI views are not on the rail's glass.")

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        let image = UIGraphicsImageRenderer(bounds: key.view.bounds, format: format).image { _ in
            key.view.drawHierarchy(in: key.view.bounds, afterScreenUpdates: true)
        }
        let pixels = try RenderedPixels(try XCTUnwrap(image.cgImage), scale: 2)
        let centre = pixels.rgba(at: CGPoint(x: HostedKeyProbe.side / 2, y: HostedKeyProbe.side / 2))
        let well = NotebookSwatchShelf.color(from: NotebookTheme.selectedWell.uiColor.resolvedColor(with: screen.traitCollection))
        let expected = [well.red, well.green, well.blue].map { Int(($0 * 255).rounded()) }
        for (channel, value) in zip(expected, centre.prefix(3)) {
            XCTAssertEqual(Int(value), channel, accuracy: 3, "The selected key sinks into the matte well: \(centre)")
        }
    }

    // MARK: - Panel

    func testPanelFollowsTheReferenceLayout() async throws {
        let rig = try await ColorScreenRig.mount()
        defer { rig.close() }
        let screen = try await rig.open()
        let panel = screen.panel
        panel.layoutIfNeeded()

        XCTAssertEqual(panel.backgroundColor, NotebookTheme.colorPanelFill.uiColor)
        XCTAssertEqual(panel.layer.cornerRadius, NotebookTheme.panelCornerRadius)
        XCTAssertEqual(panel.titleLabel.text, "Color Picker")
        XCTAssertEqual(panel.titleLabel.textColor, NotebookTheme.colorPanelText.uiColor)
        XCTAssertEqual(panel.titleLabel.textAlignment, .center)
        XCTAssertEqual(panel.titleLabel.frame.midX, panel.bounds.midX, accuracy: 0.5, "The title is centred.")
        let key = panel.eyedropperKey.frame
        XCTAssertEqual(key.size, CGSize(width: 44, height: 44))
        XCTAssertLessThan(key.maxX, panel.titleLabel.frame.minX, "The eyedropper sits at top left.")
        XCTAssertEqual(key.midY, panel.titleLabel.frame.midY, accuracy: 0.5)
        XCTAssertNotNil(panel.eyedropperKey.glyph.image)
        XCTAssertEqual(panel.eyedropperKey.accessibilityLabel, "Eyedropper")

        let square = panel.square.frame
        let slider = panel.hueSlider.frame
        XCTAssertGreaterThan(square.minY, key.maxY)
        XCTAssertGreaterThan(square.height, NotebookTheme.colorSquareMinimumHeight)
        XCTAssertGreaterThan(slider.minY, square.maxY, "The hue slider runs under the square.")
        XCTAssertEqual(slider.width, square.width)
        XCTAssertGreaterThanOrEqual(slider.height, 44, "The slider takes touches across a full key's height.")
        let hex = panel.hexField.frame
        let well = panel.segmentWell.frame
        let alpha = panel.field(.alpha).frame
        XCTAssertGreaterThan(hex.minY, slider.maxY)
        XCTAssertLessThan(hex.maxX, well.minX)
        XCTAssertLessThan(well.maxX, alpha.minX)
        XCTAssertEqual(hex.minX, square.minX, accuracy: 0.5)
        XCTAssertEqual(alpha.maxX, square.maxX, accuracy: 0.5)
        for field in [EditorColorField.hue, .saturation, .brightness] {
            XCTAssertTrue(panel.field(field).superview === panel.segmentWell, "Hue, saturation and brightness share one well.")
        }

        let captions = panel.subviews.compactMap { $0 as? UILabel }.filter { $0 !== panel.titleLabel }
        XCTAssertEqual(captions.sorted { $0.frame.minX < $1.frame.minX }.map(\.text), ["HEX", "H", "S", "B", "Alpha"],
                       "The true names: hue, saturation and brightness, not red, green and blue.")
        for caption in captions {
            XCTAssertGreaterThan(caption.frame.minY, hex.maxY, "Gray labels under the fields.")
            XCTAssertEqual(caption.textColor, NotebookTheme.colorPanelLabel.uiColor)
        }

        // At its least height only the square is smaller; everything else keeps its place inside.
        let compact = NotebookColorPickerPanel(color: panel.color)
        compact.frame = CGRect(x: 0, y: 0, width: panel.bounds.width, height: compact.minimumHeight)
        compact.layoutIfNeeded()
        XCTAssertEqual(compact.square.frame.height, NotebookTheme.colorSquareMinimumHeight, accuracy: 0.5)
        let preferredSquare = ((compact.bounds.width - 2 * NotebookTheme.colorPanelPadding) * NotebookTheme.colorSquareAspectRatio).rounded()
        XCTAssertEqual(compact.height(forWidth: compact.bounds.width) - compact.minimumHeight,
                       preferredSquare - NotebookTheme.colorSquareMinimumHeight, accuracy: 0.5, "The two differ only in the square.")
        let lowest = compact.subviews.map(\.frame.maxY).max() ?? 0
        XCTAssertEqual(lowest, compact.bounds.maxY - NotebookTheme.colorPanelPadding, accuracy: 0.5, "The labels end inside the card.")
    }

    func testHueTrackShowsUnderTheRingTheHueItPicks() throws {
        let slider = NotebookHueSlider(frame: CGRect(x: 0, y: 0, width: 360, height: NotebookTheme.colorHueSliderHeight))
        slider.layoutIfNeeded()
        let locations = try XCTUnwrap(slider.track.locations)
        XCTAssertEqual(locations.count, NotebookHueSlider.trackHues.count)
        XCTAssertEqual(slider.track.colors?.count, locations.count)
        XCTAssertEqual(slider.track.frame.minX, 0)
        for (hue, location) in zip(NotebookHueSlider.trackHues, locations) {
            slider.hue = hue
            let x = CGFloat(location.doubleValue) * slider.track.bounds.width
            XCTAssertEqual(x, slider.handleCenter.x, accuracy: 0.01, "\(hue)° lies under the ring that picks it.")
            XCTAssertEqual(slider.hue(at: CGPoint(x: x, y: slider.bounds.midY)), hue, accuracy: 0.01)
        }
        XCTAssertGreaterThan(locations.first?.doubleValue ?? 0, 0, "The rounded ends lie beyond the ring's travel.")
        XCTAssertLessThan(locations.last?.doubleValue ?? 1, 1)
    }

    func testPanelShowsTheInkInUseAsItsTrueValues() async throws {
        let rig = try await ColorScreenRig.mount()
        defer { rig.close() }
        NotebookToolbarActions(store: rig.store).selectColor(try XCTUnwrap(EditorInkColor(hex: "EF6C40")))
        let screen = try await rig.open()
        let panel = screen.panel
        XCTAssertEqual(panel.hexField.text, "EF6C40")
        XCTAssertEqual(panel.field(.hue).text, "15")
        XCTAssertEqual(panel.field(.saturation).text, "73")
        XCTAssertEqual(panel.field(.brightness).text, "94")
        XCTAssertEqual(panel.field(.alpha).text, "100")
        XCTAssertEqual(panel.field(.hue).accessibilityValue, "15 degrees")
        XCTAssertEqual(panel.field(.saturation).accessibilityValue, "73 percent")
    }

    func testSquareSliderAndFieldsStayInStep() async throws {
        let rig = try await ColorScreenRig.mount()
        defer { rig.close() }
        let screen = try await rig.open()
        let panel = screen.panel
        var changes: [NotebookColorChange] = []
        let forward = panel.onChange
        panel.onChange = { color, change in
            changes.append(change)
            forward?(color, change)
        }

        // A drag across the square, by finger or Pencil, as UIKit reports it.
        let square = panel.square
        square.layoutIfNeeded()
        XCTAssertEqual(square.components(at: CGPoint(x: square.bounds.width, y: 0)).saturation, 1)
        XCTAssertEqual(square.components(at: CGPoint(x: -40, y: square.bounds.height + 40)).brightness, 0, "Kept inside the square.")
        square.saturation = 0.5
        square.brightness = 0.25
        square.sendActions(for: .valueChanged)
        XCTAssertEqual(changes, [.passing])
        XCTAssertEqual(panel.color.saturation, 0.5)
        XCTAssertEqual(panel.color.brightness, 0.25)
        XCTAssertEqual(panel.field(.saturation).text, "50")
        XCTAssertEqual(panel.field(.brightness).text, "25")
        XCTAssertEqual(panel.hexField.text, panel.color.rgb.hexString)
        XCTAssertEqual(square.handle.center, CGPoint(x: square.bounds.width * 0.5, y: square.bounds.height * 0.75))
        square.sendActions(for: .touchUpInside)
        XCTAssertEqual(changes, [.passing, .settled], "Lifting settles the colour.")
        XCTAssertEqual(screen.color, panel.color)

        let slider = panel.hueSlider
        slider.layoutIfNeeded()
        XCTAssertEqual(slider.hue(at: CGPoint(x: slider.bounds.maxX + 30, y: 0)), 360)
        slider.hue = 240
        slider.sendActions(for: .valueChanged)
        slider.sendActions(for: .touchUpOutside)
        XCTAssertEqual(panel.field(.hue).text, "240")
        XCTAssertEqual(square.hue, 240, "The square shows the new hue.")
        XCTAssertEqual(
            square.hueFill.backgroundColor.map { NotebookSwatchShelf.color(from: UIColor(cgColor: $0)) },
            EditorInkColor(red: 0, green: 0, blue: 1)
        )
        XCTAssertEqual(panel.color.saturation, 0.5, "The hue moves alone.")

        enter("EF6C40", in: panel.hexField, of: panel)
        XCTAssertEqual(panel.field(.hue).text, "15")
        XCTAssertEqual(panel.field(.saturation).text, "73")
        XCTAssertEqual(slider.hue, panel.color.hue)
        XCTAssertEqual(square.saturation, panel.color.saturation)
        XCTAssertEqual(changes.last, .settled)

        enter("400", in: panel.field(.hue), of: panel)
        XCTAssertEqual(panel.field(.hue).text, "360", "A value past the range is brought into it.")
        enter("", in: panel.field(.saturation), of: panel)
        XCTAssertEqual(panel.field(.saturation).text, "73", "An empty field returns to the value it showed.")
        enter("12", in: panel.hexField, of: panel)
        XCTAssertEqual(panel.hexField.text, panel.color.rgb.hexString, "An incomplete HEX returns too.")
        enter("200", in: panel.field(.hue), of: panel)
        enter("808080", in: panel.hexField, of: panel)
        XCTAssertEqual(panel.field(.hue).text, "200", "A gray keeps the hue it came from.")
        XCTAssertEqual(panel.field(.saturation).text, "0")
        XCTAssertEqual(slider.hue, 200)
        enter("50", in: panel.field(.alpha), of: panel)
        XCTAssertEqual(panel.color.alpha, 0.5)
        XCTAssertEqual(screen.scratchpad.ink?.color.alpha ?? 0, 0.5, accuracy: 0.01, "The scratchpad's ink takes the alpha.")
    }

    func testFieldsAcceptOnlyWhatTheyCanHold() async throws {
        let rig = try await ColorScreenRig.mount()
        defer { rig.close() }
        let screen = try await rig.open()
        let panel = screen.panel
        func accepts(_ field: UITextField, _ text: String, typing: String) -> Bool {
            field.text = text
            return panel.textField(field, shouldChangeCharactersIn: NSRange(location: text.utf16.count, length: 0), replacementString: typing)
        }
        XCTAssertTrue(accepts(panel.hexField, "EF6C4", typing: "0"))
        XCTAssertTrue(accepts(panel.hexField, "ef", typing: "c"), "Lowercase is read as uppercase.")
        XCTAssertFalse(accepts(panel.hexField, "EF6C40", typing: "1"), "Six digits at most.")
        XCTAssertFalse(accepts(panel.hexField, "EF", typing: "G"))
        XCTAssertTrue(accepts(panel.field(.hue), "36", typing: "0"))
        XCTAssertFalse(accepts(panel.field(.hue), "360", typing: "0"))
        XCTAssertFalse(accepts(panel.field(.alpha), "5", typing: "%"))
        XCTAssertEqual(panel.hexField.autocorrectionType, .no)
        XCTAssertEqual(panel.field(.hue).keyboardType, .numberPad)
    }

    func testPanelTextHandlesAndBordersMeetContrast() {
        func ratio(_ foreground: NotebookTheme.Tone, _ background: NotebookTheme.Tone, increased: Bool = false) -> Double {
            let traits = UITraitCollection(accessibilityContrast: increased ? .high : .normal)
            let back = NotebookSwatchShelf.color(from: background.uiColor.resolvedColor(with: traits))
            let front = NotebookSwatchShelf.color(from: foreground.uiColor.resolvedColor(with: traits))
            return Self.composite(front, over: back).contrastRatio(against: back)
        }
        for increased in [false, true] {
            XCTAssertGreaterThanOrEqual(ratio(NotebookTheme.colorPanelText, NotebookTheme.colorPanelFill, increased: increased), 4.5)
            XCTAssertGreaterThanOrEqual(ratio(NotebookTheme.colorPanelText, NotebookTheme.colorFieldFill, increased: increased), 4.5)
            XCTAssertGreaterThanOrEqual(ratio(NotebookTheme.colorPanelLabel, NotebookTheme.colorPanelFill, increased: increased), 4.5)
            XCTAssertGreaterThanOrEqual(ratio(NotebookTheme.colorFieldEdge, NotebookTheme.colorPanelFill, increased: increased), 3)
            XCTAssertGreaterThanOrEqual(ratio(NotebookTheme.colorFieldEdge, NotebookTheme.colorFieldFill, increased: increased), 3)
            XCTAssertGreaterThanOrEqual(ratio(NotebookTheme.trialTryingBorder, NotebookTheme.colorPanelFill, increased: increased), 3)
            XCTAssertGreaterThanOrEqual(ratio(NotebookTheme.trialReadyBorder, NotebookTheme.colorPanelFill, increased: increased), 3)
            XCTAssertGreaterThanOrEqual(ratio(NotebookTheme.trialTryingMark, NotebookTheme.colorPanelFill, increased: increased), 4.5)
            XCTAssertGreaterThanOrEqual(ratio(NotebookTheme.trialReadyMark, NotebookTheme.colorPanelFill, increased: increased), 4.5)
            XCTAssertGreaterThanOrEqual(ratio(NotebookTheme.glyphSecondary, NotebookTheme.backdropStone, increased: increased), 4.5,
                                        "The exit hint on the stone.")
            for shell in [NotebookTheme.panelTop, NotebookTheme.panelBottom] {
                XCTAssertGreaterThanOrEqual(ratio(NotebookTheme.glyph, shell, increased: increased), 4.5, "The toast's words.")
                XCTAssertGreaterThanOrEqual(ratio(NotebookTheme.colorToastCheck, shell, increased: increased), 3, "The toast's check.")
            }
        }
        XCTAssertGreaterThanOrEqual(ratio(NotebookTheme.colorPanelFill, NotebookTheme.backdropStone), 3, "The cards on the stone.")

        // A ring handle reads on whatever lies under it: its white or its dark rim reaches 3:1.
        let white = NotebookSwatchShelf.color(from: NotebookTheme.colorHandleRing.uiColor)
        let rim = NotebookSwatchShelf.color(from: NotebookTheme.colorHandleRim.uiColor)
        var samples = stride(from: 0.0, to: 360, by: 15).map { EditorHSBColor(hue: $0, saturation: 1, brightness: 1).rgb }
        for saturation in stride(from: 0.0, through: 1, by: 0.25) {
            for brightness in stride(from: 0.0, through: 1, by: 0.125) {
                samples += stride(from: 0.0, to: 360, by: 30).map {
                    EditorHSBColor(hue: $0, saturation: saturation, brightness: brightness).rgb
                }
            }
        }
        for sample in samples {
            let best = max(white.contrastRatio(against: sample), Self.composite(rim, over: sample).contrastRatio(against: sample))
            XCTAssertGreaterThanOrEqual(best, 3, "\(sample.hexString)")
        }
    }

    // MARK: - Shade bar

    func testShadeBarSpansTheBottomWithLargeStepsOfTheHue() async throws {
        let rig = try await ColorScreenRig.mount()
        defer { rig.close() }
        let screen = try await rig.open()
        let bar = screen.shadeBar
        let bounds = screen.view.bounds
        XCTAssertEqual(bar.frame.minX, 0)
        XCTAssertEqual(bar.frame.width, bounds.width, "Full width.")
        XCTAssertEqual(bar.frame.maxY, bounds.maxY, "Down to the bottom edge.")
        XCTAssertEqual(bar.frame.height, NotebookTheme.shadeBarHeight + screen.view.safeAreaInsets.bottom)
        XCTAssertGreaterThanOrEqual(NotebookTheme.shadeBarHeight, 120)
        XCTAssertLessThanOrEqual(NotebookTheme.shadeBarHeight, 160)
        XCTAssertEqual(bar.steps.count, 11)
        XCTAssertEqual(bar.shades, EditorShadeRamp.steps(of: screen.shadeBase, count: 11))
        for (step, shade) in zip(bar.steps, bar.shades) {
            XCTAssertGreaterThanOrEqual(step.bounds.width, 44)
            XCTAssertGreaterThanOrEqual(step.bounds.height, 44)
            XCTAssertEqual(step.backgroundColor, shade.with(alpha: 1).rgb.platformColor)
            XCTAssertTrue(step.frame.maxY <= bar.strip.bounds.maxY + 0.5)
        }
        XCTAssertLessThanOrEqual(bar.strip.convert(bar.strip.bounds, to: screen.view).maxY,
                                 bounds.maxY - screen.view.safeAreaInsets.bottom, "Clear of the home indicator.")
        XCTAssertEqual(bar.strip.layer.borderColor, NotebookTheme.colorFieldEdge.uiColor.cgColor,
                       "The strip is outlined, so a step as dark as the sheet still shows where it ends.")
        XCTAssertEqual(bar.steps.first?.accessibilityLabel, "Shade 1 of 11, lightest")
        XCTAssertEqual(bar.steps.last?.accessibilityLabel, "Shade 11 of 11, darkest")

        screen.show(screen.color.with(hue: 200), change: .passing)
        XCTAssertEqual(bar.shades.map(\.hue), Array(repeating: 200, count: 11), "The shades follow the hue as it changes.")
        XCTAssertEqual(bar.steps[3].backgroundColor, bar.shades[3].rgb.platformColor)

        screen.show(screen.color.with(alpha: 0.3), change: .passing)
        XCTAssertEqual(bar.shades.map(\.alpha), Array(repeating: 0.3, count: 11), "Each shade carries the ink's alpha, ...")
        for (step, shade) in zip(bar.steps, bar.shades) {
            XCTAssertEqual(step.backgroundColor, shade.with(alpha: 1).rgb.platformColor,
                           "... yet shows opaque, never darkened by the sheet beneath.")
        }
        bar.steps[8].sendActions(for: .touchUpInside)
        XCTAssertEqual(screen.color.alpha, 0.3, "A tapped shade keeps the alpha for the ink.")
        XCTAssertEqual(screen.scratchpad.ink?.color.alpha ?? 0, 0.3, accuracy: 0.01)
    }

    func testTappingAShadeSelectsItAndTheBarHoldsStill() async throws {
        let rig = try await ColorScreenRig.mount()
        defer { rig.close() }
        let screen = try await rig.open()
        screen.prefersCrossFade = { true }
        let bar = screen.shadeBar
        screen.show(EditorHSBColor(hue: 15, saturation: 0.8, brightness: 0.6), change: .passing)
        let shades = bar.shades
        XCTAssertNil(bar.selectedIndex, "A colour off the bar marks no step.")
        XCTAssertTrue(bar.selectionRing.isHidden)

        bar.steps[2].sendActions(for: .touchUpInside)
        XCTAssertEqual(screen.color, shades[2])
        XCTAssertEqual(screen.panel.color, shades[2], "The panel shows the shade.")
        XCTAssertEqual(bar.shades, shades, "A tapped tint leaves the bar as it was.")
        XCTAssertEqual(bar.selectedIndex, 2)
        XCTAssertFalse(bar.selectionRing.isHidden)
        XCTAssertEqual(bar.selectionRing.frame,
                       bar.steps[2].convert(bar.steps[2].bounds, to: bar).insetBy(dx: NotebookTheme.shadeSelectionInset,
                                                                                  dy: NotebookTheme.shadeSelectionInset))
        XCTAssertTrue(bar.steps[2].accessibilityTraits.contains(.selected))
        XCTAssertTrue(screen.showsScratchpad, "A tapped shade is a chosen colour.")

        screen.panel.hueSlider.hue = 100
        screen.panel.hueSlider.sendActions(for: .valueChanged)
        XCTAssertEqual(bar.selectedIndex, 2, "A new hue keeps the ring on the same step.")
        XCTAssertEqual(bar.shades[2], screen.color)
    }

    // MARK: - Glide

    func testFirstSettledColourGlidesThePanelAsideForTheScratchpad() async throws {
        let rig = try await ColorScreenRig.mount()
        defer { rig.close() }
        let screen = try await rig.open()
        screen.prefersCrossFade = { false }
        let layout = try XCTUnwrap(screen.layout)
        XCTAssertFalse(screen.showsScratchpad)
        XCTAssertEqual(screen.panel.frame, layout.centredPicker, "The panel starts centred.")
        XCTAssertEqual(screen.scratchpad.view.alpha, 0)
        XCTAssertTrue(screen.scratchpad.view.accessibilityElementsHidden)
        XCTAssertFalse(screen.scratchpad.view.isUserInteractionEnabled)

        screen.show(EditorHSBColor(hue: 120, saturation: 0.6, brightness: 0.5), change: .passing)
        XCTAssertFalse(screen.showsScratchpad, "A drag still in progress leaves the panel under the finger.")
        XCTAssertEqual(screen.panel.center, CGPoint(x: layout.centredPicker.midX, y: layout.centredPicker.midY))

        // A layout still pending at the first choice must not place the panel aside before it glides.
        screen.view.setNeedsLayout()
        screen.show(screen.color, change: .settled)
        XCTAssertTrue(screen.showsScratchpad)
        XCTAssertEqual(screen.panel.center, CGPoint(x: layout.picker.midX, y: layout.picker.midY))
        XCTAssertEqual(screen.panel.bounds.size, layout.centredPicker.size)
        let glide = try XCTUnwrap(screen.panel.layer.animation(forKey: "transform") as? CASpringAnimation,
                                  "The panel glides by its transform, on a spring.")
        XCTAssertEqual(glide.perceptualDuration, NotebookTheme.colorScreenGlideDuration, accuracy: 0.05)
        XCTAssertNil(screen.panel.layer.animation(forKey: "position"))
        XCTAssertNil(screen.panel.layer.animation(forKey: "bounds"))
        let presented = try XCTUnwrap(screen.panel.layer.presentation())
        XCTAssertGreaterThan(presented.frame.midX, layout.picker.midX, "It starts from the centre and moves left.")
        XCTAssertNotNil(screen.scratchpad.view.layer.animation(forKey: "transform"), "The scratchpad slides in beside it.")
        XCTAssertEqual(screen.scratchpad.view.alpha, 1)
        XCTAssertFalse(screen.scratchpad.view.accessibilityElementsHidden)
        XCTAssertTrue(screen.scratchpad.view.isUserInteractionEnabled)
        XCTAssertGreaterThan(screen.scratchpad.view.frame.minX, layout.picker.maxX, "On the right.")

        screen.show(EditorHSBColor(hue: 0, saturation: 1, brightness: 1), change: .settled)
        XCTAssertEqual(screen.panel.center, CGPoint(x: layout.picker.midX, y: layout.picker.midY),
                       "Later colours leave the layout as it is.")
    }

    func testReduceMotionFadesInsteadOfGliding() async throws {
        let rig = try await ColorScreenRig.mount()
        defer { rig.close() }
        let screen = try await rig.open()
        screen.prefersCrossFade = { true }
        let layout = try XCTUnwrap(screen.layout)

        screen.view.setNeedsLayout()
        screen.show(EditorHSBColor(hue: 260, saturation: 0.5, brightness: 0.5), change: .settled)
        XCTAssertTrue(screen.showsScratchpad)
        XCTAssertEqual(screen.panel.frame, layout.picker)
        XCTAssertEqual(screen.panel.transform, .identity)
        XCTAssertEqual(screen.scratchpad.view.transform, .identity)
        XCTAssertEqual(screen.scratchpad.view.alpha, 1)
        for layer in [screen.panel.layer, screen.scratchpad.view.layer] {
            for key in ["position", "transform", "bounds"] {
                XCTAssertNil(layer.animation(forKey: key), "Nothing glides under Reduce Motion: \(key).")
            }
        }
        let step = try XCTUnwrap(
            screen.panel.layer.animation(forKey: NotebookColorPickerScreenController.fadeStepKey) as? CAKeyframeAnimation
        )
        XCTAssertEqual(step.calculationMode, .discrete, "The panel steps to its place; it never travels.")
        XCTAssertEqual(step.values?.compactMap { ($0 as? NSValue)?.cgPointValue }, [
            CGPoint(x: layout.centredPicker.midX, y: layout.centredPicker.midY), CGPoint(x: layout.picker.midX, y: layout.picker.midY)
        ], "It fades out where it showed, even with a layout pending.")
        let dip = try XCTUnwrap(screen.panel.layer.animation(forKey: NotebookColorPickerScreenController.fadeKey) as? CAKeyframeAnimation)
        XCTAssertEqual(dip.values?.compactMap { ($0 as? NSNumber)?.doubleValue }, [1, 0, 1], "It is unseen at the moment it steps.")
        XCTAssertEqual(dip.duration, NotebookTheme.colorScreenFadeDuration, accuracy: 0.001)
        let appear = try XCTUnwrap(
            screen.scratchpad.view.layer.animation(forKey: NotebookColorPickerScreenController.fadeKey) as? CABasicAnimation
        )
        XCTAssertEqual((appear.fromValue as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual(appear.fillMode, .backwards, "The scratchpad stays hidden until the panel returns.")
    }

    // MARK: - Border and toast

    func testBorderStartsAtTheTopCentreAndRunsClockwise() {
        let rect = CGRect(x: 5, y: 5, width: 300, height: 200)
        let path = NotebookTrialBorder.path(around: rect, cornerRadius: 15)
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            let element = element.pointee
            let count = switch element.type {
            case .moveToPoint, .addLineToPoint: 1
            case .addQuadCurveToPoint: 2
            case .addCurveToPoint: 3
            default: 0
            }
            if count > 0 { points.append(element.points[count - 1]) }
        }
        XCTAssertEqual(points.first, CGPoint(x: rect.midX, y: rect.minY), "It starts at the top centre.")
        XCTAssertEqual(points[1], CGPoint(x: rect.maxX - 15, y: rect.minY), "It first runs right along the top.")
        // Clockwise on screen: right edge, then bottom, then left, then back along the top.
        func firstIndex(where condition: (CGPoint) -> Bool) -> Int { points.firstIndex(where: condition) ?? .max }
        let right = firstIndex { abs($0.x - rect.maxX) < 0.01 && $0.y > rect.midY }
        let bottom = firstIndex { abs($0.y - rect.maxY) < 0.01 && $0.x < rect.midX }
        let left = firstIndex { abs($0.x - rect.minX) < 0.01 && $0.y < rect.midY }
        XCTAssertLessThan(right, bottom)
        XCTAssertLessThan(bottom, left)
        XCTAssertLessThan(left, points.count)
        XCTAssertEqual(path.boundingBoxOfPath, rect)
        XCTAssertTrue(path.currentPoint == CGPoint(x: rect.midX, y: rect.minY), "It closes where it began.")
    }

    func testBorderDrawsYellowOverTheHoldThenTurnsGreenAndTheToastRises() async throws {
        let rig = try await ColorScreenRig.mount()
        defer { rig.close() }
        let clock = TrialClock()
        let screen = try await rig.open()
        screen.prefersCrossFade = { false }
        screen.now = { clock.time }
        let scratchpad = screen.scratchpad
        let border = scratchpad.border
        screen.show(EditorHSBColor(hue: 220, saturation: 0.7, brightness: 0.6), change: .settled)
        screen.view.layoutIfNeeded()
        XCTAssertEqual(border.stroke.strokeEnd, 0, "Nothing until the scratchpad is used.")
        XCTAssertTrue(scratchpad.statusLabel.isHidden)
        XCTAssertTrue(screen.toast.view.isHidden)
        XCTAssertEqual(screen.exitHint.accessibilityHint, NotebookColorPickerScreenController.exitLeavesHint)

        scratchpad.beginStroke()
        XCTAssertEqual(screen.trialPhase, .trying)
        XCTAssertEqual(border.stroke.strokeColor, NotebookTheme.trialTryingBorder.uiColor.cgColor, "Yellow from the first stroke.")
        XCTAssertEqual(border.stroke.lineWidth, NotebookTheme.trialBorderWidth)
        XCTAssertEqual(border.stroke.lineCap, .round)
        let draw = try XCTUnwrap(border.stroke.animation(forKey: NotebookTrialBorder.drawKey) as? CABasicAnimation)
        XCTAssertEqual(draw.keyPath, "strokeEnd")
        XCTAssertEqual((draw.fromValue as? NSNumber)?.doubleValue, 0, "From its first point.")
        XCTAssertEqual((draw.toValue as? NSNumber)?.doubleValue, 1)
        XCTAssertEqual(draw.duration, InkTrialTimeline.holdDuration, accuracy: 0.001, "Closing exactly as the hold ends.")
        XCTAssertEqual(Self.controlPoints(of: draw.timingFunction), [0, 0, 1, 1], "At an even pace.")
        XCTAssertEqual(border.stroke.path, NotebookTrialBorder.path(
            around: border.course, cornerRadius: NotebookTheme.panelCornerRadius - NotebookTheme.trialBorderInset
        ))
        XCTAssertEqual(border.startPoint, CGPoint(x: border.bounds.midX, y: NotebookTheme.trialBorderInset))
        XCTAssertFalse(scratchpad.statusLabel.isHidden)
        XCTAssertEqual(scratchpad.statusLabel.text, "TRYING…", "The state is said beside the caption.")
        XCTAssertEqual(scratchpad.canvas.accessibilityValue, NotebookScratchpadController.tryingStatus)
        XCTAssertTrue(screen.toast.view.isHidden)

        clock.time += InkTrialTimeline.holdDuration / 2
        screen.refreshTrial()
        XCTAssertTrue(border.stroke.animation(forKey: NotebookTrialBorder.drawKey) === draw, "Half way, the same drawing goes on.")

        clock.time += InkTrialTimeline.holdDuration / 2
        screen.refreshTrial()
        XCTAssertEqual(screen.trialPhase, .retained)
        XCTAssertEqual(border.stroke.strokeColor, NotebookTheme.trialReadyBorder.uiColor.cgColor, "Green once leaving keeps it.")
        XCTAssertEqual(border.stroke.strokeEnd, 1)
        XCTAssertNil(border.stroke.animation(forKey: NotebookTrialBorder.drawKey))
        let turn = try XCTUnwrap(border.stroke.animation(forKey: NotebookTrialBorder.turnKey) as? CABasicAnimation)
        XCTAssertEqual(turn.keyPath, "strokeColor")
        XCTAssertEqual(scratchpad.statusLabel.text, "READY")
        XCTAssertEqual(scratchpad.canvas.accessibilityValue, NotebookScratchpadController.readyStatus)
        XCTAssertEqual(screen.exitHint.accessibilityHint, NotebookColorPickerScreenController.exitKeepsHint)

        let toast = try XCTUnwrap(screen.toast.view)
        let card = scratchpad.view.frame
        XCTAssertFalse(toast.isHidden, "The toast arrives with the green.")
        XCTAssertEqual(toast.alpha, 1)
        XCTAssertEqual(toast.transform, .identity)
        let rise = try XCTUnwrap(toast.layer.animation(forKey: "transform") as? CASpringAnimation)
        XCTAssertEqual(rise.perceptualDuration, NotebookTheme.colorToastEntranceDuration, accuracy: 0.05)
        let start = try XCTUnwrap(rise.fromValue as? NSValue).caTransform3DValue
        XCTAssertEqual(toast.center.x + start.m41, screen.borderStart.x, accuracy: 0.5, "It emerges from where the border started.")
        XCTAssertEqual(toast.center.y + start.m42, screen.borderStart.y, accuracy: 0.5)
        XCTAssertEqual(screen.borderStart, screen.view.convert(CGPoint(x: card.midX - card.minX, y: NotebookTheme.trialBorderInset),
                                                               from: scratchpad.view), "The scratchpad's top centre.")
        XCTAssertEqual(start.m11, NotebookTheme.colorToastStartScale, accuracy: 0.001, "Small at first.")
        XCTAssertEqual(toast.frame.midX, card.midX, accuracy: 0.5, "It rests centred above the scratchpad.")
        XCTAssertEqual(toast.frame.maxY, card.minY - NotebookTheme.colorToastGap, accuracy: 0.5)
        XCTAssertEqual(NotebookColorSelectedToast.title, "Color Selected")
        XCTAssertTrue((screen.view.accessibilityElements as? [NSObject])?.contains(toast) ?? false)
    }

    func testAColourChangeRestartsTheBorderAndSendsTheToastAway() async throws {
        let rig = try await ColorScreenRig.mount()
        defer { rig.close() }
        let clock = TrialClock()
        let screen = try await rig.open()
        screen.prefersCrossFade = { false }
        screen.now = { clock.time }
        screen.show(EditorHSBColor(hue: 30, saturation: 0.7, brightness: 0.6), change: .settled)
        screen.scratchpad.beginStroke()
        clock.time += InkTrialTimeline.holdDuration
        screen.refreshTrial()
        XCTAssertEqual(screen.trialPhase, .retained)

        screen.show(screen.color, change: .settled)
        XCTAssertEqual(screen.trialPhase, .retained, "The same colour again changes nothing.")
        screen.show(screen.color.with(hue: 31), change: .passing)
        XCTAssertEqual(screen.trialPhase, .trying)
        let border = screen.scratchpad.border
        XCTAssertEqual(border.stroke.strokeColor, NotebookTheme.trialTryingBorder.uiColor.cgColor, "Back to yellow.")
        let draw = try XCTUnwrap(border.stroke.animation(forKey: NotebookTrialBorder.drawKey) as? CABasicAnimation)
        XCTAssertEqual((draw.fromValue as? NSNumber)?.doubleValue, 0, "From the top centre again.")
        XCTAssertEqual(draw.duration, InkTrialTimeline.holdDuration, accuracy: 0.001)
        XCTAssertEqual(screen.toast.view.alpha, 0, "The toast leaves.")
        XCTAssertNotNil(screen.toast.view.layer.animation(forKey: "opacity"), "With an ease out.")
        XCTAssertEqual(screen.scratchpad.statusLabel.text, "TRYING…")

        clock.time += InkTrialTimeline.holdDuration - 0.01
        screen.refreshTrial()
        XCTAssertEqual(screen.trialPhase, .trying, "The hold restarts from the change.")
        clock.time += 0.01
        screen.refreshTrial()
        XCTAssertEqual(screen.trialPhase, .retained)
        XCTAssertEqual(screen.toast.view.alpha, 1, "And returns with the green.")
    }

    func testAColourChangeWhileYellowDrawsTheBorderAgainFromTheTopCentre() async throws {
        let rig = try await ColorScreenRig.mount()
        defer { rig.close() }
        let clock = TrialClock()
        let screen = try await rig.open()
        screen.prefersCrossFade = { false }
        screen.now = { clock.time }
        screen.show(EditorHSBColor(hue: 30, saturation: 0.7, brightness: 0.6), change: .settled)
        screen.scratchpad.beginStroke()
        let border = screen.scratchpad.border
        let first = try XCTUnwrap(border.stroke.animation(forKey: NotebookTrialBorder.drawKey))
        clock.time += 2
        screen.refreshTrial()
        XCTAssertTrue(border.stroke.animation(forKey: NotebookTrialBorder.drawKey) === first, "A refresh leaves the drawing going.")

        screen.show(screen.color.with(hue: 200), change: .passing)
        let restarted = try XCTUnwrap(border.stroke.animation(forKey: NotebookTrialBorder.drawKey) as? CABasicAnimation)
        XCTAssertFalse(restarted === first, "The new colour draws its own border.")
        XCTAssertEqual((restarted.fromValue as? NSNumber)?.doubleValue, 0, "From the top centre again.")
        XCTAssertEqual(restarted.duration, InkTrialTimeline.holdDuration, accuracy: 0.001, "Over the whole hold.")
        XCTAssertEqual(screen.trial.retainsAt, clock.time + InkTrialTimeline.holdDuration)
        XCTAssertEqual(screen.trialPhase, .trying)
    }

    func testReduceMotionShowsTheBorderWholeThenTurnsItGreen() async throws {
        let rig = try await ColorScreenRig.mount()
        defer { rig.close() }
        let clock = TrialClock()
        let screen = try await rig.open()
        screen.prefersCrossFade = { true }
        screen.now = { clock.time }
        screen.show(EditorHSBColor(hue: 30, saturation: 0.7, brightness: 0.6), change: .settled)
        screen.scratchpad.beginStroke()
        let border = screen.scratchpad.border
        XCTAssertEqual(border.stroke.strokeEnd, 1, "Complete from the first stroke.")
        XCTAssertNil(border.stroke.animation(forKey: NotebookTrialBorder.drawKey), "It never draws itself round.")
        XCTAssertNotNil(border.stroke.animation(forKey: NotebookTrialBorder.fadeKey), "It fades in.")
        XCTAssertEqual(border.stroke.strokeColor, NotebookTheme.trialTryingBorder.uiColor.cgColor)

        clock.time += InkTrialTimeline.holdDuration
        screen.refreshTrial()
        XCTAssertEqual(border.stroke.strokeColor, NotebookTheme.trialReadyBorder.uiColor.cgColor, "Green after the hold.")
        let toast = try XCTUnwrap(screen.toast.view)
        XCTAssertNil(toast.layer.animation(forKey: "transform"), "The toast only fades in.")
        XCTAssertNotNil(toast.layer.animation(forKey: "opacity"))
        XCTAssertEqual(toast.transform, .identity)
    }

    func testTheBorderTurnsGreenByItselfAfterItsHold() async throws {
        let rig = try await ColorScreenRig.mount()
        defer { rig.close() }
        let screen = try await rig.open()
        screen.show(EditorHSBColor(hue: 90, saturation: 0.7, brightness: 0.6), change: .settled)
        let start = CACurrentMediaTime()
        screen.scratchpad.beginStroke()
        XCTAssertEqual(screen.trialPhase, .trying)

        try await NotebookTestFixtures.waitUntil(seconds: InkTrialTimeline.holdDuration + 3) { screen.trialPhase == .retained }
        XCTAssertGreaterThanOrEqual(CACurrentMediaTime() - start, InkTrialTimeline.holdDuration - 0.01)
        XCTAssertEqual(screen.scratchpad.phase, .retained)
        XCTAssertFalse(screen.toast.view.isHidden)
    }

    // MARK: - Leaving

    func testLeavingOnceGreenWritesWithTheColourAndAddsItToTheSwatches() async throws {
        let rig = try await ColorScreenRig.mount()
        defer { rig.close() }
        let clock = TrialClock()
        let screen = try await rig.open()
        screen.now = { clock.time }
        let chosen = EditorHSBColor(hue: 320, saturation: 0.7, brightness: 0.62)

        screen.show(EditorHSBColor(hue: 140, saturation: 0.6, brightness: 0.5), change: .passing)
        screen.show(chosen, change: .settled)
        screen.scratchpad.beginStroke()
        clock.time += InkTrialTimeline.holdDuration
        screen.refreshTrial()
        XCTAssertEqual(screen.trialPhase, .retained)
        XCTAssertEqual(rig.store.tool, EditorToolState.standard, "Nothing changes before leaving.")
        screen.leave()

        let kept = chosen.rgb.quantized
        XCTAssertEqual(rig.store.tool.color, kept)
        XCTAssertEqual(rig.store.toolbar.customSwatches, [kept])
        let ink = try XCTUnwrap(rig.controller.canvasView.tool as? PKInkingTool)
        XCTAssertEqual(NotebookSwatchShelf.color(from: ink.color), kept, "The notes write with it at once.")
        XCTAssertNotNil(screen.view.layer.animation(forKey: "opacity"), "The screen fades away.")
        try await rig.waitUntilClosed()
        XCTAssertFalse(rig.trigger.isPresented)
        try await NotebookTestFixtures.waitUntil { rig.controller.canvasView.isFirstResponder }
    }

    func testLeavingBeforeGreenLeavesTheInkAndSwatchesAsTheyWere() async throws {
        for strokes in [false, true] {
            let rig = try await ColorScreenRig.mount()
            defer { rig.close() }
            let tool = rig.store.tool
            let toolbar = rig.store.toolbar
            var emissions = 0
            let subscriptions = [
                rig.store.$tool.dropFirst().sink { _ in emissions += 1 },
                rig.store.$toolbar.dropFirst().sink { _ in emissions += 1 }
            ]
            let clock = TrialClock()
            let screen = try await rig.open()
            screen.now = { clock.time }

            screen.show(EditorHSBColor(hue: 180, saturation: 0.8, brightness: 0.7), change: .settled)
            if strokes {
                screen.scratchpad.beginStroke()
                clock.time += InkTrialTimeline.holdDuration - 0.01
                screen.refreshTrial()
            }
            XCTAssertEqual(screen.trialPhase, strokes ? .trying : .untried)
            screen.leave()
            clock.time += InkTrialTimeline.holdDuration
            screen.refreshTrial()
            screen.leave()
            try await rig.waitUntilClosed()

            XCTAssertEqual(rig.store.tool, tool, "strokes: \(strokes)")
            XCTAssertEqual(rig.store.toolbar, toolbar, "strokes: \(strokes)")
            XCTAssertEqual(emissions, 0, "Leaving early stores nothing, and a closing screen ignores a later exit.")
            withExtendedLifetime(subscriptions) {}
        }
    }

    func testClosingTheWritingGateClosesTheScreenWithoutApplying() async throws {
        let rig = try await ColorScreenRig.mount()
        defer { rig.close() }
        let clock = TrialClock()
        let screen = try await rig.open()
        screen.now = { clock.time }
        screen.show(EditorHSBColor(hue: 30, saturation: 0.9, brightness: 0.9), change: .settled)
        screen.scratchpad.beginStroke()
        clock.time += InkTrialTimeline.holdDuration
        screen.refreshTrial()
        XCTAssertEqual(screen.trialPhase, .retained)

        rig.store.setToolbarAvailable(false, for: rig.controller)
        try await rig.waitUntilClosed()
        rig.store.setToolbarAvailable(true, for: rig.controller)

        XCTAssertEqual(rig.store.tool, .standard)
        XCTAssertTrue(rig.store.toolbar.customSwatches.isEmpty)
    }

    func testATapOffThePanelScratchpadAndShadesLeaves() async throws {
        let rig = try await ColorScreenRig.mount()
        defer { rig.close() }
        let screen = try await rig.open()
        screen.prefersCrossFade = { true }
        let layout = try XCTUnwrap(screen.layout)
        let tap = screen.exitTap
        XCTAssertTrue(screen.view.gestureRecognizers?.contains(tap) ?? false)
        XCTAssertEqual(tap.numberOfTapsRequired, 1)
        XCTAssertTrue(tap.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.pencil.rawValue)), "Pencil taps leave too.")
        XCTAssertTrue(tap.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.direct.rawValue)))
        XCTAssertFalse(tap.cancelsTouchesInView, "Strokes and drags are never held back.")
        XCTAssertTrue(tap.delegate === screen)

        let stone = CGPoint(x: screen.view.bounds.maxX - 8, y: layout.picker.midY)
        let panel = CGPoint(x: layout.centredPicker.midX, y: layout.centredPicker.midY)
        let scratchpad = CGPoint(x: layout.scratchpad.midX, y: layout.scratchpad.midY)
        let shades = CGPoint(x: screen.shadeBar.frame.midX, y: screen.shadeBar.frame.midY)
        XCTAssertTrue(screen.exitsOnTap(at: stone))
        XCTAssertTrue(screen.exitsOnTap(at: CGPoint(x: screen.exitHint.frame.midX, y: screen.exitHint.frame.midY)))
        XCTAssertFalse(screen.exitsOnTap(at: panel))
        XCTAssertFalse(screen.exitsOnTap(at: CGPoint(x: layout.centredPicker.minX + 1, y: layout.centredPicker.maxY - 1)))
        XCTAssertFalse(screen.exitsOnTap(at: shades), "The shade bar is part of the screen's controls.")
        XCTAssertTrue(screen.exitsOnTap(at: scratchpad), "Before a colour is chosen there is only stone there.")

        screen.show(EditorHSBColor(hue: 30, saturation: 0.5, brightness: 0.5), change: .settled)
        XCTAssertFalse(screen.exitsOnTap(at: panel), "Mid-change the panel still counts where it showed.")
        try await NotebookTestFixtures.waitUntil { screen.panel.layer.presentation()?.frame == layout.picker }
        XCTAssertFalse(screen.exitsOnTap(at: scratchpad))
        XCTAssertFalse(screen.exitsOnTap(at: CGPoint(x: layout.picker.midX, y: layout.picker.midY)))
        XCTAssertTrue(screen.exitsOnTap(at: CGPoint(x: layout.picker.maxX + NotebookTheme.colorScreenCardGap / 2, y: layout.picker.midY)),
                      "The gap between the cards is stone.")

        // A recognised tap leaves through the recogniser's own action.
        tap.state = .ended
        try await rig.waitUntilClosed()
    }

    func testATapOutsideWhileTypingOnlyPutsTheKeyboardAway() async throws {
        let rig = try await ColorScreenRig.mount()
        defer { rig.close() }
        let screen = try await rig.open()
        let field = screen.panel.field(.hue)
        XCTAssertTrue(field.becomeFirstResponder())
        field.text = "200"
        XCTAssertTrue(screen.panel.isEditing)

        screen.exitTap.state = .ended
        try await NotebookTestFixtures.waitUntil { !screen.panel.isEditing }
        XCTAssertEqual(screen.color.hue, 200, "The entry is kept.")
        XCTAssertFalse(screen.isClosing, "The screen stays open.")

        screen.leave()
        try await rig.waitUntilClosed()
    }

    func testReadingAFieldLeavesTheColourAndAGreenBorderAsTheyWere() async throws {
        enum WayOut: CaseIterable {
            case tapOutside
            case voiceOverEscape
            case exitHint
        }
        // The square and the slider reach finer values than the whole numbers the fields show.
        let fine = EditorHSBColor(hue: 123.456, saturation: 0.73456, brightness: 0.9)
        for wayOut in WayOut.allCases {
            let rig = try await ColorScreenRig.mount()
            defer { rig.close() }
            let clock = TrialClock()
            let screen = try await rig.open()
            screen.prefersCrossFade = { true }
            screen.now = { clock.time }
            let panel = screen.panel
            screen.show(fine, change: .settled)
            screen.scratchpad.beginStroke()
            clock.time += InkTrialTimeline.holdDuration
            screen.refreshTrial()
            XCTAssertEqual(screen.trialPhase, .retained)

            for field in [panel.hexField] + EditorColorField.allCases.map({ panel.field($0) }) {
                let shown = field.text
                XCTAssertTrue(field.becomeFirstResponder())
                XCTAssertTrue(panel.finishEditing())
                XCTAssertEqual(screen.color, fine, "Reading \(field.accessibilityLabel ?? "") moves nothing.")
                XCTAssertEqual(field.text, shown)
            }
            // An entry that only repeats what the field shows, however it is written, is no change.
            let saturation = panel.field(.saturation)
            XCTAssertTrue(saturation.becomeFirstResponder())
            saturation.text = "073"
            panel.finishEditing()
            XCTAssertEqual(saturation.text, "73")
            XCTAssertTrue(panel.hexField.becomeFirstResponder())
            panel.hexField.text = "#" + fine.rgb.hexString.lowercased()
            panel.finishEditing()
            XCTAssertEqual(panel.hexField.text, fine.rgb.hexString)
            XCTAssertEqual(screen.color, fine)
            XCTAssertEqual(screen.trialPhase, .retained, "The border stays green.")
            XCTAssertTrue(screen.isToastShown)

            // Leaving with a field still focused keeps the green colour, whichever the way out.
            XCTAssertTrue(panel.field(.brightness).becomeFirstResponder())
            switch wayOut {
            case .tapOutside:
                screen.exitTap.state = .ended
                try await NotebookTestFixtures.waitUntil { !panel.isEditing && screen.exitTap.state == .possible }
                XCTAssertFalse(screen.isClosing, "The first tap only puts the keyboard away.")
                XCTAssertEqual(screen.trialPhase, .retained)
                screen.exitTap.state = .ended
            case .voiceOverEscape:
                XCTAssertTrue(screen.accessibilityPerformEscape())
            case .exitHint:
                XCTAssertTrue(screen.exitHint.accessibilityActivate())
            }
            try await rig.waitUntilClosed()
            XCTAssertEqual(rig.store.tool.color, fine.rgb.quantized, "\(wayOut)")
            XCTAssertEqual(rig.store.toolbar.customSwatches, [fine.rgb.quantized], "\(wayOut)")
        }
    }

    func testOnASmallIPadTheKeyboardSqueezesTheSquareOnlyToItsMinimum() async throws {
        let size = CGSize(width: 1_133, height: 744)
        let rig = try await ColorScreenRig.mount(size: size)
        defer { rig.close() }
        let screen = try await rig.open()
        screen.prefersCrossFade = { true }
        screen.show(EditorHSBColor(hue: 30, saturation: 0.5, brightness: 0.5), change: .settled)
        let keyboard = CGRect(x: 0, y: size.height - 398, width: size.width, height: 398)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [
            UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: keyboard),
            UIResponder.keyboardAnimationDurationUserInfoKey: 0.0
        ])
        screen.view.layoutIfNeeded()

        XCTAssertEqual(screen.keyboardCover, keyboard.height)
        XCTAssertEqual(screen.panel.frame.height, screen.panel.minimumHeight, accuracy: 0.5)
        XCTAssertEqual(screen.panel.square.frame.height, NotebookTheme.colorSquareMinimumHeight, accuracy: 0.5)
        let fields = screen.panel.convert(screen.panel.field(.alpha).frame, to: screen.view)
        XCTAssertLessThanOrEqual(fields.maxY, keyboard.minY, "The fields stay in sight above the keyboard.")
        XCTAssertLessThanOrEqual(screen.exitHint.frame.maxY, keyboard.minY)
    }

    func testCardsKeepAboveADockedKeyboardWhileTyping() async throws {
        let rig = try await ColorScreenRig.mount(size: CGSize(width: 1_366, height: 1_024))
        defer { rig.close() }
        let screen = try await rig.open()
        screen.prefersCrossFade = { true }
        screen.show(EditorHSBColor(hue: 30, saturation: 0.5, brightness: 0.5), change: .settled)
        screen.view.layoutIfNeeded()
        let resting = try XCTUnwrap(screen.layout)
        let keyboard = CGRect(x: 0, y: 1_024 - 420, width: 1_366, height: 420)
        func post(_ name: Notification.Name, _ frame: CGRect) {
            NotificationCenter.default.post(name: name, object: nil, userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: frame),
                UIResponder.keyboardAnimationDurationUserInfoKey: 0.0
            ])
            screen.view.layoutIfNeeded()
        }

        post(UIResponder.keyboardWillChangeFrameNotification, keyboard)
        XCTAssertEqual(screen.keyboardCover, 420)
        let fields = screen.panel.convert(screen.panel.hexField.frame, to: screen.view)
        XCTAssertLessThanOrEqual(fields.maxY, keyboard.minY, "The fields stay in sight above the keyboard.")
        XCTAssertLessThanOrEqual(screen.exitHint.frame.maxY, keyboard.minY)
        XCTAssertLessThan(screen.panel.frame.minY, resting.picker.minY, "The cards rise with it.")

        post(UIResponder.keyboardWillChangeFrameNotification, CGRect(x: 400, y: 300, width: 320, height: 260))
        XCTAssertEqual(screen.keyboardCover, 0, "A floating keyboard leaves the cards where they rest.")
        post(UIResponder.keyboardWillChangeFrameNotification, keyboard)
        post(UIResponder.keyboardWillHideNotification, keyboard)
        XCTAssertEqual(screen.keyboardCover, 0)
        XCTAssertEqual(screen.layout, resting, "They return once it goes.")
        XCTAssertEqual(screen.panel.frame, resting.picker)
    }

    func testEscapeAndVoiceOverLeave() async throws {
        do {
            let rig = try await ColorScreenRig.mount()
            defer { rig.close() }
            let screen = try await rig.open()
            let escape = try XCTUnwrap(screen.keyCommands?.first { $0.input == UIKeyCommand.inputEscape })
            XCTAssertTrue(escape.modifierFlags.isEmpty)
            XCTAssertEqual(screen.keyCommands?.count, 1, "Escape is the only command; there is nothing to confirm.")
            XCTAssertTrue(screen.panel.field(.alpha).becomeFirstResponder())
            _ = screen.perform(try XCTUnwrap(escape.action))
            XCTAssertFalse(screen.panel.isEditing, "Escape first puts the keyboard away.")
            XCTAssertFalse(screen.isClosing)
            _ = screen.perform(try XCTUnwrap(escape.action))
            try await rig.waitUntilClosed()
        }
        do {
            let rig = try await ColorScreenRig.mount()
            defer { rig.close() }
            let screen = try await rig.open()
            XCTAssertTrue(screen.accessibilityPerformEscape(), "The VoiceOver escape gesture leaves.")
            try await rig.waitUntilClosed()
        }
        do {
            let rig = try await ColorScreenRig.mount()
            defer { rig.close() }
            let screen = try await rig.open()
            XCTAssertTrue(screen.exitHint.accessibilityActivate(), "The hint is the labelled way out.")
            try await rig.waitUntilClosed()
        }
    }

    // MARK: - Eyedropper

    func testEyedropperPicturesTheNotebookBeneathWithItsInk() async throws {
        let ink = PKStroke(
            ink: PKInk(.marker, color: UIColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1)),
            path: PKStrokePath(controlPoints: (0..<30).map { index in
                PKStrokePoint(location: CGPoint(x: 100 + CGFloat(index) * 10, y: 300), timeOffset: Double(index) * 0.01,
                              size: CGSize(width: 40, height: 40), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }, creationDate: Date())
        )
        let rig = try await ColorScreenRig.mount(drawing: PKDrawing(strokes: [ink]))
        defer { rig.close() }
        try await Task.sleep(for: .milliseconds(300))
        let screen = try await rig.open()
        let snapshot = try XCTUnwrap(screen.snapshot, "The page is pictured as the screen opens.")
        let page = rig.controller.view!
        XCTAssertEqual(snapshot.frame, page.convert(page.bounds, to: nil), "The notebook's own view, not the window's chrome.")
        XCTAssertTrue(screen.panel.eyedropperKey.isEnabled)

        // Drawing coordinates are page points; the canvas shows them at its zoom.
        let canvas = rig.controller.canvasView
        let strokePoint = canvas.convert(CGPoint(x: 250 * canvas.zoomScale, y: 300 * canvas.zoomScale), to: nil)
        let sampled = try XCTUnwrap(snapshot.color(at: strokePoint))
        XCTAssertGreaterThan(sampled.blue, sampled.red + 0.3, "The ink on the page is in the picture: \(sampled.hexString)")
        let blank = try XCTUnwrap(snapshot.color(at: canvas.convert(CGPoint(x: 250 * canvas.zoomScale, y: 700 * canvas.zoomScale), to: nil)))
        XCTAssertLessThan(blank.contrastRatio(against: NotebookSwatchShelf.color(from: NotebookTheme.paperIvory.uiColor)), 1.2,
                          "Blank paper samples as paper: \(blank.hexString)")
        XCTAssertNil(snapshot.color(at: CGPoint(x: -5, y: 10)), "Nothing off the picture.")
    }

    func testEyedropperSamplesThePageAndReturnsToThePicker() async throws {
        let rig = try await ColorScreenRig.mount()
        defer { rig.close() }
        let page = UIView()
        let left = UIView()
        let right = UIView()
        // Exact 8-bit values, so the picture holds them unchanged.
        let leftColor = EditorInkColor(red: 204 / 255, green: 51 / 255, blue: 26 / 255)
        let rightColor = EditorInkColor(red: 26 / 255, green: 128 / 255, blue: 77 / 255)
        left.backgroundColor = leftColor.platformColor
        right.backgroundColor = rightColor.platformColor
        page.frame = rig.window.bounds
        left.frame = CGRect(x: 0, y: 0, width: page.bounds.midX, height: page.bounds.height)
        right.frame = CGRect(x: page.bounds.midX, y: 0, width: page.bounds.midX, height: page.bounds.height)
        page.addSubview(left)
        page.addSubview(right)
        rig.window.insertSubview(page, at: 0)
        // A page that has been on screen, as the notebook has by the time the screen opens.
        try await Task.sleep(for: .milliseconds(100))
        let screen = try await rig.open()
        screen.prefersCrossFade = { true }
        screen.pageSource = { _ in page }
        screen.capturePage()
        page.removeFromSuperview()
        screen.panel.field(.alpha).text = "80"
        screen.panel.textFieldDidEndEditing(screen.panel.field(.alpha))
        let hue = screen.color.hue

        screen.panel.eyedropperKey.sendActions(for: .touchUpInside)
        let dropper = try XCTUnwrap(screen.eyedropper, "The eyedropper key opens the page.")
        XCTAssertTrue(dropper.superview === screen.view)
        XCTAssertEqual(dropper.page.image, screen.snapshot?.image)
        XCTAssertFalse(screen.exitTap.isEnabled, "Touches on the page pick; they never leave.")
        XCTAssertEqual(screen.view.accessibilityElements as? [UIView], [dropper])

        let point = CGPoint(x: dropper.bounds.width * 0.25, y: dropper.bounds.midY)
        dropper.hover(at: point)
        XCTAssertFalse(dropper.loupe.isHidden, "A loupe follows the touch.")
        XCTAssertEqual(dropper.loupe.center.x, point.x)
        XCTAssertEqual(dropper.loupe.center.y, point.y - NotebookTheme.eyedropperLoupeOffset, "It floats above the finger.")
        let zoomed = dropper.loupe.contents.contentsRect
        let visible = NotebookTheme.eyedropperLoupeDiameter / NotebookTheme.eyedropperLoupeZoom
        XCTAssertEqual(zoomed.width * dropper.bounds.width, visible, accuracy: 0.01, "Magnified around the point.")
        XCTAssertEqual(zoomed.midX * dropper.bounds.width, point.x, accuracy: 0.01)
        XCTAssertEqual(dropper.hoveredColor, leftColor)
        XCTAssertEqual(dropper.loupe.ring.strokeColor, dropper.hoveredColor?.platformColor.cgColor, "Ringed in the colour beneath.")

        dropper.lift(at: CGPoint(x: dropper.bounds.width * 0.75, y: 40))
        XCTAssertNil(screen.eyedropper, "Lifting returns to the picker.")
        let picked = EditorInkColor(red: rightColor.red, green: rightColor.green, blue: rightColor.blue, alpha: 0.8).quantized
        XCTAssertEqual(screen.color.rgb.quantized, picked, "The colour under the lift, at the alpha set.")
        XCTAssertNotEqual(screen.color.hue, hue)
        XCTAssertEqual(screen.panel.hexField.text, "1A804D")
        XCTAssertTrue(screen.showsScratchpad, "A sampled colour is a chosen colour.")
        XCTAssertTrue(screen.exitTap.isEnabled)

        screen.startEyedropper()
        let second = try XCTUnwrap(screen.eyedropper)
        second.lift(at: CGPoint(x: -20, y: -20))
        XCTAssertNotNil(screen.eyedropper, "A lift off the page picks nothing and waits.")
        XCTAssertTrue(second.accessibilityPerformEscape(), "VoiceOver's escape returns without a colour.")
        XCTAssertNil(screen.eyedropper)
        screen.startEyedropper()
        let escape = try XCTUnwrap(screen.keyCommands?.first)
        _ = screen.perform(try XCTUnwrap(escape.action))
        XCTAssertNil(screen.eyedropper, "Escape returns from the eyedropper first.")
        XCTAssertFalse(screen.isClosing)
        screen.startEyedropper()
        rig.window.frame = CGRect(x: 0, y: 0, width: 1_366, height: 1_024)
        rig.window.layoutIfNeeded()
        screen.view.layoutIfNeeded()
        XCTAssertNil(screen.eyedropper, "Turning the iPad returns to the picker: the picture holds one orientation.")
        XCTAssertEqual(screen.color.rgb.quantized, picked)
    }

    // MARK: - Scratchpad

    func testScratchpadInkNeverReachesTheNotebook() async throws {
        let rig = try await ColorScreenRig.mount(drawing: PKDrawing(strokes: [NotebookTestFixtures.stroke()]))
        defer { rig.close() }
        var observations = 0
        rig.controller.onObservation = { _ in
            observations += 1
            return .open
        }
        let notebookDrawing = rig.controller.canvasView.drawing
        let availability = rig.controller.currentUndoAvailability
        let clock = TrialClock()
        let screen = try await rig.open()
        screen.now = { clock.time }
        let scratch = screen.scratchpad.canvas

        let history = try XCTUnwrap(scratch.undoManager)
        XCTAssertFalse(history === rig.controller.canvasView.undoManager, "The scratchpad keeps its own history.")
        XCTAssertFalse(history === rig.window.undoManager)
        XCTAssertTrue(screen.undoManager === history, "Undo anywhere on the screen stays on the scratchpad.")

        screen.show(EditorHSBColor(hue: 220, saturation: 0.8, brightness: 0.7), change: .settled)
        screen.scratchpad.beginStroke()
        scratch.drawing = PKDrawing(strokes: (0..<3).map { NotebookTestFixtures.stroke(x: CGFloat($0) * 40) })
        history.registerUndo(withTarget: scratch) { $0.drawing = PKDrawing() }
        XCTAssertEqual(rig.controller.currentUndoAvailability, availability)
        XCTAssertNil(screen.target(forAction: NSSelectorFromString("redo:"), withSender: nil),
                     "Nothing to redo on the scratchpad, and the notebook beneath is never asked.")
        XCTAssertTrue(
            screen.target(forAction: NSSelectorFromString("undo:"), withSender: nil) as? NotebookColorPickerScreenController === screen
        )

        clock.time += InkTrialTimeline.holdDuration
        screen.refreshTrial()
        screen.leave()
        try await rig.waitUntilClosed()
        XCTAssertEqual(rig.controller.canvasView.drawing.dataRepresentation(), notebookDrawing.dataRepresentation())
        XCTAssertEqual(rig.controller.currentUndoAvailability, availability)
        XCTAssertEqual(observations, 0, "Nothing reaches the notebook's saves.")
    }

    func testScratchpadDrawsWithTheInkLeavingWouldApply() async throws {
        let rig = try await ColorScreenRig.mount()
        defer { rig.close() }
        let actions = NotebookToolbarActions(store: rig.store)
        actions.select(.ink(.fountainPen))
        actions.selectWidth(.bold)
        let clock = TrialClock()
        let screen = try await rig.open()
        screen.now = { clock.time }
        let scratch = screen.scratchpad.canvas

        let first = EditorHSBColor(hue: 220, saturation: 0.86, brightness: 0.7)
        screen.show(first, change: .passing)
        try assertScratchInk(scratch, family: .fountainPen, width: .bold, color: first)

        let second = EditorHSBColor(hue: 20, saturation: 0.86, brightness: 0.7)
        screen.show(second, change: .passing)
        try assertScratchInk(scratch, family: .fountainPen, width: .bold, color: second, "Live as the colour changes.")

        actions.select(.eraser(.vector))
        try assertScratchInk(scratch, family: .fountainPen, width: .bold, color: second,
                             "Leaving returns from the eraser to the last ink, so the scratchpad keeps it.")
        actions.select(.ink(.monoline))
        actions.selectWidth(.fine)
        try assertScratchInk(scratch, family: .monoline, width: .fine, color: second)

        let scratchInk = try XCTUnwrap(scratch.tool as? PKInkingTool)
        screen.show(second, change: .settled)
        screen.scratchpad.beginStroke()
        clock.time += InkTrialTimeline.holdDuration
        screen.refreshTrial()
        screen.leave()
        let notebookInk = try XCTUnwrap(rig.controller.canvasView.tool as? PKInkingTool)
        XCTAssertEqual(notebookInk.inkType, scratchInk.inkType)
        XCTAssertEqual(notebookInk.width, scratchInk.width)
        XCTAssertEqual(NotebookSwatchShelf.color(from: notebookInk.color), NotebookSwatchShelf.color(from: scratchInk.color))
        try await rig.waitUntilClosed()
    }

    func testScratchpadShowsItsPaperAtThePagesZoom() async throws {
        for size in [CGSize(width: 1_024, height: 1_366), CGSize(width: 1_366, height: 1_024)] {
            let rig = try await ColorScreenRig.mount(size: size)
            defer { rig.close() }
            let screen = try await rig.open()
            screen.prefersCrossFade = { true }
            screen.show(EditorHSBColor(hue: 220, saturation: 0.8, brightness: 0.7), change: .settled)
            screen.view.layoutIfNeeded()
            let scratch = screen.scratchpad.canvas
            let page = rig.controller.canvasView

            XCTAssertEqual(page.zoomScale, size.width / CGFloat(NotebookPaperMetrics.pageWidth), accuracy: 0.001, "\(size)")
            XCTAssertEqual(scratch.zoomScale, page.zoomScale, accuracy: 0.001, "A stroke is as wide as on the page: \(size)")
            assertPageZoom(scratch, windowWidth: size.width, "\(size)")
            XCTAssertFalse(scratch.pinchGestureRecognizer?.isEnabled ?? false, "The scratchpad never zooms by itself.")
            let scratchInk = try XCTUnwrap(scratch.tool as? PKInkingTool)
            let pageInk = try XCTUnwrap(page.tool as? PKInkingTool)
            XCTAssertEqual(scratchInk.width, pageInk.width, "Both widths are in page points; the zoom alone scales them.")
        }
    }

    func testScratchpadFramesItsPaperWithCaptionStatusAndClear() async throws {
        let rig = try await ColorScreenRig.mount()
        defer { rig.close() }
        let screen = try await rig.open()
        screen.prefersCrossFade = { true }
        screen.show(EditorHSBColor(hue: 220, saturation: 0.8, brightness: 0.7), change: .settled)
        screen.view.layoutIfNeeded()
        let scratchpad = screen.scratchpad
        let card = scratchpad.view!
        let inset = NotebookTheme.scratchpadPaperInset
        XCTAssertEqual(card.backgroundColor, NotebookTheme.colorPanelFill.uiColor, "A dark frame like the panel's.")
        XCTAssertGreaterThan(card.layer.shadowOpacity, 0, "A subtle shadow under it.")
        XCTAssertNotNil(card.layer.shadowPath)
        XCTAssertEqual(scratchpad.paper.frame.minX, inset)
        XCTAssertEqual(scratchpad.paper.frame.maxX, card.bounds.maxX - inset)
        XCTAssertEqual(scratchpad.paper.frame.maxY, card.bounds.maxY - inset)
        XCTAssertEqual(scratchpad.border.frame, card.bounds)
        let course = scratchpad.border.course
        XCTAssertLessThan(course.minX + NotebookTheme.trialBorderWidth / 2, scratchpad.paper.frame.minX,
                          "The border runs in the band around the paper, never over it.")
        XCTAssertGreaterThan(course.minX - NotebookTheme.trialBorderWidth / 2, 0)
        XCTAssertEqual(scratchpad.captionLabel.text, "TRY YOUR INK")
        XCTAssertEqual(scratchpad.captionLabel.accessibilityLabel, "Try your ink")
        XCTAssertLessThan(scratchpad.captionLabel.frame.maxY, scratchpad.paper.frame.minY)
        XCTAssertEqual(scratchpad.clearKey.title.text, "Clear")
        XCTAssertEqual(scratchpad.clearKey.frame.maxX, card.bounds.maxX - inset)
        XCTAssertLessThan(scratchpad.clearKey.frame.maxY, scratchpad.paper.frame.minY)
        XCTAssertFalse(scratchpad.clearKey.isEnabled, "Nothing to clear on blank paper.")
        XCTAssertEqual(scratchpad.clearKey.alpha, NotebookTheme.disabledOpacity, accuracy: 0.001)
        XCTAssertTrue(scratchpad.clearKey.accessibilityTraits.contains(.notEnabled))

        scratchpad.canvas.drawing = PKDrawing(strokes: [NotebookTestFixtures.stroke()])
        scratchpad.canvasViewDrawingDidChange(scratchpad.canvas)
        XCTAssertTrue(scratchpad.clearKey.isEnabled)
        XCTAssertEqual(scratchpad.clearKey.alpha, 1)
        scratchpad.beginStroke()
        scratchpad.canvas.undoManager?.registerUndo(withTarget: scratchpad.canvas) { $0.drawing = PKDrawing() }
        scratchpad.clearKey.sendActions(for: .touchUpInside)
        XCTAssertTrue(scratchpad.canvas.drawing.strokes.isEmpty)
        XCTAssertFalse(scratchpad.canvas.undoManager?.canUndo ?? true)
        XCTAssertFalse(scratchpad.clearKey.isEnabled)
        XCTAssertEqual(screen.trialPhase, .trying, "Clearing the paper does not restart the trial.")
    }

    func testScratchpadIsASheetOfTheNotebooksPaper() async throws {
        let materials = NotebookMaterials.shared
        try await NotebookTestFixtures.waitUntil {
            materials.prepare()
            return materials.paperFibrePattern != nil
        }
        let paper = NotebookScratchpadPaper()
        XCTAssertEqual(paper.backgroundColor, NotebookTheme.paperIvory.uiColor)
        XCTAssertTrue(paper.grainLayer.backgroundColor === materials.paperFibrePattern, "The notebook's own fibre tile.")
        XCTAssertFalse(paper.grainLayer.isHidden)

        let settings = PlainMaterialSettings()
        let plainPaper = NotebookScratchpadPaper(accessibility: settings.source)
        XCTAssertFalse(plainPaper.grainLayer.isHidden)
        settings.reducesTransparency = true
        settings.center.post(name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
        XCTAssertTrue(plainPaper.grainLayer.isHidden, "Plain materials hide the grain, as on the page.")

        let scratchpad = NotebookScratchpadController()
        scratchpad.loadViewIfNeeded()
        XCTAssertTrue(scratchpad.canvas.superview === scratchpad.paper)
        XCTAssertFalse(scratchpad.canvas.isScrollEnabled)
        XCTAssertFalse(scratchpad.canvas.isRulerActive)
        #if targetEnvironment(simulator)
        XCTAssertEqual(scratchpad.canvas.drawingPolicy, .anyInput, "Simulator input draws, as on the notebook.")
        #else
        XCTAssertEqual(scratchpad.canvas.drawingPolicy, .pencilOnly)
        #endif
    }

    // MARK: - Rotation

    func testRotationKeepsEverythingInView() async throws {
        let rig = try await ColorScreenRig.mount()
        defer { rig.close() }
        let clock = TrialClock()
        let screen = try await rig.open()
        screen.prefersCrossFade = { true }
        screen.now = { clock.time }
        screen.show(EditorHSBColor(hue: 30, saturation: 0.5, brightness: 0.5), change: .settled)
        screen.scratchpad.beginStroke()
        clock.time += InkTrialTimeline.holdDuration
        screen.refreshTrial()

        for size in [CGSize(width: 1_366, height: 1_024), CGSize(width: 1_024, height: 1_366), CGSize(width: 375, height: 1_024)] {
            rig.window.frame = CGRect(origin: .zero, size: size)
            rig.window.layoutIfNeeded()
            screen.view.layoutIfNeeded()
            let layout = try XCTUnwrap(screen.layout)
            XCTAssertEqual(screen.view.bounds.size, size)
            XCTAssertEqual(layout.arrangement, size.width < 600 ? .stacked : .sideBySide, "\(size)")
            let panel = screen.panel.frame
            let scratchpad = screen.scratchpad.view.frame
            let toast = screen.toast.view.frame
            XCTAssertEqual(panel, layout.picker, "\(size)")
            XCTAssertEqual(scratchpad, layout.scratchpad, "\(size)")
            XCTAssertEqual(screen.exitHint.frame, layout.hint, "\(size)")
            XCTAssertFalse(panel.intersects(scratchpad), "\(size)")
            XCTAssertFalse(toast.intersects(scratchpad), "\(size)")
            XCTAssertFalse(toast.intersects(panel), "\(size)")
            XCTAssertEqual(toast.midX, scratchpad.midX, accuracy: 0.5, "\(size)")
            XCTAssertEqual(screen.shadeBar.frame.width, size.width, "\(size)")
            XCTAssertEqual(screen.shadeBar.frame.maxY, size.height, "\(size)")
            XCTAssertEqual(screen.shadeBar.steps.count, size.width < 600 ? 9 : 11, "\(size)")
            XCTAssertLessThanOrEqual(screen.exitHint.frame.maxY, screen.shadeBar.frame.minY, "\(size)")
            assertPageZoom(screen.scratchpad.canvas, windowWidth: size.width, "\(size)")
            for frame in [panel, scratchpad, toast, screen.exitHint.frame] {
                XCTAssertTrue(screen.view.bounds.inset(by: screen.view.safeAreaInsets).contains(frame), "\(frame) in \(size)")
                XCTAssertFalse(frame.isEmpty, "\(size)")
            }
        }
    }

    // MARK: - Accessibility

    func testScreenReadsInOrderWithALabelledWayOut() async throws {
        let rig = try await ColorScreenRig.mount()
        defer { rig.close() }
        let clock = TrialClock()
        let screen = try await rig.open()
        screen.prefersCrossFade = { true }
        screen.now = { clock.time }
        func order() -> [NSObject] { (screen.view.accessibilityElements as? [NSObject]) ?? [] }
        XCTAssertEqual(order(), [screen.panel, screen.shadeBar, screen.exitHint])
        XCTAssertEqual(screen.panel.accessibilityLabel, "Color Picker")
        XCTAssertEqual(screen.shadeBar.accessibilityLabel, "Shades")
        XCTAssertTrue(screen.exitHint.isAccessibilityElement)
        XCTAssertEqual(screen.exitHint.accessibilityLabel, "Exit")
        XCTAssertEqual(screen.exitHint.accessibilityUserInputLabels, ["Exit", "Tap anywhere to exit"],
                       "Voice Control accepts the words it shows.")
        XCTAssertTrue(screen.exitHint.accessibilityTraits.contains(.button))
        XCTAssertTrue(screen.panel.square.accessibilityTraits.contains(.adjustable))
        XCTAssertEqual(screen.panel.hueSlider.accessibilityLabel, "Hue")

        screen.show(EditorHSBColor(hue: 30, saturation: 0.5, brightness: 0.5), change: .settled)
        XCTAssertEqual(order(), [screen.panel, screen.scratchpad.view, screen.shadeBar, screen.exitHint])
        screen.scratchpad.beginStroke()
        clock.time += InkTrialTimeline.holdDuration
        screen.refreshTrial()
        XCTAssertEqual(order(), [screen.panel, screen.scratchpad.view, screen.toast.view, screen.shadeBar, screen.exitHint])

        let canvas = screen.scratchpad.canvas
        XCTAssertTrue(canvas.isAccessibilityElement)
        XCTAssertEqual(canvas.accessibilityLabel, NotebookScratchpadController.canvasLabel)
        XCTAssertEqual(canvas.accessibilityHint, NotebookScratchpadController.canvasHint)
        XCTAssertTrue(canvas.accessibilityTraits.contains(.allowsDirectInteraction), "VoiceOver users can draw on it.")

        let square = screen.panel.square
        let brightness = square.brightness
        square.accessibilityIncrement()
        XCTAssertEqual(square.brightness, brightness + NotebookSaturationBrightnessSquare.step, accuracy: 1e-9)
        XCTAssertEqual(screen.color.brightness, square.brightness, accuracy: 1e-9, "Adjusting reaches the screen.")
    }

    // MARK: - Helpers

    /// The content area of a full-screen window with an iPad's status bar, above a shade bar.
    private static func content(in size: CGSize) -> CGRect {
        let margin = NotebookTheme.colorScreenMargin
        let bar = NotebookTheme.shadeBarHeight + 20
        return CGRect(x: margin, y: 24 + margin, width: size.width - 2 * margin, height: size.height - 24 - bar - 2 * margin)
    }

    /// The two inner control points of a timing curve, linear when they lie on its diagonal ends.
    private static func controlPoints(of function: CAMediaTimingFunction?) -> [Float] {
        guard let function else { return [] }
        return [1, 2].flatMap { index -> [Float] in
            var point: [Float] = [0, 0]
            function.getControlPoint(at: index, values: &point)
            return point
        }
    }

    private static func composite(_ color: EditorInkColor, over background: EditorInkColor) -> EditorInkColor {
        EditorInkColor(
            red: color.red * color.alpha + background.red * (1 - color.alpha),
            green: color.green * color.alpha + background.green * (1 - color.alpha),
            blue: color.blue * color.alpha + background.blue * (1 - color.alpha)
        )
    }

    /// Types `text` into `field` and ends editing, as the keyboard's Done key does.
    private func enter(_ text: String, in field: UITextField, of panel: NotebookColorPickerPanel) {
        panel.textFieldDidBeginEditing(field)
        field.text = text
        panel.textFieldDidEndEditing(field)
    }

    /// The scratchpad at the zoom of a page filling `windowWidth`, its sheet fixed in place.
    private func assertPageZoom(
        _ canvas: PKCanvasView, windowWidth: CGFloat, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        let scale = windowWidth / CGFloat(NotebookPaperMetrics.pageWidth)
        XCTAssertEqual(canvas.zoomScale, scale, accuracy: 0.001, message, file: file, line: line)
        XCTAssertEqual(canvas.minimumZoomScale, scale, accuracy: 0.001, message, file: file, line: line)
        XCTAssertEqual(canvas.maximumZoomScale, scale, accuracy: 0.001, message, file: file, line: line)
        XCTAssertEqual(canvas.contentSize, canvas.bounds.size, message, file: file, line: line)
        XCTAssertEqual(canvas.contentOffset, .zero, message, file: file, line: line)
    }

    private func assertScratchInk(
        _ canvas: PKCanvasView, family: EditorInkFamily, width: EditorWidthStep, color: EditorHSBColor,
        _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let ink = try XCTUnwrap(canvas.tool as? PKInkingTool, file: file, line: line)
        var expected = EditorToolState.standard
        expected.select(.ink(family))
        expected.widthStep = width
        expected.color = color.rgb.quantized
        let native = try XCTUnwrap(expected.nativeTool as? PKInkingTool, file: file, line: line)
        XCTAssertEqual(ink.inkType, family.inkType, message, file: file, line: line)
        XCTAssertEqual(ink.width, native.width, message, file: file, line: line)
        XCTAssertEqual(NotebookSwatchShelf.color(from: ink.color), expected.color, message, file: file, line: line)
    }
}

private extension NotebookScratchpadController {
    /// A stroke beginning, as PencilKit reports it.
    func beginStroke() {
        canvasViewDidBeginUsingTool(canvas)
    }
}

/// A clock the test moves by hand.
@MainActor
private final class TrialClock {
    var time: TimeInterval = 1_000
}

/// Accessibility settings the test toggles, delivered through a private notification centre.
@MainActor
private final class PlainMaterialSettings {
    var reducesTransparency = false
    let center = NotificationCenter()

    var source: NotebookMaterialAccessibility {
        NotebookMaterialAccessibility(
            notificationCenter: center,
            isReduceTransparencyEnabled: { self.reducesTransparency },
            isIncreaseContrastEnabled: { false }
        )
    }
}

/// A selected key, hosted in its own controller as the colour screen hosts its SwiftUI views,
/// that reports whether it is drawn on the rail's glass.
@MainActor
private final class HostedKeyProbe {
    static let side: CGFloat = 88

    struct Key: View {
        let probe: HostedKeyProbe
        @Environment(\.notebookKeysOnGlass) private var isOnGlass

        var body: some View {
            Button {} label: { Color.clear.frame(width: HostedKeyProbe.side, height: HostedKeyProbe.side) }
                .buttonStyle(NotebookKeyStyle(isSelected: true))
                .onAppear { probe.isOnGlass = isOnGlass }
        }
    }

    var isOnGlass: Bool?
}

/// A notebook in the toolbar host whose colour screen opens through the same presentation the
/// custom colour well uses, from the host itself or, as the well does, from a key on glass.
@MainActor
private final class ColorScreenRig {
    final class Trigger: ObservableObject {
        @Published var isPresented = false
    }

    struct Host: View {
        @ObservedObject var trigger: Trigger
        let store: NotebookSceneToolStore
        let controller: NotebookViewController
        let presentsFromGlass: Bool

        var body: some View {
            let notebook = NotebookToolbarHost(store: store) { MountedNotebookController(controller: controller) }
            if presentsFromGlass {
                notebook.overlay(alignment: .top) {
                    Color.clear
                        .frame(width: NotebookTheme.controlSize, height: NotebookTheme.controlSize)
                        .notebookColorScreen(isPresented: $trigger.isPresented, store: store)
                        .notebookGlass(in: Capsule())
                }
            } else {
                notebook.notebookColorScreen(isPresented: $trigger.isPresented, store: store)
            }
        }
    }

    let trigger = Trigger()
    let store: NotebookSceneToolStore
    let controller: NotebookViewController
    let hosting: AppearanceTrackingHostingController<Host>
    let window: UIWindow

    private init(store: NotebookSceneToolStore, controller: NotebookViewController, presentsFromGlass: Bool) throws {
        self.store = store
        self.controller = controller
        hosting = AppearanceTrackingHostingController(rootView: Host(
            trigger: trigger, store: store, controller: controller, presentsFromGlass: presentsFromGlass
        ))
        window = try NotebookTestFixtures.window(showing: hosting)
    }

    static func mount(
        drawing: PKDrawing = PKDrawing(), size: CGSize? = nil, presentsFromGlass: Bool = false
    ) async throws -> ColorScreenRig {
        let store = NotebookTestFixtures.toolStore()
        let controller = NotebookViewController(pageCount: 3, initialDrawing: drawing, toolStore: store)
        let rig = try ColorScreenRig(store: store, controller: controller, presentsFromGlass: presentsFromGlass)
        if let size {
            rig.window.frame = CGRect(origin: .zero, size: size)
            rig.window.layoutIfNeeded()
        }
        do {
            try await NotebookTestFixtures.waitUntilAppeared(rig.hosting)
            try await NotebookTestFixtures.waitUntil {
                controller.isCanvasVisible && store.isToolbarAvailable && controller.canvasView.isFirstResponder
            }
        } catch {
            rig.close()
            throw error
        }
        return rig
    }

    /// The screen once it is fully shown.
    func open() async throws -> NotebookColorPickerScreenController {
        trigger.isPresented = true
        let screen = try await NotebookTestFixtures.waitForValue { () -> NotebookColorPickerScreenController? in
            guard let presented = self.hosting.presentedViewController, let screen = Self.screen(in: presented),
                  screen.view.window != nil, screen.isFirstResponder else { return nil }
            return screen
        }
        screen.view.layoutIfNeeded()
        return screen
    }

    func waitUntilClosed() async throws {
        try await NotebookTestFixtures.waitUntil { self.hosting.presentedViewController == nil && !self.trigger.isPresented }
    }

    func close() {
        hosting.presentedViewController?.dismiss(animated: false)
        controller.tearDown()
        window.isHidden = true
        window.rootViewController = nil
    }

    private static func screen(in controller: UIViewController) -> NotebookColorPickerScreenController? {
        if let screen = controller as? NotebookColorPickerScreenController { return screen }
        return controller.children.lazy.compactMap { screen(in: $0) }.first
    }
}
