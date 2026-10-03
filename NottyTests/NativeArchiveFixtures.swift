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
    private let controller = UIViewController()
    private var renderExpectation: XCTestExpectation?
    private var expectedIDs: [UUID] = []

    override init() {
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        }
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
    }

    func assign(_ drawing: PKDrawing) async {
        let ready = XCTestExpectation(description: "Assigned native drawing finished rendering")
        expectedIDs = drawing.strokes.map(\.id)
        renderExpectation = ready
        canvas.drawing = drawing
        canvas.setNeedsLayout()
        canvas.layoutIfNeeded()
        let result = await XCTWaiter.fulfillment(of: [ready], timeout: 5)
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
