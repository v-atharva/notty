import SwiftUI

@MainActor
struct NotebookScreen: View {
    @StateObject private var session = NotebookSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                switch session.loadState {
                case .loading:
                    ProgressView("Opening notebook")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed:
                    ContentUnavailableView {
                        Label("Couldn't open notebook", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("Your saved files have not been replaced.")
                    } actions: {
                        Button("Retry") {
                            Task { await session.load() }
                        }
                    }
                case .ready:
                    NotebookCanvas(session: session)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            saveStatus
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
                ToolbarItem(placement: .topBarTrailing) {
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
        .task { await session.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.flush() }
        }
        .onDisappear { session.flush() }
    }

    @ViewBuilder
    private var saveStatus: some View {
        HStack(spacing: 10) {
            switch session.saveState {
            case .idle:
                Text("Ready")
            case .saving:
                ProgressView()
                    .controlSize(.small)
                Text(session.inputPaused ? "Catching up on saves…" : "Saving…")
            case .saved(let date):
                Image(systemName: "checkmark.circle")
                Text("Saved \(date.formatted(date: .omitted, time: .shortened))")
            case .failed:
                Image(systemName: "exclamationmark.triangle")
                Text("Changes are waiting to save.")
                Spacer(minLength: 8)
                Button("Retry", action: session.retrySave)
            }
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .foregroundStyle(Color(red: 0.28, green: 0.23, blue: 0.18))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(red: 0.98, green: 0.96, blue: 0.91))
        .accessibilityElement(children: .contain)
    }
}
