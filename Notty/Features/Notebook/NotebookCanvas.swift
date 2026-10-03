import SwiftUI

@MainActor
struct NotebookCanvas: UIViewControllerRepresentable {
    let session: NotebookSession
    let pageCount: Int

    init(session: NotebookSession) {
        self.session = session
        self.pageCount = session.pageCount
    }

    func makeUIViewController(context: Context) -> NotebookViewController {
        let seed = session.makeCanvasSeed()
        let controller = NotebookViewController(
            pageCount: seed.pageCount, initialDrawing: seed.drawing
        )
        controller.onObservation = { [weak session] observation in
            guard let session else { return .readOnly }
            session.recordObservation(observation, ownerID: seed.ownerID)
            return session.inputGateForCanvas(ownerID: seed.ownerID)
        }
        session.attachCanvas(
            ownerID: seed.ownerID,
            observations: { [weak controller] in controller?.captureBarrier() },
            applyInputGate: { [weak controller] in controller?.setInputGate($0) }
        )
        controller.onDetach = { [weak session] in
            session?.detachCanvas(ownerID: seed.ownerID)
        }
        controller.setInputGate(session.inputGate)
        return controller
    }

    func updateUIViewController(_ controller: NotebookViewController, context: Context) {
        session.renderDiagnostics.canvasUpdateCount += 1
        controller.setPageCount(pageCount)
    }

    static func dismantleUIViewController(
        _ controller: NotebookViewController, coordinator: Void
    ) {
        controller.tearDown()
    }
}
