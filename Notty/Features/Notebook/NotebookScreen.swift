import SwiftUI

@MainActor
struct NotebookScreen: View {
    @StateObject private var session: NotebookSession

    init(session: NotebookSession = NotebookSession()) {
        _session = StateObject(wrappedValue: session)
    }
    @State private var showsRecoveryCopies = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let _ = session.renderDiagnostics.screenBodyCount += 1
        NavigationStack {
            Group {
                switch session.loadState {
                case .loading:
                    ProgressView("Opening notebook")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let failure):
                    ContentUnavailableView {
                        Label("Couldn't open notebook", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(failure.message)
                    } actions: {
                        Button("Try opening again") { Task { await session.load() } }
                    }
                case .ready:
                    NotebookCanvas(session: session)
                        .id(session.canvasGeneration)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            NotebookSaveStatusView(session: session, model: session.statusModel)
                        }
                }
            }
            .background(Color(red: 0.98, green: 0.96, blue: 0.91))
            .navigationTitle(session.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("notty")
                        .font(.system(.title3, design: .serif, weight: .semibold))
                        .foregroundStyle(Color(red: 0.28, green: 0.23, blue: 0.18))
                        .accessibilityLabel("Notty")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showsRecoveryCopies = true
                    } label: {
                        Label("Recovery copies", systemImage: "clock.arrow.circlepath")
                    }
                    NotebookIntegrityIndicator(session: session, model: session.integrityModel)
                    NotebookExtendPaperButton(session: session, model: session.gateModel)
                }
            }
        }
        .tint(Color(red: 0.36, green: 0.29, blue: 0.22))
        .preferredColorScheme(.light)
        .sheet(isPresented: $showsRecoveryCopies) { NotebookRecoveryView(session: session) }
        .task { await session.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.flush() }
        }
        .onDisappear { session.flush() }
    }

}

@MainActor
private struct NotebookExtendPaperButton: View {
    let session: NotebookSession
    @ObservedObject var model: NotebookCanvasGateModel

    var body: some View {
        Button(action: session.extendPaper) {
            Label("Extend paper", systemImage: "plus")
        }
        .disabled(
            !model.state.inputGate.allowsMutation
            || model.state.pageCount >= NotebookViewController.maximumPageCount
        )
    }
}

@MainActor
private struct NotebookSaveStatusView: View {
    let session: NotebookSession
    @ObservedObject var model: NotebookSavePresentationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.state.status {
            case .idle:
                Text("Ready")
            case .saving:
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.state.inputPaused ? "Catching up on saves…" : "Saving…")
                }
            case .saved(let date):
                Label("Saved \(date.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle")
            case .failed(let cause):
                Label(cause.title, systemImage: "exclamationmark.triangle").fontWeight(.semibold)
                Text(cause.message)
                Text("Writing is paused. You can scroll and zoom.")
                HStack(spacing: 16) {
                    if cause.canRetry {
                        Button("Retry save", action: session.retrySave)
                            .disabled(model.state.performingRecovery)
                    }
                    Button("Preserve recovery copy") {
                        Task { await session.saveRecoveryCopy() }
                    }
                    .disabled(!model.state.canPreserveRecovery)
                    if model.state.canReopenSaved {
                        Button("Reopen saved notebook") {
                            Task { await session.reopenSavedNotebook() }
                        }
                    }
                }
            }
            if model.state.performingRecovery {
                ProgressView("Preserving or opening notebook")
            }
            if let message = model.state.recoveryMessage { Text(message) }
            if let failure = model.state.recoveryFailure { Text(failure.title).fontWeight(.semibold) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.footnote)
        .foregroundStyle(Color(red: 0.28, green: 0.23, blue: 0.18))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(red: 0.98, green: 0.96, blue: 0.91))
        .accessibilityElement(children: .contain)
    }
}

@MainActor
private struct NotebookIntegrityIndicator: View {
    let session: NotebookSession
    @ObservedObject var model: NotebookIntegrityPresentationModel
    @State private var showsDetails = false

    var body: some View {
        Button {
            showsDetails = true
        } label: {
            Group {
                switch model.state {
                case .checking:
                    ProgressView().controlSize(.small)
                case .verified:
                    Image(systemName: "checkmark.shield")
                case .damaged:
                    Image(systemName: "exclamationmark.shield")
                case .incomplete:
                    Image(systemName: "questionmark.circle")
                case nil:
                    Image(systemName: "checkmark.shield").hidden()
                }
            }
            .frame(width: 28, height: 28)
        }
        .disabled(model.state == nil)
        .accessibilityLabel(model.state?.label ?? "Notebook history")
        .accessibilityHidden(model.state == nil)
        .popover(isPresented: $showsDetails) {
            NotebookIntegrityDetails(session: session, integrity: model, saves: session.statusModel)
        }
        .onChange(of: model.state) { _, state in
            guard let state, state != .checking else { return }
            AccessibilityNotification.Announcement(state.label).post()
        }
    }
}

@MainActor
private struct NotebookIntegrityDetails: View {
    let session: NotebookSession
    @ObservedObject var integrity: NotebookIntegrityPresentationModel
    @ObservedObject var saves: NotebookSavePresentationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let state = integrity.state {
                Text(state.label).font(.headline)
                Text(state.detail)
                if case .damaged = state {
                    Button("Preserve recovery copy") {
                        Task { await session.saveRecoveryCopy() }
                    }
                    .disabled(!saves.state.canPreserveRecovery)
                    if saves.state.canReopenSaved {
                        Button("Reopen saved notebook") {
                            Task { await session.reopenSavedNotebook() }
                        }
                    }
                }
                if let message = saves.state.recoveryMessage { Text(message) }
                if let failure = saves.state.recoveryFailure { Text(failure.message) }
            }
        }
        .padding(20)
        .frame(idealWidth: 320, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
