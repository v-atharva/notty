import Foundation
import PencilKit
import UIKit
import XCTest
@testable import NottyCore

@MainActor
final class NativeArchiveReuseTests: XCTestCase {
    func testLiveCanvasDecodeThenAddOneReusesEveryUnchangedArchive() async throws {
        let originals = [
            NativeArchiveFixtures.stroke(),
            NativeArchiveFixtures.stroke(x: 120),
            NativeArchiveFixtures.stroke(x: 220)
        ]
        let encoder = InkCodec()
        let assets = try await encoder.encode(PKDrawing(strokes: originals))
        let codec = InkCodec()
        let drawing = try await codec.decode(assets)
        let live = NativeArchiveCanvas()
        defer { live.close() }
        await live.assign(drawing)
        XCTAssertNotNil(live.canvas.window)
        let assigned = live.canvas.drawing
        XCTAssertEqual(assigned.strokes.map(\.id), assets.map(\.id))
        XCTAssertEqual(assigned.strokes.map { $0.path.id }, drawing.strokes.map { $0.path.id })
        let beforeAssignmentEncode = await codec.workMetrics
        let assignedAssets = try await codec.encode(assigned)
        let afterAssignmentEncode = await codec.workMetrics
        XCTAssertEqual(assignedAssets, assets)
        XCTAssertEqual(assignedAssets.map(\.cachedDigest), assets.map(\.cachedDigest))
        XCTAssertEqual(afterAssignmentEncode.serializedStrokes, beforeAssignmentEncode.serializedStrokes)
        XCTAssertEqual(afterAssignmentEncode.hashedArchiveBytes, beforeAssignmentEncode.hashedArchiveBytes)
        XCTAssertEqual(try InkDrawingSignature(assigned), try InkDrawingSignature(drawing))

        let added = NativeArchiveFixtures.stroke(x: 320)
        await live.assign(PKDrawing(strokes: assigned.strokes + [added]))
        let before = await codec.workMetrics
        let result = try await codec.encode(live.canvas.drawing)
        let after = await codec.workMetrics
        XCTAssertEqual(result.map(\.id), assets.map(\.id) + [added.id])
        XCTAssertEqual(Array(result.prefix(assets.count)), assets)
        XCTAssertEqual(result.prefix(assets.count).map(\.cachedDigest), assets.map(\.cachedDigest))
        XCTAssertEqual(after.serializedStrokes - before.serializedStrokes, 1)
        XCTAssertEqual(after.hashedArchiveBytes - before.hashedArchiveBytes, result.last?.data.count)
        XCTAssertEqual(after.comparedPoints - before.comparedPoints, 0)
        try report(name: "canvas-add-one", values: [
            "strokeCount": result.count,
            "serializations": after.serializedStrokes - before.serializedStrokes,
            "pointComparisons": after.comparedPoints - before.comparedPoints,
            "signatureChecks": after.signatureChecks - before.signatureChecks,
            "assetSHABytes": after.hashedArchiveBytes - before.hashedArchiveBytes
        ])
    }

    func testValidNativePathChangesAndArchiveCanvasRoundTripsPreservePathIdentity() async throws {
        let original = NativeArchiveFixtures.stroke()
        let changed = NativeArchiveFixtures.changedPath(original)
        XCTAssertEqual(changed.id, original.id)
        XCTAssertEqual(changed.path.count, original.path.count)
        XCTAssertEqual(changed.path.creationDate, original.path.creationDate)
        XCTAssertNotEqual(changed.path.id, original.path.id)
        let live = NativeArchiveCanvas()
        defer { live.close() }
        let codec = InkCodec()
        for native in [original, changed] {
            let assets = try await codec.encode(PKDrawing(strokes: [native]))
            let restored = try await InkCodec().decode(assets)
            XCTAssertEqual(restored.strokes.map(\.id), [native.id])
            XCTAssertEqual(restored.strokes[0].path.id, native.path.id)
            await live.assign(restored)
            XCTAssertEqual(live.canvas.drawing.strokes[0].path.id, native.path.id)
            let before = await codec.workMetrics
            let cached = try await codec.encode(live.canvas.drawing)
            let after = await codec.workMetrics
            XCTAssertEqual(cached, assets)
            XCTAssertEqual(cached[0].cachedDigest, assets[0].cachedDigest)
            XCTAssertEqual(after.serializedStrokes, before.serializedStrokes)
            XCTAssertEqual(after.hashedArchiveBytes, before.hashedArchiveBytes)
            XCTAssertEqual(
                try InkDrawingSignature(live.canvas.drawing),
                try InkDrawingSignature(PKDrawing(strokes: [native]))
            )
            for (actual, expected) in zip(live.canvas.drawing.strokes[0].path, native.path) {
                XCTAssertEqual(actual.location, expected.location)
                XCTAssertEqual(actual.timeOffset, expected.timeOffset)
                XCTAssertEqual(actual.size, expected.size)
                XCTAssertEqual(actual.force, expected.force)
            }
        }
    }

    func testLiveCanvasEveryPublicPointFieldUsesDistinctNativePathIdentity() async throws {
        let original = NativeArchiveFixtures.stroke()
        let untouched = NativeArchiveFixtures.stroke(x: 120)
        let live = NativeArchiveCanvas()
        defer { live.close() }
        var pathIDs: Set<UUID> = [original.path.id]
        for field in NativeArchiveFixtures.PointField.allCases {
            let changed = field.changed(original)
            XCTAssertEqual(changed.id, original.id, field.rawValue)
            XCTAssertTrue(pathIDs.insert(changed.path.id).inserted, field.rawValue)
            XCTAssertNotEqual(field.value(changed.path[0]), field.value(original.path[0]), field.rawValue)
            let codec = InkCodec()
            let assets = try await codec.encode(PKDrawing(strokes: [original, untouched]))
            let baseline = try await InkCodec().decode(assets)
            await live.assign(PKDrawing(strokes: [changed, untouched]))
            let observed = live.canvas.drawing
            XCTAssertEqual(observed.strokes.map(\.id), [original.id, untouched.id], field.rawValue)
            XCTAssertEqual(observed.strokes[0].path.id, changed.path.id, field.rawValue)
            XCTAssertEqual(
                field.value(observed.strokes[0].path[0]), field.value(changed.path[0]), field.rawValue
            )
            XCTAssertNotEqual(
                try InkDrawingSignature(PKDrawing(strokes: [original, untouched])),
                try InkDrawingSignature(observed), field.rawValue
            )
            let before = await codec.workMetrics
            let result = try await codec.encode(observed)
            let after = await codec.workMetrics
            XCTAssertEqual(result[1], assets[1], field.rawValue)
            XCTAssertEqual(result[1].cachedDigest, assets[1].cachedDigest, field.rawValue)
            XCTAssertNotEqual(result[0].data, assets[0].data, field.rawValue)
            XCTAssertEqual(after.serializedStrokes - before.serializedStrokes, 1, field.rawValue)
            XCTAssertEqual(after.hashedArchiveBytes - before.hashedArchiveBytes, result[0].data.count, field.rawValue)
            XCTAssertEqual(after.comparedPoints - before.comparedPoints, 0, field.rawValue)
            let restored = try await InkCodec().decode(result)
            XCTAssertEqual(restored.strokes.map(\.id), result.map(\.id), field.rawValue)
            XCTAssertEqual(restored.strokes[0].path.id, changed.path.id, field.rawValue)
            let restoredValue = field.value(restored.strokes[0].path[0])
            XCTAssertEqual(restoredValue, field.value(changed.path[0]), accuracy: 0.001, field.rawValue)
            XCTAssertGreaterThan(
                abs(restoredValue - field.value(baseline.strokes[0].path[0])), 0.002, field.rawValue
            )
            try report(name: "point-field-\(field.rawValue)", values: [
                "distinctNativePath": changed.path.id == original.path.id ? 0 : 1,
                "restoredFieldErrorMillionths":
                    Int((abs(restoredValue - field.value(changed.path[0])) * 1_000_000).rounded()),
                "restoredChangeMillionths":
                    Int((abs(restoredValue - field.value(baseline.strokes[0].path[0])) * 1_000_000).rounded()),
                "serializations": after.serializedStrokes - before.serializedStrokes,
                "pointComparisons": after.comparedPoints - before.comparedPoints,
                "assetSHABytes": after.hashedArchiveBytes - before.hashedArchiveBytes
            ])
        }
    }

    func testLiveCanvasNativeWorkRemainsBoundedAtOneHundredAndTwoThousand() async throws {
        let live = NativeArchiveCanvas()
        defer { live.close() }
        var samples: [[String: Int]] = []
        for count in [100, 2_000] {
            let strokes = (0..<count).map {
                NativeArchiveFixtures.stroke(x: 20 + CGFloat($0 % 60) * 10)
            }
            let codec = InkCodec()
            let original = try await codec.encode(PKDrawing(strokes: strokes))
            var changed = strokes
            changed[0].transform = CGAffineTransform(translationX: 3, y: 5)
            await live.assign(PKDrawing(strokes: changed))
            let observed = live.canvas.drawing
            let native = try InkDrawingSignature(observed)
            let anotherNative = try InkDrawingSignature(observed)
            let nativeComparison = native.compared(to: anotherNative)
            XCTAssertTrue(nativeComparison.isEqual)
            XCTAssertEqual(nativeComparison.work.comparedPoints, 0)
            XCTAssertEqual(nativeComparison.work.signatureChecks, count)
            let exact = try InkDrawingSignature(observed, comparisonMode: .exact)
            for comparison in [native.compared(to: exact), exact.compared(to: native)] {
                XCTAssertTrue(comparison.isEqual)
                XCTAssertEqual(comparison.work.comparedPoints, count * 4)
            }
            let before = await codec.workMetrics
            let result = try await codec.encode(observed)
            let after = await codec.workMetrics
            XCTAssertEqual(Array(result.dropFirst()), Array(original.dropFirst()))
            XCTAssertEqual(
                result.dropFirst().map(\.cachedDigest), original.dropFirst().map(\.cachedDigest)
            )
            let sample: [String: Int] = [
                "strokeCount": count,
                "serializations": after.serializedStrokes - before.serializedStrokes,
                "pointComparisons": after.comparedPoints - before.comparedPoints,
                "signatureChecks": after.signatureChecks - before.signatureChecks,
                "assetSHABytes": after.hashedArchiveBytes - before.hashedArchiveBytes,
                "copiedArchiveBytes": after.copiedArchiveBytes - before.copiedArchiveBytes,
                "maskSnapshots": after.maskSnapshots - before.maskSnapshots,
                "renderStateBytes": after.renderStateBytes - before.renderStateBytes,
                "nativeDrawingEqualityFallbacks":
                    after.nativeDrawingEqualityFallbacks - before.nativeDrawingEqualityFallbacks,
                "barrierPointComparisons": nativeComparison.work.comparedPoints,
                "barrierSignatureChecks": nativeComparison.work.signatureChecks
            ]
            samples.append(sample)
            XCTAssertEqual(sample["serializations"], 1)
            XCTAssertEqual(sample["pointComparisons"], 0)
            XCTAssertEqual(sample["assetSHABytes"], result[0].data.count)
            XCTAssertEqual(sample["copiedArchiveBytes"], result[0].data.count)
            try report(name: "bounded-work-\(count)", values: sample)
        }
        for key in [
            "serializations", "pointComparisons", "assetSHABytes", "copiedArchiveBytes",
            "maskSnapshots", "renderStateBytes", "nativeDrawingEqualityFallbacks",
            "barrierPointComparisons"
        ] {
            let small = try XCTUnwrap(samples[0][key])
            let large = try XCTUnwrap(samples[1][key])
            if small == 0 {
                XCTAssertEqual(large, 0, key)
            } else {
                XCTAssertLessThanOrEqual(Double(large), Double(small) * 1.5, key)
            }
        }
        XCTAssertEqual(samples[0]["signatureChecks"], 200)
        XCTAssertEqual(samples[1]["signatureChecks"], 4_000)
    }

    func testLiveCanvasFieldChangesSerializeOnlyTheChangedNativeStroke() async throws {
        let native = NativeArchiveFixtures.stroke()
        let untouched = NativeArchiveFixtures.stroke(x: 120)
        let live = NativeArchiveCanvas()
        defer { live.close() }
        let codec = InkCodec()
        let original = try await codec.encode(PKDrawing(strokes: [native, untouched]))
        var variants: [PKStroke] = []
        var changed = native
        changed.transform = CGAffineTransform(translationX: 15, y: 25)
        variants.append(changed)
        changed.ink = PKInk(.marker, color: .red)
        variants.append(changed)
        changed.mask = UIBezierPath(rect: CGRect(x: 10, y: 20, width: 40, height: 40))
        variants.append(changed)
        changed.mask = UIBezierPath(ovalIn: CGRect(x: 10, y: 20, width: 40, height: 40))
        variants.append(changed)
        changed.renderGroupID = UUID()
        variants.append(changed)
        changed.renderState = PKStroke.RenderState(grainOffset: CGPoint(x: 10, y: 20))
        variants.append(changed)
        changed = NativeArchiveFixtures.changedPath(changed)
        variants.append(changed)
        changed = PKStroke(
            ink: changed.ink, path: changed.path, transform: changed.transform,
            mask: changed.mask, randomSeed: changed.randomSeed + 1,
            id: changed.id, renderGroupID: changed.renderGroupID, renderState: changed.renderState
        )
        variants.append(changed)

        var previous = original
        for (variantIndex, variant) in variants.enumerated() {
            await live.assign(PKDrawing(strokes: [variant, untouched]))
            let before = await codec.workMetrics
            let result = try await codec.encode(live.canvas.drawing)
            let after = await codec.workMetrics
            XCTAssertEqual(result.map(\.id), [native.id, untouched.id])
            XCTAssertEqual(result[1], original[1])
            XCTAssertEqual(result[1].cachedDigest, original[1].cachedDigest)
            XCTAssertNotEqual(result[0].data, previous[0].data)
            XCTAssertEqual(after.serializedStrokes - before.serializedStrokes, 1)
            XCTAssertEqual(after.hashedArchiveBytes - before.hashedArchiveBytes, result[0].data.count)
            let restored = try await InkCodec().decode(result)
            XCTAssertEqual(restored.strokes[0].path.id, variant.path.id)
            XCTAssertEqual(restored.strokes[0].transform, variant.transform)
            XCTAssertEqual(restored.strokes[0].randomSeed, variant.randomSeed)
            XCTAssertEqual(restored.strokes[0].renderGroupID, variant.renderGroupID)
            let maximumMaskError = assertQuantizedMask(
                restored.strokes[0].mask?.cgPath, matches: variant.mask?.cgPath
            )
            try report(name: "mask-quantization-\(variantIndex)", values: [
                "maximumCoordinateErrorMillionths": Int((maximumMaskError * 1_000_000).rounded()),
                "coordinateToleranceMillionths": 20_000
            ])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            XCTAssertEqual(try encoder.encode(restored.strokes[0].renderState), try encoder.encode(variant.renderState))
            previous = result
        }
        let work = await codec.workMetrics
        XCTAssertGreaterThan(work.maskSnapshots, 0)
        XCTAssertGreaterThan(work.encodedRenderStates, 0)
        XCTAssertGreaterThan(work.renderStateBytes, 0)
    }

    func testLiveCanvasEraseUndoReusesOriginalArchivesAndOrder() async throws {
        let natives = [NativeArchiveFixtures.stroke(), NativeArchiveFixtures.stroke(x: 120)]
        let codec = InkCodec()
        let original = try await codec.encode(PKDrawing(strokes: natives))
        let live = NativeArchiveCanvas()
        defer { live.close() }
        await live.assign(PKDrawing(strokes: [natives[1]]))
        _ = try await codec.encode(live.canvas.drawing)
        let before = await codec.workMetrics
        await live.assign(PKDrawing(strokes: natives))
        let restored = try await codec.encode(live.canvas.drawing)
        let after = await codec.workMetrics
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.map(\.cachedDigest), original.map(\.cachedDigest))
        XCTAssertEqual(after.serializedStrokes, before.serializedStrokes)
        XCTAssertEqual(after.hashedArchiveBytes, before.hashedArchiveBytes)
    }

    func testCompleteRenderStateSnapshotAndMutableMaskSignatureRemainExact() throws {
        var native = NativeArchiveFixtures.stroke()
        native.ink = PKInk(.crayon, color: .black)
        let renderState = PKStroke.RenderState(grainOffset: CGPoint(x: 10, y: 20))
        native.renderState = renderState
        XCTAssertNotNil(native.renderState)
        let stateBeforeMask = native.renderState == nil ? 0 : 1
        native.mask = UIBezierPath(rect: CGRect(x: 10, y: 20, width: 40, height: 40))
        let stateAfterMask = native.renderState == nil ? 0 : 1
        native.renderState = renderState
        XCTAssertNotNil(native.renderState)
        let seededDrawing = PKDrawing(strokes: [native])
        XCTAssertNotNil(seededDrawing.strokes.first?.renderState)
        try report(name: "mask-render-state-retention", values: [
            "renderStateBeforeMask": stateBeforeMask,
            "renderStateAfterMask": stateAfterMask,
            "renderStateAfterExplicitRestore": native.renderState == nil ? 0 : 1,
            "renderStateAfterDrawingConstruction": seededDrawing.strokes.first?.renderState == nil ? 0 : 1
        ])
        let initial = try InkDrawingSignature(seededDrawing)
        let unchanged = try InkDrawingSignature(PKDrawing(strokes: [native]))
        XCTAssertTrue(initial.compared(to: unchanged).isEqual)
        XCTAssertEqual(initial.constructionWork.encodedRenderStates, 1)
        XCTAssertGreaterThan(initial.constructionWork.renderStateBytes, 0)

        var state = try XCTUnwrap(native.renderState)
        state.grainOffset = CGPoint(x: 30, y: 40)
        native.renderState = state
        XCTAssertNotEqual(initial, try InkDrawingSignature(PKDrawing(strokes: [native])))
        let beforeMaskChange = try InkDrawingSignature(PKDrawing(strokes: [native]))
        let retainedRenderState = native.renderState
        let mask = try XCTUnwrap(native.mask)
        mask.removeAllPoints()
        mask.append(UIBezierPath(ovalIn: CGRect(x: 10, y: 20, width: 40, height: 40)))
        native.mask = mask
        native.renderState = retainedRenderState
        XCTAssertNotNil(native.renderState)
        let afterMaskChange = try InkDrawingSignature(PKDrawing(strokes: [native]))
        XCTAssertNotEqual(beforeMaskChange, afterMaskChange)

        let substroke = native.substroke(range: 1...2)
        let drawing = PKDrawing(strokes: [substroke])
        let first = try InkDrawingSignature(drawing)
        let second = try InkDrawingSignature(drawing)
        XCTAssertEqual(first, second)
        if let render = substroke.renderState {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            XCTAssertGreaterThan(try encoder.encode(render).count, 0)
            XCTAssertEqual(first.constructionWork.encodedRenderStates, 1)
        }
    }

    private struct MaskElement {
        let type: CGPathElementType
        let points: [CGPoint]
    }

    private func maskElements(_ path: CGPath) -> [MaskElement] {
        var result: [MaskElement] = []
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let count: Int
            switch element.type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            case .closeSubpath: count = 0
            @unknown default:
                XCTFail("Unsupported native mask path element.")
                count = 0
            }
            result.append(MaskElement(
                type: element.type,
                points: Array(UnsafeBufferPointer(start: element.points, count: count))
            ))
        }
        return result
    }

    private func assertQuantizedMask(
        _ actual: CGPath?, matches expected: CGPath?,
        file: StaticString = #filePath, line: UInt = #line
    ) -> CGFloat {
        guard let actual, let expected else {
            XCTAssertEqual(actual == nil, expected == nil, file: file, line: line)
            return 0
        }
        let actualElements = maskElements(actual)
        let expectedElements = maskElements(expected)
        XCTAssertEqual(actualElements.count, expectedElements.count, file: file, line: line)
        var maximumError: CGFloat = 0
        for (actual, expected) in zip(actualElements, expectedElements) {
            XCTAssertEqual(actual.type, expected.type, file: file, line: line)
            XCTAssertEqual(actual.points.count, expected.points.count, file: file, line: line)
            for (actualPoint, expectedPoint) in zip(actual.points, expected.points) {
                maximumError = max(maximumError, abs(actualPoint.x - expectedPoint.x))
                maximumError = max(maximumError, abs(actualPoint.y - expectedPoint.y))
                XCTAssertEqual(actualPoint.x, expectedPoint.x, accuracy: 0.02, file: file, line: line)
                XCTAssertEqual(actualPoint.y, expectedPoint.y, accuracy: 0.02, file: file, line: line)
            }
        }
        return maximumError
    }

    private func report(name: String, values: [String: Int]) throws {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        print("NOTTY_SAVE_METRIC \(name) \(String(decoding: data, as: UTF8.self))")
        if let path = ProcessInfo.processInfo.environment["NOTTY_SAVE_METRICS_DIRECTORY"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("codec-native-\(name).json"), options: .atomic)
        }
    }
}
