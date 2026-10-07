import PencilKit
import UIKit
import XCTest

@MainActor
enum NativeArchiveFixtures {
    static func stroke(id: UUID = UUID(), x: CGFloat = 20) -> PKStroke {
        let points = (0..<4).map { index in
            PKStrokePoint(
                location: CGPoint(x: x + CGFloat(index) * 10, y: 40),
                timeOffset: Double(index) * 0.02,
                size: CGSize(width: 3, height: 3), opacity: 1,
                force: 1, azimuth: 0, altitude: .pi / 2
            )
        }
        return PKStroke(
            ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_000)),
            transform: .identity, mask: nil, randomSeed: 17,
            id: id, renderGroupID: nil, renderState: nil
        )
    }

    enum PointField: String, CaseIterable {
        case location, timeOffset, size, opacity, force, azimuth, altitude
        case secondaryScale, threshold, lateralJitter

        func value(_ point: PKStrokePoint) -> Double {
            switch self {
            case .location: return Double(point.location.x)
            case .timeOffset: return point.timeOffset
            case .size: return Double(point.size.width)
            case .opacity: return Double(point.opacity)
            case .force: return Double(point.force)
            case .azimuth: return Double(point.azimuth)
            case .altitude: return Double(point.altitude)
            case .secondaryScale: return Double(point.secondaryScale)
            case .threshold: return Double(point.threshold)
            case .lateralJitter: return Double(point.lateralJitter)
            }
        }

        func changed(_ stroke: PKStroke) -> PKStroke {
            let points = stroke.path.enumerated().map { index, point in
                guard index == 0 else { return point }
                var location = point.location
                var timeOffset = point.timeOffset
                var size = point.size
                var opacity = point.opacity
                var force = point.force
                var azimuth = point.azimuth
                var altitude = point.altitude
                var secondaryScale = point.secondaryScale
                var threshold = point.threshold
                var lateralJitter = point.lateralJitter
                switch self {
                case .location: location.x += 7
                case .timeOffset: timeOffset += 0.005
                case .size: size.width += 2
                case .opacity: opacity = 0.5
                case .force: force = 0.5
                case .azimuth: azimuth = 0.5
                case .altitude: altitude = 0.7
                case .secondaryScale: secondaryScale = 0.75
                case .threshold: threshold = 0.25
                case .lateralJitter: lateralJitter = 0.25
                }
                return PKStrokePoint(
                    location: location, timeOffset: timeOffset, size: size, opacity: opacity,
                    force: force, azimuth: azimuth, altitude: altitude,
                    secondaryScale: secondaryScale, threshold: threshold, lateralJitter: lateralJitter
                )
            }
            var result = stroke
            result.path = PKStrokePath(
                controlPoints: points, creationDate: stroke.path.creationDate
            )
            return result
        }
    }

    static func changedPath(_ stroke: PKStroke) -> PKStroke {
        var result = stroke
        let points = stroke.path.map { point in
            PKStrokePoint(
                location: CGPoint(x: point.location.x + 7, y: point.location.y),
                timeOffset: point.timeOffset, size: point.size, opacity: point.opacity,
                force: point.force, azimuth: point.azimuth, altitude: point.altitude
            )
        }
        result.path = PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate)
        return result
    }
}

@MainActor
final class NativeArchiveCanvas: NSObject, PKCanvasViewDelegate {
    let window: UIWindow
    let canvas = PKCanvasView()
    private let controller = AppearanceTrackingController()
    private var renderExpectation: XCTestExpectation?
    private var expectedIDs: [UUID] = []

    /// Shows a canvas in its own window, returning once the window's root has appeared.
    init(windowScene: UIWindowScene) async throws {
        window = UIWindow(windowScene: windowScene)
        super.init()
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        window.rootViewController = controller
        controller.loadViewIfNeeded()
        canvas.frame = controller.view.bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.delegate = self
        controller.view.addSubview(canvas)
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        do {
            try await NotebookTestFixtures.waitUntilAppeared(controller)
        } catch {
            close()
            throw error
        }
    }

    func assign(_ drawing: PKDrawing) async {
        let ready = XCTestExpectation(description: "Assigned native drawing finished rendering")
        expectedIDs = drawing.strokes.map(\.id)
        renderExpectation = ready
        canvas.drawing = drawing
        canvas.setNeedsLayout()
        canvas.layoutIfNeeded()
        let result = await XCTWaiter.fulfillment(of: [ready], timeout: NotebookTestFixtures.readinessTimeout)
        XCTAssertEqual(result, .completed)
        renderExpectation = nil
    }

    func canvasViewDidFinishRendering(_ canvasView: PKCanvasView) {
        guard canvasView.drawing.strokes.map(\.id) == expectedIDs,
              let expectation = renderExpectation else { return }
        renderExpectation = nil
        expectation.fulfill()
    }

    func close() {
        renderExpectation = nil
        canvas.delegate = nil
        window.isHidden = true
        window.rootViewController = nil
    }
}
