import Darwin
import Foundation
import PencilKit
import XCTest
@testable import NottyCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class NotebookRecoveryCapacityTests: XCTestCase {
    func testEightPendingTenThousandStrokeEditsPreserveExactOrderedContentAndProvenance() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = largeBatch()
        XCTAssertEqual(batch.edits.count, 8)
        XCTAssertTrue(batch.edits.allSatisfy { $0.strokeIDs.count == 10_000 })
        let beforeRSS = try processPeakResidentBytes()
        let store = try NotebookRecoveryStore(rootURL: root)
        let receipt = try await store.preserve(batch)
        let reopened = try NotebookRecoveryStore(rootURL: root)
        let loaded = try await reopened.load(id: receipt.id)
        let afterRSS = try processPeakResidentBytes()
        XCTAssertEqual(loaded, batch)
        XCTAssertEqual(receipt.editCount, 8)
        XCTAssertEqual(loaded.edits.map(\.id), batch.edits.map(\.id))
        XCTAssertEqual(loaded.edits.map(\.stamp), batch.edits.map(\.stamp))
        for (actual, expected) in zip(loaded.edits, batch.edits) {
            XCTAssertEqual(actual.strokeIDs, expected.strokeIDs)
            XCTAssertEqual(actual.drawingData, expected.drawingData)
            XCTAssertEqual(actual.title, expected.title)
            XCTAssertEqual(actual.pageCount, expected.pageCount)
        }
        let directory = root.appendingPathComponent(receipt.id.uuidString.lowercased(), isDirectory: true)
        let manifestBytes = try Data(contentsOf: directory.appendingPathComponent("manifest.json")).count
        XCTAssertLessThan(manifestBytes, 256 * 1_024)
        let archiveBytes = batch.edits.reduce(0) { $0 + $1.drawingData.count }
        let identityBytes = 8 * 10_000 * 16
        try writeMetrics([
            "manifestBytes": manifestBytes, "identityBytes": identityBytes,
            "archiveBytes": archiveBytes, "editCount": 8, "strokeCount": 10_000,
            "processPeakRSSBeforeBytes": beforeRSS, "processPeakRSSAfterBytes": afterRSS
        ])
    }

    private func largeBatch() -> NotebookRecoveryBatch {
        let template = stroke()
        let originals = (0..<10_000).map { _ in
            var copy = template
            copy.id = UUID()
            return copy
        }
        let sessionID = UUID()
        let edits = (0..<8).map { index in
            var strokes = originals
            strokes[index].transform = CGAffineTransform(translationX: CGFloat(index + 1), y: 10)
            let drawing = PKDrawing(strokes: strokes)
            return NotebookRecoveryEdit(
                id: UUID(), drawingData: drawing.dataRepresentation(),
                strokeIDs: drawing.strokes.map(\.id),
                title: String(repeating: "t", count: 4_096), pageCount: 12,
                stamp: NotebookEditStamp(
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                    uptime: Double(index), sessionID: sessionID
                )
            )
        }
        return NotebookRecoveryBatch(notebookID: UUID(), baseRevisionID: UUID(), edits: edits)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func stroke() -> PKStroke {
        #if canImport(UIKit)
        let color = UIColor.black
        #else
        let color = NSColor.black
        #endif
        let points = (0..<4).map { index in
            PKStrokePoint(
                location: CGPoint(x: CGFloat(index) * 10, y: 40),
                timeOffset: Double(index) * 0.02, size: CGSize(width: 3, height: 3),
                opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
            )
        }
        return PKStroke(
            ink: PKInk(.pen, color: color),
            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_000))
        )
    }

    private func processPeakResidentBytes() throws -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw NotebookRepositoryError.ioFailure(errno)
        }
        return Int64(usage.ru_maxrss)
    }

    private func writeMetrics(_ metrics: [String: Any]) throws {
        guard let path = ProcessInfo.processInfo.environment["NOTTY_RECOVERY_METRICS_DIRECTORY"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys, .prettyPrinted])
            .write(to: directory.appendingPathComponent("recovery-8-edits-10000-strokes.json"), options: .atomic)
    }
}
