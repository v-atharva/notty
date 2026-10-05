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
    @State private var sceneStore: NotebookSceneToolStore?
    @State private var canvasFrame = CGRect.zero

    /// - Parameter store: a store to use instead of the window scene's, for tests.
    init(
        store: NotebookSceneToolStore? = nil, extendsCanvasUnderChrome: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        injectedStore = store
        self.extendsCanvasUnderChrome = extendsCanvasUnderChrome
        self.content = content()
    }

    private var store: NotebookSceneToolStore? { injectedStore ?? sceneStore }

    var body: some View {
        ZStack(alignment: .topLeading) {
            content
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named(NotebookToolbarLayer.coordinateSpace))
                } action: { canvasFrame = $0 }
                // Toolbar movement never animates the canvas viewport.
                .transaction { $0.animation = nil }
                // Measure the expanded canvas inside the safe-area modifier, not its safe proposal.
                .ignoresSafeArea(extendsCanvasUnderChrome ? .container : .keyboard)
            if let store {
                NotebookToolbarLayer(store: store, canvasFrame: canvasFrame)
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

/// Where a dragged toolbar is drawn and where it comes to rest, fixed at the start of a drag.
struct NotebookToolbarDragResolver: Equatable {
    let size: CGSize
    /// The size the toolbar takes once docked, which places the dock slots. A collapsed handle
    /// is dragged at its own size but measured against the slots the targets draw.
    let dockSize: CGSize
    let usable: CGRect
    let startPlacement: EditorToolbarPlacement
    let startFrame: CGRect

    init(placement: EditorToolbarPlacement, size: CGSize, dockSize: CGSize? = nil, usable: CGRect) {
        self.size = size
        self.dockSize = dockSize ?? size
        self.usable = usable
        startPlacement = placement
        startFrame = EditorToolbarLayout.frame(for: placement, size: size, in: usable)
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
        EditorToolbarLayout.placement(
            forDragEnding: previewFrame(translation: translation), dockSize: dockSize, in: usable,
            current: startPlacement
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

/// How much of the canvas a toolbar takes from the page end it sits against, as
/// extra scroll space for that end. A toolbar further from both edges than its own height
/// leaves room to scroll any covered writing past it, so it reserves nothing; this also
/// keeps a notebook opening with its first page at the top.
enum NotebookToolbarObstruction {
    static func insets(toolbar: CGRect, canvas: CGRect, usable: CGRect? = nil) -> UIEdgeInsets {
        if let usable {
            guard !canvas.isEmpty else { return .zero }
            let overlay = insets(toolbar: toolbar, canvas: usable)
            return UIEdgeInsets(
                top: max(usable.minY - canvas.minY, 0) + overlay.top, left: 0,
                bottom: max(canvas.maxY - usable.maxY, 0) + overlay.bottom, right: 0
            )
        }
        guard toolbar.intersects(canvas) else { return .zero }
        let topGap = toolbar.minY - canvas.minY
        let bottomGap = canvas.maxY - toolbar.maxY
        if topGap <= bottomGap {
            guard topGap < toolbar.height else { return .zero }
            return UIEdgeInsets(top: toolbar.maxY - canvas.minY, left: 0, bottom: 0, right: 0)
        }
        guard bottomGap < toolbar.height else { return .zero }
        return UIEdgeInsets(top: 0, left: 0, bottom: canvas.maxY - toolbar.minY, right: 0)
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
/// the drag ends, and never for a cancelled drag.
@MainActor
@Observable
final class NotebookToolbarDragSession {
    private(set) var previewFrame: CGRect?
    private(set) var targetedDock: EditorToolbarDock?
    private var resolver: NotebookToolbarDragResolver?

    var isActive: Bool { resolver != nil }

    func move(to translation: CGSize, resolver proposed: NotebookToolbarDragResolver) {
        if resolver == nil { resolver = proposed }
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
    }
}

/// The toolbar, its collapsed handle and the dock targets shown while dragging.
@MainActor
private struct NotebookToolbarLayer: View {
    nonisolated static let coordinateSpace = "NotebookToolbarHost"
    /// Where the accessibility "Float" action places the toolbar: centred, near the top of the page.
    private static let floatingStart = CGPoint(x: 0.5, y: 0.25)
    /// Movement before the handle starts a drag, so a tap on it never shifts the toolbar.
    private static let dragStartDistance: CGFloat = 4
    private static let presentation = Animation.easeOut(duration: 0.2)
    private static let snap = Animation.spring(duration: 0.35, bounce: 0.2)

    @ObservedObject var store: NotebookSceneToolStore
    /// The canvas, in this layer's coordinate space.
    let canvasFrame: CGRect
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag = NotebookToolbarDragSession()
    @State private var dockSnaps = 0
    @GestureState private var isDragging = false

    private var actions: NotebookToolbarActions { NotebookToolbarActions(store: store) }

    var body: some View {
        GeometryReader { proxy in
            let usable = CGRect(origin: .zero, size: proxy.size)
            let composition = NotebookToolbarComposition(preferences: store.toolbar, horizontalSizeClass: sizeClass)
            let size = composition.toolbarSize(forHostWidth: usable.width)
            let dockSize = dockSlotSize(forHostWidth: usable.width)
            let resting = EditorToolbarLayout.frame(for: store.toolbar.placement, size: size, in: usable)
            ZStack(alignment: .topLeading) {
                NotebookDockTargets(drag: drag, slotSize: dockSize, usable: usable)
                toolbar(composition: composition, size: size, dockSize: dockSize, usable: usable)
                    .modifier(NotebookToolbarDragPosition(drag: drag, restingFrame: resting))
            }
            .onChange(
                of: NotebookToolbarObstruction.insets(
                    toolbar: resting, canvas: canvasFrame, usable: usable
                ),
                initial: true
            ) { _, insets in
                store.setOverlayObstruction(insets)
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
    }

    @ViewBuilder
    private func toolbar(
        composition: NotebookToolbarComposition, size: CGSize, dockSize: CGSize, usable: CGRect
    ) -> some View {
        let resolver = NotebookToolbarDragResolver(
            placement: store.toolbar.placement, size: size, dockSize: dockSize, usable: usable
        )
        if composition.showsRevealHandle {
            NotebookToolbarRevealHandle(actions: actions) {
                withAnimation(reduceMotion ? nil : Self.presentation) { actions.setCollapsed(false) }
            }
            // Takes precedence over the button only once the finger moves, so a tap still reveals.
            .highPriorityGesture(dragGesture(resolver), including: actions.dragGestureMask)
            .accessibilityActions { placementActions(composition: composition) }
        } else {
            NotebookToolbar(store: store, composition: composition, collapse: collapse) {
                NotebookToolbarGrip()
                    .gesture(dragGesture(resolver), including: actions.dragGestureMask)
                    .accessibilityElement()
                    .accessibilityLabel("Move toolbar")
                    .accessibilityValue(placementDescription)
                    .accessibilityHint("Choose an action to dock the toolbar at the top or float it over the page.")
                    .accessibilityActions { placementActions(composition: composition) }
            }
        }
    }

    private func dragGesture(_ resolver: NotebookToolbarDragResolver) -> some Gesture {
        DragGesture(minimumDistance: Self.dragStartDistance, coordinateSpace: .named(Self.coordinateSpace))
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in drag.move(to: value.translation, resolver: resolver) }
            .onEnded { value in
                withAnimation(reduceMotion ? nil : Self.snap) {
                    let placement = drag.end(at: value.translation, resolver: resolver, actions: actions)
                    if let placement, resolver.snapsToNewDock(placement) { dockSnaps += 1 }
                }
            }
    }

    private func dockSlotSize(forHostWidth width: CGFloat) -> CGSize {
        NotebookToolbarComposition(
            preferences: EditorToolbarPreferences(placement: .docked(.topCenter), isCollapsed: false, customSwatches: []),
            horizontalSizeClass: sizeClass
        )
        .toolbarSize(forHostWidth: width)
    }

    @ViewBuilder
    private func placementActions(composition: NotebookToolbarComposition) -> some View {
        Button("Dock top left") { actions.place(.docked(.topLeading)) }
        Button("Dock top center") { actions.place(.docked(.topCenter)) }
        Button("Dock top right") { actions.place(.docked(.topTrailing)) }
        if !composition.isFloating {
            Button("Float") { actions.place(.floating(Self.floatingStart)) }
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
/// is. A toolbar as wide as the window has one frame for every dock, drawn as one slot.
enum NotebookDockMarkers {
    /// As wide as the zone around a dock's edge that snaps to it.
    static let markerWidth = 2 * EditorToolbarLayout.snapDistance

    static func frames(slotSize: CGSize, in usable: CGRect) -> [EditorToolbarDock: CGRect] {
        func slot(_ dock: EditorToolbarDock) -> CGRect {
            EditorToolbarLayout.frame(for: .docked(dock), size: slotSize, in: usable)
        }
        guard slot(.topTrailing).minX - slot(.topLeading).minX >= 1 else { return [.topCenter: slot(.topCenter)] }
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
/// the full slot the toolbar will take is outlined.
private struct NotebookDockTargets: View {
    let drag: NotebookToolbarDragSession
    let slotSize: CGSize
    let usable: CGRect

    var body: some View {
        if drag.isActive {
            let markers = NotebookDockMarkers.frames(slotSize: slotSize, in: usable)
            // A single slot stands for every dock, so any targeted dock fills it.
            let isShared = markers.count == 1
            ZStack(alignment: .topLeading) {
                ForEach(EditorToolbarDock.allCases, id: \.self) { dock in
                    if let marker = markers[dock] {
                        let isTargeted = isShared ? drag.targetedDock != nil : drag.targetedDock == dock
                        target(
                            marker,
                            fill: isTargeted ? NotebookTheme.dockSlotTargetedFillOpacity : NotebookTheme.dockSlotFillOpacity
                        )
                    }
                }
                if !isShared, let dock = drag.targetedDock {
                    target(EditorToolbarLayout.frame(for: .docked(dock), size: slotSize, in: usable), fill: 0)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Targets lie over leather when docked and over paper when floating, so a pale fill and
    /// dark dashes keep them readable on both.
    private func target(_ frame: CGRect, fill: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: NotebookTheme.toolbarCornerRadius, style: .continuous)
        return shape
            .fill(NotebookTheme.toolbarSurface.color.opacity(fill))
            .overlay {
                shape.strokeBorder(
                    NotebookTheme.glyph.color.opacity(NotebookTheme.dockSlotOutlineOpacity),
                    style: NotebookTheme.dockSlotOutline
                )
            }
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }
}

/// The drag region at the leading end of the toolbar, kept apart from the scrolling strips.
private struct NotebookToolbarGrip: View {
    var body: some View {
        Capsule()
            .fill(NotebookTheme.toolbarDivider.color)
            .frame(width: NotebookTheme.dragHandleSize.height, height: NotebookTheme.dragHandleSize.width)
            .frame(width: NotebookTheme.dragHandleHitSize.width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
    }
}

/// What remains of a collapsed floating toolbar; always inside the canvas area.
private struct NotebookToolbarRevealHandle: View {
    let actions: NotebookToolbarActions
    let reveal: () -> Void

    var body: some View {
        Button(action: reveal) {
            // Only the glyph dims while writing is paused; the shell stays opaque over the page.
            NotebookToolGlyph(symbol: "pencil.tip.crop.circle", isSelected: false)
                .opacity(actions.contentOpacity)
        }
        .buttonStyle(NotebookRevealHandleStyle())
        .disabled(!actions.isEnabled)
        .accessibilityLabel("Show tools")
    }
}

/// Draws the collapsed handle as the toolbar's opaque shell with the reveal control inside it,
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
        label
            .frame(width: NotebookTheme.collapsedHandleSize.width, height: NotebookTheme.collapsedHandleSize.height)
            .background {
                NotebookControlBackground(
                    shape: .well, isSelected: false, isPressed: isPressed && isEnabled, isFocused: isFocused && isEnabled
                )
                // Inset as controls are in a strip, which keeps the well's corners inside the shell's.
                .padding(NotebookTheme.stripInsets.top)
            }
            .background { NotebookToolbarShell() }
            .contentShape(RoundedRectangle(cornerRadius: NotebookTheme.toolbarCornerRadius, style: .continuous))
    }
}

/// Reports the window scene this view is shown in, which owns the scene's tool store.
private struct NotebookWindowSceneReader: UIViewRepresentable {
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
