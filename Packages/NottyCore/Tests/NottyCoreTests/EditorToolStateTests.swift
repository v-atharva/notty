import PencilKit
import XCTest
@testable import NottyCore

final class EditorToolStateTests: XCTestCase {
    func testStandardStateIsANativeInkWithinItsValidWidthRange() throws {
        let tool = try XCTUnwrap(EditorToolState.standard.nativeTool as? PKInkingTool)
        let family = try XCTUnwrap(EditorToolState.standard.inkFamily)
        XCTAssertEqual(tool.inkType, family.inkType)
        XCTAssertTrue(family.inkType.validWidthRange.contains(tool.width))
    }

    func testEveryFamilyMapsToItsPencilKitInkAndHonoursTheWidthStep() throws {
        for family in EditorInkFamily.allCases {
            var fine = EditorToolState.standard
            fine.select(.ink(family))
            fine.widthStep = .fine
            var bold = fine
            bold.widthStep = .bold
            let fineTool = try XCTUnwrap(fine.nativeTool as? PKInkingTool)
            let boldTool = try XCTUnwrap(bold.nativeTool as? PKInkingTool)
            XCTAssertEqual(fineTool.inkType, family.inkType)
            XCTAssertLessThan(fineTool.width, boldTool.width, "\(family)")
            XCTAssertTrue(family.inkType.validWidthRange.contains(boldTool.width), "\(family)")
        }
    }

    func testPresetSetsFamilyColourAndWidth() throws {
        let preset = try XCTUnwrap(EditorInkCatalog.presets.first { $0.family == .fountainPen })
        var state = EditorToolState.standard
        state.apply(preset)
        XCTAssertEqual(state.kind, .ink(.fountainPen))
        XCTAssertEqual(state.color, preset.color)
        XCTAssertEqual(state.widthStep, preset.widthStep)
        XCTAssertEqual(state.activePresetID, preset.id)
    }

    func testChangingColourOrWidthClearsThePresetButKeepsTheInk() throws {
        var state = EditorToolState.standard
        state.apply(try XCTUnwrap(EditorInkCatalog.presets.first))
        state.color = EditorInkCatalog.swatches[3]
        XCTAssertNil(state.activePresetID)
        XCTAssertEqual(state.kind, .ink(EditorInkCatalog.presets[0].family))
    }

    func testChangingTheWidthClearsThePreset() throws {
        let preset = try XCTUnwrap(EditorInkCatalog.presets.first)
        var state = EditorToolState.standard
        state.apply(preset)
        state.widthStep = preset.widthStep
        XCTAssertEqual(state.activePresetID, preset.id, "setting the same width keeps the preset")
        state.widthStep = try XCTUnwrap(EditorWidthStep.allCases.first { $0 != preset.widthStep })
        XCTAssertNil(state.activePresetID)
        XCTAssertEqual(state.kind, .ink(preset.family))
    }

    func testSwitchingInkFamilyClearsThePreset() throws {
        let preset = try XCTUnwrap(EditorInkCatalog.presets.first)
        var state = EditorToolState.standard
        state.apply(preset)
        state.select(.ink(preset.family))
        XCTAssertEqual(state.activePresetID, preset.id, "reselecting the preset's ink keeps it")
        state.select(.ink(try XCTUnwrap(EditorInkFamily.allCases.first { $0 != preset.family })))
        XCTAssertNil(state.activePresetID)
    }

    func testThePresetSurvivesATripThroughTheEraserOrLasso() throws {
        let preset = try XCTUnwrap(EditorInkCatalog.presets.first)
        for away in [EditorToolKind.eraser(.vector), .eraser(.bitmap), .lasso] {
            var state = EditorToolState.standard
            state.apply(preset)
            state.select(away)
            XCTAssertEqual(state.activePresetID, preset.id, "\(away)")
            state.selectPreviousInk()
            XCTAssertEqual(state.kind, .ink(preset.family), "\(away)")
            XCTAssertEqual(state.activePresetID, preset.id, "\(away)")
        }
    }

    func testEraserAndLassoMapToNativeTools() throws {
        var state = EditorToolState.standard
        state.select(.eraser(.vector))
        XCTAssertEqual((state.nativeTool as? PKEraserTool)?.eraserType, .vector)
        state.select(.eraser(.bitmap))
        XCTAssertEqual((state.nativeTool as? PKEraserTool)?.eraserType, .bitmap)
        state.select(.lasso)
        XCTAssertTrue(state.nativeTool is PKLassoTool)
        XCTAssertNil(state.inkFamily)
    }

    func testSelectingTheEraserUsesTheLastEraserModeAndStaysOnIt() {
        var state = EditorToolState.standard
        state.select(.eraser(.bitmap))
        state.select(.ink(.pencil))
        state.selectEraser()
        XCTAssertEqual(state.kind, .eraser(.bitmap))
        state.selectEraser()
        XCTAssertEqual(state.kind, .eraser(.bitmap), "selecting the eraser again never toggles back to ink")
        state.selectPreviousInk()
        XCTAssertEqual(state.kind, .ink(.pencil))
    }

    func testReturningFromTheEraserRestoresTheLastInk() {
        var state = EditorToolState.standard
        state.select(.ink(.marker))
        state.select(.eraser(.vector))
        state.selectPreviousInk()
        XCTAssertEqual(state.kind, .ink(.marker))
    }

    func testInkColourIsTheLightAppearanceValue() throws {
        var state = EditorToolState.standard
        state.color = EditorInkColor(red: 0.2, green: 0.4, blue: 0.6)
        let tool = try XCTUnwrap(state.nativeTool as? PKInkingTool)
        let components = try XCTUnwrap(tool.color.cgColor.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil
        )?.components)
        XCTAssertEqual(components[0], 0.2, accuracy: 0.01)
        XCTAssertEqual(components[2], 0.6, accuracy: 0.01)
    }
}

final class EditorPencilDoubleTapTests: XCTestCase {
    func testIgnoreAndSystemShortcutChangeNothing() {
        for preference in [EditorPencilTapPreference.ignore, .runSystemShortcut] {
            var state = EditorToolState.standard
            XCTAssertFalse(state.handlePencilDoubleTap(preference))
            XCTAssertEqual(state, .standard)
        }
    }

    func testSwitchEraserTogglesAndRemembersTheEraserMode() {
        var state = EditorToolState.standard
        state.select(.ink(.marker))
        state.select(.eraser(.bitmap))
        state.select(.ink(.marker))

        XCTAssertFalse(state.handlePencilDoubleTap(.switchEraser))
        XCTAssertEqual(state.kind, .eraser(.bitmap), "returns to the eraser mode last used")
        XCTAssertFalse(state.handlePencilDoubleTap(.switchEraser))
        XCTAssertEqual(state.kind, .ink(.marker), "a second tap returns to the ink")
    }

    func testSwitchEraserFromTheLassoGoesToTheEraserAndBackToTheLasso() {
        var state = EditorToolState.standard
        state.select(.lasso)
        _ = state.handlePencilDoubleTap(.switchEraser)
        XCTAssertEqual(state.kind, .eraser(.vector))
        _ = state.handlePencilDoubleTap(.switchEraser)
        XCTAssertEqual(state.kind, .lasso, "a second tap returns to the tool in use before the eraser")
    }

    func testSwitchEraserReturnsPastAnEraserModeChange() {
        var state = EditorToolState.standard
        state.select(.lasso)
        state.select(.eraser(.vector))
        state.select(.eraser(.bitmap))
        _ = state.handlePencilDoubleTap(.switchEraser)
        XCTAssertEqual(state.kind, .lasso, "changing the eraser mode is not a tool before the eraser")
    }

    func testSwitchEraserRestoresTheInkAndItsPreset() throws {
        let preset = try XCTUnwrap(EditorInkCatalog.presets.first)
        var state = EditorToolState.standard
        state.apply(preset)
        let inking = state
        _ = state.handlePencilDoubleTap(.switchEraser)
        XCTAssertEqual(state.activePresetID, preset.id)
        _ = state.handlePencilDoubleTap(.switchEraser)
        XCTAssertEqual(state, inking)
        XCTAssertEqual(state.activePresetID, preset.id)
    }

    func testSwitchEraserFromARestoredEraserReturnsToTheStoredInk() {
        var state = EditorToolState.standard
        state.select(.ink(.crayon))
        state.select(.eraser(.bitmap))
        var restored = EditorToolState.decode(state.encoded())
        _ = restored.handlePencilDoubleTap(.switchEraser)
        XCTAssertEqual(restored.kind, .ink(.crayon))
    }

    func testSwitchPreviousSwapsWithTheLastDifferentTool() {
        var state = EditorToolState.standard
        state.select(.ink(.pencil))
        state.select(.lasso)
        XCTAssertFalse(state.handlePencilDoubleTap(.switchPrevious))
        XCTAssertEqual(state.kind, .ink(.pencil))
        _ = state.handlePencilDoubleTap(.switchPrevious)
        XCTAssertEqual(state.kind, .lasso)
    }

    func testSwitchPreviousWithNoHistoryKeepsTheTool() {
        var state = EditorToolState.standard
        _ = state.handlePencilDoubleTap(.switchPrevious)
        XCTAssertEqual(state.kind, EditorToolState.standard.kind)
    }

    func testReselectingTheSameToolDoesNotEraseHistory() {
        var state = EditorToolState.standard
        state.select(.lasso)
        state.select(.lasso)
        _ = state.handlePencilDoubleTap(.switchPrevious)
        XCTAssertEqual(state.kind, EditorToolState.standard.kind)
    }

    func testShowPreferencesRevealTheToolbarWithoutChangingTheTool() {
        for preference in [EditorPencilTapPreference.showColorPalette, .showInkAttributes, .showContextualPalette] {
            var state = EditorToolState.standard
            state.isRulerActive = true
            XCTAssertTrue(state.handlePencilDoubleTap(preference))
            XCTAssertEqual(state.kind, EditorToolState.standard.kind)
            XCTAssertTrue(state.isRulerActive, "double-tap never toggles the ruler")
        }
    }
}

final class EditorToolStatePersistenceTests: XCTestCase {
    func testRoundTripsEveryToolKindRulerAndPreset() throws {
        var samples: [EditorToolState] = []
        for family in EditorInkFamily.allCases {
            var state = EditorToolState.standard
            state.select(.ink(family))
            state.widthStep = .bold
            samples.append(state)
        }
        for kind in [EditorToolKind.eraser(.vector), .eraser(.bitmap), .lasso] {
            var state = EditorToolState.standard
            state.select(kind)
            state.isRulerActive = true
            samples.append(state)
        }
        var preset = EditorToolState.standard
        preset.apply(try XCTUnwrap(EditorInkCatalog.presets.last))
        samples.append(preset)
        for away in [EditorToolKind.eraser(.bitmap), .lasso] {
            var presetAway = preset
            presetAway.select(away)
            samples.append(presetAway)
        }

        for sample in samples {
            let decoded = EditorToolState.decode(sample.encoded())
            XCTAssertEqual(decoded.kind, sample.kind)
            XCTAssertEqual(decoded.color, sample.color)
            XCTAssertEqual(decoded.widthStep, sample.widthStep)
            XCTAssertEqual(decoded.isRulerActive, sample.isRulerActive)
            XCTAssertEqual(decoded.activePresetID, sample.activePresetID)
            XCTAssertEqual(decoded, sample)

            var decodedEraser = decoded
            decodedEraser.selectEraser()
            var sampleEraser = sample
            sampleEraser.selectEraser()
            XCTAssertEqual(decodedEraser.kind, sampleEraser.kind, "the last eraser mode survives")
        }
    }

    func testTheStoredFormatNamesEveryFieldIndependentlyOfDeclarationOrder() throws {
        var state = EditorToolState.standard
        state.select(.ink(.fountainPen))
        state.widthStep = .medium
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: state.encoded()) as? [String: Any])
        XCTAssertEqual(stored["version"] as? Int, 1)
        XCTAssertEqual(stored["kind"] as? String, "ink")
        XCTAssertEqual(stored["family"] as? String, "fountainPen")
        XCTAssertEqual(stored["width"] as? Int, 1)
        XCTAssertEqual(stored["lastEraser"] as? String, "vector")
    }

    func testReadsToolsStoredByTheCurrentFormat() {
        let families: [String: EditorInkFamily] = [
            "pen": .pen, "monoline": .monoline, "fountainPen": .fountainPen, "reed": .reed,
            "pencil": .pencil, "marker": .marker, "crayon": .crayon, "watercolor": .watercolor,
        ]
        XCTAssertEqual(Set(families.values), Set(EditorInkFamily.allCases))
        for (name, family) in families {
            let json = #"{"version":1,"kind":"ink","family":"\#(name)","color":[0,0,0,1],"width":2,"ruler":false}"#
            XCTAssertEqual(EditorToolState.decode(Data(json.utf8)).kind, .ink(family), name)
        }
        let widths: [Int: EditorWidthStep] = [0: .fine, 1: .medium, 2: .bold]
        XCTAssertEqual(Set(widths.values), Set(EditorWidthStep.allCases))
        for (stored, step) in widths {
            let json = #"{"version":1,"kind":"ink","family":"pen","color":[0,0,0,1],"width":\#(stored),"ruler":false}"#
            XCTAssertEqual(EditorToolState.decode(Data(json.utf8)).widthStep, step, "\(stored)")
        }
        for (name, mode) in [("vector", EditorEraserMode.vector), ("bitmap", .bitmap)] {
            let json = """
            {"version":1,"kind":"eraser","eraser":"\(name)","color":[0,0,0,1],"width":0,"ruler":true,
             "lastInk":"marker","lastEraser":"\(name)"}
            """
            var decoded = EditorToolState.decode(Data(json.utf8))
            XCTAssertEqual(decoded.kind, .eraser(mode))
            XCTAssertTrue(decoded.isRulerActive)
            decoded.selectPreviousInk()
            XCTAssertEqual(decoded.kind, .ink(.marker))
        }
        let lasso = #"{"version":1,"kind":"lasso","color":[0,0,0,1],"width":0,"ruler":false,"lastInk":"pencil"}"#
        XCTAssertEqual(EditorToolState.decode(Data(lasso.utf8)).kind, .lasso)
    }

    func testRestoredEraserStillReturnsToTheStoredInk() {
        var state = EditorToolState.standard
        state.select(.ink(.watercolor))
        state.select(.eraser(.bitmap))
        var decoded = EditorToolState.decode(state.encoded())
        decoded.selectPreviousInk()
        XCTAssertEqual(decoded.kind, .ink(.watercolor))
    }

    func testInvalidDataFallsBackToTheStandardTool() {
        let invalid: [Data?] = [
            nil,
            Data("not json".utf8),
            Data(#"{"version":99,"kind":"ink","family":"pen","color":[0,0,0,1],"width":0,"ruler":false}"#.utf8),
            Data(#"{"version":1,"kind":"ink","family":"quill","color":[0,0,0,1],"width":0,"ruler":false}"#.utf8),
            Data(#"{"version":1,"kind":"eraser","eraser":"sponge","color":[0,0,0,1],"width":0,"ruler":false}"#.utf8),
            Data(#"{"version":1,"kind":"ink","family":"pen","color":[0,0,0,1],"width":7,"ruler":false}"#.utf8),
            Data(#"{"version":1,"kind":"ink","family":"pen","color":[0,0,0],"width":0,"ruler":false}"#.utf8),
        ]
        for data in invalid {
            XCTAssertEqual(EditorToolState.decode(data), .standard)
        }
    }

    func testAStoredPresetIsClaimedOnlyWhileItsValuesStillMatch() throws {
        let preset = try XCTUnwrap(EditorInkCatalog.presets.first)
        let json = """
        {"version":1,"kind":"ink","family":"\(preset.family.rawValue)","color":[0.9,0.1,0.1,1],
         "width":\(preset.widthStep.rawValue),"ruler":false,"preset":"\(preset.id)","lastInk":"\(preset.family.rawValue)"}
        """
        XCTAssertNil(EditorToolState.decode(Data(json.utf8)).activePresetID)
        let unknown = #"{"version":1,"kind":"ink","family":"pen","color":[0,0,0,1],"width":0,"ruler":false,"preset":"gone"}"#
        XCTAssertNil(EditorToolState.decode(Data(unknown.utf8)).activePresetID)
    }

    func testAPresetStoredWhileErasingIsClaimedOnlyForItsOwnInk() throws {
        let preset = try XCTUnwrap(EditorInkCatalog.presets.first)
        let color = preset.color
        func stored(lastInk: EditorInkFamily) -> Data {
            Data("""
            {"version":1,"kind":"eraser","eraser":"vector","color":[\(color.red),\(color.green),\(color.blue),1],
             "width":\(preset.widthStep.rawValue),"ruler":false,"preset":"\(preset.id)","lastInk":"\(lastInk.rawValue)"}
            """.utf8)
        }
        XCTAssertEqual(EditorToolState.decode(stored(lastInk: preset.family)).activePresetID, preset.id)
        let otherInk = try XCTUnwrap(EditorInkFamily.allCases.first { $0 != preset.family })
        XCTAssertNil(EditorToolState.decode(stored(lastInk: otherInk)).activePresetID)
    }
}
