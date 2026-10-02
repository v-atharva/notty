import SwiftUI

@MainActor
struct NotebookCanvas: UIViewControllerRepresentable {
    @ObservedObject var session: NotebookSession

    func makeUIViewController(context: Context) -> NotebookViewController {
        let controller = NotebookViewController(
            pageCount: session.pageCount,
            initialDrawing: session.initialDrawing
        )
        controller.onCompletedEdit = { [weak session] drawing in
            session?.recordCompletedEdit(drawing) ?? false
        }
        session.snapshotProvider = { [weak controller] in
            controller?.currentDrawing
        }
        controller.setEditingEnabled(session.canEdit)
        return controller
    }

    func updateUIViewController(
        _ controller: NotebookViewController,
        context: Context
    ) {
        controller.setPageCount(session.pageCount)
        controller.setEditingEnabled(session.canEdit)
    }

    static func dismantleUIViewController(
        _ controller: NotebookViewController,
        coordinator: Void
    ) {
        controller.tearDown()
    }
}
