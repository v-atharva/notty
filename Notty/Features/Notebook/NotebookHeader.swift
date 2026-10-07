import NottyCore
import SwiftUI
import UIKit

// MARK: - Header host

/// Places the header over the page. Its controller lays the hosted header out by bounds and centre,
/// so the transform the writing view sets never fights SwiftUI's layout.
struct NotebookHeaderHost: UIViewControllerRepresentable {
    let session: NotebookSession
    let openRecoveryCopies: @MainActor () -> Void

    func makeUIViewController(context: Context) -> NotebookHeaderHostController {
        NotebookHeaderHostController(
            header: NotebookHeader(
                session: session, chrome: session.writingChrome, openRecoveryCopies: openRecoveryCopies
            ),
            chrome: session.writingChrome
        )
    }

    func updateUIViewController(_ controller: NotebookHeaderHostController, context: Context) {}
}

final class NotebookHeaderHostController: UIViewController {
    private let hosting: UIHostingController<NotebookHeader>
    private let chrome: NotebookWritingChrome

    init(header: NotebookHeader, chrome: NotebookWritingChrome) {
        hosting = UIHostingController(rootView: header)
        self.chrome = chrome
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(header:chrome:).")
    }

    /// The hosted header, which carries the scroll-follow transform.
    var headerView: UIView { hosting.view }
    /// The header as hosted, with the actions its screen gave it.
    var header: NotebookHeader { hosting.rootView }

    override func loadView() {
        view = NotebookHeaderContainerView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The header sits on the always-light paper, and its popovers inherit this.
        overrideUserInterfaceStyle = .light
        hosting.view.backgroundColor = .clear
        // The header reaches up beside the status bar while it leaves; its content keeps its layout.
        hosting.safeAreaRegions = []
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        chrome.attachHeader(hosting.view)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let frame = Self.shellFrame(in: view.bounds).insetBy(
            dx: -NotebookTheme.shellShadowBleed, dy: -NotebookTheme.shellShadowBleed
        )
        hosting.view.bounds = CGRect(origin: .zero, size: frame.size)
        hosting.view.center = CGPoint(x: frame.midX, y: frame.midY)
    }

    /// The shell sits `headerTopGap` below the top safe area. The hosted view reaches past it by the
    /// shadow bleed on every side, so nothing clips the baked shadow.
    static func shellFrame(in bounds: CGRect) -> CGRect {
        CGRect(x: 0, y: NotebookTheme.headerTopGap, width: bounds.width, height: NotebookTheme.headerHeight)
    }
}

/// Lets touches beside the header shell, and on a header that has started to leave, through to the
/// page and the toolbar beneath.
private final class NotebookHeaderContainerView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard NotebookHeaderHostController.shellFrame(in: bounds).contains(point) else { return nil }
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

// MARK: - Header

/// Which parts of the header show at a shell width: the nameplate, then the readout captions, then
/// Redo give way as the shell narrows, so the title keeps its least room.
struct NotebookHeaderLayout: Equatable {
    /// The narrowest compact shell that still holds Undo, Redo and the menu key beside a tray
    /// with the title's least room and the save glyph, within the leading pad, the gap before
    /// Undo and the trailing pad.
    static let redoMinimumShellWidth: CGFloat = {
        let keys = 3 * NotebookTheme.controlSize + 3 * NotebookTheme.itemSpacing
            + 2 * NotebookTheme.dividerPadding + NotebookTheme.dividerThickness
        let tray = NotebookTheme.trayContentInset + NotebookTheme.headerTitleMinimumWidth
            + NotebookTheme.readoutPadding + NotebookTheme.controlSize
        return 3 * NotebookTheme.headerPadding + tray + keys
    }()

    let showsNameplate: Bool
    /// A compact header keeps the save readout's glyph alone and drops a verified history's cell.
    let isCompact: Bool
    /// Captions give way to glyphs alone at accessibility text sizes; the words stay in VoiceOver
    /// and the Large Content Viewer.
    let showsCaptions: Bool
    /// In the narrowest windows Redo moves into the notebook menu, leaving the title its room.
    let showsRedo: Bool

    init(shellWidth: CGFloat, typeSize: DynamicTypeSize) {
        showsNameplate = shellWidth >= NotebookTheme.headerNameplateMinimumWidth && !typeSize.isAccessibilitySize
        isCompact = shellWidth < NotebookTheme.headerCompactWidth
        showsCaptions = !typeSize.isAccessibilitySize
        showsRedo = shellWidth >= Self.redoMinimumShellWidth
    }

    var showsSaveCaption: Bool { showsCaptions && !isCompact }

    var leadingInset: CGFloat { showsNameplate ? NotebookTheme.nameplateLeadingInset : NotebookTheme.headerPadding }
    var trailingGroupGap: CGFloat { isCompact ? NotebookTheme.headerPadding : NotebookTheme.headerTrailingGap }
}

/// The editor's header: the "notty" nameplate on the shell, the recessed tray with the note title
/// and its readouts, then Undo, Redo and the accent key that opens the notebook menu.
struct NotebookHeader: View {
    let session: NotebookSession
    let chrome: NotebookWritingChrome
    let openRecoveryCopies: @MainActor () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        GeometryReader { proxy in
            let _ = session.renderDiagnostics.headerBodyCount += 1
            let bleed = NotebookTheme.shellShadowBleed
            let shellWidth = max(proxy.size.width - 2 * bleed, 0)
            let layout = NotebookHeaderLayout(shellWidth: shellWidth, typeSize: typeSize)
            HStack(spacing: 0) {
                if layout.showsNameplate {
                    NotebookNameplate()
                        .padding(.trailing, NotebookTheme.nameplateTrayGap)
                }
                NotebookTitleTray(session: session, chrome: chrome, layout: layout)
                    .frame(maxWidth: NotebookTheme.trayMaxWidth)
                    .layoutPriority(1)
                Spacer(minLength: layout.trailingGroupGap)
                HStack(spacing: NotebookTheme.itemSpacing) {
                    NotebookHistoryKeys(session: session, model: session.commandModel, showsRedo: layout.showsRedo)
                    NotebookChromeDivider(axis: .vertical)
                    NotebookMenuKey(
                        session: session, chrome: chrome, hostWidth: shellWidth + 2 * NotebookTheme.headerSideInset,
                        sizeClass: sizeClass, offersRedo: !layout.showsRedo, openRecoveryCopies: openRecoveryCopies
                    )
                }
            }
            .padding(.leading, layout.leadingInset)
            .padding(.trailing, NotebookTheme.headerPadding)
            .frame(width: shellWidth, height: NotebookTheme.headerHeight)
            .background { NotebookPanelShell() }
            .padding(bleed)
        }
        .tint(NotebookTheme.controlTint.color)
    }
}

/// "notty", engraved on the shell rather than set in the tray, so it never reads as part of the title.
private struct NotebookNameplate: View {
    var body: some View {
        Text("notty")
            .notebookTypeface(NotebookTheme.wordmark)
            .foregroundStyle(NotebookTheme.glyphSecondary.color)
            .shadow(color: NotebookTheme.engraveHighlight.color, radius: 0, x: 0, y: 1)
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("Notty")
    }
}

/// The recessed display tray: the note title, then the limit, history and save readouts.
private struct NotebookTitleTray: View {
    let session: NotebookSession
    let chrome: NotebookWritingChrome
    let layout: NotebookHeaderLayout

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NotebookTheme.trayCornerRadius, style: .continuous)
        HStack(spacing: 0) {
            // The width rules keep the title its least room beside the save readout. Rarer readouts
            // in a narrow window take it from the title, which truncates.
            NotebookHeaderTitle(session: session, chrome: chrome)
                .padding(.leading, NotebookTheme.trayContentInset)
                .padding(.trailing, NotebookTheme.readoutPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                NotebookLimitReadout(chrome: chrome, model: session.limitsModel)
                NotebookIntegrityReadout(session: session, chrome: chrome, model: session.integrityModel, layout: layout)
                NotebookSaveReadout(session: session, chrome: chrome, model: session.statusModel, layout: layout)
            }
            .fixedSize()
        }
        // Should the readouts alone outgrow the room, the tray keeps its place and they stay at
        // its trailing end, so nothing pushes Undo, Redo or the menu key off the header.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
        .frame(height: NotebookTheme.trayHeight)
        .clipShape(shape)
        .background { NotebookRecessedTray() }
    }
}

private struct NotebookHeaderTitle: View {
    @ObservedObject var session: NotebookSession
    let chrome: NotebookWritingChrome

    var body: some View {
        Text(session.title)
            .notebookTypeface(NotebookTheme.noteTitle)
            .foregroundStyle(NotebookTheme.glyph.color)
            .lineLimit(1)
            .truncationMode(.tail)
            // The typewriter face runs wide; it shrinks a little before it truncates.
            .minimumScaleFactor(0.9)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityAddTraits(.isHeader)
            .accessibilityShowsLargeContentViewer { Text(session.title) }
            .accessibilityAction(named: "Show tools and title") { chrome.reveal(.sticky) }
    }
}

/// Undo and Redo, under the model's rules for when each is available.
private struct NotebookHistoryKeys: View {
    let session: NotebookSession
    @ObservedObject var model: NotebookCanvasCommandModel
    let showsRedo: Bool

    var body: some View {
        HStack(spacing: NotebookTheme.itemSpacing) {
            NotebookHeaderKey(title: "Undo", symbol: "arrow.uturn.backward", action: session.undo)
                .disabled(!model.state.canUndo)
            if showsRedo {
                NotebookHeaderKey(title: "Redo", symbol: "arrow.uturn.forward", action: session.redo)
                    .disabled(!model.state.canRedo)
            }
        }
    }
}

private struct NotebookHeaderKey: View {
    let title: String
    let symbol: String
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(NotebookTheme.headerGlyphFont)
                .frame(width: NotebookTheme.controlSize, height: NotebookTheme.controlSize)
        }
        .buttonStyle(NotebookKeyStyle())
        .accessibilityLabel(title)
        .help(title)
        .accessibilityShowsLargeContentViewer { Label(title, systemImage: symbol) }
    }
}

// MARK: - Readouts

/// What a readout in the tray shows. An unusual state always carries a word as well as its glyph
/// and colour.
struct NotebookReadout: Equatable {
    enum Tone: Equatable {
        case standard
        /// Near the save limit, or history that could not be fully checked.
        case caution
        /// A failed save or recovery, or damaged history.
        case alert
    }

    /// Captions the save readout shows while writing; its slot fits the widest, so it holds still.
    static let steadySaveCaptions = ["Ready", "Saving", "Saved"]

    /// Nil while a check is in progress, which shows a progress indicator instead.
    let symbol: String?
    /// Nil for a glyph-only readout.
    let caption: String?
    let label: String
    let tone: Tone

    var glyphTone: NotebookTheme.Tone {
        switch tone {
        case .standard: NotebookTheme.glyph
        case .caution: NotebookTheme.cautionGlyph
        case .alert: NotebookTheme.alertGlyph
        }
    }

    var captionTone: NotebookTheme.Tone {
        switch tone {
        case .standard: NotebookTheme.glyphSecondary
        case .caution: NotebookTheme.cautionGlyph
        case .alert: NotebookTheme.alertGlyph
        }
    }

    static func save(_ state: NotebookSavePresentation, displayed: NotebookSaveStatus) -> NotebookReadout {
        let failed = "exclamationmark.triangle.fill"
        let readout: (symbol: String, caption: String, tone: Tone)
        if !state.isReady {
            readout = ("lock", "Not ready", .standard)
        } else if state.performingRecovery {
            readout = ("lifepreserver", "Recovery", .standard)
        } else if state.recoveryFailure != nil {
            readout = (failed, "Recovery failed", .alert)
        } else {
            switch displayed {
            case .idle: readout = ("doc", "Ready", .standard)
            case .saving: readout = ("circle.dotted", "Saving", .standard)
            case .saved: readout = ("checkmark.circle", "Saved", .standard)
            case .failed: readout = (failed, "Save failed", .alert)
            }
        }
        return NotebookReadout(
            symbol: readout.symbol, caption: readout.caption,
            label: readout.caption + ". Notebook save details", tone: readout.tone
        )
    }

    /// Nil before the history check starts.
    static func integrity(_ state: NotebookIntegrityState?) -> NotebookReadout? {
        guard let state else { return nil }
        switch state {
        case .checking:
            return NotebookReadout(symbol: nil, caption: "Checking", label: state.label, tone: .standard)
        case .verified:
            return NotebookReadout(symbol: "checkmark.seal", caption: nil, label: state.label, tone: .standard)
        case .damaged:
            return NotebookReadout(symbol: "xmark.seal", caption: "Damaged", label: state.label, tone: .alert)
        case .incomplete:
            return NotebookReadout(symbol: "questionmark.circle", caption: "Incomplete", label: state.label, tone: .caution)
        }
    }

    static let nearLimit = NotebookReadout(
        symbol: "gauge.with.dots.needle.67percent", caption: nil, label: "Notebook nearing save limit", tone: .caution
    )
}

/// One cell of the tray: a 16 pt glyph and, room allowing, a caps caption. A verified history's
/// glyph sits in its own secondary tone. Every cell is a tray-depth key that opens its details.
struct NotebookReadoutLabel: View {
    let readout: NotebookReadout
    var showsCaption = true
    /// Captions whose widest sets the caption slot, so these never shift the layout.
    var steadyCaptions: [String] = []

    var body: some View {
        let caption = showsCaption ? readout.caption : nil
        HStack(spacing: NotebookTheme.readoutSpacing) {
            glyph
                .frame(width: NotebookTheme.readoutGlyphSize, height: NotebookTheme.readoutGlyphSize)
            if let caption {
                ZStack(alignment: .leading) {
                    ForEach(steadyCaptions, id: \.self) { Text($0).hidden() }
                    // Rarer, longer captions widen the slot rather than being cut off.
                    Text(caption).foregroundStyle(readout.captionTone.color)
                }
                .notebookTypeface(NotebookTheme.readoutCaption)
                .textCase(.uppercase)
                .lineLimit(1)
                .fixedSize()
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            }
        }
        .padding(.horizontal, caption == nil ? 0 : NotebookTheme.readoutPadding)
        .frame(minWidth: NotebookTheme.controlSize, minHeight: NotebookTheme.trayHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(readout.label)
    }

    @ViewBuilder
    private var glyph: some View {
        if let symbol = readout.symbol {
            let verified = readout.caption == nil && readout.tone == .standard
            Image(systemName: symbol)
                .font(.system(size: NotebookTheme.readoutGlyphSize))
                .foregroundStyle((verified ? NotebookTheme.glyphSecondary : readout.glyphTone).color)
        } else {
            ProgressView()
                .controlSize(.small)
                .tint(NotebookTheme.glyphSecondary.color)
        }
    }
}

extension NotebookReadout {
    /// What the Large Content Viewer shows for a readout: its word, or its label when it has none.
    @ViewBuilder
    var largeContent: some View {
        if let symbol {
            Label(caption ?? label, systemImage: symbol)
        } else {
            Text(caption ?? label)
        }
    }
}

private struct NotebookSaveReadout: View {
    let session: NotebookSession
    let chrome: NotebookWritingChrome
    @ObservedObject var model: NotebookSavePresentationModel
    let layout: NotebookHeaderLayout
    @State private var showsDetails = false

    var body: some View {
        let readout = NotebookReadout.save(model.state, displayed: model.displayedStatus)
        Button { showsDetails = true } label: {
            NotebookReadoutLabel(
                readout: readout, showsCaption: layout.showsSaveCaption,
                steadyCaptions: NotebookReadout.steadySaveCaptions
            )
            .frame(minWidth: layout.showsSaveCaption ? NotebookTheme.statusReadoutMinWidth : NotebookTheme.controlSize)
        }
        .buttonStyle(NotebookKeyStyle(shape: .readout))
        .help("Save details")
        .accessibilityShowsLargeContentViewer { readout.largeContent }
        .popover(isPresented: $showsDetails) {
            NotebookSaveDetails(session: session, model: model)
                .notebookDetailPresentation()
        }
        .notebookChromePresentation(showsDetails, chrome: chrome)
    }
}

private struct NotebookIntegrityReadout: View {
    let session: NotebookSession
    let chrome: NotebookWritingChrome
    @ObservedObject var model: NotebookIntegrityPresentationModel
    let layout: NotebookHeaderLayout
    @State private var showsDetails = false

    var body: some View {
        // A container that always exists, so the popover and the announcements outlive the cell.
        ZStack {
            // A compact header keeps its room for the title while history is verified; checking,
            // damaged and incomplete history always show.
            if let readout = NotebookReadout.integrity(model.state),
               !(layout.isCompact && readout.caption == nil) {
                Button { showsDetails = true } label: {
                    NotebookReadoutLabel(readout: readout, showsCaption: layout.showsCaptions)
                }
                .buttonStyle(NotebookKeyStyle(shape: .readout))
                .help("History details")
                .accessibilityShowsLargeContentViewer { readout.largeContent }
            }
        }
        .popover(isPresented: $showsDetails) {
            NotebookIntegrityDetails(session: session, integrity: model, saves: session.statusModel)
                .notebookDetailPresentation()
        }
        .notebookChromePresentation(showsDetails, chrome: chrome)
        .onChange(of: model.state) { _, state in
            guard let state, state != .checking else { return }
            AccessibilityNotification.Announcement(state.label).post()
        }
    }
}

private struct NotebookLimitReadout: View {
    let chrome: NotebookWritingChrome
    @ObservedObject var model: NotebookLimitsPresentationModel
    @State private var showsDetails = false

    var body: some View {
        ZStack {
            // Present only near the limit, so the tray reserves no empty cell the rest of the time.
            if model.state.isNearLimit {
                Button { showsDetails = true } label: {
                    NotebookReadoutLabel(readout: .nearLimit)
                }
                .buttonStyle(NotebookKeyStyle(shape: .readout))
                .help("Save limit")
                .accessibilityShowsLargeContentViewer { NotebookReadout.nearLimit.largeContent }
            }
        }
        .popover(isPresented: $showsDetails) {
            NotebookLimitDetails(model: model)
                .notebookDetailPresentation()
        }
        .notebookChromePresentation(showsDetails, chrome: chrome)
    }
}

// MARK: - Details

struct NotebookSaveDetails: View {
    let session: NotebookSession
    @ObservedObject var model: NotebookSavePresentationModel

    var body: some View {
        VStack(alignment: .leading, spacing: NotebookTheme.sectionSpacing) {
            switch model.state.status {
            case .idle:
                NotebookDetailHeadline("Ready")
            case .saving:
                NotebookDetailHeadline(model.state.inputPaused ? "Catching up on saves" : "Saving")
            case .saved(let date):
                NotebookDetailHeadline("Saved")
                Text(date.formatted(date: .abbreviated, time: .standard))
            case .failed(let cause):
                NotebookDetailHeadline(cause.title)
                Text(cause.message)
                Text("Writing is paused. You can scroll and zoom.")
                VStack(spacing: NotebookTheme.sectionSpacing) {
                    if cause.canRetry {
                        Button("Retry save", action: session.retrySave)
                            .buttonStyle(NotebookActionKeyStyle(kind: .primary))
                            .disabled(model.state.performingRecovery)
                    }
                    Button("Preserve recovery copy") {
                        Task { await session.saveRecoveryCopy() }
                    }
                    .buttonStyle(NotebookActionKeyStyle(kind: .secondary))
                    .disabled(!model.state.canPreserveRecovery)
                    if model.state.canReopenSaved {
                        Button("Reopen saved notebook") {
                            Task { await session.reopenSavedNotebook() }
                        }
                        .buttonStyle(NotebookActionKeyStyle(kind: .secondary))
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
    }
}

private struct NotebookIntegrityDetails: View {
    let session: NotebookSession
    @ObservedObject var integrity: NotebookIntegrityPresentationModel
    @ObservedObject var saves: NotebookSavePresentationModel

    var body: some View {
        VStack(alignment: .leading, spacing: NotebookTheme.sectionSpacing) {
            if let state = integrity.state {
                NotebookDetailHeadline(state.label)
                Text(state.detail)
                if case .damaged = state {
                    VStack(spacing: NotebookTheme.sectionSpacing) {
                        Button("Preserve recovery copy") {
                            Task { await session.saveRecoveryCopy() }
                        }
                        .buttonStyle(NotebookActionKeyStyle(kind: .secondary))
                        .disabled(!saves.state.canPreserveRecovery)
                        if saves.state.canReopenSaved {
                            Button("Reopen saved notebook") {
                                Task { await session.reopenSavedNotebook() }
                            }
                            .buttonStyle(NotebookActionKeyStyle(kind: .secondary))
                        }
                    }
                }
                if let message = saves.state.recoveryMessage { Text(message) }
                if let failure = saves.state.recoveryFailure { Text(failure.message) }
            }
        }
    }
}

private struct NotebookLimitDetails: View {
    @ObservedObject var model: NotebookLimitsPresentationModel

    var body: some View {
        VStack(alignment: .leading, spacing: NotebookTheme.sectionSpacing) {
            Label {
                NotebookDetailHeadline(NotebookReadout.nearLimit.label)
            } icon: {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .foregroundStyle(NotebookTheme.cautionGlyph.color)
            }
            Text("This drawing contains \(model.state.strokeCount) of 10,000 supported strokes.")
            if let bytes = model.state.encodedBytes {
                Text("Its most recent encoding uses \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)) of 64 MiB.")
            }
            Text("If an edit exceeds the save limit, preserve a recovery copy before reopening. Larger preserved states remain available for inspection.")
        }
    }
}

private struct NotebookDetailHeadline: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(NotebookTheme.glyph.color)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// The matte panel the save, history and limit details share. It takes its own height where
    /// that fits and scrolls where a large text size makes it taller than the popover can be, so
    /// no explanation or recovery action is ever cut short.
    func notebookDetailPresentation() -> some View {
        ViewThatFits(in: .vertical) {
            notebookDetailPanel()
            ScrollView {
                notebookDetailPanel()
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .presentationBackground(NotebookTheme.panelSurface.color)
        .presentationCompactAdaptation(.popover)
    }

    private func notebookDetailPanel() -> some View {
        font(.footnote)
            .foregroundStyle(NotebookTheme.glyphSecondary.color)
            .tint(NotebookTheme.controlTint.color)
            .padding(NotebookTheme.detailPadding)
            .frame(idealWidth: NotebookTheme.popoverWidth, alignment: .leading)
            .accessibilityElement(children: .contain)
    }

    /// Keeps the header and tools in sight while the presentation `isPresented` describes is open.
    func notebookChromePresentation(_ isPresented: Bool, chrome: NotebookWritingChrome) -> some View {
        modifier(NotebookPresentationPin(isPresented: isPresented) { chrome.setPresentation($0, isPresented: $1) })
    }

    /// The same for a popover or sheet of the toolbar, which reaches the writing view through its store.
    func notebookToolbarPresentation(_ isPresented: Bool, store: NotebookSceneToolStore) -> some View {
        modifier(NotebookPresentationPin(isPresented: isPresented) { store.setToolbarPresentation($0, isPresented: $1) })
    }
}

/// Reports one presentation as it opens and closes, and as closed once the view presenting it leaves.
private struct NotebookPresentationPin: ViewModifier {
    let isPresented: Bool
    let report: @MainActor (UUID, Bool) -> Void
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, presented in report(id, presented) }
            .onDisappear { report(id, false) }
    }
}
