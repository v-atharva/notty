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

        do {
            _ = try await codec.encode(PKDrawing(strokes: [native, native]))
            XCTFail("Duplicate native identities must fail.")
        } catch InkCodec.CodecError.duplicateStrokeID {}

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
}
