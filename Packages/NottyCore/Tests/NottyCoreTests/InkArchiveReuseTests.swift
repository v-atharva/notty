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
final class InkArchiveReuseTests: XCTestCase {
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
                size: CGSize(width: 3, height: 3), opacity: 1,
                force: 1, azimuth: 0, altitude: .pi / 2
            )
        }
        return PKStroke(
            ink: PKInk(.pen, color: color),
            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_000)),
            transform: .identity, mask: nil, randomSeed: 17,
            id: id, renderGroupID: nil, renderState: nil
        )
    }

    func testArchiveBytesAndTrustedDigestsRemainPairedAcrossCacheHits() async throws {
        let native = stroke()
        let firstArchive = PKDrawing(strokes: [native]).dataRepresentation()
        let secondArchive = PKDrawing(strokes: [native]).dataRepresentation()
        XCTAssertEqual(firstArchive, secondArchive)
        let codec = InkCodec()
        let first = try await codec.encode(PKDrawing(strokes: [native]))
        let before = await codec.workMetrics
        let second = try await codec.encode(PKDrawing(strokes: [native]))
        let after = await codec.workMetrics
        XCTAssertEqual(first, second)
        XCTAssertEqual(first[0].cachedDigest, NotebookDigest.sha256(first[0].data))
        XCTAssertEqual(second[0].cachedDigest, first[0].cachedDigest)
        XCTAssertEqual(after.hashedArchiveBytes, before.hashedArchiveBytes)
        XCTAssertEqual(after.copiedArchiveBytes, before.copiedArchiveBytes)
        XCTAssertEqual(after.serializedStrokes, before.serializedStrokes)
        XCTAssertEqual(after.comparedPoints - before.comparedPoints, native.path.count)
        XCTAssertNil(NotebookStroke(id: native.id, data: first[0].data).cachedDigest)
    }

    func testDecodeCopiesAliasedBytesBeforeTrustingTheirDigest() async throws {
        let native = stroke()
        let archive = PKDrawing(strokes: [native]).dataRepresentation()
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: archive.count, alignment: 1)
        defer { pointer.deallocate() }
        archive.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: archive.count)
        let aliased = Data(bytesNoCopy: pointer, count: archive.count, deallocator: .none)
        let authoritativeID = UUID()
        let codec = InkCodec()
        let drawing = try await codec.decode([NotebookStroke(id: authoritativeID, data: aliased)])
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: archive.count)
        let cached = try await codec.encode(drawing)
        XCTAssertEqual(cached[0].data, archive)
        XCTAssertEqual(cached[0].cachedDigest, NotebookDigest.sha256(archive))
        XCTAssertEqual(cached[0].id, authoritativeID)
        let observed1 = await codec.serializedStrokeCount
        XCTAssertEqual(observed1, 0)
    }

    func testCombinedDecodePreservesAuthoritativeOrderDespiteArchiveIdentityCollisions() async throws {
        let native = stroke()
        let archive = PKDrawing(strokes: [native]).dataRepresentation()
        let firstID = UUID()
        let secondID = UUID()
        let assets = [
            NotebookStroke(id: firstID, data: archive),
            NotebookStroke(id: secondID, data: archive)
        ]
        let codec = InkCodec()
        let restored = try await codec.decode(assets)
        XCTAssertEqual(restored.strokes.map(\.id), [firstID, secondID])
        let encoded = try await codec.encode(restored)
        XCTAssertEqual(encoded.map(\.id), assets.map(\.id))
        XCTAssertEqual(encoded.map(\.data), assets.map(\.data))
        XCTAssertEqual(encoded.map(\.cachedDigest), [NotebookDigest.sha256(archive), NotebookDigest.sha256(archive)])
        let observed2 = await codec.serializedStrokeCount
        XCTAssertEqual(observed2, 0)
    }

    func testErasedStrokeUndoReusesBoundedRetiredArchive() async throws {
        let first = stroke()
        let second = stroke(x: 120)
        let codec = InkCodec()
        let original = try await codec.encode(PKDrawing(strokes: [first, second]))
        _ = try await codec.encode(PKDrawing(strokes: [second]))
        let observed3 = await codec.retiredStrokeCount
        XCTAssertEqual(observed3, 1)
        let restored = try await codec.encode(PKDrawing(strokes: [first, second]))
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.map(\.cachedDigest), original.map(\.cachedDigest))
        let observed4 = await codec.serializedStrokeCount
        XCTAssertEqual(observed4, 2)
        let observed5 = await codec.retiredStrokeCount
        XCTAssertEqual(observed5, 0)
    }

    func testRetiredArchivesRespectBothEntryAndByteLimits() async throws {
        let natives = (0..<70).map { stroke(x: CGFloat($0) * 10) }
        let codec = InkCodec()
        _ = try await codec.encode(PKDrawing(strokes: natives))
        _ = try await codec.encode(PKDrawing())
        let observed6 = await codec.retiredStrokeCount
        XCTAssertEqual(observed6, InkCodec.maximumRetiredStrokeCount)
        let observed7 = await codec.retiredArchiveBytes
        XCTAssertLessThanOrEqual(observed7, InkCodec.maximumRetiredBytes)

        let archiveBytes = PKDrawing(strokes: [natives[0]]).dataRepresentation().count
        let byteBounded = InkCodec(
            maximumStrokeCount: 10, maximumDrawingBytes: 64 * 1_024 * 1_024,
            maximumRetiredStrokeCount: 64, maximumRetiredBytes: archiveBytes
        )
        _ = try await byteBounded.encode(PKDrawing(strokes: Array(natives.prefix(3))))
        _ = try await byteBounded.encode(PKDrawing())
        let observed8 = await byteBounded.retiredArchiveBytes
        XCTAssertLessThanOrEqual(observed8, archiveBytes)
        let observed9 = await byteBounded.retiredStrokeCount
        XCTAssertLessThan(observed9, 3)
    }

    func testFailedEncodeAndDecodeKeepLastValidCacheAndCountAttemptedWork() async throws {
        let native = stroke()
        let archiveBytes = PKDrawing(strokes: [native]).dataRepresentation().count
        let codec = InkCodec(maximumStrokeCount: 10, maximumDrawingBytes: archiveBytes)
        let original = try await codec.encode(PKDrawing(strokes: [native]))
        let before = await codec.workMetrics
        do {
            _ = try await codec.encode(PKDrawing(strokes: [native, stroke(x: 120)]))
            XCTFail("The aggregate byte limit was not enforced.")
        } catch InkCodec.CodecError.oversizedDrawingArchive {}
        let failedWork = await codec.workMetrics
        XCTAssertGreaterThan(failedWork.serializedStrokes, before.serializedStrokes)
        XCTAssertGreaterThan(failedWork.hashedArchiveBytes, before.hashedArchiveBytes)
        let observed10 = await codec.cachedStrokeCount
        XCTAssertEqual(observed10, 1)
        let observed11 = await codec.retiredStrokeCount
        XCTAssertEqual(observed11, 0)
        let retry = try await codec.encode(PKDrawing(strokes: [native]))
        XCTAssertEqual(retry, original)
        XCTAssertEqual(retry[0].cachedDigest, original[0].cachedDigest)

        do {
            _ = try await codec.decode([NotebookStroke(id: UUID(), data: Data([0, 1, 2, 3]))])
            XCTFail("Invalid native archive bytes were accepted.")
        } catch {}
        let retried = try await codec.encode(PKDrawing(strokes: [native]))
        XCTAssertEqual(retried, original)
        let observed12 = await codec.cachedStrokeCount
        XCTAssertEqual(observed12, 1)
        let observed13 = await codec.retiredStrokeCount
        XCTAssertEqual(observed13, 0)
    }

    func testDrawingSignaturePreservesOrderIdentityAndFullPointComparison() throws {
        let first = stroke()
        let second = stroke(x: 120)
        let original = PKDrawing(strokes: [first, second])
        let signature = try InkDrawingSignature(original)
        let same = try InkDrawingSignature(original)
        let comparison = signature.compared(to: same)
        XCTAssertTrue(comparison.isEqual)
        XCTAssertEqual(comparison.work.comparedPoints, 8)
        XCTAssertEqual(comparison.work.signatureChecks, 2)
        XCTAssertEqual(signature.constructionWork.signatureChecks, 2)
        XCTAssertNotEqual(signature, try InkDrawingSignature(PKDrawing(strokes: [second, first])))

        var changed = first
        changed.transform = CGAffineTransform(translationX: 1, y: 2)
        XCTAssertNotEqual(signature, try InkDrawingSignature(PKDrawing(strokes: [changed, second])))
        changed = first
        changed.id = UUID()
        XCTAssertNotEqual(signature, try InkDrawingSignature(PKDrawing(strokes: [changed, second])))
    }

    func testChangedNativePathGetsNewIdentityAndSignatureRetainsEveryPointField() throws {
        let original = stroke()
        let old = try InkDrawingSignature(PKDrawing(strokes: [original]))
        let shifted = original.path.map { point in
            PKStrokePoint(
                location: CGPoint(x: point.location.x + 7, y: point.location.y),
                timeOffset: point.timeOffset, size: point.size, opacity: point.opacity,
                force: point.force, azimuth: point.azimuth, altitude: point.altitude
            )
        }
        var changed = original
        changed.path = PKStrokePath(controlPoints: shifted, creationDate: original.path.creationDate)
        XCTAssertNotEqual(changed.path.id, original.path.id)
        XCTAssertEqual(changed.id, original.id)
        XCTAssertNotEqual(old, try InkDrawingSignature(PKDrawing(strokes: [changed])))
    }

    func testOneStrokeChangeMetricsExposeExactFallbackWorkAtOneHundredAndTwoThousand() async throws {
        for count in [100, 2_000] {
            let strokes = (0..<count).map { stroke(x: CGFloat($0) * 10) }
            let codec = InkCodec()
            let initial = try await codec.encode(PKDrawing(strokes: strokes))
            let before = await codec.workMetrics
            var changed = strokes
            changed[0].transform = CGAffineTransform(translationX: 3, y: 5)
            let encoded = try await codec.encode(PKDrawing(strokes: changed))
            let after = await codec.workMetrics
            XCTAssertEqual(after.serializedStrokes - before.serializedStrokes, 1)
            XCTAssertEqual(after.hashedArchiveBytes - before.hashedArchiveBytes, encoded[0].data.count)
            XCTAssertEqual(after.comparedPoints - before.comparedPoints, (count - 1) * 4)
            XCTAssertEqual(Array(encoded.dropFirst()), Array(initial.dropFirst()))
            let metrics: [String: Int] = [
                "strokeCount": count,
                "serializations": after.serializedStrokes - before.serializedStrokes,
                "pointComparisons": after.comparedPoints - before.comparedPoints,
                "signatureChecks": after.signatureChecks - before.signatureChecks,
                "assetSHABytes": after.hashedArchiveBytes - before.hashedArchiveBytes,
                "copiedArchiveBytes": after.copiedArchiveBytes - before.copiedArchiveBytes
            ]
            let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
            print("NOTTY_SAVE_METRIC \(String(decoding: data, as: UTF8.self))")
        }
    }
}
