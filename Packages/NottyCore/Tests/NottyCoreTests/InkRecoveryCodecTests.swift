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
final class InkRecoveryCodecTests: XCTestCase {
    func testRecoveryProfileAcceptsAnEmergencyStateBeyondNotebookCount() async throws {
        let native = stroke()
        let strokes = (0...InkCodec.maximumStrokeCount).map { _ in
            var copy = native
            copy.id = UUID()
            return copy
        }
        let drawing = PKDrawing(strokes: strokes)
        XCTAssertEqual(drawing.strokes.count, 10_001)
        let normal = InkCodec(comparisonMode: .exact)
        do {
            _ = try await normal.encode(drawing)
            XCTFail("Normal notebook bounds must remain unchanged.")
        } catch InkCodec.CodecError.tooManyStrokes {}
        let normalWork = await normal.workMetrics
        XCTAssertEqual(normalWork.serializedStrokes, 0)
        let emergency = InkCodec(profile: .recovery)
        let assets = try await emergency.encode(drawing)
        XCTAssertEqual(assets.map(\.id), strokes.map(\.id))
        let restored = try await InkCodec(profile: .recovery).decode(assets)
        XCTAssertEqual(restored.strokes.map(\.id), strokes.map(\.id))
        XCTAssertEqual(restored.strokes.first?.path.count, native.path.count)
        XCTAssertEqual(restored.strokes.last?.path.count, native.path.count)
    }

    func testRecoveryCountOverflowRejectsBeforeNativeArchiveWork() async throws {
        let codec = InkCodec(profile: .recovery)
        let assets = (0...20_000).map { _ in NotebookStroke(id: UUID(), data: Data([0])) }
        do {
            _ = try await codec.decode(assets)
            XCTFail("Recovery states above 20,000 IDs must fail before decoding.")
        } catch InkCodec.CodecError.tooManyStrokes {}
        let work = await codec.workMetrics
        XCTAssertEqual(work.serializedStrokes, 0)
        XCTAssertEqual(work.hashedArchiveBytes, 0)
        XCTAssertEqual(work.copiedArchiveBytes, 0)
        let cached = await codec.cachedStrokeCount
        XCTAssertEqual(cached, 0)
    }

    func testClosedProfilesKeepSeparateAssetAndLogicalStateBounds() {
        XCTAssertEqual(InkCodec.Profile.notebook.maximumStrokeCount, 10_000)
        XCTAssertEqual(InkCodec.Profile.notebook.maximumStrokeBytes, 10 * 1_024 * 1_024)
        XCTAssertEqual(InkCodec.Profile.notebook.maximumDrawingBytes, 64 * 1_024 * 1_024)
        XCTAssertEqual(InkCodec.Profile.recovery.maximumStrokeCount, 20_000)
        XCTAssertEqual(InkCodec.Profile.recovery.maximumStrokeBytes, 128 * 1_024 * 1_024)
        XCTAssertEqual(InkCodec.Profile.recovery.maximumDrawingBytes, 128 * 1_024 * 1_024)
    }

    func testIndividualAssetFailureRetainsTheLastValidOwnedCache() async throws {
        let native = stroke()
        let data = PKDrawing(strokes: [native]).dataRepresentation()
        let codec = InkCodec(
            maximumStrokeCount: 10, maximumDrawingBytes: data.count * 4,
            maximumStrokeBytes: data.count
        )
        let valid = NotebookStroke(id: native.id, data: data)
        let original = try await codec.decode([valid])
        let before = await codec.workMetrics
        let oversized = NotebookStroke(id: UUID(), data: Data(repeating: 0, count: data.count + 1))
        do {
            _ = try await codec.decode([valid, oversized])
            XCTFail("An oversized later asset must fail without committing a partial cache.")
        } catch InkCodec.CodecError.oversizedStrokeArchive {}
        let cached = await codec.cachedStrokeCount
        XCTAssertEqual(cached, 1)
        let afterFailure = await codec.workMetrics
        XCTAssertEqual(afterFailure.copiedArchiveBytes - before.copiedArchiveBytes, data.count)
        XCTAssertEqual(afterFailure.hashedArchiveBytes - before.hashedArchiveBytes, data.count)
        let reused = try await codec.encode(original)
        XCTAssertEqual(reused, [valid])
        XCTAssertEqual(reused[0].cachedDigest, NotebookDigest.sha256(data))
        let afterReuse = await codec.workMetrics
        XCTAssertEqual(afterReuse.copiedArchiveBytes, afterFailure.copiedArchiveBytes)
        XCTAssertEqual(afterReuse.hashedArchiveBytes, afterFailure.hashedArchiveBytes)
        XCTAssertEqual(afterReuse.serializedStrokes, afterFailure.serializedStrokes)
    }

    func testLogicalStateLimitCountsRepeatedValidArchivesUnderDifferentIDs() async throws {
        let data = PKDrawing(strokes: [stroke()]).dataRepresentation()
        let assets = [
            NotebookStroke(id: UUID(), data: data),
            NotebookStroke(id: UUID(), data: data)
        ]
        let exact = InkCodec(
            maximumStrokeCount: 2, maximumDrawingBytes: data.count * 2,
            maximumStrokeBytes: data.count
        )
        let drawing = try await exact.decode(assets)
        XCTAssertEqual(drawing.strokes.map(\.id), assets.map(\.id))
        let below = InkCodec(
            maximumStrokeCount: 2, maximumDrawingBytes: data.count * 2 - 1,
            maximumStrokeBytes: data.count
        )
        do {
            _ = try await below.decode(assets)
            XCTFail("Physical reuse cannot expand the logical state limit.")
        } catch InkCodec.CodecError.oversizedDrawingArchive {}
        let work = await below.workMetrics
        XCTAssertEqual(work.copiedArchiveBytes, data.count)
        XCTAssertEqual(work.hashedArchiveBytes, data.count)
        let cached = await below.cachedStrokeCount
        XCTAssertEqual(cached, 0)
    }

    func testRecoveryDecodeOwnsAliasedInputAndReusesExactOriginalBytes() async throws {
        let data = PKDrawing(strokes: [stroke()]).dataRepresentation()
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: 1)
        defer { pointer.deallocate() }
        data.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: data.count)
        let aliased = Data(bytesNoCopy: pointer, count: data.count, deallocator: .none)
        let identities = [UUID(), UUID()]
        let codec = InkCodec(profile: .recovery)
        let drawing = try await codec.decode(identities.map { NotebookStroke(id: $0, data: aliased) })
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: data.count)
        XCTAssertEqual(drawing.strokes.map(\.id), identities)
        let before = await codec.workMetrics
        let assets = try await codec.encode(drawing)
        XCTAssertEqual(assets.map(\.id), identities)
        XCTAssertEqual(assets.map(\.data), [data, data])
        XCTAssertEqual(assets.map(\.cachedDigest), [
            NotebookDigest.sha256(data), NotebookDigest.sha256(data)
        ])
        let after = await codec.workMetrics
        XCTAssertEqual(after.copiedArchiveBytes, before.copiedArchiveBytes)
        XCTAssertEqual(after.hashedArchiveBytes, before.hashedArchiveBytes)
        XCTAssertEqual(after.serializedStrokes, before.serializedStrokes)
    }

    func testRecoveryChangedStrokeAndEraseUndoKeepOwnedByteIdentity() async throws {
        let first = stroke()
        let second = stroke(x: 120)
        let codec = InkCodec(profile: .recovery)
        let original = try await codec.encode(PKDrawing(strokes: [first, second]))
        var moved = second
        moved.transform = CGAffineTransform(translationX: 25, y: 30)
        let changed = try await codec.encode(PKDrawing(strokes: [first, moved]))
        XCTAssertEqual(changed[0].data, original[0].data)
        XCTAssertEqual(changed[0].cachedDigest, original[0].cachedDigest)
        let afterChange = await codec.workMetrics
        XCTAssertEqual(afterChange.serializedStrokes, 3)
        _ = try await codec.encode(PKDrawing(strokes: [moved]))
        let restored = try await codec.encode(PKDrawing(strokes: [first, moved]))
        XCTAssertEqual(restored, changed)
        let afterUndo = await codec.workMetrics
        XCTAssertEqual(afterUndo.serializedStrokes, afterChange.serializedStrokes)
        XCTAssertEqual(afterUndo.hashedArchiveBytes, afterChange.hashedArchiveBytes)
        let retiredCount = await codec.retiredStrokeCount
        let retiredBytes = await codec.retiredArchiveBytes
        XCTAssertLessThanOrEqual(retiredCount, 64)
        XCTAssertLessThanOrEqual(retiredBytes, 8 * 1_024 * 1_024)
    }

    private func stroke(id: UUID = UUID(), x: CGFloat = 20) -> PKStroke {
        #if canImport(UIKit)
        let color = UIColor.black
        #else
        let color = NSColor.black
        #endif
        let points = (0..<4).map { index in
            PKStrokePoint(
                location: CGPoint(x: x + CGFloat(index) * 10, y: 40),
                timeOffset: Double(index) * 0.02, size: CGSize(width: 3, height: 3),
                opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
            )
        }
        return PKStroke(
            ink: PKInk(.pen, color: color),
            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_000)),
            transform: .identity, mask: nil, randomSeed: 17,
            id: id, renderGroupID: nil, renderState: nil
        )
    }
}
