import Combine
import NottyCore
import UIKit

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
        case scrolledToTop
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
        case .scrolledToTop:
            state.scrolledToTop()
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

    /// A stroke cut short by its canvas being torn down, replaced or hidden. SwiftUI dismantles a
    /// canvas inside its update, where the tools must not change, so the requests the stroke held
    /// are carried out a turn later, once no new stroke has begun.
    func toolCancelled() {
        isToolActive = false
        state.toolCancelled()
        Task { [weak self] in
            guard let self, !self.isToolActive else { return }
            self.performHeldRequests()
        }
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
        userScrolled(by: offset - baseline, isAtTop: Self.isAtTop(scrollView))
    }

    /// The drag ended without deceleration, or its deceleration came to rest. A header left
    /// part-way settles to the end the state chose, and the next scroll starts from nothing.
    func userScrollEnded() {
        scrollBaseline = nil
        state.userScrollEnded()
        apply(.settle)
    }

    /// The last finger left a page that no longer moves. A tap that stops a deceleration reports
    /// neither a drag nor the deceleration's end, so a scroll still under way ends here.
    func fingersLifted() {
        guard scrollBaseline != nil else { return }
        userScrollEnded()
    }

    /// Layout placed or moved the page, as opening, a resize or a change in the space kept for the
    /// chrome does. The state learns where the page now rests, so a later arrival at the top counts
    /// from there, and a scroll under way counts on from the new offset, so the jump is never
    /// travel. Publishes nothing, as layout can run inside a SwiftUI update.
    func layoutMovedPage(in scrollView: UIScrollView) {
        state.pageMoved(isAtTop: Self.isAtTop(scrollView))
        guard scrollBaseline != nil else { return }
        scrollBaseline = Self.trackedOffset(of: scrollView)
    }

    /// The status-bar tap's scroll to the top has settled. It is the user's own request, so it
    /// brings the chrome back however the page got where it was, once any stroke has ended, and it
    /// ends a scroll the tap cut short.
    func scrolledToTop() {
        scrollBaseline = nil
        perform(.scrolledToTop)
    }

    /// Whether the user is moving `scrollView`: touching, dragging or letting it decelerate. Offsets
    /// that change otherwise belong to layout or code, never to the user.
    static func isUserDriven(_ scrollView: UIScrollView) -> Bool {
        scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
    }

    /// True while the page rests at or above its top, overscroll included.
    private static func isAtTop(_ scrollView: UIScrollView) -> Bool {
        scrollView.contentOffset.y <= -scrollView.contentInset.top + 0.5
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
    /// anything; everything else waits for the pen to lift. A shown header stays as far up as the
    /// page has taken it, so a reveal of the tools alone mid-scroll leaves it where it is.
    private func apply(_ motion: HeaderMotion? = nil) {
        let forced = !state.pins.isEmpty
        guard !isToolActive || forced else { return }
        drivenStore?.setToolsHidden(!state.showsTools)
        let target = state.showsHeader ? (prefersReducedMotion() ? 0 : state.headerTravel) : Self.fullTravel
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
