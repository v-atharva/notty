import Foundation
import SwiftUI

@MainActor
struct NotebookScreen: View {
    @StateObject private var session: NotebookSession

    private let startNewNotebook: (@MainActor () async -> Void)?

    init(
        session: NotebookSession = NotebookSession(),
        startNewNotebook: (@MainActor () async -> Void)? = nil
    ) {
        _session = StateObject(wrappedValue: session)
        self.startNewNotebook = startNewNotebook
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
                        .background(NotebookTheme.paperIvory.color)
                case .failed(let failure):
                    ContentUnavailableView {
                        Label("Couldn't open notebook", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(failure.message)
                    } actions: {
                        Button("Try opening again") { Task { await session.load() } }
                        if let startNewNotebook {
                            Button("Start new notebook and keep this one") {
                                Task { await startNewNotebook() }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NotebookTheme.paperIvory.color)
                case .ready:
                    NotebookToolbarHost(extendsCanvasUnderChrome: true) {
                        NotebookCanvas(session: session)
                            .id(session.canvasGeneration)
                    }
                }
            }
            .background { NotebookTheme.paperIvory.color.ignoresSafeArea() }
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .navigationTitle(session.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    ForEach(NotebookUpcomingFeature.placed(.navigationLeading)) { feature in
                        NotebookUpcomingBarButton(feature: feature)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Text("notty")
                        .font(NotebookTheme.wordmark.font)
                        .foregroundStyle(NotebookTheme.glyph.color)
                        // The leading bar items share their width; the wordmark is never truncated.
                        .fixedSize()
                        .accessibilityLabel("Notty")
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .principal) {
                    Text(session.title)
                        .font(NotebookTheme.noteTitle.font)
                        .foregroundStyle(NotebookTheme.glyph.color)
                        .lineLimit(1)
                        // The typewriter face runs wide; shrink a little before truncating.
                        .minimumScaleFactor(0.85)
                        .layoutPriority(1)
                        .accessibilityAddTraits(.isHeader)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NotebookHistoryButtons(session: session, model: session.commandModel)
                    NotebookRecoveryCopiesButton(session: session, model: session.commandModel) {
                        showsRecoveryCopies = true
                    }
                    NotebookSaveStatusView(session: session, model: session.statusModel)
                    NotebookLimitsIndicator(model: session.limitsModel)
                    NotebookIntegrityIndicator(session: session, model: session.integrityModel)
                    NotebookExtendPaperButton(session: session, model: session.gateModel)
                }
                // Its own capsule, apart from the working actions.
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    NotebookUpcomingMenu()
                }
            }
        }
        .tint(NotebookTheme.controlTint.color)
        .preferredColorScheme(.light)
        .toolbarColorScheme(.light, for: .statusBar)
        .sheet(isPresented: $showsRecoveryCopies, onDismiss: session.endRecoveryCopiesPresentation) {
            NotebookRecoveryView(session: session)
        }
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
private struct NotebookHistoryButtons: View {
    let session: NotebookSession
    @ObservedObject var model: NotebookCanvasCommandModel

    var body: some View {
        HStack(spacing: 12) {
            Button(action: session.undo) {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.state.canUndo)
            Button(action: session.redo) {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!model.state.canRedo)
        }
    }
}

@MainActor
private struct NotebookRecoveryCopiesButton: View {
    let session: NotebookSession
    @ObservedObject var model: NotebookCanvasCommandModel
    let present: () -> Void

    var body: some View {
        Button {
            guard session.beginRecoveryCopiesPresentation() else { return }
            present()
        } label: {
            Label("Recovery copies", systemImage: "clock.arrow.circlepath")
        }
        .disabled(!model.state.canOpenRecoveryCopies)
    }
}

@MainActor
private struct NotebookSaveStatusView: View {
    let session: NotebookSession
    @ObservedObject var model: NotebookSavePresentationModel
    @State private var showsDetails = false

    /// Captions seen while writing; the slot fits the widest so the capsule holds still on every save.
    private static let steadyCaptions = ["Ready", "Saving", "Saved"]

    private var caption: String {
        guard model.state.isReady else { return "Not ready" }
        if model.state.performingRecovery { return "Recovery" }
        if model.state.recoveryFailure != nil { return "Recovery failed" }
        switch model.displayedStatus {
        case .idle: return "Ready"
        case .saving: return "Saving"
        case .saved: return "Saved"
        case .failed: return "Save failed"
        }
    }

    private var symbol: String {
        if model.state.recoveryFailure != nil { return "exclamationmark.triangle" }
        switch model.displayedStatus {
        case .idle: return "doc"
        case .saving: return "arrow.up.doc"
        case .saved: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    var body: some View {
        Button { showsDetails = true } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .frame(width: 18)
                // Rarer, longer captions widen the slot rather than being cut off.
                ZStack(alignment: .leading) {
                    ForEach(Self.steadyCaptions, id: \.self) { Text($0).hidden() }
                    Text(caption)
                }
                .lineLimit(1)
            }
            .font(.caption)
            // The inherited tint is too faint for caption text on the glass capsule.
            .foregroundStyle(NotebookTheme.glyph.color)
            .frame(height: 28)
        }
        .accessibilityLabel(caption + ". Notebook save details")
        .popover(isPresented: $showsDetails) {
            NotebookSaveDetails(session: session, model: model)
        }
    }
}

@MainActor
private struct NotebookSaveDetails: View {
    let session: NotebookSession
    @ObservedObject var model: NotebookSavePresentationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.state.status {
            case .idle:
                Text("Ready").font(.headline)
            case .saving:
                Text(model.state.inputPaused ? "Catching up on saves" : "Saving").font(.headline)
            case .saved(let date):
                Text("Saved").font(.headline)
                Text(date.formatted(date: .abbreviated, time: .standard))
            case .failed(let cause):
                Text(cause.title).font(.headline)
                Text(cause.message)
                Text("Writing is paused. You can scroll and zoom.")
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
            if model.state.performingRecovery { Text("Preserving or opening notebook") }
            if let message = model.state.recoveryMessage { Text(message) }
            if let failure = model.state.recoveryFailure {
                Text(failure.title).fontWeight(.semibold)
                Text(failure.message)
            }
        }
        .font(.footnote)
        .padding(20)
        .frame(idealWidth: 320, alignment: .leading)
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


@MainActor
private struct NotebookLimitsIndicator: View {
    @ObservedObject var model: NotebookLimitsPresentationModel
    @State private var showsDetails = false

    var body: some View {
        // Present only near the limit, so the bar does not reserve an empty slot the rest of the time.
        if model.state.isNearLimit {
            Button {
                showsDetails = true
            } label: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("Notebook nearing save limit")
            .popover(isPresented: $showsDetails) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Notebook nearing save limit").font(.headline)
                    Text("This drawing contains \(model.state.strokeCount) of 10,000 supported strokes.")
                    if let bytes = model.state.encodedBytes {
                        Text("Its most recent encoding uses \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)) of 64 MiB.")
                    }
                    Text("If an edit exceeds the save limit, preserve a recovery copy before reopening. Larger preserved states remain available for inspection.")
                }
                .padding()
                .frame(maxWidth: 320)
            }
        }
    }
}
