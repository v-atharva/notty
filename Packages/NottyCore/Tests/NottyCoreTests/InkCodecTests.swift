import Foundation
import PencilKit
import XCTest
@testable import NottyCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@available(iOS 27.0, macOS 27.0, *)
final class InkCodecTests: XCTestCase {
    private func stroke(id: UUID = UUID(), x: CGFloat = 20) -> PKStroke {
        #if canImport(UIKit)
        let color = UIColor.black
        #else
        let color = NSColor.black
        #endif

        let points = (0..<4).map { index in
            PKStrokePoint(
                location: CGPoint(x: x + CGFloat(index) * 10, y: 40),
                timeOffset: Double(index) * 0.02,
                size: CGSize(width: 3, height: 3),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        let path = PKStrokePath(
            controlPoints: points,
            creationDate: Date(timeIntervalSince1970: 1_000)
        )
        var result = PKStroke(ink: PKInk(.pen, color: color), path: path)
        result.id = id
        return result
    }

    func testRoundtripPreservesOrderIdentityAndGeometry() async throws {
        let first = stroke()
        let second = stroke(x: 120)
        let original = PKDrawing(strokes: [first, second])
        let encoder = InkCodec()
        let assets = try await encoder.encode(original)
        let reopened = try await InkCodec().decode(assets)

        XCTAssertEqual(assets.map(\.id), [first.id, second.id])
        XCTAssertEqual(reopened.strokes.map(\.id), [first.id, second.id])
        XCTAssertEqual(reopened.strokes.map(\.renderBounds), original.strokes.map(\.renderBounds))
    }

    func testUnchangedStrokeArchivesAreReusedAfterMoveAndErase() async throws {
        let first = stroke()
        let second = stroke(x: 120)
        let codec = InkCodec()
        let initial = try await codec.encode(PKDrawing(strokes: [first, second]))
        _ = try await codec.encode(PKDrawing(strokes: [first, second]))
        let firstCount = await codec.serializedStrokeCount
        XCTAssertEqual(firstCount, 2)

        var moved = second
        moved.transform = CGAffineTransform(translationX: 15, y: 25)
        let changed = try await codec.encode(PKDrawing(strokes: [first, moved]))
        let movedCount = await codec.serializedStrokeCount
        XCTAssertEqual(movedCount, 3)
        XCTAssertEqual(changed[0].data, initial[0].data)
        XCTAssertEqual(changed[1].id, second.id)

        let erased = try await codec.encode(PKDrawing(strokes: [moved]))
        let erasedCount = await codec.serializedStrokeCount
        XCTAssertEqual(erasedCount, 3)
        let cacheCount = await codec.cachedStrokeCount
        XCTAssertEqual(cacheCount, 1)
        XCTAssertEqual(erased[0].data, changed[1].data)
        let reopened = try await InkCodec().decode(erased)
        XCTAssertEqual(reopened.strokes[0].id, second.id)
        XCTAssertEqual(reopened.strokes[0].transform, moved.transform)
    }

    func testDecodeReappliesManifestIdentity() async throws {
        let native = stroke()
        let manifestID = UUID()
        let asset = NotebookStroke(
            id: manifestID,
            data: PKDrawing(strokes: [native]).dataRepresentation()
        )
        let reopened = try await InkCodec().decode([asset])
        XCTAssertEqual(reopened.strokes[0].id, manifestID)
    }

    func testRejectsDuplicateIDsAndInvalidArchives() async throws {
        let codec = InkCodec()
        let native = stroke()
        let asset = NotebookStroke(
            id: native.id,
            data: PKDrawing(strokes: [native]).dataRepresentation()
        )
        do {
            _ = try await codec.decode([asset, asset])
            XCTFail("Duplicate identities must fail.")
        } catch InkCodec.CodecError.duplicateStrokeID {}

        let normalized = PKDrawing(strokes: [native, native])
        let normalizedIDs = normalized.strokes.map(\.id)
        XCTAssertFalse(normalizedIDs.isEmpty)
        XCTAssertLessThanOrEqual(normalizedIDs.count, 2)
        XCTAssertEqual(Set(normalizedIDs).count, normalizedIDs.count)
        let normalizedAssets = try await codec.encode(normalized)
        XCTAssertEqual(normalizedAssets.map(\.id), normalizedIDs)

        for data in [
            Data([0, 1, 2, 3]),
            PKDrawing().dataRepresentation(),
            PKDrawing(strokes: [native, stroke()]).dataRepresentation()
        ] {
            do {
                _ = try await codec.decode([NotebookStroke(id: UUID(), data: data)])
                XCTFail("Invalid single-stroke archives must fail.")
            } catch {}
        }
    }

    func testCountLimitRejectsBeforeSerializationOrDecoding() async throws {
        let native = stroke()
        let drawing = PKDrawing(strokes: [native, stroke(), stroke()])
        let encoder = InkCodec(maximumStrokeCount: 2, maximumDrawingBytes: 1_000_000)
        do {
            _ = try await encoder.encode(drawing)
            XCTFail("Excess count must fail before serialization.")
        } catch InkCodec.CodecError.tooManyStrokes {}
        let count = await encoder.serializedStrokeCount
        let cacheCount = await encoder.cachedStrokeCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(cacheCount, 0)

        let invalidAssets = (0..<3).map { _ in
            NotebookStroke(id: UUID(), data: Data([0]))
        }
        do {
            _ = try await encoder.decode(invalidAssets)
            XCTFail("Excess count must fail before malformed data is decoded.")
        } catch InkCodec.CodecError.tooManyStrokes {}
    }

    func testAggregateLimitStopsEncodingBeforeRemainingStrokes() async throws {
        let first = stroke()
        let second = stroke(x: 120)
        let third = stroke(x: 220)
        let firstBytes = PKDrawing(strokes: [first]).dataRepresentation().count
        let secondBytes = PKDrawing(strokes: [second]).dataRepresentation().count
        let codec = InkCodec(
            maximumStrokeCount: 10,
            maximumDrawingBytes: firstBytes + secondBytes - 1
        )
        do {
            _ = try await codec.encode(PKDrawing(strokes: [first, second, third]))
            XCTFail("Combined archives above the limit must fail.")
        } catch InkCodec.CodecError.oversizedDrawingArchive {}
        let serialized = await codec.serializedStrokeCount
        let cached = await codec.cachedStrokeCount
        XCTAssertEqual(serialized, 2)
        XCTAssertEqual(cached, 0)
    }

    func testAggregateLimitRejectsBeforeDecodingOversizedTail() async throws {
        let first = stroke()
        let firstData = PKDrawing(strokes: [first]).dataRepresentation()
        let codec = InkCodec(
            maximumStrokeCount: 10,
            maximumDrawingBytes: firstData.count
        )
        let assets = [
            NotebookStroke(id: first.id, data: firstData),
            NotebookStroke(id: UUID(), data: Data([0]))
        ]
        do {
            _ = try await codec.decode(assets)
            XCTFail("Aggregate limit must reject the second asset before decode.")
        } catch InkCodec.CodecError.oversizedDrawingArchive {}
        let cached = await codec.cachedStrokeCount
        XCTAssertEqual(cached, 0)
    }
    func testProductionStrokeLimitRejectsSharedPathCopiesWithoutSerialization() async throws {
        let template = stroke()
        let strokes = (0...InkCodec.maximumStrokeCount).map { _ in
            var copy = template
            copy.id = UUID()
            return copy
        }
        let codec = InkCodec()
        do {
            _ = try await codec.encode(PKDrawing(strokes: strokes))
            XCTFail("The production count limit must reject excess strokes.")
        } catch InkCodec.CodecError.tooManyStrokes {}
        let serialized = await codec.serializedStrokeCount
        XCTAssertEqual(serialized, 0)
    }

    func testMaskChangeKeepsIdentityAndCreatesChangedArchive() async throws {
        let original = stroke()
        let codec = InkCodec()
        let initial = try await codec.encode(PKDrawing(strokes: [original]))
        var masked = original
        #if canImport(UIKit)
        let mask = UIBezierPath(rect: CGRect(x: 10, y: 20, width: 30, height: 40))
        #else
        let mask = NSBezierPath(rect: CGRect(x: 10, y: 20, width: 30, height: 40))
        #endif
        masked.mask = mask
        let changed = try await codec.encode(PKDrawing(strokes: [masked]))
        let count = await codec.serializedStrokeCount
        XCTAssertEqual(count, 2)
        XCTAssertEqual(changed[0].id, original.id)
        XCTAssertNotEqual(changed[0].data, initial[0].data)
        let reopened = try await InkCodec().decode(changed)
        XCTAssertEqual(reopened.strokes[0].id, original.id)
        XCTAssertEqual(reopened.strokes[0].mask?.bounds, mask.bounds)
    }

    func testSameBoundsDifferentMaskGeometryInvalidatesCache() async throws {
        var native = stroke()
        let rect = CGRect(x: 10, y: 20, width: 40, height: 40)
        #if canImport(UIKit)
        native.mask = UIBezierPath(rect: rect)
        #else
        native.mask = NSBezierPath(rect: rect)
        #endif
        let codec = InkCodec()
        let first = try await codec.encode(PKDrawing(strokes: [native]))

        #if canImport(UIKit)
        native.mask = UIBezierPath(ovalIn: rect)
        #else
        native.mask = NSBezierPath(ovalIn: rect)
        #endif
        let second = try await codec.encode(PKDrawing(strokes: [native]))
        let count = await codec.serializedStrokeCount
        XCTAssertEqual(count, 2)
        XCTAssertEqual(second[0].id, first[0].id)
        XCTAssertNotEqual(second[0].data, first[0].data)
    }

    func testRenderStateAndGroupInvalidateCache() async throws {
        var native = stroke()
        let codec = InkCodec()
        let first = try await codec.encode(PKDrawing(strokes: [native]))
        native.renderGroupID = UUID()
        let grouped = try await codec.encode(PKDrawing(strokes: [native]))
        native.renderState = PKStroke.RenderState(grainOffset: CGPoint(x: 10, y: 20))
        let rendered = try await codec.encode(PKDrawing(strokes: [native]))
        let count = await codec.serializedStrokeCount
        XCTAssertEqual(count, 3)
        XCTAssertNotEqual(grouped[0].data, first[0].data)
        XCTAssertNotEqual(rendered[0].data, grouped[0].data)
        let reopened = try await InkCodec().decode(rendered)
        XCTAssertEqual(reopened.strokes[0].renderState, native.renderState)
        XCTAssertEqual(reopened.strokes[0].renderGroupID, native.renderGroupID)
    }

    func testDecodeThenEncodeReusesOriginalAsset() async throws {
        let encoder = InkCodec()
        let assets = try await encoder.encode(PKDrawing(strokes: [stroke()]))
        let decoder = InkCodec()
        let drawing = try await decoder.decode(assets)
        let unchanged = try await decoder.encode(drawing)
        let count = await decoder.serializedStrokeCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(unchanged, assets)
    }

    func testColorAndInkTypeChangesInvalidateCachedArchive() async throws {
        let codec = InkCodec()
        var native = stroke()
        let first = try await codec.encode(PKDrawing(strokes: [native]))
        #if canImport(UIKit)
        let red = UIColor.red
        #else
        let red = NSColor.red
        #endif
        native.ink = PKInk(.pen, color: red)
        let recolored = try await codec.encode(PKDrawing(strokes: [native]))
        native.ink = PKInk(.marker, color: red)
        let retyped = try await codec.encode(PKDrawing(strokes: [native]))

        let serialized = await codec.serializedStrokeCount
        XCTAssertEqual(serialized, 3)
        XCTAssertNotEqual(recolored[0].data, first[0].data)
        XCTAssertNotEqual(retyped[0].data, recolored[0].data)
        XCTAssertEqual(retyped[0].id, native.id)
        let reopened = try await InkCodec().decode(retyped)
        XCTAssertEqual(reopened.strokes[0].ink.inkType, .marker)
        XCTAssertEqual(reopened.strokes[0].id, native.id)
    }

    func testChangedPointValuesWithUnchangedCountAndDateInvalidateCachedArchive() async throws {
        let codec = InkCodec()
        var native = stroke()
        let first = try await codec.encode(PKDrawing(strokes: [native]))
        let originalDate = native.path.creationDate
        let shifted = native.path.map { point in
            PKStrokePoint(
                location: CGPoint(x: point.location.x + 7, y: point.location.y),
                timeOffset: point.timeOffset, size: point.size, opacity: point.opacity,
                force: point.force, azimuth: point.azimuth, altitude: point.altitude
            )
        }
        native.path = PKStrokePath(controlPoints: shifted, creationDate: originalDate)
        let changed = try await codec.encode(PKDrawing(strokes: [native]))

        let serialized = await codec.serializedStrokeCount
        XCTAssertEqual(serialized, 2)
        XCTAssertNotEqual(changed[0].data, first[0].data)
        XCTAssertEqual(changed[0].id, native.id)
        let reopened = try await InkCodec().decode(changed)
        XCTAssertEqual(reopened.strokes[0].path.count, shifted.count)
        XCTAssertEqual(reopened.strokes[0].path.creationDate, originalDate)
        for (actual, expected) in zip(reopened.strokes[0].path, shifted) {
            XCTAssertEqual(actual.location.x, expected.location.x, accuracy: 0.001)
            XCTAssertEqual(actual.location.y, expected.location.y, accuracy: 0.001)
        }
    }


    func testInPlaceMaskMutationNeverReusesStaleArchive() async throws {
        let codec = InkCodec()
        var native = stroke()
        #if canImport(UIKit)
        native.mask = UIBezierPath(rect: CGRect(x: 10, y: 20, width: 30, height: 40))
        #else
        native.mask = NSBezierPath(rect: CGRect(x: 10, y: 20, width: 30, height: 40))
        #endif
        let first = try await codec.encode(PKDrawing(strokes: [native]))
        let liveMask = try XCTUnwrap(native.mask)
        let originalBounds = liveMask.bounds
        #if canImport(UIKit)
        liveMask.apply(CGAffineTransform(translationX: 25, y: 0))
        #else
        liveMask.transform(using: AffineTransform(translationByX: 25, byY: 0))
        #endif
        let expected = try XCTUnwrap(native.mask?.bounds)
        XCTAssertNotEqual(expected, originalBounds)
        let changed = try await codec.encode(PKDrawing(strokes: [native]))
        let reopened = try await InkCodec().decode(changed)

        let serialized = await codec.serializedStrokeCount
        XCTAssertEqual(serialized, 2)
        XCTAssertNotEqual(changed[0].data, first[0].data)
        XCTAssertEqual(reopened.strokes[0].mask?.bounds, expected)
        XCTAssertEqual(reopened.strokes[0].id, native.id)
    }

    func testPointWidthChangeInvalidatesCachedArchive() async throws {
        let codec = InkCodec()
        var native = stroke()
        let first = try await codec.encode(PKDrawing(strokes: [native]))
        let originalDate = native.path.creationDate
        let widened = native.path.map { point in
            PKStrokePoint(
                location: point.location, timeOffset: point.timeOffset,
                size: CGSize(width: 9, height: 9), opacity: point.opacity,
                force: point.force, azimuth: point.azimuth, altitude: point.altitude
            )
        }
        native.path = PKStrokePath(controlPoints: widened, creationDate: originalDate)
        let changed = try await codec.encode(PKDrawing(strokes: [native]))

        let serialized = await codec.serializedStrokeCount
        XCTAssertEqual(serialized, 2)
        XCTAssertNotEqual(changed[0].data, first[0].data)
        XCTAssertEqual(changed[0].id, native.id)
        let reopened = try await InkCodec().decode(changed)
        XCTAssertEqual(reopened.strokes[0].path.count, widened.count)
        XCTAssertEqual(reopened.strokes[0].path.creationDate, originalDate)
        for (actual, expected) in zip(reopened.strokes[0].path, widened) {
            XCTAssertEqual(actual.location, expected.location)
            XCTAssertEqual(actual.size, expected.size)
        }
    }

}
