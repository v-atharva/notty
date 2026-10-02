import SwiftUI

@MainActor
struct NotebookCanvas: UIViewControllerRepresentable {
    @Binding var pageCount: Int

    init(pageCount: Binding<Int>) {
        _pageCount = pageCount
    }

    func makeUIViewController(context: Context) -> NotebookViewController {
        NotebookViewController(pageCount: pageCount)
    }

    func updateUIViewController(_ controller: NotebookViewController, context: Context) {
        controller.setPageCount(pageCount)
    }

    static func dismantleUIViewController(_ controller: NotebookViewController, coordinator: Void) {
        controller.tearDown()
    }
}
