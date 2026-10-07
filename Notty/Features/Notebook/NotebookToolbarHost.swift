import NottyCore
import SwiftUI
import UIKit

/// Overlays the drawing toolbar on the full notebook canvas. Top docks anchor its position
/// without reserving a band; the page scrolls behind every placement.
@MainActor
struct NotebookToolbarHost<Content: View>: View {
    private let injectedStore: NotebookSceneToolStore?
    private let content: Content
    private let extendsCanvasUnderChrome: Bool
    private let topReservation: CGFloat
    private let headerExtent: CGFloat
    @State private var sceneStore: NotebookSceneToolStore?
    @State private var chrome = NotebookCanvasChrome.none

    /// - Parameters:
    ///   - store: the store whose toolbar to draw, when the caller has it already: the window scene's,
    ///     resolved before the host shows so the toolbar is there from its first frame, or a test's.
    ///     Without one the host resolves the window scene's itself, a turn after it first shows.
    ///   - extendsCanvasUnderChrome: lets paper cover system edges while controls stay in the safe area.
    ///   - topReservation: room below the top safe area for a header drawn over the canvas. The
    ///     toolbar lays out below it, and the canvas reserves it as covered chrome.
    ///   - headerExtent: how far below the top safe area that header reaches. The toolbar's own
    ///     margin may begin inside it, so the canvas keeps at least this much covered however
    ///     little the toolbar takes.
    init(
        store: NotebookSceneToolStore? = nil, extendsCanvasUnderChrome: Bool = false, topReservation: CGFloat = 0,
        headerExtent: CGFloat = 0, @ViewBuilder content: () -> Content
    ) {
        injectedStore = store
        self.extendsCanvasUnderChrome = extendsCanvasUnderChrome
        self.topReservation = topReservation
        self.headerExtent = headerExtent
        self.content = content()
    }

    private var store: NotebookSceneToolStore? { injectedStore ?? sceneStore }

    var body: some View {
        ZStack(alignment: .topLeading) {
            content
                // Every canvas reserves the chrome and the toolbar drawn over it, whether or not
                // it owns the tools. The reservation is applied here rather than measured, so a
                // new reservation reaches the canvas even when no geometry changes.
                .environment(\.notebookCanvasChrome, chrome.reserving(top: topReservation, atLeast: headerExtent))
                .environment(\.notebookToolbarStore, store)
                // One measurement gives the canvas and the control area together, so the chrome
                // never passes through a value mixing an old size with a new one.
                .onGeometryChange(for: NotebookCanvasChrome.self) {
                    NotebookCanvasChrome(
                        canvasSize: $0.size, controlArea: $0.bounds(of: .named(NotebookToolbarLayer.coordinateSpace))
                    )
                } action: { chrome = $0 }
                // Toolbar movement never animates the canvas viewport.
                .transaction { $0.animation = nil }
                // Measure the expanded canvas inside the safe-area modifier, not its safe proposal.
                .ignoresSafeArea(extendsCanvasUnderChrome ? .container : .keyboard)
            if let store {
                NotebookToolbarLayer(store: store)
                    .padding(.top, topReservation)
                    // The toolbar is read before the canvas, as it sits above it.
                    .accessibilityElement(children: .contain)
                    .accessibilitySortPriority(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(.named(NotebookToolbarLayer.coordinateSpace))
        .ignoresSafeArea(.keyboard)
        .background {
            if injectedStore == nil {
                NotebookWindowSceneReader { scene in
                    let owner = NotebookSceneToolStore.owner(for: scene)
                    if sceneStore !== owner { sceneStore = owner }
                }
            }
        }
    }
}

/// A named accessibility action on the stand-in for hidden tools.
struct NotebookToolsRevealAction {
    let name: String
    let perform: @MainActor () -> Void
}

extension NotebookToolsRevealAction {
    /// Brings the rail back from whatever stands in for it. A tap on any stand-in performs it.
    @MainActor
    static func showTools(from store: NotebookSceneToolStore, animation: Animation?) -> Self {
        Self(name: "Show tools and title") {
            withAnimation(animation) { NotebookToolbarActions(store: store).showTools() }
        }
    }

    /// What a stand-in offers assistive technologies: the tools back first, then each writing view
    /// in its order, which the scene's notebook adopts.
    @MainActor
    static func standInActions(for store: NotebookSceneToolStore, animation: Animation?) -> [Self] {
        [showTools(from: store, animation: animation)] + EditorChromeMode.allCases.map { mode in
            Self(name: "Writing view: \(mode.title)") { store.chooseWritingView(mode) }
        }
    }
}

/// How the tools leave and come back when the writing view hides them. They fade as they rise
/// a little and spring back without bounce; under Reduce Motion they only fade. The stand-in
/// left behind fades in once they have gone and vanishes as soon as a reveal starts.
struct NotebookToolsTransition: Equatable {
    let reduceMotion: Bool

    /// How far above their place hidden tools rest.
    var hiddenOffset: CGFloat { reduceMotion ? 0 : -NotebookTheme.toolsHideTravel }

    var hide: Animation {
        reduceMotion ? .linear(duration: NotebookTheme.toolsFadeDuration) : .easeIn(duration: NotebookTheme.toolsHideDuration)
    }

    var reveal: Animation {
        reduceMotion
            ? .linear(duration: NotebookTheme.toolsFadeDuration)
            : .spring(duration: NotebookTheme.toolsRevealDuration, bounce: 0)
    }

    var standInAppearance: Animation {
        .easeOut(duration: NotebookTheme.toolsFadeDuration).delay(reduceMotion ? 0 : NotebookTheme.toolsHideDuration)
    }
}

/// Where a dragged toolbar is drawn and where it comes to rest, fixed at the start of a drag.
struct NotebookToolbarDragResolver: Equatable {
    let size: CGSize
    /// The size the toolbar takes once docked, which places the dock slots. A collapsed handle
    /// is dragged at its own size but measured against the slots the targets draw.
    let dockSize: CGSize
    let usable: CGRect
    /// One centred slot stands for every dock, as the window cannot tell them apart.
    let docksShared: Bool
    let startPlacement: EditorToolbarPlacement
    let startFrame: CGRect

    init(
        placement: EditorToolbarPlacement, size: CGSize, dockSize: CGSize? = nil, usable: CGRect,
        docksShared: Bool = false
    ) {
        self.size = size
        self.dockSize = dockSize ?? size
        self.usable = usable
        self.docksShared = docksShared
        startPlacement = placement
        var shown = placement
        if docksShared, case .docked = placement { shown = .docked(.topCenter) }
        startFrame = EditorToolbarLayout.frame(for: shown, size: size, in: usable)
    }

    /// Follows the finger but stays inside the canvas area; the leading and top edges win
    /// when the toolbar is larger than the area.
    func previewFrame(translation: CGSize) -> CGRect {
        let moved = startFrame.offsetBy(dx: translation.width, dy: translation.height)
        return CGRect(
            x: max(min(moved.minX, usable.maxX - moved.width), usable.minX),
            y: max(min(moved.minY, usable.maxY - moved.height), usable.minY),
            width: moved.width, height: moved.height
        )
    }

    /// Resolved from the preview the user sees, so a toolbar shown on a dock lands in it
    /// even when the finger has moved past the edge.
    func placement(translation: CGSize) -> EditorToolbarPlacement {
        let preview = previewFrame(translation: translation)
        guard docksShared else {
            return EditorToolbarLayout.placement(
                forDragEnding: preview, dockSize: dockSize, in: usable, current: startPlacement
            )
        }
        // Measured against an area just wide enough for the centred slot, every dock resolves
        // to that slot. A drop there keeps the stored dock, which shows again in a wider window.
        let slot = EditorToolbarLayout.frame(for: .docked(.topCenter), size: dockSize, in: usable)
        let slotArea = CGRect(
            x: slot.minX - EditorToolbarLayout.margin, y: usable.minY,
            width: slot.width + 2 * EditorToolbarLayout.margin, height: usable.height
        )
        if case .docked = EditorToolbarLayout.placement(forDragEnding: preview, dockSize: dockSize, in: slotArea) {
            if case .docked = startPlacement { return startPlacement }
            return .docked(.topCenter)
        }
        return EditorToolbarLayout.placement(
            forDragEnding: preview, dockSize: dockSize, in: usable, snapDistance: -.infinity
        )
    }

    func targetedDock(translation: CGSize) -> EditorToolbarDock? {
        if case let .docked(dock) = placement(translation: translation) { return dock }
        return nil
    }

    /// True when a drop lands in a dock other than the one the drag started from.
    func snapsToNewDock(_ placement: EditorToolbarPlacement) -> Bool {
        guard case .docked = placement else { return false }
        return placement != startPlacement
    }
}

/// The canvas edges the status bar and navigation header cover at the top and the home indicator
/// covers at the bottom: where the canvas reaches past the area the host lays its controls out
/// in. Every canvas reserves them as scroll space whatever its input gate, so its first and last
/// lines can always be scrolled clear.
struct NotebookCanvasChrome: Equatable {
    static let none = NotebookCanvasChrome(top: 0, bottom: 0, canvasSize: .zero)

    /// Covered down to where the toolbar's control area begins; the toolbar's obstruction adds to it.
    let top: CGFloat
    let bottom: CGFloat
    /// The canvas size this was measured for, which tells a re-measure after a resize apart
    /// from other changes.
    let canvasSize: CGSize
    /// The least the canvas keeps covered at the top, whatever the toolbar takes: the bottom of a
    /// header drawn over it.
    var coveredTop: CGFloat = 0
}

extension NotebookCanvasChrome {
    /// - Parameter controlArea: the host's control area in the canvas's own coordinates.
    init(canvasSize: CGSize, controlArea: CGRect?) {
        guard let controlArea, canvasSize.width > 0, canvasSize.height > 0 else {
            self = .none
            return
        }
        self.init(
            top: max(controlArea.minY, 0), bottom: max(canvasSize.height - controlArea.maxY, 0),
            canvasSize: canvasSize
        )
    }

    /// The chrome with `reservation` more covered at the top, where the host keeps room for a
    /// header below the top safe area, and at least `headerExtent` below it covered whatever the
    /// toolbar takes. An unmeasured canvas stays unmeasured.
    func reserving(top reservation: CGFloat, atLeast headerExtent: CGFloat = 0) -> NotebookCanvasChrome {
        guard self != .none, reservation > 0 || headerExtent > 0 else { return self }
        return NotebookCanvasChrome(
            top: top + reservation, bottom: bottom, canvasSize: canvasSize, coveredTop: top + headerExtent
        )
    }
}

extension EnvironmentValues {
    /// The chrome over the canvas, as the toolbar host last measured it.
    @Entry var notebookCanvasChrome = NotebookCanvasChrome.none
    /// The store whose toolbar the host draws over the canvas.
    @Entry var notebookToolbarStore: NotebookSceneToolStore?
}

/// How much of the control area a toolbar takes from the end it sits against, as extra scroll
/// space for that end on top of the chrome. A toolbar further from both edges than its own
/// height leaves room to scroll any covered writing past it, so it reserves nothing; this also
/// keeps a notebook opening with its first page at the top.
enum NotebookToolbarObstruction {
    /// A toolbar's obstruction together with the size of the area it was measured in, so a
    /// re-measure for a resized control area can be told apart from the toolbar moving.
    struct Measurement: Equatable {
        let insets: UIEdgeInsets
        let area: CGSize

        init(toolbar: CGRect, area: CGRect) {
            insets = NotebookToolbarObstruction.insets(toolbar: toolbar, area: area)
            self.area = area.size
        }
    }

    static func insets(toolbar: CGRect, area: CGRect) -> UIEdgeInsets {
        guard toolbar.intersects(area) else { return .zero }
        let topGap = toolbar.minY - area.minY
        let bottomGap = area.maxY - toolbar.maxY
        if topGap <= bottomGap {
            guard topGap < toolbar.height else { return .zero }
            return UIEdgeInsets(top: toolbar.maxY - area.minY, left: 0, bottom: 0, right: 0)
        }
        guard bottomGap < toolbar.height else { return .zero }
        return UIEdgeInsets(top: 0, left: 0, bottom: area.maxY - toolbar.minY, right: 0)
    }
}

/// Hands the toolbar's obstruction to the store from the view update that measures it. Every
/// measurement must reach the canvas, and reach it before UIKit lays the canvas out at a new
/// size, so the canvas can tell a resize from a move; a change handler drops a second change
/// within one frame. The canvas applies it as layout, which publishes nothing during the update.
private struct NotebookToolbarObstructionReporter: UIViewRepresentable {
    let store: NotebookSceneToolStore
    let measurement: NotebookToolbarObstruction.Measurement

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.report(measurement, to: store)
    }

    @MainActor
    final class Coordinator {
        private weak var store: NotebookSceneToolStore?
        private var reported: NotebookToolbarObstruction.Measurement?

        /// A store's first measurement is never a resize, as nothing was measured before it.
        func report(_ measurement: NotebookToolbarObstruction.Measurement, to store: NotebookSceneToolStore) {
            let previous = self.store === store ? reported : nil
            guard measurement != previous else { return }
            self.store = store
            reported = measurement
            store.setOverlayObstruction(
                measurement.insets, followingResize: previous.map { $0.area != measurement.area } ?? false
            )
        }
    }
}

/// Fades the rail as the writing view hides it, rising by `offset`, and brings it back. Its keys
/// leave keyboard focus as the hide begins, between strokes, rather than as the fade ends, and are
/// live again from the first frame of a reveal. They keep their look while they fade; only the
/// opacity and offset change from frame to frame.
struct NotebookRailFade: ViewModifier, Animatable {
    /// 0 while shown, 1 once hidden.
    var hiddenAmount: Double
    let offset: CGFloat
    /// Where the fade is heading.
    let isHidden: Bool

    nonisolated var animatableData: Double {
        get { hiddenAmount }
        set { hiddenAmount = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(1 - hiddenAmount)
            .offset(y: offset * hiddenAmount)
            .disabled(isHidden)
            .environment(\.notebookKeysHiding, isHidden)
    }
}

/// Moves the toolbar to its drag preview. Only this modifier reads the per-frame position,
/// so the toolbar it wraps is not rebuilt while it is dragged.
struct NotebookToolbarDragPosition: ViewModifier {
    let drag: NotebookToolbarDragSession
    let restingFrame: CGRect

    func body(content: Content) -> some View {
        let frame = drag.previewFrame ?? restingFrame
        content
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }
}

/// One toolbar drag. Moves only update the preview; the placement is stored once, when
/// the drag ends, and never for a cancelled drag. From its first move to its end the store
/// knows a drag is under way, so the writing view keeps the toolbar and header in sight.
@MainActor
@Observable
final class NotebookToolbarDragSession {
    private(set) var previewFrame: CGRect?
    private(set) var targetedDock: EditorToolbarDock?
    private var resolver: NotebookToolbarDragResolver?
    /// The store told of the drag under way.
    @ObservationIgnored private weak var draggedStore: NotebookSceneToolStore?

    var isActive: Bool { resolver != nil }

    func move(
        to translation: CGSize, resolver proposed: NotebookToolbarDragResolver, actions: NotebookToolbarActions
    ) {
        if resolver == nil {
            resolver = proposed
            draggedStore = actions.store
            actions.store.setToolbarDragging(true)
        }
        guard let resolver else { return }
        previewFrame = resolver.previewFrame(translation: translation)
        let dock = resolver.targetedDock(translation: translation)
        if dock != targetedDock { targetedDock = dock }
    }

    /// Stores where the drag ended and returns it, or nil when there is no resolver or the
    /// toolbar is unavailable. SwiftUI does not order onEnded against the gesture-state reset
    /// that clears the session, so the gesture passes its own resolver for that case; the
    /// session's, fixed when the drag started, wins while it is still set.
    @discardableResult
    func end(
        at translation: CGSize, resolver fallback: NotebookToolbarDragResolver? = nil,
        actions: NotebookToolbarActions
    ) -> EditorToolbarPlacement? {
        guard let resolver = resolver ?? fallback else { return nil }
        cancel()
        let placement = resolver.placement(translation: translation)
        return actions.place(placement) ? placement : nil
    }

    func cancel() {
        resolver = nil
        previewFrame = nil
        targetedDock = nil
        draggedStore?.setToolbarDragging(false)
        draggedStore = nil
    }
}

/// The toolbar, its collapsed handle, the stand-in left while the writing view hides the
/// tools, and the dock targets shown while dragging.
@MainActor
private struct NotebookToolbarLayer: View {
    nonisolated static let coordinateSpace = "NotebookToolbarHost"
    /// Movement before the handle starts a drag, so a tap on it never shifts the toolbar.
    private static let dragStartDistance: CGFloat = 4
    private static let presentation = Animation.easeOut(duration: 0.2)
    private static let snap = Animation.spring(duration: 0.35, bounce: 0.2)

    @ObservedObject var store: NotebookSceneToolStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag = NotebookToolbarDragSession()
    @State private var dockSnaps = 0
    @GestureState private var isDragging = false

    /// True while the writing view hides an expanded rail. A collapsed handle stays in sight.
    private static func hidesRail(in store: NotebookSceneToolStore) -> Bool {
        store.areToolsHidden && !store.toolbar.isCollapsed
    }

    private var actions: NotebookToolbarActions { NotebookToolbarActions(store: store) }

    var body: some View {
        let hidden = Self.hidesRail(in: store)
        GeometryReader { proxy in
            let usable = CGRect(origin: .zero, size: proxy.size)
            let composition = NotebookToolbarComposition(
                preferences: store.toolbar, horizontalSizeClass: sizeClass, dynamicTypeSize: dynamicTypeSize,
                legibilityWeight: legibilityWeight
            )
            let rail = composition.rail(forHostWidth: usable.width)
            let resting = composition.frame(for: store.toolbar.placement, rail: rail, in: usable)
            let transition = NotebookToolsTransition(reduceMotion: reduceMotion)
            ZStack(alignment: .topLeading) {
                NotebookDockTargets(drag: drag, slotSize: rail.size, usable: usable, docksShared: rail.docksShared)
                toolbar(composition: composition, rail: rail, usable: usable)
                    .modifier(NotebookToolbarDragPosition(drag: drag, restingFrame: resting))
                    // Keyed to the store itself, so however often it changes within a frame the
                    // rail ends up as last asked.
                    .animation(hidden ? transition.hide : transition.reveal) {
                        $0.modifier(NotebookRailFade(
                            hiddenAmount: hidden ? 1 : 0, offset: transition.hiddenOffset, isHidden: hidden
                        ))
                    }
                    // Applied outside the animation's body too, where SwiftUI does not refresh a
                    // changed `disabled`, so the hidden keys leave keyboard focus in the app as well.
                    .disabled(hidden)
                    .allowsHitTesting(!hidden)
                    .accessibilityHidden(hidden)
                if !composition.showsRevealHandle {
                    standIn(composition: composition, rail: rail, resting: resting, usable: usable)
                        .animation(hidden ? transition.standInAppearance : nil) { $0.opacity(hidden ? 1 : 0) }
                        .allowsHitTesting(hidden)
                        .accessibilityHidden(!hidden)
                        // Out of sight it is out of keyboard focus too. It shows only while enabled.
                        .disabled(!hidden)
                }
            }
            // Measured from where the expanded rail rests whether or not it shows, so hiding the
            // tools never changes the scroll space and never moves the page.
            .background {
                NotebookToolbarObstructionReporter(
                    store: store, measurement: NotebookToolbarObstruction.Measurement(toolbar: resting, area: usable)
                )
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: dockSnaps)
        .onChange(of: store.revealRequest) {
            withAnimation(reduceMotion ? nil : Self.presentation) { actions.revealIfCollapsed() }
        }
        .onChange(of: isDragging) { _, dragging in
            // A cancelled gesture never reaches onEnded, so its preview is dropped here. An ended
            // gesture may arrive here first; onEnded still stores it through its own resolver.
            if !dragging { drag.cancel() }
        }
        // A layer that leaves mid-drag never sees the gesture end.
        .onDisappear { drag.cancel() }
    }

    @ViewBuilder
    private func toolbar(composition: NotebookToolbarComposition, rail: NotebookToolbarRail, usable: CGRect) -> some View {
        let resolver = NotebookToolbarDragResolver(
            placement: store.toolbar.placement, size: composition.toolbarSize(of: rail),
            dockSize: rail.size, usable: usable, docksShared: rail.docksShared
        )
        if composition.showsRevealHandle {
            NotebookToolbarRevealHandle(
                store: store, label: store.areToolsHidden ? "Show tools and title" : "Show tools"
            ) { showTools() }
            .disabled(!actions.isEnabled && !store.areToolsHidden)
            .environment(\.notebookKeysPaused, !actions.isEnabled)
            // Takes precedence over the button only once the finger moves, so a tap still reveals.
            .highPriorityGesture(dragGesture(resolver), including: actions.dragGestureMask)
            .accessibilityActions {
                placementActions(composition: composition)
                if store.areToolsHidden { revealActionButtons }
            }
        } else {
            NotebookToolbar(store: store, composition: composition, rail: rail, collapse: collapse) {
                NotebookToolbarGrip()
                    .gesture(dragGesture(resolver), including: actions.dragGestureMask)
                    .accessibilityElement()
                    .accessibilityLabel("Move toolbar")
                    .accessibilityValue(placementDescription)
                    .accessibilityHint("Choose an action to dock the toolbar at the top or float it over the page.")
                    .accessibilityActions { placementActions(composition: composition) }
                    .accessibilityShowsLargeContentViewer {
                        Label("Move toolbar", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                    }
            }
        }
    }

    private var standInAnimation: Animation? { reduceMotion ? nil : Self.presentation }

    /// Every stand-in for the rail brings it back the same way.
    private func showTools() {
        NotebookToolsRevealAction.showTools(from: store, animation: standInAnimation).perform()
    }

    /// What stays in sight while the writing view hides the tools: a docked rail leaves a small
    /// tab hanging where it folded away, a floating rail its collapsed handle. Either asks for
    /// the tools back; what else returns with them is the writing view's decision.
    @ViewBuilder
    private func standIn(
        composition: NotebookToolbarComposition, rail: NotebookToolbarRail, resting: CGRect, usable: CGRect
    ) -> some View {
        if composition.isFloating {
            let handle = EditorToolbarLayout.frame(
                for: store.toolbar.placement, size: NotebookTheme.collapsedHandleSize, in: usable
            )
            NotebookToolbarRevealHandle(store: store, label: "Show tools and title") { showTools() }
                .accessibilityActions { revealActionButtons }
                .frame(width: handle.width, height: handle.height)
                .position(x: handle.midX, y: handle.midY)
        } else {
            let tab = NotebookToolsRevealTab.frame(
                hangingFrom: resting, dock: rail.docksShared ? .topCenter : dock(of: store.toolbar.placement)
            )
            NotebookToolsRevealTab { showTools() }
                .accessibilityActions { revealActionButtons }
                .frame(width: tab.width, height: tab.height)
                .position(x: tab.midX, y: tab.midY)
        }
    }

    private var revealActionButtons: some View {
        let choices = NotebookToolsRevealAction.standInActions(for: store, animation: standInAnimation)
        return ForEach(choices.indices, id: \.self) { index in
            Button(choices[index].name) { choices[index].perform() }
        }
    }

    private func dock(of placement: EditorToolbarPlacement) -> EditorToolbarDock {
        if case let .docked(dock) = placement { return dock }
        return .topCenter
    }

    private func dragGesture(_ resolver: NotebookToolbarDragResolver) -> some Gesture {
        DragGesture(minimumDistance: Self.dragStartDistance, coordinateSpace: .named(Self.coordinateSpace))
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in drag.move(to: value.translation, resolver: resolver, actions: actions) }
            .onEnded { value in
                withAnimation(reduceMotion ? nil : Self.snap) {
                    let placement = drag.end(at: value.translation, resolver: resolver, actions: actions)
                    if let placement, resolver.snapsToNewDock(placement) { dockSnaps += 1 }
                }
            }
    }

    @ViewBuilder
    private func placementActions(composition: NotebookToolbarComposition) -> some View {
        Button("Dock top left") { actions.place(.docked(.topLeading)) }
        Button("Dock top center") { actions.place(.docked(.topCenter)) }
        Button("Dock top right") { actions.place(.docked(.topTrailing)) }
        if !composition.isFloating {
            Button("Float") { actions.place(NotebookToolbarActions.floatingPlacement) }
        }
        if composition.showsCollapseControl {
            Button("Hide tools", action: collapse)
        }
    }

    private var placementDescription: String {
        switch store.toolbar.placement {
        case .docked(.topLeading): "Docked top left"
        case .docked(.topCenter): "Docked top center"
        case .docked(.topTrailing): "Docked top right"
        case .floating: "Floating"
        }
    }

    private func collapse() {
        withAnimation(reduceMotion ? nil : Self.presentation) { actions.setCollapsed(true) }
    }
}

/// Where the dock targets are drawn. Each dock is marked by a short slot at the edge of the
/// docked toolbar it aligns, the leading edge, the centre or the trailing edge, which is where
/// a dragged toolbar or handle snaps to it; the markers never overlap however wide the toolbar
/// is. Docks the window cannot tell apart share one centred slot.
enum NotebookDockMarkers {
    /// As wide as the zone around a dock's edge that snaps to it.
    static let markerWidth = 2 * EditorToolbarLayout.snapDistance

    static func frames(slotSize: CGSize, in usable: CGRect, docksShared: Bool) -> [EditorToolbarDock: CGRect] {
        func slot(_ dock: EditorToolbarDock) -> CGRect {
            EditorToolbarLayout.frame(for: .docked(dock), size: slotSize, in: usable)
        }
        guard !docksShared, slot(.topTrailing).minX - slot(.topLeading).minX >= 1 else {
            return [.topCenter: slot(.topCenter)]
        }
        var markers: [EditorToolbarDock: CGRect] = [:]
        for dock in EditorToolbarDock.allCases {
            let slot = slot(dock)
            let width = min(markerWidth, slot.width)
            let x = switch dock {
            case .topLeading: slot.minX
            case .topCenter: slot.midX - width / 2
            case .topTrailing: slot.maxX - width
            }
            markers[dock] = CGRect(x: x, y: slot.minY, width: width, height: slot.height)
        }
        return markers
    }
}

/// Dock markers shown while the toolbar is dragged. The targeted dock's marker fills in and
/// the full slot the toolbar will take is outlined. Nothing lifts and no shadow changes.
struct NotebookDockTargets: View {
    let drag: NotebookToolbarDragSession
    let slotSize: CGSize
    let usable: CGRect
    let docksShared: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if drag.isActive {
                let markers = NotebookDockMarkers.frames(slotSize: slotSize, in: usable, docksShared: docksShared)
                // A single slot stands for every dock and is the whole frame the rail lands in, so a
                // targeted dock draws it as the landing slot rather than as a filled marker.
                let isShared = markers.count == 1
                ZStack(alignment: .topLeading) {
                    ForEach(EditorToolbarDock.allCases, id: \.self) { dock in
                        if let marker = markers[dock] {
                            let isTargeted = isShared ? drag.targetedDock != nil : drag.targetedDock == dock
                            let fill: NotebookDockTarget.Fill = isTargeted ? (isShared ? .landing : .targeted) : .idle
                            NotebookDockTarget(fill: fill, isLanding: isShared && isTargeted)
                                .frame(width: marker.width, height: marker.height)
                                .position(x: marker.midX, y: marker.midY)
                        }
                    }
                    if !isShared, let dock = drag.targetedDock {
                        let slot = EditorToolbarLayout.frame(for: .docked(dock), size: slotSize, in: usable)
                        NotebookDockTarget(fill: .landing, isLanding: true)
                            .frame(width: slot.width, height: slot.height)
                            .position(x: slot.midX, y: slot.midY)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: NotebookTheme.dockMarkerFadeDuration), value: drag.isActive)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One dock target. Targets lie over paper, or over the stone backdrop beside a zoomed-out
/// page, so a pale well tone and a dark outline keep them readable on both. Under Reduce
/// Transparency the fills are precomposited and opaque; under Increase Contrast every outline
/// is solid and full strength.
struct NotebookDockTarget: View {
    enum Fill {
        /// A dock the toolbar could land in.
        case idle
        /// The dock the toolbar would land in.
        case targeted
        /// The full frame the toolbar would take.
        case landing
    }

    let fill: Fill
    /// The frame the toolbar would take is outlined solid; markers are dashed.
    let isLanding: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NotebookTheme.panelCornerRadius, style: .continuous)
        let outline = Self.outline(isLanding: isLanding, contrast: contrast)
        shape
            .fill(Self.tone(for: fill, reduceTransparency: reduceTransparency))
            .overlay { shape.strokeBorder(outline.color, style: outline.style) }
    }

    static func tone(for fill: Fill, reduceTransparency: Bool) -> Color {
        switch fill {
        case .idle:
            reduceTransparency
                ? NotebookTheme.dockSlotOpaqueFill.color
                : NotebookTheme.selectedWell.color.opacity(NotebookTheme.dockSlotFillOpacity)
        case .targeted:
            reduceTransparency
                ? NotebookTheme.dockSlotTargetedOpaqueFill.color
                : NotebookTheme.selectedWell.color.opacity(NotebookTheme.dockSlotTargetedFillOpacity)
        case .landing:
            reduceTransparency
                ? NotebookTheme.dockSlotLandingOpaqueFill.color
                : NotebookTheme.selectedWell.color.opacity(NotebookTheme.dockSlotLandingFillOpacity)
        }
    }

    static func outline(isLanding: Bool, contrast: ColorSchemeContrast) -> (color: Color, style: StrokeStyle) {
        if contrast == .increased { return (NotebookTheme.glyph.color, NotebookTheme.dockSlotLandingOutline) }
        return (
            NotebookTheme.glyph.color.opacity(NotebookTheme.dockSlotOutlineOpacity),
            isLanding ? NotebookTheme.dockSlotLandingOutline : NotebookTheme.dockSlotOutline
        )
    }
}

/// The drag region of the grip column, kept apart from the scrolling strips: two raised
/// ridges, as on hardware.
private struct NotebookToolbarGrip: View {
    var body: some View {
        HStack(spacing: NotebookTheme.gripRidgeSpacing) {
            ForEach(0..<2, id: \.self) { _ in
                Capsule()
                    .frame(width: NotebookTheme.gripRidgeSize.width, height: NotebookTheme.gripRidgeSize.height)
            }
        }
        .foregroundStyle(NotebookTheme.glyphSecondary.color)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

/// The tab a docked rail leaves where it folded away while the writing view hides the tools.
/// It is faint only because it is small: the chevron on it keeps full contrast.
private struct NotebookToolsRevealTab: View {
    /// The tab's touch area, hanging from the top of the rail it stands in for: inset from the
    /// rail's leading or trailing end at those docks, centred otherwise.
    static func frame(hangingFrom rail: CGRect, dock: EditorToolbarDock) -> CGRect {
        let hit = NotebookTheme.revealTabHitSize
        let inset = (hit.width - NotebookTheme.revealTabSize.width) / 2
        let tabInset = NotebookTheme.stripInsets.left
        let x = switch dock {
        case .topLeading: rail.minX + tabInset - inset
        case .topCenter: rail.midX - hit.width / 2
        case .topTrailing: rail.maxX - tabInset + inset - hit.width
        }
        return CGRect(x: x, y: rail.minY, width: hit.width, height: hit.height)
    }

    let reveal: () -> Void

    var body: some View {
        let symbol = "chevron.compact.down"
        Button(action: reveal) {
            // The secondary glyph tone reads as the full glyph under Increase Contrast.
            Image(systemName: symbol)
                .font(.system(size: NotebookTheme.chevronSize, weight: .semibold))
                .foregroundStyle(NotebookTheme.glyphSecondary.color)
        }
        .buttonStyle(NotebookRevealTabStyle())
        .accessibilityLabel("Show tools and title")
        .accessibilityShowsLargeContentViewer {
            Label("Show tools and title", systemImage: symbol)
        }
    }
}

/// Draws the reveal tab's capsule at the top of its larger touch area, pressed and focused like
/// every key: the capsule sinks and the chevron drops a point.
private struct NotebookRevealTabStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let face = NotebookTheme.revealTabSize
        let hit = NotebookTheme.revealTabHitSize
        NotebookKey(
            label: configuration.label.frame(width: face.width, height: face.height),
            isSelected: false, isPressed: configuration.isPressed, shape: .capsule
        )
        .background { NotebookRevealTabFace() }
        .frame(width: hit.width, height: hit.height, alignment: .top)
        .contentShape(Rectangle())
    }
}

/// The tab's capsule, a little translucent over the paper unless the system asks for opaque
/// chrome.
private struct NotebookRevealTabFace: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shadow = NotebookTheme.contactShadow
        let opaque = reduceTransparency || contrast == .increased
        Capsule()
            .fill(NotebookTheme.panelSurface.color.opacity(opaque ? 1 : NotebookTheme.revealTabOpacity))
            .overlay {
                Capsule().strokeBorder(NotebookTheme.panelLowerEdge.color, lineWidth: NotebookTheme.shellBorderWidth)
            }
            .shadow(color: shadow.color, radius: shadow.radius, x: shadow.offset.width, y: shadow.offset.height)
            .accessibilityHidden(true)
    }
}

/// What remains of a collapsed floating toolbar, or of a floating rail the writing view hides:
/// the tool in use, with a bead of its ink. Always inside the canvas area.
private struct NotebookToolbarRevealHandle: View {
    @ObservedObject var store: NotebookSceneToolStore
    let label: String
    let reveal: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let tool = store.tool
        Button(action: reveal) {
            // Only the content dims while writing is paused; the shell stays opaque over the page.
            Image(systemName: tool.kind.symbol)
                .font(.system(size: NotebookTheme.handleGlyphSize))
                .modifier(NotebookKeyForeground())
                .frame(width: NotebookTheme.controlSize, height: NotebookTheme.controlSize)
                .overlay {
                    if tool.inkFamily != nil {
                        Circle()
                            .fill(tool.color.swiftUIColor)
                            .padding(NotebookTheme.shellBorderWidth)
                            .background { Circle().fill(NotebookTheme.panelTop.color) }
                            .frame(
                                width: NotebookTheme.handleBeadDiameter + 2 * NotebookTheme.shellBorderWidth,
                                height: NotebookTheme.handleBeadDiameter + 2 * NotebookTheme.shellBorderWidth
                            )
                            .offset(x: NotebookTheme.handleBeadOffset, y: NotebookTheme.handleBeadOffset)
                    }
                }
                .opacity(NotebookToolbarActions(store: store).contentOpacity(for: contrast))
                .contentShape(Rectangle())
        }
        .buttonStyle(NotebookRevealHandleStyle())
        .accessibilityLabel(label)
        .accessibilityValue(toolDescription)
        .accessibilityShowsLargeContentViewer {
            Label(label, systemImage: tool.kind.symbol)
        }
    }

    /// The tool in use, and its colour when it inks.
    private var toolDescription: String {
        let tool = store.tool
        guard tool.inkFamily != nil else { return tool.kind.title }
        return "\(tool.kind.title), \(tool.color.accessibilityName)"
    }
}

/// Draws the collapsed handle as a small opaque shell with the reveal control inside it,
/// pressed and focused the same way as every control in the expanded toolbar.
struct NotebookRevealHandleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        NotebookRevealHandleBody(label: configuration.label, isPressed: configuration.isPressed)
    }
}

struct NotebookRevealHandleBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let radius = NotebookTheme.compactPanelCornerRadius
        label
            .frame(width: NotebookTheme.collapsedHandleSize.width, height: NotebookTheme.collapsedHandleSize.height)
            .background {
                NotebookKeyStyle.Background(
                    shape: .well, isSelected: false, isPressed: isPressed && isEnabled, isFocused: isFocused && isEnabled
                )
                // Inset as controls are in a strip, which keeps the well's corners inside the shell's.
                .padding(NotebookTheme.stripInsets.top)
            }
            .background { NotebookPanelShell(cornerRadius: radius) }
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Reports the window scene this view is shown in, which owns the scene's tool store.
struct NotebookWindowSceneReader: UIViewRepresentable {
    let onResolve: @MainActor (UIWindowScene) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.onResolve = onResolve
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onResolve = onResolve
    }

    final class ReaderView: UIView {
        var onResolve: (@MainActor (UIWindowScene) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // SwiftUI may be mid-update when the view moves, so report on the next turn.
            Task { [weak self] in
                guard let self, let scene = self.window?.windowScene else { return }
                self.onResolve?(scene)
            }
        }
    }
}
