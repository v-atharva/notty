import Foundation
import NottyCore
import SwiftUI

@MainActor
struct NotebookScreen: View {
    /// Room the toolbar host keeps below the top safe area for the header, so a docked toolbar sits
    /// just below the header and stays put when the header leaves.
    static let headerReservation = NotebookTheme.headerTopGap + NotebookTheme.headerHeight
        + NotebookTheme.headerToolbarGap - EditorToolbarLayout.margin

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
        // Kept for the future library; the editor draws its own header in place of the bar.
        NavigationStack {
            Group {
                switch session.loadState {
                case .loading:
                    NotebookStatusCard(loading: "Opening notebook")
                        .padding(NotebookTheme.detailPadding)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let failure):
                    NotebookStatusCard(title: "Couldn't open notebook", message: failure.message) {
                        Button("Try opening again") { Task { await session.load() } }
                    } secondary: {
                        if let startNewNotebook {
                            Button("Start new notebook and keep this one") {
                                Task { await startNewNotebook() }
                            }
                        }
                    }
                    .padding(NotebookTheme.detailPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready:
                    editor
                }
            }
            .background { NotebookTheme.paperIvory.color.ignoresSafeArea() }
            .toolbar(.hidden, for: .navigationBar)
            .navigationTitle(session.title)
        }
        .tint(NotebookTheme.controlTint.color)
        .preferredColorScheme(.light)
        .toolbarColorScheme(.light, for: .statusBar)
        .sheet(isPresented: $showsRecoveryCopies, onDismiss: session.endRecoveryCopiesPresentation) {
            NotebookRecoveryView(session: session)
        }
        .notebookChromePresentation(showsRecoveryCopies, chrome: session.writingChrome)
        .task { await session.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.flush() }
        }
        .onDisappear { session.flush() }
    }

    private var editor: some View {
        ZStack(alignment: .top) {
            NotebookToolbarHost(extendsCanvasUnderChrome: true, topReservation: Self.headerReservation) {
                NotebookCanvas(session: session)
                    .id(session.canvasGeneration)
            }
            NotebookHeaderHost(session: session, openRecoveryCopies: openRecoveryCopies)
                .frame(height: NotebookTheme.headerTopGap + NotebookTheme.headerHeight)
                .padding(.horizontal, NotebookTheme.headerSideInset)
                // The header is read first, then the toolbar, then the page.
                .accessibilitySortPriority(2)
        }
        .background { NotebookWritingCommands(chrome: session.writingChrome) }
    }

    private func openRecoveryCopies() {
        guard session.beginRecoveryCopiesPresentation() else { return }
        showsRecoveryCopies = true
    }
}

/// The writing view's keyboard commands and its home-indicator preference. They live in the
/// screen's own hierarchy, which the canvas's responder chain reaches, and apart from the screen's
/// body, so only a change of writing view or of an open presentation redraws them.
private struct NotebookWritingCommands: View {
    @ObservedObject var chrome: NotebookWritingChrome

    var body: some View {
        ZStack {
            Button("Show or Hide Tools and Title", action: chrome.toggle)
                .keyboardShortcut("t", modifiers: [.command, .option])
            // While a popover or sheet is open, Escape is left to close it.
            if !chrome.isPresenting {
                Button("Show Tools and Title") { chrome.reveal(.sticky) }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            // Titled for the shortcut overlay, where they appear without the menu around them.
            ForEach(EditorChromeMode.allCases, id: \.self) { mode in
                Button("Writing View: \(mode.title)") { chrome.setMode(mode) }
                    .keyboardShortcut(mode.shortcutKey, modifiers: [.command, .control])
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
        // Focus keeps the status bar but lets the home indicator fade over the page.
        .persistentSystemOverlays(chrome.mode == .focus ? .hidden : .automatic)
    }
}
