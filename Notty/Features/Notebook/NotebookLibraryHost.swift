import Combine
import Foundation
import NottyCore
import SwiftUI

@MainActor
final class NotebookLibraryModel: ObservableObject {
    enum State {
        case loading
        case creatingFirstNotebook
        case notebook(NotebookSession)
        case recoveryRequired
        case failed(NotebookSaveFailure)
    }

    @Published private(set) var state = State.loading
    @Published private(set) var isCreating = false
    @Published private(set) var creationFailure: NotebookSaveFailure?
    private let openLibrary: @Sendable () async throws -> NotebookLibraryAccess
    private let makeNotebookID: @Sendable () -> UUID
    private let legacyNotebookID: UUID
    private let beforeSelection: (@Sendable () async throws -> Void)?
    private var library: NotebookLibraryAccess?
    private var selection: NotebookSelectionToken?
    private var operationID = UUID()
    private var started = false

    init(
        legacyNotebookID: UUID = NotebookSession.defaultNotebookID,
        openLibrary: @escaping @Sendable () async throws -> NotebookLibraryAccess = {
            try await NotebookLibraryAccess.shared()
        },
        makeNotebookID: @escaping @Sendable () -> UUID = { UUID() },
        beforeSelection: (@Sendable () async throws -> Void)? = nil
    ) {
        self.legacyNotebookID = legacyNotebookID
        self.openLibrary = openLibrary
        self.makeNotebookID = makeNotebookID
        self.beforeSelection = beforeSelection
    }

    func load() async {
        guard !started, !isCreating else { return }
        started = true
        let operation = UUID()
        operationID = operation
        state = .loading
        creationFailure = nil
        selection = nil
        do {
            let access = try await openLibrary()
            guard operationID == operation, !Task.isCancelled else { return }
            library = access
            let selected = try await access.readSelection(legacyNotebookID: legacyNotebookID)
            guard operationID == operation, !Task.isCancelled else { return }
            switch selected {
            case .selected(let id, let token):
                selection = token
                installSession(id: id, library: access)
            case .empty(let token):
                selection = token
                state = .creatingFirstNotebook
                await startNewNotebook()
            case .recoveryRequired(let token):
                selection = token
                state = .recoveryRequired
            }
        } catch {
            guard operationID == operation else { return }
            selection = nil
            state = .failed(NotebookSaveFailure.classify(error))
        }
    }

    func retry() async {
        guard !isCreating else { return }
        switch state {
        case .failed, .recoveryRequired, .creatingFirstNotebook: break
        case .loading, .notebook: return
        }
        started = false
        await load()
    }

    func startNewNotebook() async {
        guard !isCreating, let library, let selection else { return }
        let previousSession: NotebookSession?
        let transitionID: UUID?
        switch state {
        case .notebook(let session):
            guard let transition = session.beginNewNotebookTransition() else { return }
            previousSession = session
            transitionID = transition
        case .recoveryRequired, .creatingFirstNotebook:
            previousSession = nil
            transitionID = nil
        case .loading, .failed:
            return
        }
        let operation = UUID()
        operationID = operation
        isCreating = true
        creationFailure = nil
        let id = makeNotebookID()
        let stamp = NotebookEditStamp(
            capturedAt: Date(), uptime: ProcessInfo.processInfo.systemUptime, sessionID: UUID()
        )
        defer {
            if let previousSession, let transitionID {
                previousSession.endNewNotebookTransition(transitionID)
            }
            if operationID == operation { isCreating = false }
        }
        let beforeSelection = self.beforeSelection
        do {
            let selected = try await library.createAndSelectNotebook(
                id: id, expectedSelection: selection, stamp: stamp,
                beforeSelection: {
                    try await beforeSelection?()
                    if let previousSession, let transitionID {
                        try await previousSession.prepareNewNotebookSelection(transitionID: transitionID)
                    }
                }
            )
            // Selection is already durable; reflect that outcome even if this task was cancelled.
            guard operationID == operation else { return }
            guard case .selected(let selectedID, let token) = selected, selectedID == id else {
                creationFailure = .revisionConflict
                return
            }
            self.selection = token
            installSession(id: id, library: library)
        } catch {
            guard operationID == operation else { return }
            creationFailure = NotebookSaveFailure.classify(error)
        }
    }

    /// Hides the notice that a new notebook could not be selected. The open notebook is not
    /// affected; a later attempt reports its own outcome.
    func dismissCreationFailure() {
        guard case .notebook = state, !isCreating else { return }
        creationFailure = nil
    }

    private func installSession(id: UUID, library: NotebookLibraryAccess) {
        let session = NotebookSession(
            notebookID: id, openStorage: { await library.storage(notebookID: id, requiresExistingCommit: true) }
        )
        state = .notebook(session)
    }
}

@MainActor
struct NotebookLibraryHost: View {
    @StateObject private var model: NotebookLibraryModel

    init(model: NotebookLibraryModel = NotebookLibraryModel()) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                NotebookStatusCard(loading: "Opening library")
                    .centredOnPaper()
            case .creatingFirstNotebook:
                if let failure = model.creationFailure {
                    NotebookStatusCard(title: "Couldn't create your first notebook", message: failure.message) {
                        Button("Try again") { Task { await model.retry() } }
                            .disabled(model.isCreating)
                    }
                    .centredOnPaper()
                } else {
                    NotebookStatusCard(loading: "Creating your first notebook")
                        .centredOnPaper()
                }
            case .notebook(let session):
                NotebookScreen(session: session, startNewNotebook: {
                    await model.startNewNotebook()
                })
                .id(session.notebookID)
                .overlay(alignment: .top) {
                    if let failure = model.creationFailure {
                        selectionFailureBanner(failure)
                    }
                }
            case .recoveryRequired:
                NotebookStatusCard(
                    title: "Retained notebooks need recovery",
                    message: Self.lines(
                        "Your existing notebooks and recovery copies will be kept. You can start a separate notebook.",
                        model.creationFailure?.message
                    )
                ) {
                    Button("Start new notebook and keep retained files") {
                        Task { await model.startNewNotebook() }
                    }
                    .disabled(model.isCreating)
                } secondary: {
                    Button("Check library again") { Task { await model.retry() } }
                        .disabled(model.isCreating)
                }
                .centredOnPaper()
            case .failed(let failure):
                NotebookStatusCard(
                    title: "Couldn't open library",
                    message: Self.lines(failure.message, "Your retained files have not been replaced.")
                ) {
                    Button("Try again") { Task { await model.retry() } }
                }
                .centredOnPaper()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Every state sits on the editor's light paper, so opening never flashes the system appearance.
        .background { NotebookTheme.paperIvory.color.ignoresSafeArea() }
        .preferredColorScheme(.light)
        .task { await model.load() }
    }

    /// The notice that a new notebook could not be selected. It lies over the top of the open
    /// notebook, so it can be dismissed to uncover the controls beneath it.
    private func selectionFailureBanner(_ failure: NotebookSaveFailure) -> some View {
        HStack(spacing: 0) {
            Text("The new notebook could not be selected. \(failure.message)")
                .font(.callout)
                .foregroundStyle(NotebookTheme.glyph.color)
                .padding([.vertical, .leading], NotebookTheme.popoverPadding)
            Button {
                model.dismissCreationFailure()
            } label: {
                Image(systemName: "xmark")
                    .font(.callout.weight(.semibold))
                    .frame(width: NotebookTheme.controlSize, height: NotebookTheme.controlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NotebookKeyStyle())
            .accessibilityLabel("Dismiss")
            .help("Dismiss")
            // Inset like a readout cell in the tray, so a pressed well stays clear of the shell's edge.
            .padding(.trailing, NotebookTheme.readoutInset)
        }
        .background { NotebookPanelShell(cornerRadius: NotebookTheme.compactPanelCornerRadius) }
        .frame(maxWidth: NotebookTheme.statusCardMaxWidth)
        .padding([.top, .horizontal], NotebookTheme.sectionSpacing)
    }

    /// Separate statements of a card's message, one per line.
    private static func lines(_ lines: String?...) -> String {
        lines.compactMap { $0 }.joined(separator: "\n")
    }
}

private extension View {
    /// Centres a status card on the paper, scrolling it when a large text size makes it taller
    /// than the screen. The padding keeps the card's shadow clear of the edges.
    func centredOnPaper() -> some View {
        ViewThatFits(in: .vertical) {
            padding(NotebookTheme.detailPadding)
            ScrollView {
                padding(NotebookTheme.detailPadding)
            }
        }
    }
}
