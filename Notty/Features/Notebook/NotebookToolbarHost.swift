import NottyCore
import SwiftUI
import UIKit

/// Overlays the drawing toolbar on the full notebook canvas. Docks anchor its position without
/// reserving a band; the page scrolls behind every placement.
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

/// How the tools leave and come back when the writing view hides them. They fade as they move a
/// little toward the screen edge they rest against, up from the top or floating and sideways at
/// a side dock, and spring back without bounce; under Reduce Motion they only fade. The stand-in
/// left behind fades in once they have gone and vanishes as soon as a reveal starts.
struct NotebookToolsTransition: Equatable {
    let reduceMotion: Bool

    /// Where hidden tools rest relative to their place.
    func hiddenOffset(for orientation: NotebookRailOrientation) -> CGSize {
        guard !reduceMotion else { return .zero }
        let travel = NotebookTheme.toolsHideTravel
        return switch orientation {
        case .horizontal: CGSize(width: 0, height: -travel)
        case .leftEdge: CGSize(width: -travel, height: 0)
        case .rightEdge: CGSize(width: travel, height: 0)
        }
    }

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
    /// The sizes the expanded rail takes at the top and side docks, which place the dock slots.
    /// A collapsed handle is dragged at its own size but measured against the slots the targets draw.
    let dockSizes: EditorToolbarLayout.DockSizes
    let usable: CGRect
    /// Whether this window offers the side docks. Without them a rail stored at a side rests at the
    /// top, and dropping it back there keeps the stored side.
    let sideDocks: Bool
    /// Where the dragged view centres from a floating toolbar's stored point: a collapsed handle
    /// over the first row of the rail it expands into, so a drop stores the point that puts that
    /// row where the handle was let go.
    let centreOffset: CGSize
    let startPlacement: EditorToolbarPlacement
    let startFrame: CGRect

    init(
        placement: EditorToolbarPlacement, size: CGSize, dockSizes: EditorToolbarLayout.DockSizes? = nil,
        usable: CGRect, sideDocks: Bool = true, centreOffset: CGSize = .zero
    ) {
        self.size = size
        // Without measured docks the rail is taken to stand on end at a side as it lies at the top.
        self.dockSizes = dockSizes
            ?? EditorToolbarLayout.DockSizes(horizontal: size, vertical: CGSize(width: size.height, height: size.width))
        self.usable = usable
        self.sideDocks = sideDocks
        self.centreOffset = centreOffset
        startPlacement = placement
        var shown = placement
        if !sideDocks, placement.axis == .vertical { shown = .docked(.topCenter) }
        startFrame = EditorToolbarLayout.frame(for: shown, size: size, in: usable, centreOffset: centreOffset)
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

    /// Resolved from the preview the user sees, so a toolbar shown on the top dock lands in it
    /// even when the finger has moved past the edge, and from the finger, in the usable area's
    /// coordinates, which says which side a rail is pushed to. The finger travels with the
    /// drag's translation.
    func placement(translation: CGSize, pointer: CGPoint? = nil) -> EditorToolbarPlacement {
        let resolved = EditorToolbarLayout.placement(
            forDragEnding: previewFrame(translation: translation),
            finger: pointer.map { EditorToolbarDragFinger(location: $0, travel: translation) },
            dockSizes: dockSizes, in: usable, sideDocks: sideDocks, centreOffset: centreOffset
        )
        if !sideDocks, resolved == .docked(.topCenter), startPlacement.axis == .vertical { return startPlacement }
        return resolved
    }

    /// The dock a drop would land in, as the window shows it.
    func targetedDock(translation: CGSize, pointer: CGPoint? = nil) -> EditorToolbarDock? {
        guard case let .docked(dock) = placement(translation: translation, pointer: pointer) else { return nil }
        return sideDocks || dock.axis == .horizontal ? dock : .topCenter
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
/// keeps a notebook opening with its first page at the top. A rail on end at a side dock
/// overlays the page's edge and reserves nothing either: the page keeps its full width, the
/// writing beneath shows through the glass, and the writing view clears the rail after a stroke.
enum NotebookToolbarObstruction {
    /// A toolbar's obstruction together with the size of the area it was measured in, so a
    /// re-measure for a resized control area can be told apart from the toolbar moving.
    struct Measurement: Equatable {
        let insets: UIEdgeInsets
        let area: CGSize

        init(toolbar: CGRect, area: CGRect, axis: EditorToolbarAxis = .horizontal) {
            insets = axis == .vertical ? .zero : NotebookToolbarObstruction.insets(toolbar: toolbar, area: area)
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

/// Fades the rail as the writing view hides it, moving by `offset`, and brings it back. Its keys
/// leave keyboard focus as the hide begins, between strokes, rather than as the fade ends, and are
/// live again from the first frame of a reveal. They keep their look while they fade; only the
/// opacity and offset change from frame to frame.
struct NotebookRailFade: ViewModifier, Animatable {
    /// 0 while shown, 1 once hidden.
    var hiddenAmount: Double
    let offset: CGSize
    /// Where the fade is heading.
    let isHidden: Bool

    nonisolated var animatableData: Double {
        get { hiddenAmount }
        set { hiddenAmount = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(1 - hiddenAmount)
            .offset(x: offset.width * hiddenAmount, y: offset.height * hiddenAmount)
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

    /// - Parameter pointer: the finger in the usable area's coordinates, which says which side a
    ///   rail is pushed to.
    func move(
        to translation: CGSize, pointer: CGPoint? = nil, resolver proposed: NotebookToolbarDragResolver,
        actions: NotebookToolbarActions
    ) {
        if resolver == nil {
            resolver = proposed
            draggedStore = actions.store
            actions.store.setToolbarDragging(true)
        }
        guard let resolver else { return }
        previewFrame = resolver.previewFrame(translation: translation)
        let dock = resolver.targetedDock(translation: translation, pointer: pointer)
        if dock != targetedDock { targetedDock = dock }
    }

    /// Stores where the drag ended and returns it, or nil when there is no resolver or the
    /// toolbar is unavailable. SwiftUI does not order onEnded against the gesture-state reset
    /// that clears the session, so the gesture passes its own resolver for that case; the
    /// session's, fixed when the drag started, wins while it is still set.
    @discardableResult
    func end(
        at translation: CGSize, pointer: CGPoint? = nil, resolver fallback: NotebookToolbarDragResolver? = nil,
        actions: NotebookToolbarActions
    ) -> EditorToolbarPlacement? {
        guard let resolver = resolver ?? fallback else { return nil }
        cancel()
        let placement = resolver.placement(translation: translation, pointer: pointer)
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
    /// The layer's own area, which drags measure the finger in, so it lines up with the docks.
    nonisolated static let dragSpace = "NotebookToolbarLayer"
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
                legibilityWeight: legibilityWeight, isInkRowOpen: store.isInkRowOpen
            )
            let rail = composition.rail(in: usable.size)
            let dockSizes = composition.dockSizes(in: usable.size)
            // The expanded rail's frame, its second row's room included whether or not it shows,
            // or the collapsed handle's.
            let resting = composition.frame(of: rail, in: usable)
            let transition = NotebookToolsTransition(reduceMotion: reduceMotion)
            ZStack(alignment: .topLeading) {
                // Drawn at the sizes the rail shows at; a drop is measured against the expanded ones.
                NotebookDockTargets(
                    drag: drag, dockSizes: composition.shownDockSizes(in: usable.size), usable: usable,
                    sideDocks: composition.offersSideDocks
                )
                toolbar(composition: composition, rail: rail, dockSizes: dockSizes, usable: usable)
                    .modifier(NotebookToolbarDragPosition(drag: drag, restingFrame: resting))
                    // A rail that turns on end at a side, or back, changes its whole layout, so the
                    // old one fades out where it was and the new one fades in where it rests rather
                    // than stretching between the two.
                    .id(rail.orientation)
                    .transition(.opacity)
                    // Keyed to the store itself, so however often it changes within a frame the
                    // rail ends up as last asked.
                    .animation(hidden ? transition.hide : transition.reveal) {
                        $0.modifier(NotebookRailFade(
                            hiddenAmount: hidden ? 1 : 0, offset: transition.hiddenOffset(for: rail.orientation),
                            isHidden: hidden
                        ))
                    }
                    // Applied outside the animation's body too, where SwiftUI does not refresh a
                    // changed `disabled`, so the hidden keys leave keyboard focus in the app as well.
                    .disabled(hidden)
                    .allowsHitTesting(!hidden)
                    .accessibilityHidden(hidden)
                if !composition.showsRevealHandle {
                    standIn(composition: composition, resting: resting, usable: usable)
                        .animation(hidden ? transition.standInAppearance : nil) { $0.opacity(hidden ? 1 : 0) }
                        .allowsHitTesting(hidden)
                        .accessibilityHidden(!hidden)
                        // Out of sight it is out of keyboard focus too. It shows only while enabled.
                        .disabled(!hidden)
                }
            }
            .coordinateSpace(.named(Self.dragSpace))
            // Measured from where the expanded rail rests whether or not it or its second row shows,
            // so hiding the tools or opening that row never changes the scroll space or moves the page.
            .background {
                NotebookToolbarObstructionReporter(
                    store: store,
                    measurement: NotebookToolbarObstruction.Measurement(
                        toolbar: resting, area: usable, axis: composition.axis
                    )
                )
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: dockSnaps)
        .onChange(of: store.revealRequest) {
            withAnimation(reduceMotion ? nil : Self.presentation) { actions.revealIfCollapsed() }
            // The colours the gesture asks for are on the second row, wherever the rail has one.
            if !NotebookToolbarComposition(preferences: store.toolbar, horizontalSizeClass: sizeClass).foldsInkOptions {
                actions.openInkRow()
            }
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
    private func toolbar(
        composition: NotebookToolbarComposition, rail: NotebookToolbarRail,
        dockSizes: EditorToolbarLayout.DockSizes, usable: CGRect
    ) -> some View {
        let resolver = NotebookToolbarDragResolver(
            placement: store.toolbar.placement, size: composition.toolbarSize(of: rail),
            dockSizes: dockSizes, usable: usable, sideDocks: composition.offersSideDocks,
            centreOffset: composition.centreOffset
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
                NotebookToolbarGrip(axis: rail.orientation.axis)
                    .gesture(dragGesture(resolver), including: actions.dragGestureMask)
                    .accessibilityElement()
                    .accessibilityLabel("Move toolbar")
                    .accessibilityValue(placementDescription)
                    .accessibilityHint(
                        "Choose an action to dock the toolbar at the top or at a side, or float it over the page."
                    )
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
    /// tab at the edge it folded away toward, a floating rail its collapsed handle. Either asks
    /// for the tools back; what else returns with them is the writing view's decision.
    @ViewBuilder
    private func standIn(composition: NotebookToolbarComposition, resting: CGRect, usable: CGRect) -> some View {
        if let dock = composition.shownDock {
            let tab = NotebookToolsRevealTab.frame(standingFor: resting, dock: dock)
            NotebookToolsRevealTab(dock: dock) { showTools() }
                .accessibilityActions { revealActionButtons }
                .frame(width: tab.width, height: tab.height)
                .position(x: tab.midX, y: tab.midY)
        } else {
            let handle = composition.handleFrame(in: usable)
            NotebookToolbarRevealHandle(store: store, label: "Show tools and title") { showTools() }
                .accessibilityActions { revealActionButtons }
                .frame(width: handle.width, height: handle.height)
                .position(x: handle.midX, y: handle.midY)
        }
    }

    private var revealActionButtons: some View {
        let choices = NotebookToolsRevealAction.standInActions(for: store, animation: standInAnimation)
        return ForEach(choices.indices, id: \.self) { index in
            Button(choices[index].name) { choices[index].perform() }
        }
    }

    private func dragGesture(_ resolver: NotebookToolbarDragResolver) -> some Gesture {
        DragGesture(minimumDistance: Self.dragStartDistance, coordinateSpace: .named(Self.dragSpace))
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                drag.move(to: value.translation, pointer: value.location, resolver: resolver, actions: actions)
            }
            .onEnded { value in
                withAnimation(reduceMotion ? nil : Self.snap) {
                    let placement = drag.end(
                        at: value.translation, pointer: value.location, resolver: resolver, actions: actions
                    )
                    if let placement, resolver.snapsToNewDock(placement) { dockSnaps += 1 }
                }
            }
    }

    @ViewBuilder
    private func placementActions(composition: NotebookToolbarComposition) -> some View {
        ForEach(NotebookToolbarPlacementChoice.docks) { choice in
            Button(choice.actionName) { actions.place(choice.placement) }
        }
        if !composition.isFloating {
            let float = NotebookToolbarPlacementChoice.float
            Button(float.actionName) { actions.place(float.placement) }
        }
        if composition.showsCollapseControl {
            Button("Hide tools", action: collapse)
        }
    }

    private var placementDescription: String {
        switch store.toolbar.placement {
        case .docked(.leftEdge): "Docked at the left edge"
        case .docked(.topCenter): "Docked top center"
        case .docked(.rightEdge): "Docked at the right edge"
        case .floating: "Floating"
        }
    }

    private func collapse() {
        withAnimation(reduceMotion ? nil : Self.presentation) { actions.setCollapsed(true) }
    }
}

/// The places the toolbar can be sent without dragging, in the order the grip's actions and the
/// notebook menu offer them: the left edge, the top centre, the right edge, then floating.
struct NotebookToolbarPlacementChoice: Identifiable, Equatable {
    static let docks = [
        NotebookToolbarPlacementChoice(
            placement: .docked(.leftEdge), symbol: "rectangle.leadingthird.inset.filled", label: "Left",
            actionName: "Dock at left edge"
        ),
        NotebookToolbarPlacementChoice(
            placement: .docked(.topCenter), symbol: "rectangle.topthird.inset.filled", label: "Center",
            actionName: "Dock top center"
        ),
        NotebookToolbarPlacementChoice(
            placement: .docked(.rightEdge), symbol: "rectangle.trailingthird.inset.filled", label: "Right",
            actionName: "Dock at right edge"
        ),
    ]
    static let float = NotebookToolbarPlacementChoice(
        placement: NotebookToolbarActions.floatingPlacement, symbol: "rectangle.center.inset.filled", label: "Float",
        actionName: "Float"
    )
    static let all = docks + [float]

    let placement: EditorToolbarPlacement
    let symbol: String
    /// The word a menu segment shows.
    let label: String
    /// The full name of the action, for assistive technologies and pointer help.
    let actionName: String

    var id: String { label }
    /// What Voice Control answers to: the word a segment shows, then its full name.
    var inputLabels: [String] { [label, actionName] }
}

/// Where the dock targets are drawn. The top dock is marked by a short slot across the middle of
/// the frame the docked rail takes, where a dragged rail or handle snaps to it. A side dock is
/// marked by a strip down the screen edge, inside the margins, as far in as a finger docks the
/// rail there, since only how near the finger comes to the edge counts. Where the top dock's frame
/// reaches over that edge, the strip starts below it: a rail held there ends with its top by the
/// top dock's and lands in it instead. The markers never overlap however large the rail is. A
/// window without side docks marks only the top.
enum NotebookDockMarkers {
    /// As long as the zone around the top dock that snaps to it.
    static let markerLength = 2 * EditorToolbarLayout.snapDistance

    static func frames(
        dockSizes: EditorToolbarLayout.DockSizes, in usable: CGRect, sideDocks: Bool
    ) -> [EditorToolbarDock: CGRect] {
        var markers: [EditorToolbarDock: CGRect] = [:]
        let margin = EditorToolbarLayout.margin
        let reach = EditorToolbarLayout.edgeSnapDistance - margin
        let top = EditorToolbarLayout.frame(for: .docked(.topCenter), size: dockSizes.horizontal, in: usable)
        for dock in EditorToolbarDock.allCases where sideDocks || dock.axis == .horizontal {
            let slot = EditorToolbarLayout.frame(for: .docked(dock), size: dockSizes.size(for: dock), in: usable)
            let width = min(reach, slot.width)
            switch dock {
            case .topCenter:
                let length = min(markerLength, slot.width)
                markers[dock] = CGRect(x: slot.midX - length / 2, y: slot.minY, width: length, height: slot.height)
            case .leftEdge:
                markers[dock] = sideStrip(x: slot.minX, width: width, in: usable, below: top)
            case .rightEdge:
                markers[dock] = sideStrip(x: slot.maxX - width, width: width, in: usable, below: top)
            }
        }
        return markers
    }

    /// A side marker from `x`, `width` wide, down the edge inside the margins, starting below the
    /// top dock's frame where that frame reaches over it.
    private static func sideStrip(x: CGFloat, width: CGFloat, in usable: CGRect, below top: CGRect) -> CGRect {
        let margin = EditorToolbarLayout.margin
        let edge = CGRect(x: x, y: usable.minY + margin, width: width, height: max(usable.height - 2 * margin, 0))
        guard edge.minX < top.maxX, top.minX < edge.maxX else { return edge }
        let minY = min(top.maxY + margin, edge.maxY)
        return CGRect(x: x, y: minY, width: width, height: edge.maxY - minY)
    }
}

/// Dock markers shown while the toolbar is dragged. The targeted dock's marker fills in and
/// the full slot the toolbar will take, on end at a side, is outlined. Nothing lifts and no
/// shadow changes.
struct NotebookDockTargets: View {
    let drag: NotebookToolbarDragSession
    let dockSizes: EditorToolbarLayout.DockSizes
    let usable: CGRect
    let sideDocks: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if drag.isActive {
                let markers = NotebookDockMarkers.frames(dockSizes: dockSizes, in: usable, sideDocks: sideDocks)
                ZStack(alignment: .topLeading) {
                    ForEach(EditorToolbarDock.allCases, id: \.self) { dock in
                        if let marker = markers[dock] {
                            NotebookDockTarget(fill: drag.targetedDock == dock ? .targeted : .idle, isLanding: false)
                                .frame(width: marker.width, height: marker.height)
                                .position(x: marker.midX, y: marker.midY)
                        }
                    }
                    if let dock = drag.targetedDock {
                        let slot = EditorToolbarLayout.frame(
                            for: .docked(dock), size: dockSizes.size(for: dock), in: usable
                        )
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
/// ridges, as on hardware. They cross the rail, so on end they lie level rather than reading as
/// more seams beside the one between the columns. Along the top they stand level with the first
/// row, so opening the second leaves them where they are.
private struct NotebookToolbarGrip: View {
    /// The way the rail's rows run.
    let axis: Axis

    var body: some View {
        let ridge = NotebookTheme.gripRidgeSize
        let isHorizontal = axis == .horizontal
        let layout = isHorizontal
            ? AnyLayout(HStackLayout(spacing: NotebookTheme.gripRidgeSpacing))
            : AnyLayout(VStackLayout(spacing: NotebookTheme.gripRidgeSpacing))
        layout {
            ForEach(0..<2, id: \.self) { _ in
                Capsule().frame(
                    width: isHorizontal ? ridge.width : ridge.height, height: isHorizontal ? ridge.height : ridge.width
                )
            }
        }
        .modifier(NotebookKeyForeground(isMark: true))
        .frame(height: isHorizontal ? NotebookTheme.rowHeight : nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isHorizontal ? .top : .center)
        .contentShape(Rectangle())
    }
}

/// The tab a docked rail leaves at the edge it folded away toward while the writing view hides
/// the tools: below the top dock, or standing against a side. It is faint only because it is
/// small: the chevron on it keeps full contrast.
struct NotebookToolsRevealTab: View {
    /// The tab's touch area: hanging from the middle of the top rail's top edge, or standing at
    /// the middle of a side rail's outer edge, where the rail comes back from.
    static func frame(standingFor rail: CGRect, dock: EditorToolbarDock) -> CGRect {
        let hit = NotebookTheme.revealTabHitSize
        return switch dock {
        case .topCenter: CGRect(x: rail.midX - hit.width / 2, y: rail.minY, width: hit.width, height: hit.height)
        case .leftEdge: CGRect(x: rail.minX, y: rail.midY - hit.width / 2, width: hit.height, height: hit.width)
        case .rightEdge:
            CGRect(x: rail.maxX - hit.height, y: rail.midY - hit.width / 2, width: hit.height, height: hit.width)
        }
    }

    /// Points the way the tools come back: down from the top, in from a side.
    static func symbol(for dock: EditorToolbarDock) -> String {
        switch dock {
        case .topCenter: "chevron.compact.down"
        case .leftEdge: "chevron.compact.right"
        case .rightEdge: "chevron.compact.left"
        }
    }

    let dock: EditorToolbarDock
    let reveal: () -> Void

    var body: some View {
        let symbol = Self.symbol(for: dock)
        Button(action: reveal) {
            Image(systemName: symbol)
                .font(.system(size: NotebookTheme.chevronSize, weight: .semibold))
        }
        .buttonStyle(NotebookRevealTabStyle(dock: dock))
        .accessibilityLabel("Show tools and title")
        .accessibilityShowsLargeContentViewer {
            Label("Show tools and title", systemImage: symbol)
        }
    }
}

/// Draws the reveal tab's glass capsule at the screen-edge end of its larger touch area, pressed
/// and focused like every key: the capsule sinks and the chevron drops a point.
private struct NotebookRevealTabStyle: ButtonStyle {
    let dock: EditorToolbarDock

    func makeBody(configuration: Configuration) -> some View {
        let isSide = dock.axis == .vertical
        let face = isSide
            ? CGSize(width: NotebookTheme.revealTabSize.height, height: NotebookTheme.revealTabSize.width)
            : NotebookTheme.revealTabSize
        let hit = NotebookTheme.revealTabHitSize
        let alignment: Alignment = switch dock {
        case .topCenter: .top
        case .leftEdge: .leading
        case .rightEdge: .trailing
        }
        NotebookKey(
            label: configuration.label.frame(width: face.width, height: face.height),
            isSelected: false, isPressed: configuration.isPressed, shape: .capsule
        )
        .notebookGlass(in: Capsule(), interactive: true)
        .frame(width: isSide ? hit.height : hit.width, height: isSide ? hit.width : hit.height, alignment: alignment)
        .contentShape(Rectangle())
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
            // Only the content dims while writing is paused; the glass stays as it is over the page.
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

/// Draws the collapsed handle as a small pane of the rail's glass with the reveal control inside
/// it, pressed and focused the same way as every control in the expanded toolbar.
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
        let shape = RoundedRectangle(cornerRadius: NotebookTheme.compactPanelCornerRadius, style: .continuous)
        label
            .frame(width: NotebookTheme.collapsedHandleSize.width, height: NotebookTheme.collapsedHandleSize.height)
            .background {
                NotebookKeyStyle.Background(
                    shape: .well, isSelected: false, isPressed: isPressed && isEnabled, isFocused: isFocused && isEnabled
                )
                // Inset as controls are in a strip, which keeps the well's corners inside the glass's.
                .padding(NotebookTheme.stripInsets.top)
            }
            .notebookGlass(in: shape, interactive: true)
            .contentShape(shape)
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
