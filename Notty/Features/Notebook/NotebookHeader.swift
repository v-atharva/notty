import Combine
import NottyCore
import SwiftUI
import UIKit

// MARK: - Writing view

/// Decides when the header and the tools leave the page for the writing view the user chose, and
/// moves the header with the user's own scrolling. One per notebook session: it drives the scene's
/// tool store for the tools and the header host for the title.
///
/// The header moves through its UIKit view's transform and opacity, so scrolling runs no SwiftUI
/// body. Insets never change with visibility: the space stays reserved as if everything showed, so
/// the page never moves when the chrome does. Nothing starts moving while a stroke is in progress;
/// requests made then wait for the pen to lift, except a pin, which shows everything at once.
@MainActor
final class NotebookWritingChrome: ObservableObject {
    /// How far the header travels to leave: its gap below the status bar and its own height.
    static let fullTravel = NotebookTheme.headerTopGap + NotebookTheme.headerHeight
    /// Saves catching up pause writing, usually for a moment. Only a pause that lasts this long
    /// keeps the header and tools in sight, so a brief one never flashes them over the page.
    static let catchUpPinDelay = Duration.seconds(1)

    /// The writing view, mirrored from the scene's stored toolbar preferences.
    @Published private(set) var mode = EditorChromeMode.focus
    /// The scene store whose toolbar is drawn over the notebook, once the canvas reports it.
    @Published private(set) var store: NotebookSceneToolStore?
    /// True while one of the editor's popovers, sheets or menus is open.
    @Published private(set) var isPresenting = false

    private(set) var state = EditorChromeState()
    /// How far the header has moved up with the page: 0 in place, `fullTravel` gone.
    private(set) var travel: CGFloat = 0
    /// Decides whether the user is moving the page; `isUserDriven(_:)` unless replaced, since a
    /// scroll view reports touches only when they are real.
    var scrollIsUserDriven: @MainActor (UIScrollView) -> Bool = NotebookWritingChrome.isUserDriven
    private weak var header: UIView?

    private enum Request {
        case reveal(EditorChromeReveal)
        case toggle
    }

    private enum HeaderMotion {
        /// Direct manipulation: the header moves with the finger.
        case follow
        /// A header left part-way when scrolling stops.
        case settle
        case reveal
        case hide
        /// A pin brings the header back at once, fading in without moving.
        case force
    }

    private var isToolActive = false
    /// Requests made during a stroke, performed once it ends.
    private var heldRequests: [Request] = []
    /// The vertical offset at the last user-driven scroll event, nil outside user scrolling.
    private var scrollBaseline: CGFloat?
    private var pendingStore: NotebookSceneToolStore?

    private var modelPins: Set<EditorChromePin> = []
    /// True once saves catching up have paused writing for `catchUpPinDelay`.
    private var isCatchUpPinned = false
    private var catchUpTask: Task<Void, Never>?
    private var presentations: Set<UUID> = []
    private var isToolbarDragging = false
    private var hasKeyboardFocus = false
    private var isAssistiveTechnologyActive: Bool

    private let prefersReducedMotion: @MainActor () -> Bool
    private let assistiveTechnologyRunning: @MainActor () -> Bool
    /// Waits out a transient reveal and the catch-up grace.
    private let delay: @Sendable (Duration) async throws -> Void
    private var transientTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var modeSubscription: AnyCancellable?

    init(
        gate: NotebookCanvasGateModel, saves: NotebookSavePresentationModel,
        integrity: NotebookIntegrityPresentationModel,
        prefersReducedMotion: @escaping @MainActor () -> Bool = { UIAccessibility.isReduceMotionEnabled },
        assistiveTechnologyRunning: @escaping @MainActor () -> Bool = {
            UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        },
        delay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.prefersReducedMotion = prefersReducedMotion
        self.assistiveTechnologyRunning = assistiveTechnologyRunning
        self.delay = delay
        isAssistiveTechnologyActive = assistiveTechnologyRunning()
        modelPins = Self.pins(gate: gate.state.inputGate, saves: saves.state, integrity: integrity.state)
        state.setPins(currentPins)

        // The models publish while the session refreshes, which can happen inside a SwiftUI update,
        // so their pins land on the next turn rather than changing the toolbar mid-update. The main
        // queue also runs while a scroll is tracking, unlike the run loop's default mode.
        Publishers.CombineLatest3(gate.$state, saves.$state, integrity.$state)
            .map { Self.pins(gate: $0.inputGate, saves: $1, integrity: $2) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pins in
                MainActor.assumeIsolated { self?.setModelPins(pins) }
            }
            .store(in: &subscriptions)
        gate.$state
            .map { $0.inputGate == .capacity }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] catchingUp in
                MainActor.assumeIsolated { self?.setCatchingUp(catchingUp) }
            }
            .store(in: &subscriptions)
        let center = NotificationCenter.default
        center.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)
            .merge(with: center.publisher(for: UIAccessibility.switchControlStatusDidChangeNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAssistiveTechnology() }
            }
            .store(in: &subscriptions)
        center.publisher(for: UIFocusSystem.didUpdateNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshKeyboardFocus() }
            }
            .store(in: &subscriptions)
    }

    deinit {
        transientTask?.cancel()
        catchUpTask?.cancel()
    }

    /// The conditions the session's models impose at once: the notebook not open for writing, a
    /// save or recovery problem, and damaged history. Saves catching up pause writing as well, but
    /// pin only once the pause lasts.
    nonisolated static func pins(
        gate: NotebookInputGate, saves: NotebookSavePresentation, integrity: NotebookIntegrityState?
    ) -> Set<EditorChromePin> {
        var pins = Set<EditorChromePin>()
        if gate != .open && gate != .capacity { pins.insert(.inputPaused) }
        if case .failed = saves.status { pins.insert(.saveProblem) }
        if saves.performingRecovery || saves.recoveryFailure != nil { pins.insert(.saveProblem) }
        if case .damaged = integrity { pins.insert(.integrityDamage) }
        return pins
    }

    // MARK: Attachment

    /// Takes the tools and the stored writing view from `store`, the scene store whose toolbar is
    /// drawn over the canvas. The canvas reports it while SwiftUI updates, so it is adopted a turn later.
    func attach(to store: NotebookSceneToolStore?) {
        guard let store, store !== pendingStore, !(store === self.store && store.isWritingChrome(self)) else { return }
        pendingStore = store
        Task { [weak self, weak store] in
            guard let self, let store, self.pendingStore === store else { return }
            self.pendingStore = nil
            self.adopt(store)
        }
    }

    private func adopt(_ store: NotebookSceneToolStore) {
        self.store = store
        store.adoptWritingChrome(self)
        // Writers other than this chrome, such as a reset of the whole preferences, change the mode too.
        // A value arrives a turn after it was sent, possibly after a newer choice, so the store's
        // current mode is adopted rather than the one sent.
        modeSubscription = store.$toolbar
            .map(\.chromeMode)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak store] _ in
                MainActor.assumeIsolated {
                    guard let self, let store else { return }
                    self.adoptMode(store.toolbar.chromeMode)
                }
            }
        adoptMode(store.toolbar.chromeMode)
        apply()
    }

    /// The store, while its tools still follow this chrome. A chrome that outlives its notebook's
    /// screen must not change the tools of the notebook shown after it.
    private var drivenStore: NotebookSceneToolStore? {
        guard let store, store.isWritingChrome(self) else { return nil }
        return store
    }

    /// Registers the hosted header view whose transform and opacity follow the page.
    func attachHeader(_ view: UIView) {
        header = view
        move(.follow)
    }

    // MARK: Requests

    /// Chooses and stores the writing view; a new choice shows everything.
    func setMode(_ mode: EditorChromeMode) {
        if let store, store.toolbar.chromeMode != mode {
            var preferences = store.toolbar
            preferences.setChromeMode(mode)
            store.updateToolbar(preferences)
        }
        adoptMode(mode)
    }

    private func adoptMode(_ mode: EditorChromeMode) {
        if self.mode != mode { self.mode = mode }
        state.setMode(mode)
        apply()
    }

    /// A sticky reveal shows the header and tools until the next hide trigger; a transient one
    /// shows only the tools, briefly. Made during a stroke, it waits for the pen to lift.
    func reveal(_ kind: EditorChromeReveal) {
        perform(.reveal(kind))
    }

    /// The keyboard shortcut: hides what the writing view can hide, or brings it back to stay.
    func toggle() {
        perform(.toggle)
    }

    private func perform(_ request: Request) {
        guard !isToolActive else {
            heldRequests.append(request)
            return
        }
        fulfil(request)
        apply()
    }

    private func fulfil(_ request: Request) {
        switch request {
        case let .reveal(kind):
            if let token = state.reveal(kind).transientToken { scheduleExpiry(of: token) }
        case .toggle:
            state.toggle()
        }
    }

    private func scheduleExpiry(of token: UInt64) {
        transientTask?.cancel()
        let delay = delay
        transientTask = Task { [weak self] in
            do { try await delay(EditorChromeState.transientRevealDuration) } catch { return }
            guard let self, self.state.expireTransient(token) else { return }
            self.apply()
        }
    }

    // MARK: Pins

    /// Records whether a popover, sheet or menu identified by `id` is open.
    func setPresentation(_ id: UUID, isPresented: Bool) {
        let changed = isPresented ? presentations.insert(id).inserted : presentations.remove(id) != nil
        guard changed else { return }
        let presenting = !presentations.isEmpty
        if isPresenting != presenting { isPresenting = presenting }
        refreshPins()
    }

    func setToolbarDragging(_ dragging: Bool) {
        guard isToolbarDragging != dragging else { return }
        isToolbarDragging = dragging
        refreshPins()
    }

    private func setModelPins(_ pins: Set<EditorChromePin>) {
        modelPins = pins
        refreshPins()
    }

    private func setCatchingUp(_ catchingUp: Bool) {
        catchUpTask?.cancel()
        catchUpTask = nil
        guard catchingUp else {
            guard isCatchUpPinned else { return }
            isCatchUpPinned = false
            refreshPins()
            return
        }
        let delay = delay
        catchUpTask = Task { [weak self] in
            do { try await delay(Self.catchUpPinDelay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.isCatchUpPinned = true
            self.refreshPins()
        }
    }

    private func refreshAssistiveTechnology() {
        let active = assistiveTechnologyRunning()
        guard isAssistiveTechnologyActive != active else { return }
        isAssistiveTechnologyActive = active
        refreshPins()
    }

    /// Keyboard focus appears only when someone navigates the controls with a keyboard. Focus on
    /// the page, such as its end-of-paper key, leaves the writing view free to hide.
    private func refreshKeyboardFocus() {
        let item = header.flatMap { UIFocusSystem.focusSystem(for: $0)?.focusedItem }
        let focused = item.map { !Self.isOnPage($0) } ?? false
        guard hasKeyboardFocus != focused else { return }
        hasKeyboardFocus = focused
        refreshPins()
    }

    /// Whether `environment` belongs to a notebook canvas rather than to the header or toolbar.
    static func isOnPage(_ environment: UIFocusEnvironment) -> Bool {
        var current: UIFocusEnvironment? = environment
        while let next = current {
            if next is NotebookViewController { return true }
            current = next.parentFocusEnvironment
        }
        return false
    }

    private var currentPins: Set<EditorChromePin> {
        var pins = modelPins
        if isCatchUpPinned { pins.insert(.inputPaused) }
        if !presentations.isEmpty { pins.insert(.presentation) }
        if isToolbarDragging { pins.insert(.dragging) }
        if hasKeyboardFocus { pins.insert(.keyboardFocus) }
        if isAssistiveTechnologyActive { pins.insert(.assistiveTechnology) }
        return pins
    }

    private func refreshPins() {
        state.setPins(currentPins)
        apply()
    }

    // MARK: Canvas events

    func toolBegan() {
        isToolActive = true
        state.toolBegan()
    }

    func toolEnded() {
        isToolActive = false
        state.toolEnded()
        performHeldRequests()
    }

    /// A stroke cut short by its canvas being torn down or replaced.
    func toolCancelled() {
        isToolActive = false
        state.toolCancelled()
        performHeldRequests()
    }

    private func performHeldRequests() {
        // After the stroke's own end, so a request made during it is what remains.
        let requests = heldRequests
        heldRequests.removeAll()
        for request in requests { fulfil(request) }
        apply()
    }

    /// A drag of the page by the user begins. Only scrolling between this and its end counts, so
    /// programmatic offsets and layout changes never move the header.
    func userScrollBegan(in scrollView: UIScrollView) {
        scrollBaseline = Self.trackedOffset(of: scrollView)
    }

    func userScrollMoved(in scrollView: UIScrollView) {
        guard let baseline = scrollBaseline else { return }
        // A deceleration can stop without reporting its end, as when a stroke halts it, so the
        // first offset the user no longer drives ends the scroll instead of moving the header.
        guard scrollIsUserDriven(scrollView) else {
            userScrollEnded()
            return
        }
        let offset = Self.trackedOffset(of: scrollView)
        scrollBaseline = offset
        guard !scrollView.isZooming, !scrollView.isZoomBouncing else { return }
        let isAtTop = scrollView.contentOffset.y <= -scrollView.contentInset.top + 0.5
        userScrolled(by: offset - baseline, isAtTop: isAtTop)
    }

    /// The drag ended without deceleration, or its deceleration came to rest. A header left
    /// part-way settles to the end the state chose, and the next scroll starts from nothing.
    func userScrollEnded() {
        scrollBaseline = nil
        state.userScrollEnded()
        apply(.settle)
    }

    /// The status-bar tap's scroll to the top has settled; it is the user's own request.
    func scrolledToTop() {
        userScrolled(by: 0, isAtTop: true)
        userScrollEnded()
    }

    /// Whether the user is moving `scrollView`: touching, dragging or letting it decelerate. Offsets
    /// that change otherwise belong to layout or code, never to the user.
    static func isUserDriven(_ scrollView: UIScrollView) -> Bool {
        scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
    }

    /// The offset held at the end of the scroll range, so a fling's spring back from past the last
    /// page reads as no movement instead of an upward scroll that would bring the chrome back.
    private static func trackedOffset(of scrollView: UIScrollView) -> CGFloat {
        let insets = scrollView.contentInset
        let end = max(-insets.top, scrollView.contentSize.height - scrollView.bounds.height + insets.bottom)
        return min(scrollView.contentOffset.y, end)
    }

    private func userScrolled(by delta: CGFloat, isAtTop: Bool) {
        // The header holds still under the pen.
        guard !isToolActive else { return }
        let wasShown = state.showsHeader
        state.userScrolled(by: delta, isAtTop: isAtTop)
        let follows = !prefersReducedMotion() && state.pins.isEmpty && state.mode != .pinned
        guard follows, wasShown || !state.showsHeader else {
            apply()
            return
        }
        drivenStore?.setToolsHidden(!state.showsTools)
        // A shown header sits as far up as the state has counted, so the two never disagree; one
        // the state has just hidden keeps leaving with the page and never follows it back.
        let moved = state.showsHeader ? state.headerTravel : travel + max(delta, 0)
        let clamped = min(max(moved, 0), Self.fullTravel)
        guard clamped != travel else { return }
        travel = clamped
        move(.follow)
    }

    // MARK: Presentation

    /// Brings the tools and the header in line with the state. During a stroke only a pin shows
    /// anything; everything else waits for the pen to lift.
    private func apply(_ motion: HeaderMotion? = nil) {
        let forced = !state.pins.isEmpty
        guard !isToolActive || forced else { return }
        drivenStore?.setToolsHidden(!state.showsTools)
        let target = state.showsHeader ? 0 : Self.fullTravel
        guard target != travel else { return }
        travel = target
        move(motion ?? (forced ? .force : target == 0 ? .reveal : .hide))
    }

    private func move(_ motion: HeaderMotion) {
        guard let header else { return }
        let reduceMotion = prefersReducedMotion()
        let travel = travel
        let place = {
            header.transform = reduceMotion ? .identity : CGAffineTransform(translationX: 0, y: -travel)
            header.alpha = reduceMotion ? (travel < Self.fullTravel ? 1 : 0) : Self.alpha(forTravel: travel)
            header.isUserInteractionEnabled = travel == 0
        }
        let fade = NotebookTheme.chromeFadeDuration
        switch motion {
        case .follow:
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            place()
            CATransaction.commit()
        case .force:
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            header.transform = .identity
            header.isUserInteractionEnabled = true
            CATransaction.commit()
            UIView.animate(withDuration: fade, delay: 0, options: [.curveLinear, .beginFromCurrentState]) {
                header.alpha = 1
            }
        case _ where reduceMotion:
            UIView.animate(withDuration: fade, delay: 0, options: [.curveLinear, .beginFromCurrentState], animations: place)
        case .settle:
            UIView.animate(
                withDuration: NotebookTheme.headerSettleDuration, delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState], animations: place
            )
        case .reveal:
            UIView.animate(
                springDuration: NotebookTheme.headerRevealDuration, bounce: 0, initialSpringVelocity: 0,
                delay: 0, options: [.beginFromCurrentState], animations: place
            )
        case .hide:
            UIView.animate(
                withDuration: NotebookTheme.headerHideDuration, delay: 0,
                options: [.curveEaseIn, .beginFromCurrentState], animations: place
            )
        }
    }

    /// Fully opaque until the last `headerFadeDistance` of travel, so the header never hangs
    /// half-visible under the status bar.
    static func alpha(forTravel travel: CGFloat) -> CGFloat {
        min(max((fullTravel - travel) / NotebookTheme.headerFadeDistance, 0), 1)
    }
}

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

private struct NotebookSaveDetails: View {
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
    /// The matte panel the save, history and limit details share.
    func notebookDetailPresentation() -> some View {
        font(.footnote)
            .foregroundStyle(NotebookTheme.glyphSecondary.color)
            .tint(NotebookTheme.controlTint.color)
            .padding(NotebookTheme.detailPadding)
            .frame(idealWidth: NotebookTheme.popoverWidth, alignment: .leading)
            .accessibilityElement(children: .contain)
            .presentationBackground(NotebookTheme.panelSurface.color)
            .presentationCompactAdaptation(.popover)
    }

    /// Keeps the header and tools in sight while the presentation `isPresented` describes is open.
    func notebookChromePresentation(_ isPresented: Bool, chrome: NotebookWritingChrome) -> some View {
        modifier(NotebookChromePresentationPin(isPresented: isPresented, chrome: chrome))
    }
}

private struct NotebookChromePresentationPin: ViewModifier {
    let isPresented: Bool
    let chrome: NotebookWritingChrome
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, presented in
                chrome.setPresentation(id, isPresented: presented)
            }
            .onDisappear { chrome.setPresentation(id, isPresented: false) }
    }
}
