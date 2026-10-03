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
        XCTAssertEqual(after.comparedPoints - before.comparedPoints, 12)
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
        for variant in variants {
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
            XCTAssertEqual(restored.strokes[0].mask?.cgPath, variant.mask?.cgPath)
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
        native.renderState = PKStroke.RenderState(grainOffset: CGPoint(x: 10, y: 20))
        native.mask = UIBezierPath(rect: CGRect(x: 10, y: 20, width: 40, height: 40))
        let initial = try InkDrawingSignature(PKDrawing(strokes: [native]))
        let unchanged = try InkDrawingSignature(PKDrawing(strokes: [native]))
        XCTAssertTrue(initial.compared(to: unchanged).isEqual)
        XCTAssertEqual(initial.constructionWork.encodedRenderStates, 1)
        XCTAssertGreaterThan(initial.constructionWork.renderStateBytes, 0)

        var state = try XCTUnwrap(native.renderState)
        state.grainOffset = CGPoint(x: 30, y: 40)
        native.renderState = state
        XCTAssertNotEqual(initial, try InkDrawingSignature(PKDrawing(strokes: [native])))
        let beforeMaskChange = try InkDrawingSignature(PKDrawing(strokes: [native]))
        let mask = try XCTUnwrap(native.mask)
        mask.removeAllPoints()
        mask.append(UIBezierPath(ovalIn: CGRect(x: 10, y: 20, width: 40, height: 40)))
        native.mask = mask
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
