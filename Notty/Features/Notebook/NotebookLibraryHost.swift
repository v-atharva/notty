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
                ProgressView("Opening library")
            case .creatingFirstNotebook:
                if let failure = model.creationFailure {
                    ContentUnavailableView {
                        Label("Couldn't create your first notebook", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(failure.message)
                    } actions: {
                        Button("Try again") { Task { await model.retry() } }
                            .disabled(model.isCreating)
                    }
                } else {
                    ProgressView("Creating your first notebook")
                }
            case .notebook(let session):
                NotebookScreen(session: session, startNewNotebook: {
                    await model.startNewNotebook()
                })
                .id(session.notebookID)
                .overlay(alignment: .top) {
                    if let failure = model.creationFailure {
                        Text("The new notebook could not be selected. \(failure.message)")
                            .font(.callout)
                            .padding()
                            .background(.regularMaterial)
                    }
                }
            case .recoveryRequired:
                ContentUnavailableView {
                    Label("Retained notebooks need recovery", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Your existing notebooks and recovery copies will be kept. You can start a separate notebook.")
                    if let failure = model.creationFailure { Text(failure.message) }
                } actions: {
                    Button("Start new notebook and keep retained files") {
                        Task { await model.startNewNotebook() }
                    }
                    .disabled(model.isCreating)
                    Button("Check library again") { Task { await model.retry() } }
                        .disabled(model.isCreating)
                }
            case .failed(let failure):
                ContentUnavailableView {
                    Label("Couldn't open library", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure.message)
                    Text("Your retained files have not been replaced.")
                } actions: {
                    Button("Try again") { Task { await model.retry() } }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Every state sits on the editor's light paper, so opening never flashes the system appearance.
        .background { NotebookTheme.paperIvory.color.ignoresSafeArea() }
        .preferredColorScheme(.light)
        .task { await model.load() }
    }
}
