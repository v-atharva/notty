import SwiftUI

@MainActor
struct NotebookCanvas: UIViewControllerRepresentable {
    @ObservedObject var session: NotebookSession

    func makeUIViewController(context: Context) -> NotebookViewController {
        let seed = session.makeCanvasSeed()
        let controller = NotebookViewController(
            pageCount: seed.pageCount, initialDrawing: seed.drawing
        )
        controller.onCompletedEdit = { [weak session] drawing in
            guard let session else { return .readOnly }
            session.recordCompletedEdit(drawing, ownerID: seed.ownerID)
            return session.inputGateForCanvas(ownerID: seed.ownerID)
        }
        session.attachCanvas(ownerID: seed.ownerID) { [weak controller] in
            controller?.currentDrawing
        }
        controller.onDetach = { [weak session] in
            session?.detachCanvas(ownerID: seed.ownerID)
        }
        controller.setInputGate(session.inputGate)
        return controller
    }

    func updateUIViewController(_ controller: NotebookViewController, context: Context) {
        controller.setPageCount(session.pageCount)
        let gate = session.inputGate
        if controller.inputGate != gate { controller.setInputGate(gate) }
    }

    static func dismantleUIViewController(
        _ controller: NotebookViewController, coordinator: Void
    ) {
        controller.tearDown()
    }
}
