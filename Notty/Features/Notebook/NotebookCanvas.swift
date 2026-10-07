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
        controller.canPerformHistoryAction = { [weak session] in
            session?.canPerformHistoryAction(ownerID: seed.ownerID) ?? false
        }
        controller.reserveHistoryAction = { [weak session] in
            session?.reserveHistoryAction(ownerID: seed.ownerID) ?? false
        }
        controller.onUndoAvailabilityChange = { [weak session] availability in
            session?.updateUndoAvailability(availability, ownerID: seed.ownerID)
        }
        controller.onToolCompletion = { [weak session] completion in
            session?.completedTool(completion, ownerID: seed.ownerID)
        }
        controller.onInteractionInterrupted = { [weak session] in
            session?.cancelCanvasToolCompletion(ownerID: seed.ownerID)
            // A canvas leaving mid-stroke never reports the stroke's end.
            session?.writingChrome.toolCancelled()
        }
        controller.onPaperReplacement = { [weak session] observation, pageCount in
            guard let session else { return .readOnly }
            session.recordPaperReplacement(observation, pageCount: pageCount, ownerID: seed.ownerID)
            return session.inputGateForCanvas(ownerID: seed.ownerID)
        }
        controller.onAddPage = { [weak session] in session?.extendPaper() }
        session.attachCanvas(
            ownerID: seed.ownerID,
            observations: { [weak controller] in controller?.captureBarrier() },
            applyInputGate: { [weak controller] in controller?.setInputGate($0) },
            controls: NotebookCanvasControls(
                undo: { [weak controller] in controller?.performUndo() },
                redo: { [weak controller] in controller?.performRedo() },
                setPaletteSuppressed: { [weak controller] in controller?.setPaletteSuppressed($0) },
                applyPageCount: { [weak controller] in controller?.setPageCount($0) },
                applyRequestedPageCount: { [weak controller] in controller?.setPageCount($0, bringingIntoView: true) },
                deletePage: { [weak controller] in controller?.deletePage($0) ?? false },
                mostVisiblePage: { [weak controller] in controller?.mostVisiblePage },
                currentAvailability: { [weak controller] in controller?.currentUndoAvailability ?? .unavailable },
                retire: { [weak controller] in controller?.tearDown() }
            )
        )
        controller.onDetach = { [weak session] in
            session?.detachCanvas(ownerID: seed.ownerID)
        }
        controller.writingChrome = session.writingChrome
        controller.setInputGate(session.inputGate)
        return controller
    }

    func updateUIViewController(_ controller: NotebookViewController, context: Context) {
        update(
            controller, chrome: context.environment.notebookCanvasChrome,
            toolbarStore: context.environment.notebookToolbarStore
        )
    }

    /// Brings `controller` up to date with the session and with the chrome and toolbar its host draws.
    func update(
        _ controller: NotebookViewController, chrome: NotebookCanvasChrome, toolbarStore: NotebookSceneToolStore?
    ) {
        session.renderDiagnostics.canvasUpdateCount += 1
        // The stored count makes a change of it update the canvas, but the session's own count is
        // applied: a value kept from before a page deletion would grow the paper back.
        controller.setPageCount(session.pageCount)
        controller.applyChrome(chrome)
        controller.placeUnderToolbar(of: toolbarStore)
        session.writingChrome.attach(to: toolbarStore)
    }

    static func dismantleUIViewController(
        _ controller: NotebookViewController, coordinator: Void
    ) {
        controller.tearDown()
    }
}
