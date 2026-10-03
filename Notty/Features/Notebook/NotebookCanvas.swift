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
            session?.recordCompletedEdit(drawing, ownerID: seed.ownerID) ?? false
        }
        session.attachCanvas(ownerID: seed.ownerID) { [weak controller] in
            controller?.currentDrawing
        }
        controller.onDetach = { [weak session] in
            session?.detachCanvas(ownerID: seed.ownerID)
        }
        controller.setEditingEnabled(session.canEdit)
        return controller
    }

    func updateUIViewController(_ controller: NotebookViewController, context: Context) {
        controller.setPageCount(session.pageCount)
        controller.setEditingEnabled(session.canEdit)
    }

    static func dismantleUIViewController(
        _ controller: NotebookViewController, coordinator: Void
    ) {
        controller.tearDown()
    }
}
