import SwiftUI

@MainActor
struct NotebookScreen: View {
    @StateObject private var session = NotebookSession()
    @State private var showsRecoveryCopies = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
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
                        .safeAreaInset(edge: .bottom, spacing: 0) { saveStatus }
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
                    .disabled(session.loadState != .ready)
                    Button {
                        session.extendPaper()
                    } label: {
                        Label("Extend paper", systemImage: "plus")
                    }
                    .disabled(
                        !session.canEdit
                        || session.pageCount >= NotebookViewController.maximumPageCount
                    )
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

    @ViewBuilder
    private var saveStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch session.saveState {
            case .idle:
                Text("Ready")
            case .saving:
                HStack {
                    ProgressView().controlSize(.small)
                    Text(session.inputPaused ? "Catching up on saves…" : "Saving…")
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
                            .disabled(session.isPerformingRecovery)
                    }
                    Button("Preserve recovery copy") {
                        Task { await session.saveRecoveryCopy() }
                    }
                    .disabled(!session.canPreserveRecovery)
                    if session.canReopenSaved {
                        Button("Reopen saved notebook") {
                            Task { await session.reopenSavedNotebook() }
                        }
                    }
                }
            }
            if session.isPerformingRecovery {
                ProgressView("Preserving or opening notebook")
            }
            if let message = session.recoveryMessage { Text(message) }
            if let failure = session.recoveryFailure { Text(failure.title).fontWeight(.semibold) }
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
