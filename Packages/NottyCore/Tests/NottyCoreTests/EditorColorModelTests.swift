import XCTest
@testable import NottyCore

final class EditorColorModelTests: XCTestCase {
    // MARK: HSB and RGB

    func testPrimaryAndSecondaryHuesConvertExactly() {
        let cases: [(Double, EditorInkColor)] = [
            (0, EditorInkColor(red: 1, green: 0, blue: 0)),
            (60, EditorInkColor(red: 1, green: 1, blue: 0)),
            (120, EditorInkColor(red: 0, green: 1, blue: 0)),
            (180, EditorInkColor(red: 0, green: 1, blue: 1)),
            (240, EditorInkColor(red: 0, green: 0, blue: 1)),
            (300, EditorInkColor(red: 1, green: 0, blue: 1)),
            (360, EditorInkColor(red: 1, green: 0, blue: 0))
        ]
        for (hue, rgb) in cases {
            XCTAssertEqual(EditorHSBColor(hue: hue, saturation: 1, brightness: 1).rgb, rgb, "hue \(hue)")
            if hue < 360 {
                XCTAssertEqual(EditorHSBColor(rgb).hue, hue, accuracy: 1e-9, "hue \(hue)")
            }
        }
    }

    func testTheReferenceColourReadsAsItsTrueHueSaturationAndBrightness() throws {
        // EF6C40, the colour in the user's reference, whose fields show 239 / 108 / 64 under H, S
        // and B: those are its red, green and blue. Its hue, saturation and brightness differ.
        let color = try XCTUnwrap(EditorInkColor(hex: "EF6C40"))
        XCTAssertEqual(color.quantized, EditorInkColor(red: 239 / 255, green: 108 / 255, blue: 64 / 255))
        let hsb = EditorHSBColor(color)
        XCTAssertEqual(EditorColorField.hue.value(of: hsb), 15)
        XCTAssertEqual(EditorColorField.saturation.value(of: hsb), 73)
        XCTAssertEqual(EditorColorField.brightness.value(of: hsb), 94)
        XCTAssertEqual(EditorColorField.alpha.value(of: hsb), 100)
    }

    func testEveryEightBitColourSurvivesARoundTrip() {
        // A sweep through the cube, including its corners and grays.
        let levels = stride(from: 0, through: 255, by: 17).map { Double($0) / 255 }
        for red in levels {
            for green in levels {
                for blue in levels {
                    let rgb = EditorInkColor(red: red, green: green, blue: blue, alpha: 0.6)
                    XCTAssertEqual(EditorHSBColor(rgb).rgb.quantized, rgb.quantized, "\(rgb)")
                }
            }
        }
    }

    func testGrayAndBlackKeepTheHueAndSaturationTheyCameFrom() {
        let gray = EditorHSBColor(EditorInkColor(red: 0.5, green: 0.5, blue: 0.5), keepingHue: 210, saturation: 0.7)
        XCTAssertEqual(gray.hue, 210)
        XCTAssertEqual(gray.saturation, 0, "A gray has no saturation of its own.")
        XCTAssertEqual(gray.brightness, 0.5)

        let black = EditorHSBColor(EditorInkColor(red: 0, green: 0, blue: 0), keepingHue: 210, saturation: 0.7)
        XCTAssertEqual(black.hue, 210)
        XCTAssertEqual(black.saturation, 0.7, "Black keeps the saturation, so brightening returns the colour.")
        XCTAssertEqual(black.with(brightness: 1).rgb, EditorHSBColor(hue: 210, saturation: 0.7, brightness: 1).rgb)
    }

    func testComponentsAreClampedAndNonFiniteValuesBecomeZero() {
        let color = EditorHSBColor(hue: 400, saturation: 1.5, brightness: -1, alpha: .nan)
        XCTAssertEqual(color.hue, 360)
        XCTAssertEqual(color.saturation, 1)
        XCTAssertEqual(color.brightness, 0)
        XCTAssertEqual(color.alpha, 0)
        XCTAssertEqual(EditorHSBColor(hue: -10, saturation: 0.5, brightness: 0.5).hue, 0)
        XCTAssertEqual(EditorHSBColor(hue: .infinity, saturation: 0.5, brightness: 0.5).hue, 0)
    }

    func testAlphaPassesThroughBothWays() {
        let color = EditorHSBColor(hue: 30, saturation: 0.5, brightness: 0.8, alpha: 0.25)
        XCTAssertEqual(color.rgb.alpha, 0.25)
        XCTAssertEqual(EditorHSBColor(color.rgb).alpha, 0.25)
    }

    func testSameColorComparesAtInkPrecision() {
        let color = EditorHSBColor(hue: 200, saturation: 0.5, brightness: 0.5)
        XCTAssertTrue(color.isSameColor(as: color.with(hue: 200.01)))
        XCTAssertFalse(color.isSameColor(as: color.with(hue: 205)))
        XCTAssertTrue(
            EditorHSBColor(hue: 10, saturation: 0, brightness: 0.5).isSameColor(as: EditorHSBColor(hue: 300, saturation: 0, brightness: 0.5)),
            "Grays are one colour whatever hue they keep."
        )
    }

    // MARK: HEX

    func testHexShowsSixUppercaseDigitsOfTheOpaqueChannels() {
        XCTAssertEqual(EditorInkColor(red: 239 / 255, green: 108 / 255, blue: 64 / 255, alpha: 0.4).hexString, "EF6C40")
        XCTAssertEqual(EditorInkColor(red: 0, green: 0, blue: 0).hexString, "000000")
        XCTAssertEqual(EditorInkColor(red: 1, green: 1, blue: 1).hexString, "FFFFFF")
        XCTAssertEqual(EditorInkColor(red: 0.0019, green: 0.999, blue: 0.5).hexString, "00FF80", "Rounded, never truncated.")
    }

    func testHexReadsFullAndShortFormsWithOrWithoutAHash() throws {
        let expected = EditorInkColor(red: 1, green: 0x66 / 255, blue: 0)
        XCTAssertEqual(EditorInkColor(hex: "FF6600"), expected)
        XCTAssertEqual(EditorInkColor(hex: "#ff6600"), expected)
        XCTAssertEqual(EditorInkColor(hex: " F60 "), expected)
        XCTAssertEqual(EditorInkColor(hex: "#F60"), expected)
        XCTAssertEqual(try XCTUnwrap(EditorInkColor(hex: "FF6600", alpha: 0.5)).alpha, 0.5)
        for color in [EditorInkColor(red: 0.2, green: 0.4, blue: 0.6), EditorInkColor(red: 1, green: 0, blue: 0.5)] {
            XCTAssertEqual(EditorInkColor(hex: color.hexString), color.quantized, "A round trip through HEX")
        }
    }

    func testHexRejectsAnythingButThreeOrSixHexDigits() {
        for text in ["", "#", "FF66", "FF66000", "GG6600", "FF 600", "-F6600", "+F6600", "0xFF66", "FF6600FF"] {
            XCTAssertNil(EditorInkColor(hex: text), text)
        }
    }

    func testHexTypingAllowsOnlyHexDigitsUpToSix() {
        XCTAssertTrue(EditorInkColor.isHexTyping(""))
        XCTAssertTrue(EditorInkColor.isHexTyping("ef6c4"))
        XCTAssertTrue(EditorInkColor.isHexTyping("EF6C40"))
        XCTAssertFalse(EditorInkColor.isHexTyping("EF6C401"))
        XCTAssertFalse(EditorInkColor.isHexTyping("EF6C4G"))
        XCTAssertFalse(EditorInkColor.isHexTyping("٣٣"), "Only ASCII digits are hexadecimal.")
    }

    func testHexTypingTakesTheLeadingHashTheFieldReads() {
        XCTAssertTrue(EditorInkColor.isHexTyping("#"))
        XCTAssertTrue(EditorInkColor.isHexTyping("#EF6C4"))
        XCTAssertTrue(EditorInkColor.isHexTyping("#EF6C40"), "A pasted CSS colour fits.")
        XCTAssertNotNil(EditorInkColor(hex: "#EF6C40"), "And reads as it was typed.")
        XCTAssertFalse(EditorInkColor.isHexTyping("#EF6C401"), "Still six digits at most.")
        XCTAssertFalse(EditorInkColor.isHexTyping("##EF"), "One hash only.")
        XCTAssertFalse(EditorInkColor.isHexTyping("EF#6"), "And only in front.")
        XCTAssertNil(EditorInkColor(hex: "##FF660"))
    }

    // MARK: Numeric fields

    func testFieldsClampTypedValuesIntoTheirRanges() {
        XCTAssertEqual(EditorColorField.hue.range, 0...360)
        XCTAssertEqual(EditorColorField.hue.value(from: "361"), 360)
        XCTAssertEqual(EditorColorField.hue.value(from: "360"), 360)
        XCTAssertEqual(EditorColorField.hue.value(from: "015"), 15)
        for field in [EditorColorField.saturation, .brightness, .alpha] {
            XCTAssertEqual(field.range, 0...100)
            XCTAssertEqual(field.value(from: "101"), 100)
            XCTAssertEqual(field.value(from: "999"), 100)
            XCTAssertEqual(field.value(from: "0"), 0)
            XCTAssertEqual(field.value(from: " 42 "), 42)
        }
    }

    func testFieldsRejectEmptyAndNonNumericEntries() {
        for text in ["", " ", "-5", "+5", "4.5", "1e2", "abc", "١٢", "0x1"] {
            XCTAssertNil(EditorColorField.saturation.value(from: text), text)
        }
    }

    func testFieldTypingAllowsOnlyUpToThreeAsciiDigits() {
        XCTAssertTrue(EditorColorField.allowsTyping(""))
        XCTAssertTrue(EditorColorField.allowsTyping("360"))
        XCTAssertFalse(EditorColorField.allowsTyping("3600"))
        XCTAssertFalse(EditorColorField.allowsTyping("3a"))
        XCTAssertFalse(EditorColorField.allowsTyping("-1"))
        XCTAssertFalse(EditorColorField.allowsTyping("٣"))
    }

    func testFieldsReadAndSetTheirOwnComponentOnly() {
        let color = EditorHSBColor(hue: 200, saturation: 0.5, brightness: 0.8, alpha: 0.9)
        XCTAssertEqual(EditorColorField.allCases.map { $0.value(of: color) }, [200, 50, 80, 90])
        XCTAssertEqual(EditorColorField.hue.applying(15, to: color), color.with(hue: 15))
        XCTAssertEqual(EditorColorField.saturation.applying(25, to: color), color.with(saturation: 0.25))
        XCTAssertEqual(EditorColorField.brightness.applying(100, to: color), color.with(brightness: 1))
        XCTAssertEqual(EditorColorField.alpha.applying(0, to: color), color.with(alpha: 0))
        for field in EditorColorField.allCases {
            for value in [field.range.lowerBound, field.range.upperBound / 2, field.range.upperBound] {
                XCTAssertEqual(field.value(of: field.applying(value, to: color)), value, "\(field) \(value)")
            }
        }
    }

    // MARK: Shades

    func testShadesRunFromAPaleTintThroughTheMiddleColourToADeepShade() {
        let base = EditorHSBColor(hue: 15, saturation: 0.8, brightness: 0.3, alpha: 0.7)
        let steps = EditorShadeRamp.steps(of: base, count: 11)
        let middle = EditorShadeRamp.middle(of: base)
        XCTAssertEqual(steps.count, 11)
        XCTAssertEqual(middle.saturation, 0.8)
        XCTAssertEqual(middle.brightness, 0.92, accuracy: 1e-12, "Bright for a vivid colour.")
        XCTAssertTrue(steps[5].isSameColor(as: middle), "The middle colour sits in the middle.")
        XCTAssertEqual(steps[5].saturation, 0.8, accuracy: 1e-12)
        XCTAssertEqual(steps[10].brightness, 0.92 * EditorShadeRamp.darkestShare, accuracy: 1e-12)
        XCTAssertEqual(steps[10].saturation, 0.8)
        for (index, step) in steps.enumerated() {
            XCTAssertEqual(step.hue, 15, "Every step keeps the hue.")
            XCTAssertEqual(step.alpha, 0.7, "Every step keeps the alpha.")
            guard index <= 5 else { continue }
            // Each tint is the middle colour laid over white at its share.
            let share = EditorShadeRamp.palestShare + (1 - EditorShadeRamp.palestShare) * Double(index) / 5
            let pure = middle.rgb
            XCTAssertEqual(step.rgb.red, share * pure.red + 1 - share, accuracy: 1e-9, "tint \(index)")
            XCTAssertEqual(step.rgb.green, share * pure.green + 1 - share, accuracy: 1e-9, "tint \(index)")
            XCTAssertEqual(step.rgb.blue, share * pure.blue + 1 - share, accuracy: 1e-9, "tint \(index)")
        }
        let luminance = steps.map(\.rgb.relativeLuminance)
        for (lighter, darker) in zip(luminance, luminance.dropFirst()) {
            XCTAssertGreaterThan(lighter, darker, "Lightest first, each step darker than the last.")
        }
    }

    func testShadesDependOnlyOnHueSaturationAndAlpha() {
        let dark = EditorHSBColor(hue: 120, saturation: 0.6, brightness: 0.1)
        XCTAssertEqual(EditorShadeRamp.steps(of: dark, count: 9), EditorShadeRamp.steps(of: dark.with(brightness: 0.9), count: 9))
        XCTAssertNotEqual(EditorShadeRamp.steps(of: dark, count: 9), EditorShadeRamp.steps(of: dark.with(hue: 121), count: 9))
    }

    func testAStepKeepsItsSaturationAndBrightnessWhateverTheHue() {
        // So a tapped shade stays marked as the hue slider moves.
        let base = EditorHSBColor(hue: 10, saturation: 0.45, brightness: 0.5)
        let steps = EditorShadeRamp.steps(of: base, count: 11)
        for hue in [0.0, 95, 200, 359] {
            let moved = EditorShadeRamp.steps(of: base.with(hue: hue), count: 11)
            XCTAssertEqual(moved, steps.map { $0.with(hue: hue) }, "hue \(hue)")
        }
    }

    func testAGraysStepsStayApartFromNearWhiteToNearBlack() {
        for saturation in [0.0, 0.02, 0.1] {
            let steps = EditorShadeRamp.steps(of: EditorHSBColor(hue: 30, saturation: saturation, brightness: 0.2), count: 9)
            XCTAssertGreaterThan(steps.first?.rgb.relativeLuminance ?? 0, 0.85, "Near white.")
            XCTAssertLessThan(steps.last?.rgb.relativeLuminance ?? 1, 0.03, "Near black.")
            let quantized = steps.map(\.rgb.quantized)
            XCTAssertEqual(Set(quantized).count, steps.count, "No two steps alike at saturation \(saturation).")
            for (lighter, darker) in zip(quantized, quantized.dropFirst()) {
                XCTAssertGreaterThan(lighter.contrastRatio(against: darker), 1.1, "Neighbours can be told apart.")
            }
        }
    }

    func testShadeCountsAreOddAndAtLeastThree() {
        let base = EditorHSBColor(hue: 0, saturation: 1, brightness: 1)
        XCTAssertEqual(EditorShadeRamp.steps(of: base, count: 9).count, 9)
        XCTAssertEqual(EditorShadeRamp.steps(of: base, count: 10).count, 9)
        XCTAssertEqual(EditorShadeRamp.steps(of: base, count: 1).count, 3)
        XCTAssertEqual(EditorShadeRamp.steps(of: base, count: -4).count, 3)
    }
}
