import NottyCore
import SwiftUI
import UIKit

/// Every toolbar change goes through here, so an unavailable toolbar cannot change the
/// tool or its own preferences, whichever control or gesture fired.
@MainActor
struct NotebookToolbarActions {
    let store: NotebookSceneToolStore

    var isEnabled: Bool { store.isToolbarAvailable }

    /// The controls stay visible while writing is paused, but dimmed so they read as unavailable;
    /// under Increase Contrast they dim less, so they stay legible.
    func contentOpacity(for contrast: ColorSchemeContrast = .standard) -> Double {
        guard !isEnabled else { return 1 }
        return contrast == .increased ? NotebookTheme.disabledOpacityIncreased : NotebookTheme.disabledOpacity
    }

    /// A paused toolbar cannot be dragged, so no drag preview starts that could never be stored.
    var dragGestureMask: GestureMask { isEnabled ? .all : .none }

    func select(_ kind: EditorToolKind) {
        change { $0.select(kind) }
    }

    /// Selects the eraser in the mode used last. The tool state keeps that mode privately
    /// and restores it through the same switch the Apple Pencil gesture uses.
    func selectEraser() {
        change { $0.selectEraser() }
    }

    func toggleRuler() {
        change { $0.isRulerActive.toggle() }
    }

    func apply(_ preset: EditorInkPreset) {
        change { $0.apply(preset) }
    }

    /// Colours and widths describe ink, so choosing one while erasing or selecting
    /// returns to the ink used before.
    func selectColor(_ color: EditorInkColor) {
        change { state in
            if state.inkFamily == nil { state.selectPreviousInk() }
            state.color = color
        }
    }

    func selectWidth(_ step: EditorWidthStep) {
        change { state in
            if state.inkFamily == nil { state.selectPreviousInk() }
            state.widthStep = step
        }
    }

    /// Selects the colour as the shelf stores it, so the ink in use and its swatch stay equal.
    func addCustomColor(_ color: EditorInkColor) {
        guard isEnabled else { return }
        let picked = NotebookSwatchShelf.canonicalColor(color, preserving: store.tool.color)
        selectColor(picked)
        var preferences = store.toolbar
        preferences.addCustomSwatch(picked)
        store.updateToolbar(preferences)
    }

    /// Moving the toolbar always shows it in full; only a floating toolbar collapses.
    @discardableResult
    func place(_ placement: EditorToolbarPlacement) -> Bool {
        guard isEnabled else { return false }
        var preferences = store.toolbar
        preferences.place(placement)
        store.updateToolbar(preferences)
        return true
    }

    func setCollapsed(_ collapsed: Bool) {
        guard isEnabled else { return }
        var preferences = store.toolbar
        preferences.setCollapsed(collapsed)
        store.updateToolbar(preferences)
    }

    func revealIfCollapsed() {
        if store.toolbar.isCollapsed { setCollapsed(false) }
    }

    /// What every stand-in for the rail does when tapped: the reveal tab, the handle a hidden
    /// floating rail leaves and the user's collapsed handle. Tools the writing view hides are
    /// asked back, and a collapsed handle expands, so one tap shows the whole rail. While writing
    /// is paused only the request goes through, as the stored collapse cannot change then.
    func showTools() {
        if store.areToolsHidden { store.revealTools() }
        setCollapsed(false)
    }

    private func change(_ body: (inout EditorToolState) -> Void) {
        guard isEnabled else { return }
        store.update(body)
    }
}

/// The colours on the shelf: the quick swatches, then the custom colours newest first.
enum NotebookSwatchShelf {
    /// Converts a picked colour at picker precision, so the same visible colour picked twice
    /// is recognised as one swatch.
    static func color(from uiColor: UIColor) -> EditorInkColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return EditorInkColor(red: red, green: green, blue: blue, alpha: alpha).quantized
    }

    /// Picker rounding must not turn an existing ink into a different toolbar selection.
    static func canonicalColor(_ color: EditorInkColor, preserving current: EditorInkColor) -> EditorInkColor {
        let picked = color.quantized
        if current.quantized == picked { return current }
        let known = EditorInkCatalog.swatches + EditorInkCatalog.presets.map(\.color)
        return known.first { $0.quantized == picked } ?? picked
    }

    /// One swatch per visible colour. Colours stored before the picker rounded them can differ
    /// from another swatch by less than one step; the earlier swatch, quick swatches first, stands
    /// for both.
    static func displayed(custom: [EditorInkColor]) -> [EditorInkColor] {
        var seen = Set<EditorInkColor>()
        return (EditorInkCatalog.swatches + custom).filter { seen.insert($0.quantized).inserted }
    }
}

/// Which ink controls show as selected. Presets, colours and widths describe ink, so none is
/// lit while the eraser or lasso is in use. A colour missing from the shelf, such as a custom
/// colour another scene has since pushed off it, lights the custom colour well instead, so the
/// colour in use is always marked somewhere.
struct NotebookInkMarks: Equatable {
    static let unlit = NotebookInkMarks(presetID: nil, color: nil, marksCustomColor: false, width: nil)

    let presetID: String?
    let color: EditorInkColor?
    let marksCustomColor: Bool
    let width: EditorWidthStep?

    init(tool: EditorToolState, custom: [EditorInkColor]) {
        guard tool.inkFamily != nil else {
            self = .unlit
            return
        }
        let shelfColor = NotebookSwatchShelf.displayed(custom: custom).first {
            $0.quantized == tool.color.quantized
        }
        self.init(
            presetID: tool.activePresetID, color: shelfColor,
            marksCustomColor: shelfColor == nil, width: tool.widthStep
        )
    }

    private init(presetID: String?, color: EditorInkColor?, marksCustomColor: Bool, width: EditorWidthStep?) {
        self.presetID = presetID
        self.color = color
        self.marksCustomColor = marksCustomColor
        self.width = width
    }
}

/// How the toolbar answers an Apple Pencil gesture set to show the colour palette, the ink
/// attributes or the contextual palette. Every layout answers with something visible.
enum NotebookToolbarRevealResponse: Equatable {
    /// A collapsed floating toolbar expands; its host handles this.
    case expand
    /// At compact width the current-ink chip opens its panel.
    case openInkPanel
    /// The ink strip scrolls to the colours and briefly highlights them.
    case showInkRow
}

// MARK: - Composition

/// Which parts of the toolbar show and how much room it takes, decided from the stored
/// preferences, the text size and the window width.
struct NotebookToolbarComposition: Equatable {
    /// The least distance a toolbar keeps between neighbouring docks. A window too narrow for
    /// that and every working control shares one dock slot instead.
    static let minimumDockTravel: CGFloat = 150
    /// The rail stops growing with the text size here and shows the Large Content Viewer instead.
    static let textSizeLimit = DynamicTypeSize.xxLarge
    /// A divider with its padding, laid out like a control.
    static let dividerWidth = NotebookTheme.dividerThickness + 2 * NotebookTheme.dividerPadding
    /// The grip column at the rail's leading edge. Floating, it holds the collapse key under the
    /// grip, so the rail keeps its docked width.
    static let gripColumnWidth = NotebookTheme.controlSize
    /// Key edge to key edge across a divider.
    static let groupGap = dividerWidth + 2 * NotebookTheme.itemSpacing

    /// At compact width the colour and width row folds into one current-ink chip.
    let foldsInkOptions: Bool
    let isFloating: Bool
    let isCollapsed: Bool
    /// The colours on the shelf, quick swatches first.
    let swatches: [EditorInkColor]
    /// The text size the preset labels are set at, never above `textSizeLimit`.
    let dynamicTypeSize: DynamicTypeSize

    init(
        preferences: EditorToolbarPreferences, horizontalSizeClass: UserInterfaceSizeClass?,
        dynamicTypeSize: DynamicTypeSize = .large
    ) {
        foldsInkOptions = horizontalSizeClass == .compact
        if case .floating = preferences.placement { isFloating = true } else { isFloating = false }
        isCollapsed = preferences.isCollapsed
        swatches = NotebookSwatchShelf.displayed(custom: preferences.customSwatches)
        self.dynamicTypeSize = min(dynamicTypeSize, Self.textSizeLimit)
    }

    var showsRevealHandle: Bool { isCollapsed }
    /// A floating rail offers its collapse key: in the grip column under two rows, and after the
    /// current-ink chip on the single compact row.
    var showsCollapseControl: Bool { isFloating && !isCollapsed }
    var rowCount: Int { foldsInkOptions ? 1 : 2 }

    var pencilRevealResponse: NotebookToolbarRevealResponse {
        if isCollapsed { return .expand }
        return foldsInkOptions ? .openInkPanel : .showInkRow
    }

    var expandedHeight: CGFloat {
        CGFloat(rowCount) * NotebookTheme.rowHeight + CGFloat(rowCount - 1) * NotebookTheme.rowSpacing
    }

    /// The size the toolbar takes: the collapsed handle, or the expanded rail.
    func toolbarSize(forHostWidth width: CGFloat) -> CGSize {
        toolbarSize(of: rail(forHostWidth: width))
    }

    func toolbarSize(of rail: NotebookToolbarRail) -> CGSize {
        showsRevealHandle ? NotebookTheme.collapsedHandleSize : rail.size
    }

    /// Where the toolbar rests for `placement`. Docks the window cannot tell apart all rest in
    /// the centre, whichever is stored.
    func frame(for placement: EditorToolbarPlacement, in usable: CGRect) -> CGRect {
        frame(for: placement, rail: rail(forHostWidth: usable.width), in: usable)
    }

    /// The same, for a rail already laid out for `usable`.
    func frame(for placement: EditorToolbarPlacement, rail: NotebookToolbarRail, in usable: CGRect) -> CGRect {
        var shown = placement
        if case .docked = placement, rail.docksShared { shown = .docked(.topCenter) }
        return EditorToolbarLayout.frame(for: shown, size: toolbarSize(of: rail), in: usable)
    }

    /// The expanded rail for a window `width` wide. Floating and docked rails share it, so
    /// docking and undocking never resize the rail.
    ///
    /// The rail grows to show every tool, including the planned ones, while the docks stay
    /// `minimumDockTravel` apart. A window too narrow to keep them apart with every working
    /// control showing shares one dock slot and lets the rail use its whole width. The planned
    /// tools show as a whole group or not at all, and the rows scroll whatever does not fit. The
    /// single compact row always scrolls on to the planned tools.
    func rail(forHostWidth width: CGFloat) -> NotebookToolbarRail {
        let available = max(width - 2 * EditorToolbarLayout.margin, 0)
        let travel = available - 2 * Self.minimumDockTravel
        let grip = Self.gripColumnWidth
        let working = toolRow(includingUpcoming: false)
        let complete = toolRow(includingUpcoming: true)
        let ink = foldsInkOptions ? nil : inkRow(swatches)
        let inkWidth = ink.map { $0.contentWidth + Self.inkCapWidth } ?? 0
        let quickInkWidth = foldsInkOptions ? 0 : inkRow(EditorInkCatalog.swatches).contentWidth + Self.inkCapWidth
        let core = grip + max(working.contentWidth + toolCapWidth, quickInkWidth)
        let docksShared = core > travel
        let limit = docksShared ? available : travel
        var railWidth = min(grip + max(complete.contentWidth + toolCapWidth, inkWidth), limit)
        let showsUpcoming = foldsInkOptions || grip + complete.contentWidth + toolCapWidth <= railWidth
        if !showsUpcoming {
            railWidth = min(grip + max(working.contentWidth + toolCapWidth, inkWidth), limit)
        }
        let tools = showsUpcoming ? complete : working
        let rows = railWidth - grip
        return NotebookToolbarRail(
            size: CGSize(width: railWidth, height: expandedHeight),
            docksShared: docksShared, showsUpcoming: showsUpcoming,
            toolRow: tools, inkRow: ink,
            toolRowOverflows: tools.contentWidth + toolCapWidth > rows + 0.5,
            inkRowOverflows: ink != nil && inkWidth > rows + 0.5
        )
    }

    /// Room after the tool strip: the trailing inset, or at compact width a divider, the
    /// current-ink chip and any collapse key before it.
    var toolCapWidth: CGFloat {
        let inset = NotebookTheme.stripInsets.right
        guard foldsInkOptions else { return inset }
        let collapseKey = showsCollapseControl ? NotebookTheme.itemSpacing + NotebookTheme.controlSize : 0
        return Self.groupGap + NotebookTheme.currentInkChipWidth + collapseKey + inset
    }

    /// Room after the ink strip, which never scrolls: a divider, the custom colour well and the
    /// trailing inset.
    static let inkCapWidth = groupGap + NotebookTheme.controlSize + NotebookTheme.stripInsets.right

    /// The ink families, then the eraser, lasso and ruler, then the widths, then the planned
    /// tools after a caption. At compact width the widths live in the current-ink chip's panel.
    func toolRow(includingUpcoming: Bool) -> NotebookStripRow {
        var items: [NotebookStripItem] = EditorInkFamily.allCases.map { .family($0) }
        items += [.divider(0), .eraser, .lasso, .ruler]
        if !foldsInkOptions { items += [.divider(1)] + EditorWidthStep.allCases.map { .width($0) } }
        if includingUpcoming {
            items += [.divider(2), .upcomingLabel] + NotebookUpcomingFeature.placed(.toolStrip).map { .upcoming($0) }
        }
        return row(items)
    }

    /// The presets lead, so they show at rest on every regular-width window; the swatches
    /// follow, custom colours newest first.
    func inkRow(_ swatches: [EditorInkColor]) -> NotebookStripRow {
        row(EditorInkCatalog.presets.map { .preset($0) } + [.divider(0)] + swatches.map { .swatch($0) })
    }

    private func row(_ items: [NotebookStripItem]) -> NotebookStripRow {
        NotebookStripRow(items: items) { item in
            switch item {
            case .divider: Self.dividerWidth
            case let .preset(preset): NotebookPresetChip.width(for: preset, at: dynamicTypeSize)
            default: NotebookTheme.controlSize
            }
        }
    }
}

/// The expanded rail in one window width.
struct NotebookToolbarRail: Equatable {
    let size: CGSize
    /// The window is too narrow to tell the docks apart, so every docked rail rests in the
    /// centre and one dock slot stands for all three.
    let docksShared: Bool
    /// Whether the planned tools close the tool row: at regular width only where the whole group
    /// fits, and always on the scrolling compact row.
    let showsUpcoming: Bool
    let toolRow: NotebookStripRow
    /// Nil at compact width, where the ink controls fold into the current-ink chip.
    let inkRow: NotebookStripRow?
    /// A row wider than its strip keeps room for a trailing chevron that pages it.
    let toolRowOverflows: Bool
    let inkRowOverflows: Bool

    /// The disabled placeholders that close the tool row.
    var upcomingTools: [NotebookUpcomingFeature] {
        showsUpcoming ? NotebookUpcomingFeature.placed(.toolStrip) : []
    }
}

// MARK: - Strips

/// A control, caption or divider in one of the rail's scrolling strips.
enum NotebookStripItem: Hashable, Identifiable {
    case family(EditorInkFamily)
    case eraser
    case lasso
    case ruler
    case width(EditorWidthStep)
    /// The caption that introduces the planned tools.
    case upcomingLabel
    case upcoming(NotebookUpcomingFeature)
    case preset(EditorInkPreset)
    case swatch(EditorInkColor)
    /// A hairline between groups, numbered to tell a row's dividers apart.
    case divider(Int)

    var id: String {
        switch self {
        case let .family(family): "family.\(family.rawValue)"
        case .eraser: "eraser"
        case .lasso: "lasso"
        case .ruler: "ruler"
        case let .width(step): "width.\(step.rawValue)"
        case .upcomingLabel: "upcoming"
        case let .upcoming(feature): "upcoming.\(feature.id)"
        case let .preset(preset): "preset.\(preset.id)"
        case let .swatch(color):
            // The shelf keeps one swatch per quantized colour, so its 8-bit steps name each apart.
            "swatch." + [color.red, color.green, color.blue, color.alpha].map { String(Int(($0 * 255).rounded())) }
                .joined(separator: ".")
        case let .divider(index): "divider.\(index)"
        }
    }

    /// Dividers carry nothing to read or press, so they never count as a whole control shown.
    var isDivider: Bool {
        if case .divider = self { return true }
        return false
    }
}

/// One item of a strip at the width the strip lays it out at.
struct NotebookStripSlot: Equatable, Identifiable {
    let item: NotebookStripItem
    /// Leading edge in the strip's content, after the leading inset.
    let minX: CGFloat
    let width: CGFloat

    var id: String { item.id }
    var maxX: CGFloat { minX + width }
}

/// A strip's content at fixed widths. The rail's width rule, the resting mask, snapping and
/// paging all measure these slots, which are exactly what the strip lays out.
struct NotebookStripRow: Equatable {
    /// A control paged or snapped into view lands this far in, clear of the leading chevron.
    static let leadingClearance = NotebookTheme.controlSize + NotebookTheme.itemSpacing

    let slots: [NotebookStripSlot]
    /// The leading inset and every slot with its spacing, which the rail's width rule counts. It
    /// ends at the last control, since whatever follows the strip supplies the trailing inset.
    let contentWidth: CGFloat

    init(items: [NotebookStripItem], width: (NotebookStripItem) -> CGFloat) {
        var x = NotebookTheme.stripInsets.left
        var slots: [NotebookStripSlot] = []
        for item in items {
            if !slots.isEmpty { x += NotebookTheme.itemSpacing }
            let slot = NotebookStripSlot(item: item, minX: x, width: width(item))
            slots.append(slot)
            x = slot.maxX
        }
        self.slots = slots
        contentWidth = x
    }

    private var controls: [NotebookStripSlot] { slots.filter { !$0.item.isDivider } }

    /// The furthest the strip scrolls: far enough to show its last control whole, then on to the
    /// next stop where a control sits just clear of the leading chevron. The width left over
    /// then shows after the last control instead of as a gap before the first.
    func maximumOffset(containerWidth: CGFloat) -> CGFloat {
        let end = contentWidth - containerWidth
        guard end > 0.5 else { return 0 }
        return controls.lazy.map { $0.minX - Self.leadingClearance }.first { $0 >= end - 0.5 } ?? end
    }

    /// Room after the last control that lets the strip reach its maximum offset. A strip that
    /// fits needs none.
    func trailingRoom(containerWidth: CGFloat) -> CGFloat {
        let maximum = maximumOffset(containerWidth: containerWidth)
        guard maximum > 0 else { return 0 }
        return max(maximum + containerWidth - contentWidth, 0)
    }

    /// The width the strip scrolls through in a container, its trailing room included.
    func scrollWidth(containerWidth: CGFloat) -> CGFloat {
        contentWidth + trailingRoom(containerWidth: containerWidth)
    }

    /// Offsets the strip may rest at: either end, or with a control just clear of the leading
    /// chevron.
    func restingOffsets(containerWidth: CGFloat) -> [CGFloat] {
        let maximum = maximumOffset(containerWidth: containerWidth)
        let stops = controls.map { min(max($0.minX - Self.leadingClearance, 0), maximum) }
        return Array(Set([0, maximum] + stops)).sorted()
    }

    /// The resting offset nearest to where a scroll would end.
    func restingOffset(near proposed: CGFloat, containerWidth: CGFloat) -> CGFloat {
        restingOffsets(containerWidth: containerWidth).min { abs($0 - proposed) < abs($1 - proposed) } ?? 0
    }

    /// Pages forward so that the first control not wholly shown becomes the first one shown.
    func trailingPage(from overflow: NotebookStripOverflow) -> CGFloat {
        let width = overflow.containerWidth
        let maximum = maximumOffset(containerWidth: width)
        guard let hidden = controls.first(where: { $0.maxX > overflow.offset + width + 0.5 }) else { return maximum }
        let target = min(max(hidden.minX - Self.leadingClearance, 0), maximum)
        if target > overflow.offset + 0.5 { return target }
        return restingOffsets(containerWidth: width).first { $0 > overflow.offset + 0.5 } ?? maximum
    }

    /// Pages back so that the nearest control hidden past the leading edge becomes the last one
    /// shown.
    func leadingPage(from overflow: NotebookStripOverflow) -> CGFloat {
        let width = overflow.containerWidth
        guard let hidden = controls.last(where: { $0.minX < overflow.offset + Self.leadingClearance - 0.5 }) else {
            return 0
        }
        let earlier = restingOffsets(containerWidth: width).filter { $0 < overflow.offset - 0.5 }
        return earlier.first { $0 + width >= hidden.maxX - 0.5 } ?? earlier.last ?? 0
    }

    /// The offset that shows `id` first, just clear of the leading chevron.
    func offset(showing id: NotebookStripItem.ID, containerWidth: CGFloat) -> CGFloat {
        guard let slot = slots.first(where: { $0.id == id }) else { return 0 }
        return min(max(slot.minX - Self.leadingClearance, 0), maximumOffset(containerWidth: containerWidth))
    }

    /// The part of the strip shown at rest: from the first whole control clear of the leading
    /// chevron to the end of the last whole control, so no part of a control is ever drawn.
    func restingMask(for overflow: NotebookStripOverflow) -> NotebookStripMask {
        let offset = overflow.offset
        let width = overflow.containerWidth
        let start: CGFloat
        if overflow.hidesLeading {
            let first = controls.first { $0.minX >= offset + NotebookTheme.controlSize - 0.5 }
            start = (first?.minX ?? offset + width) - offset
        } else {
            start = 0
        }
        let end: CGFloat
        if overflow.hidesTrailing {
            let last = controls.last { $0.maxX <= offset + width + 0.5 }
            end = (last?.maxX ?? offset) - offset
        } else {
            end = width
        }
        return NotebookStripMask(start: min(max(start, 0), width), end: min(max(end, start), width))
    }
}

/// The span of a strip drawn at rest, in the strip's own coordinates.
struct NotebookStripMask: Equatable {
    /// Length of the fade at an edge with hidden controls while the strip moves.
    static let fadeLength: CGFloat = 16

    let start: CGFloat
    let end: CGFloat
}

/// How far a scrolling strip's tools extend past either edge.
struct NotebookStripOverflow: Equatable {
    static let none = NotebookStripOverflow(offset: 0, contentWidth: 0, containerWidth: 0)

    let offset: CGFloat
    let contentWidth: CGFloat
    let containerWidth: CGFloat

    init(offset: CGFloat, contentWidth: CGFloat, containerWidth: CGFloat) {
        self.offset = offset
        self.contentWidth = contentWidth
        self.containerWidth = containerWidth
    }

    init(_ geometry: ScrollGeometry) {
        self.init(
            offset: geometry.contentOffset.x, contentWidth: geometry.contentSize.width,
            containerWidth: geometry.containerSize.width
        )
    }

    var hidesLeading: Bool { offset > 1 }
    var hidesTrailing: Bool { offset < maximumOffset - 1 }
    var hiddenEdges: HiddenEdges { HiddenEdges(leading: hidesLeading, trailing: hidesTrailing) }

    private var maximumOffset: CGFloat { max(contentWidth - containerWidth, 0) }

    /// The part of the overflow the strip draws, which changes only when an edge is reached or left.
    struct HiddenEdges: Equatable {
        static let none = HiddenEdges(leading: false, trailing: false)

        let leading: Bool
        let trailing: Bool
    }
}

/// The strip's latest scroll state, kept out of view state so scrolling does not redraw the
/// strip on every frame. It publishes nothing; it is an observable object only so the strip
/// creates it once rather than on every rebuild of the rail.
@MainActor
private final class NotebookStripGeometry: ObservableObject {
    var overflow = NotebookStripOverflow.none
    var isMoving = false
}

/// Lets a flicked strip come to rest at an end or with a whole control just clear of the
/// leading chevron.
private struct NotebookStripSnapping: ScrollTargetBehavior {
    let row: NotebookStripRow

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        target.rect.origin.x = row.restingOffset(near: target.rect.minX, containerWidth: context.containerSize.width)
    }
}

/// A horizontally scrolling row of controls with hidden indicators. At rest only whole
/// controls show; while it moves its edges fade instead. Separate chevrons page through
/// controls hidden past either edge: the leading one over the strip's start, the trailing one
/// in a slot after it that the row keeps while it is too wide.
@MainActor
private struct NotebookToolStrip<Control: View>: View {
    let label: String
    let row: NotebookStripRow
    let reservesTrailingChevron: Bool
    /// Each change scrolls `revealTarget` into view just clear of the leading edge.
    var reveals: UInt64 = 0
    var revealTarget: NotebookStripItem.ID?
    @ViewBuilder let control: (NotebookStripItem) -> Control
    @State private var position = ScrollPosition(edge: .leading)
    @StateObject private var geometry = NotebookStripGeometry()
    /// Changes only when the strip is resized, which sets its trailing room.
    @State private var containerWidth: CGFloat = 0
    @State private var hiddenEdges = NotebookStripOverflow.HiddenEdges.none
    /// Nil until the strip is first measured, when it shows in full.
    @State private var restingMask: NotebookStripMask?
    @State private var isMoving = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: NotebookTheme.itemSpacing) {
                    ForEach(row.slots) { slot in
                        control(slot.item)
                            .frame(width: slot.width, height: NotebookTheme.controlSize)
                    }
                }
                .padding(.leading, NotebookTheme.stripInsets.left)
                .padding(.trailing, row.trailingRoom(containerWidth: containerWidth))
                .padding(.vertical, NotebookTheme.stripInsets.top)
            }
            .scrollIndicators(.hidden)
            // The system's edge effect would blur the shell's top edge wherever the rail meets
            // the top of the window; the strip draws its own edges.
            .scrollEdgeEffectHidden()
            .scrollPosition($position)
            .scrollTargetBehavior(NotebookStripSnapping(row: row))
            .onScrollGeometryChange(for: NotebookStripOverflow.self) { geometry in
                NotebookStripOverflow(geometry)
            } action: { _, value in
                geometry.overflow = value
                if containerWidth != value.containerWidth { containerWidth = value.containerWidth }
                if hiddenEdges != value.hiddenEdges { hiddenEdges = value.hiddenEdges }
                // A programmatic scroll without animation, or a resize, settles without a phase change.
                if !geometry.isMoving { updateRestingMask() }
            }
            .onScrollPhaseChange { _, phase in
                let moving = phase != .idle
                geometry.isMoving = moving
                if !moving { updateRestingMask() }
                guard moving != isMoving else { return }
                withAnimation(reduceMotion ? nil : .linear(duration: NotebookTheme.stripFadeDuration)) {
                    isMoving = moving
                }
            }
            .mask { mask }
            .overlay(alignment: .leading) {
                if hiddenEdges.leading {
                    chevron("chevron.left", label: "Show previous \(label.lowercased())") { row.leadingPage(from: $0) }
                }
            }
            if reservesTrailingChevron {
                ZStack {
                    if hiddenEdges.trailing {
                        chevron("chevron.right", label: "Show more \(label.lowercased())") { row.trailingPage(from: $0) }
                    }
                }
                .frame(width: NotebookTheme.controlSize)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .onChange(of: reveals) {
            guard let revealTarget else { return }
            let target = row.offset(showing: revealTarget, containerWidth: geometry.overflow.containerWidth)
            withAnimation(pageAnimation) { position.scrollTo(x: target) }
        }
    }

    private var pageAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: NotebookTheme.stripPageDuration)
    }

    private func updateRestingMask() {
        let mask = row.restingMask(for: geometry.overflow)
        if restingMask != mask { restingMask = mask }
    }

    /// At rest a hard edge just past the last whole control, and clear under the leading
    /// chevron up to the first whole one; while moving, a short fade at each edge with hidden
    /// controls. The two cross-fade as the strip starts and settles.
    private var mask: some View {
        ZStack(alignment: .leading) {
            Group {
                if let restingMask {
                    Color.black
                        .frame(width: max(restingMask.end - restingMask.start, 0))
                        .offset(x: restingMask.start)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Color.black
                }
            }
            .opacity(isMoving ? 0 : 1)
            HStack(spacing: 0) {
                if hiddenEdges.leading {
                    Color.clear.frame(width: NotebookTheme.controlSize)
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: NotebookStripMask.fadeLength)
                }
                Color.black
                if hiddenEdges.trailing {
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: NotebookStripMask.fadeLength)
                }
            }
            .opacity(isMoving ? 1 : 0)
        }
    }

    private func chevron(
        _ symbol: String, label: String, offset: @escaping (NotebookStripOverflow) -> CGFloat
    ) -> some View {
        Button {
            withAnimation(pageAnimation) { position.scrollTo(x: offset(geometry.overflow)) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: NotebookTheme.chevronSize, weight: .semibold))
                .modifier(NotebookKeyForeground())
                .frame(width: NotebookTheme.controlSize, height: NotebookTheme.controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotebookKeyStyle())
        .accessibilityLabel(label)
        .accessibilityShowsLargeContentViewer {
            Label(label, systemImage: symbol)
        }
    }
}

// MARK: - Rail

/// The ivory tool rail on one shell. The first row holds the ink families, the eraser, lasso
/// and ruler, the widths and the planned tools; the second the presets and colours, with the
/// custom colour well fixed at its end. The grip column at the leading edge comes from the
/// host, which owns placement; a floating rail adds its collapse key under the grip, or on the
/// single compact row after the current-ink chip.
@MainActor
struct NotebookToolbar<Grip: View>: View {
    @ObservedObject var store: NotebookSceneToolStore
    let composition: NotebookToolbarComposition
    let rail: NotebookToolbarRail
    let collapse: () -> Void
    private let grip: Grip
    @State private var showsInkPanel = false
    @State private var inkRowReveals: UInt64 = 0
    @State private var highlightsColors = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    init(
        store: NotebookSceneToolStore, composition: NotebookToolbarComposition, rail: NotebookToolbarRail,
        collapse: @escaping () -> Void, @ViewBuilder grip: () -> Grip
    ) {
        self.store = store
        self.composition = composition
        self.rail = rail
        self.collapse = collapse
        self.grip = grip()
    }

    private var actions: NotebookToolbarActions { NotebookToolbarActions(store: store) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NotebookTheme.panelCornerRadius, style: .continuous)
        let marks = NotebookInkMarks(tool: store.tool, custom: store.toolbar.customSwatches)
        HStack(spacing: 0) {
            gripColumn
                .frame(width: NotebookToolbarComposition.gripColumnWidth)
            VStack(spacing: 0) {
                toolRow(marks)
                    .frame(height: NotebookTheme.rowHeight)
                if let inkRow = rail.inkRow {
                    NotebookChromeDivider(axis: .horizontal)
                        .frame(height: NotebookTheme.rowSpacing)
                    HStack(spacing: 0) {
                        NotebookToolStrip(
                            label: "Ink", row: inkRow, reservesTrailingChevron: rail.inkRowOverflows,
                            reveals: inkRowReveals, revealTarget: firstSwatchID(in: inkRow)
                        ) { control($0, marks: marks) }
                        HStack(spacing: NotebookTheme.itemSpacing) {
                            NotebookChromeDivider(axis: .vertical)
                            NotebookCustomColorWell(
                                store: store, isSelected: marks.marksCustomColor, isHighlighted: highlightsColors
                            )
                        }
                        .padding(.leading, NotebookTheme.itemSpacing)
                        .padding(.trailing, NotebookTheme.stripInsets.right)
                    }
                    .frame(height: NotebookTheme.rowHeight)
                }
            }
        }
        .opacity(actions.contentOpacity(for: contrast))
        .clipShape(shape)
        .background { NotebookPanelShell() }
        .contentShape(shape)
        .disabled(!actions.isEnabled)
        .dynamicTypeSize(...NotebookToolbarComposition.textSizeLimit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drawing tools")
        .onChange(of: store.revealRequest) { respondToPencilReveal() }
        .task(id: inkRowReveals) { await highlightColors() }
    }

    /// Docked, the whole column is the grip. Floating over two rows, the grip takes the top half
    /// and the collapse key the bottom, so the rail keeps its docked width.
    @ViewBuilder private var gripColumn: some View {
        if composition.showsCollapseControl && composition.rowCount > 1 {
            VStack(spacing: 0) {
                grip
                collapseKey
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay {
                Rectangle()
                    .fill(NotebookTheme.divider.color)
                    .frame(width: NotebookTheme.gripSeparatorLength, height: NotebookTheme.dividerThickness)
                    .accessibilityHidden(true)
            }
        } else {
            grip
        }
    }

    private var collapseKey: some View {
        let symbol = "arrow.down.right.and.arrow.up.left"
        return Button(action: collapse) {
            Image(systemName: symbol)
                .font(.system(size: NotebookTheme.handleGlyphSize))
                .frame(width: NotebookTheme.controlSize, height: NotebookTheme.controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotebookKeyStyle())
        .accessibilityLabel("Hide tools")
        .accessibilityShowsLargeContentViewer {
            Label("Hide tools", systemImage: symbol)
        }
    }

    private func toolRow(_ marks: NotebookInkMarks) -> some View {
        HStack(spacing: 0) {
            NotebookToolStrip(label: "Tools", row: rail.toolRow, reservesTrailingChevron: rail.toolRowOverflows) {
                control($0, marks: marks)
            }
            if composition.foldsInkOptions {
                HStack(spacing: NotebookTheme.itemSpacing) {
                    NotebookChromeDivider(axis: .vertical)
                    NotebookCurrentInkChip(store: store, showsOptions: $showsInkPanel)
                    if composition.showsCollapseControl { collapseKey }
                }
                .padding(.leading, NotebookTheme.itemSpacing)
                .padding(.trailing, NotebookTheme.stripInsets.right)
            } else {
                Color.clear.frame(width: NotebookTheme.stripInsets.right)
            }
        }
    }

    @ViewBuilder
    private func control(_ item: NotebookStripItem, marks: NotebookInkMarks) -> some View {
        switch item {
        case let .family(family):
            NotebookToolButton(title: family.title, symbol: family.symbol, isSelected: store.tool.kind == .ink(family)) {
                actions.select(.ink(family))
            }
        case .eraser:
            NotebookEraserButton(kind: store.tool.kind, actions: actions)
        case .lasso:
            NotebookToolButton(title: "Lasso", symbol: "lasso", isSelected: store.tool.kind == .lasso) {
                actions.select(.lasso)
            }
        case .ruler:
            NotebookToolButton(title: "Ruler", symbol: "ruler", isSelected: store.tool.isRulerActive, isToggle: true) {
                actions.toggleRuler()
            }
        case let .width(step):
            NotebookWidthButton(step: step, isSelected: marks.width == step) {
                actions.selectWidth(step)
            }
        case .upcomingLabel:
            NotebookUpcomingMark()
        case let .upcoming(feature):
            NotebookUpcomingToolButton(feature: feature)
        case let .preset(preset):
            NotebookPresetChip(preset: preset, isSelected: marks.presetID == preset.id) {
                actions.apply(preset)
            }
        case let .swatch(color):
            NotebookSwatchButton(color: color, isSelected: marks.color == color, isHighlighted: highlightsColors) {
                actions.selectColor(color)
            }
        case .divider:
            NotebookChromeDivider(axis: .vertical)
        }
    }

    private func firstSwatchID(in row: NotebookStripRow) -> NotebookStripItem.ID? {
        row.slots.first { if case .swatch = $0.item { true } else { false } }?.id
    }

    /// The store only counts gestures while the toolbar is available, so every count deserves an answer.
    private func respondToPencilReveal() {
        switch composition.pencilRevealResponse {
        case .expand:
            break
        case .openInkPanel:
            showsInkPanel = true
        case .showInkRow:
            inkRowReveals &+= 1
        }
    }

    private func highlightColors() async {
        guard inkRowReveals > 0 else { return }
        let fade: Animation? = reduceMotion ? nil : .easeInOut(duration: NotebookTheme.stripPageDuration)
        withAnimation(fade) { highlightsColors = true }
        try? await Task.sleep(for: NotebookInkControls.highlightDuration)
        // A newer reveal cancels this one and keeps the highlight for its own full duration.
        guard !Task.isCancelled else { return }
        withAnimation(fade) { highlightsColors = false }
    }
}

/// The presets, colours and widths in the compact current-ink chip's popover. It is presented
/// outside the toolbar's environment, so it disables itself while writing is paused.
@MainActor
struct NotebookInkControls: View {
    /// How long the colours stay highlighted after an Apple Pencil gesture asks for them.
    static let highlightDuration = Duration.seconds(1.2)

    @ObservedObject var store: NotebookSceneToolStore

    private var actions: NotebookToolbarActions { NotebookToolbarActions(store: store) }

    var body: some View {
        let marks = NotebookInkMarks(tool: store.tool, custom: store.toolbar.customSwatches)
        VStack(alignment: .leading, spacing: NotebookTheme.inkPanelSectionSpacing) {
            section("Presets") {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: NotebookTheme.presetColumnMinimum), alignment: .leading)],
                    spacing: 0
                ) {
                    ForEach(EditorInkCatalog.presets) { preset in
                        NotebookPresetChip(preset: preset, isSelected: marks.presetID == preset.id) {
                            actions.apply(preset)
                        }
                    }
                }
            }
            section("Colors") {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: NotebookTheme.controlSize), spacing: NotebookTheme.rowSpacing)],
                    spacing: NotebookTheme.rowSpacing
                ) {
                    ForEach(NotebookSwatchShelf.displayed(custom: store.toolbar.customSwatches), id: \.self) { color in
                        NotebookSwatchButton(color: color, isSelected: marks.color == color) {
                            actions.selectColor(color)
                        }
                    }
                    NotebookCustomColorWell(store: store, isSelected: marks.marksCustomColor)
                }
            }
            section("Width") {
                HStack(spacing: NotebookTheme.itemSpacing) {
                    ForEach(EditorWidthStep.allCases, id: \.self) { step in
                        NotebookWidthButton(step: step, isSelected: marks.width == step) {
                            actions.selectWidth(step)
                        }
                    }
                }
            }
        }
        .padding(NotebookTheme.inkPanelPadding)
        .frame(width: NotebookTheme.inkPanelWidth)
        .disabled(!store.isToolbarAvailable)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: NotebookTheme.itemSpacing) {
            NotebookSectionLabel(title)
            content()
        }
    }
}

/// Compact-width stand-in for the colour row: shows the current ink and opens the full choice.
@MainActor
private struct NotebookCurrentInkChip: View {
    @ObservedObject var store: NotebookSceneToolStore
    @Binding var showsOptions: Bool

    var body: some View {
        Button { showsOptions = true } label: {
            HStack(spacing: NotebookTheme.itemSpacing) {
                Circle()
                    .fill(store.tool.color.swiftUIColor)
                    .overlay(NotebookSwatchRing(color: store.tool.color))
                    .frame(width: NotebookTheme.currentInkSwatchDiameter, height: NotebookTheme.currentInkSwatchDiameter)
                Circle()
                    .modifier(NotebookKeyForeground())
                    .frame(width: store.tool.widthStep.dotDiameter, height: store.tool.widthStep.dotDiameter)
            }
            .frame(width: NotebookTheme.currentInkChipWidth, height: NotebookTheme.controlSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotebookKeyStyle())
        .accessibilityLabel("Ink options")
        .accessibilityValue("\(store.tool.color.accessibilityName), \(store.tool.widthStep.title) width")
        .accessibilityShowsLargeContentViewer {
            Label("Ink options", systemImage: "paintpalette")
        }
        .popover(isPresented: $showsOptions) {
            NotebookInkControls(store: store)
                .presentationCompactAdaptation(.popover)
        }
        .onChange(of: store.isToolbarAvailable) { _, available in
            if !available { showsOptions = false }
        }
    }
}

// MARK: - Controls

@MainActor
private struct NotebookToolButton: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    var isToggle = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            NotebookToolGlyph(symbol: symbol, isSelected: isSelected)
        }
        .buttonStyle(NotebookKeyStyle(isSelected: isSelected))
        // Several inks share similar glyphs, so pointer and Pencil hover name them.
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(traits)
        .accessibilityShowsLargeContentViewer {
            Label(title, systemImage: symbol)
        }
    }

    private var traits: AccessibilityTraits {
        let toggle: AccessibilityTraits = isToggle ? .isToggle : []
        return isSelected ? toggle.union(.isSelected) : toggle
    }
}

/// Opens the eraser in its last mode on tap; touch and hold chooses object or pixel erasing.
@MainActor
private struct NotebookEraserButton: View {
    let kind: EditorToolKind
    let actions: NotebookToolbarActions

    private var selectedMode: EditorEraserMode? {
        if case let .eraser(mode) = kind { return mode }
        return nil
    }

    private var symbol: String { selectedMode == .bitmap ? "eraser.line.dashed" : "eraser" }

    var body: some View {
        Menu {
            modeButton("Object eraser", mode: .vector)
            modeButton("Pixel eraser", mode: .bitmap)
        } label: {
            NotebookToolGlyph(symbol: symbol, isSelected: selectedMode != nil)
        } primaryAction: {
            actions.selectEraser()
        }
        .menuIndicator(.hidden)
        // A button-styled menu draws its label through the toolbar's button style, so the
        // eraser presses and focuses like every other control.
        .menuStyle(.button)
        .buttonStyle(NotebookKeyStyle(isSelected: selectedMode != nil))
        .help("Eraser")
        .accessibilityLabel("Eraser")
        .accessibilityValue(selectedMode.map { $0 == .vector ? "Object" : "Pixel" } ?? "")
        .accessibilityHint("Touch and hold to choose object or pixel erasing.")
        .accessibilityAddTraits(selectedMode == nil ? [] : .isSelected)
        .accessibilityShowsLargeContentViewer {
            Label("Eraser", systemImage: symbol)
        }
    }

    private func modeButton(_ title: String, mode: EditorEraserMode) -> some View {
        Button {
            actions.select(.eraser(mode))
        } label: {
            if selectedMode == mode {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

/// A preset as a short labelled capsule: a recessed well and a mark under the label when
/// selected, an outline otherwise. The full name stays its accessibility label, so it never
/// collides with a swatch's name.
@MainActor
struct NotebookPresetChip: View {
    /// Short names that fit a chip, keyed by preset.
    nonisolated private static let shortTitles = [
        "sepia-fountain": "Sepia",
        "charcoal-monoline": "Charcoal",
        "graphite-pencil": "Graphite",
        "ochre-marker": "Ochre",
    ]

    nonisolated static func shortTitle(for preset: EditorInkPreset) -> String {
        shortTitles[preset.id] ?? preset.name
    }

    /// The chip's width at a text size, which the rail's width rule counts and the chip lays out.
    nonisolated static func width(for preset: EditorInkPreset, at size: DynamicTypeSize) -> CGFloat {
        2 * NotebookTheme.presetChipPadding + NotebookTheme.presetDotDiameter + NotebookTheme.presetDotSpacing
            + labelWidth(shortTitle(for: preset), at: size)
    }

    /// The label's width in the control label face at a text size, rounded up to whole points.
    nonisolated static func labelWidth(_ text: String, at size: DynamicTypeSize) -> CGFloat {
        let size = min(size, NotebookToolbarComposition.textSizeLimit)
        return measuredLabelWidths[size]?[text] ?? measureLabel(text, at: size)
    }

    /// Every short title at every text size the rail is set at, measured once, as the rail's
    /// width rule asks for them on each layout.
    nonisolated private static let measuredLabelWidths: [DynamicTypeSize: [String: CGFloat]] = {
        let titles = EditorInkCatalog.presets.map(shortTitle)
        let sizes = DynamicTypeSize.allCases.filter { $0 <= NotebookToolbarComposition.textSizeLimit }
        return Dictionary(uniqueKeysWithValues: sizes.map { size in
            (size, Dictionary(uniqueKeysWithValues: titles.map { ($0, measureLabel($0, at: size)) }))
        })
    }()

    /// The face takes its text style's size at the text size, as SwiftUI sets it.
    nonisolated private static func measureLabel(_ text: String, at size: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        let style = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits)
        let font = UIFont.systemFont(ofSize: style.pointSize, weight: .medium)
        return (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    let preset: EditorInkPreset
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let title = Self.shortTitle(for: preset)
        Button(action: action) {
            HStack(spacing: NotebookTheme.presetDotSpacing) {
                Circle()
                    .fill(preset.color.swiftUIColor)
                    .overlay {
                        Circle().strokeBorder(
                            NotebookTheme.shadowTone.color.opacity(NotebookTheme.swatchRingOpacity),
                            lineWidth: NotebookTheme.shellBorderWidth
                        )
                    }
                    .frame(width: NotebookTheme.presetDotDiameter, height: NotebookTheme.presetDotDiameter)
                Text(title)
                    .font(NotebookTheme.controlLabel.font)
                    // Capped here as well as on the rail, so the label never outgrows the width
                    // measured for it, as in the compact ink panel presented outside the rail.
                    .dynamicTypeSize(...NotebookToolbarComposition.textSizeLimit)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: Self.labelWidth(title, at: dynamicTypeSize), height: NotebookTheme.presetChipHeight)
                    .overlay(alignment: .bottom) {
                        if isSelected {
                            Capsule()
                                .frame(width: NotebookTheme.selectionMarkSize.width, height: NotebookTheme.selectionMarkSize.height)
                                .padding(.bottom, NotebookTheme.presetMarkInset)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .modifier(NotebookKeyForeground())
            .padding(.horizontal, NotebookTheme.presetChipPadding)
            .frame(height: NotebookTheme.presetChipHeight)
            .background {
                // Outlined wherever the key draws no well, so a selected chip keeps its capsule
                // while writing is paused.
                if !(isSelected && isEnabled) {
                    Capsule().strokeBorder(NotebookTheme.panelLowerEdge.color, lineWidth: NotebookTheme.shellBorderWidth)
                }
            }
            .frame(minHeight: NotebookTheme.controlSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotebookKeyStyle(isSelected: isSelected, shape: .capsule))
        .help(preset.name)
        .accessibilityLabel("\(preset.name) preset")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer {
            Label(preset.name, systemImage: "circle.fill")
        }
    }
}

@MainActor
private struct NotebookSwatchButton: View {
    let color: EditorInkColor
    let isSelected: Bool
    var isHighlighted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color.swiftUIColor)
                .overlay(NotebookSwatchRing(color: color))
                .frame(width: NotebookTheme.swatchDiameter, height: NotebookTheme.swatchDiameter)
                .overlay {
                    if isSelected { NotebookSwatchCheckmark(color: color) }
                }
                .frame(width: NotebookTheme.controlSize, height: NotebookTheme.controlSize)
                .background {
                    if isHighlighted { NotebookColorHighlight() }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(NotebookKeyStyle(isSelected: isSelected))
        .accessibilityLabel(color.accessibilityName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer {
            Label(color.accessibilityName, systemImage: "circle.fill")
        }
    }
}

/// Marks the colours an Apple Pencil gesture asked to see.
private struct NotebookColorHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: NotebookTheme.selectedWellCornerRadius, style: .continuous)
            .fill(NotebookTheme.selectedWell.color.opacity(NotebookTheme.pressedWellOpacity))
            .accessibilityHidden(true)
    }
}

/// The hairline inside a swatch that keeps it defined on the shell and in a well. A colour too
/// faint to stand out from the ink row by itself gets a dark ring instead.
private struct NotebookSwatchRing: View {
    let color: EditorInkColor
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Circle().strokeBorder(tone, lineWidth: NotebookTheme.shellBorderWidth)
    }

    private var tone: Color {
        if contrast == .increased { return NotebookTheme.panelLowerEdge.color }
        if NotebookSwatchContrast.isFaint(color) { return NotebookTheme.glyphSecondary.color }
        return NotebookTheme.shadowTone.color.opacity(NotebookTheme.swatchRingOpacity)
    }
}

/// The checkmark on a selected colour, dark on light colours and light on dark ones.
private struct NotebookSwatchCheckmark: View {
    let color: EditorInkColor
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: NotebookTheme.swatchCheckmarkSize, weight: .bold))
            .foregroundStyle(NotebookSwatchContrast.mark(for: color, contrast: contrast).color)
            .accessibilityHidden(true)
    }
}

/// Readable marks and rings for swatches, measured against what is actually behind them.
enum NotebookSwatchContrast {
    /// The ink row's shell at its centre, where the swatches sit: 76% down the rail's gradient.
    static var inkRowShell: EditorInkColor {
        let top = NotebookSwatchShelf.color(from: NotebookTheme.panelTop.uiColor)
        let bottom = NotebookSwatchShelf.color(from: NotebookTheme.panelBottom.uiColor)
        let position = 0.76
        return EditorInkColor(
            red: top.red + (bottom.red - top.red) * position,
            green: top.green + (bottom.green - top.green) * position,
            blue: top.blue + (bottom.blue - top.blue) * position
        )
    }

    /// The selected swatch as it shows in its well, which darkens under Increase Contrast.
    static func background(for color: EditorInkColor, contrast: ColorSchemeContrast) -> EditorInkColor {
        let traits = UITraitCollection(accessibilityContrast: UIAccessibilityContrast(contrast))
        let well = NotebookSwatchShelf.color(from: NotebookTheme.selectedWell.uiColor.resolvedColor(with: traits))
        return composite(color, over: well)
    }

    static func mark(for color: EditorInkColor, contrast: ColorSchemeContrast) -> NotebookTheme.Tone {
        let surface = background(for: color, contrast: contrast)
        let dark = NotebookSwatchShelf.color(from: NotebookTheme.glyph.uiColor)
        let light = NotebookSwatchShelf.color(from: NotebookTheme.paperIvory.uiColor)
        return dark.contrastRatio(against: surface) >= light.contrastRatio(against: surface)
            ? NotebookTheme.glyph : NotebookTheme.paperIvory
    }

    /// True for a colour under 3:1 against the ink row, which its own edge cannot define.
    static func isFaint(_ color: EditorInkColor) -> Bool {
        composite(color, over: inkRowShell).contrastRatio(against: inkRowShell) < 3
    }

    private static func composite(_ color: EditorInkColor, over background: EditorInkColor) -> EditorInkColor {
        let alpha = color.alpha
        return EditorInkColor(
            red: color.red * alpha + background.red * (1 - alpha),
            green: color.green * alpha + background.green * (1 - alpha),
            blue: color.blue * alpha + background.blue * (1 - alpha)
        )
    }
}

/// Opens the system colour picker. Selected, it shows the colour in use, which is not on the shelf.
@MainActor
private struct NotebookCustomColorWell: View {
    /// A muted hue wheel that marks the well as the way to any colour.
    private static let hues = stride(from: 0.0, through: 1.0, by: 1.0 / 6).map {
        Color(hue: $0, saturation: 0.55, brightness: 0.8)
    }
    private static let ringWidth: CGFloat = 4

    @ObservedObject var store: NotebookSceneToolStore
    let isSelected: Bool
    var isHighlighted = false
    @State private var isPicking = false
    @State private var pick = NotebookColorPick()

    private var actions: NotebookToolbarActions { NotebookToolbarActions(store: store) }

    var body: some View {
        Button { isPicking = true } label: {
            Circle()
                .strokeBorder(AngularGradient(colors: Self.hues, center: .center), lineWidth: Self.ringWidth)
                .background {
                    if isSelected {
                        Circle()
                            .fill(store.tool.color.swiftUIColor)
                            .padding(Self.ringWidth)
                    }
                }
                .frame(width: NotebookTheme.swatchDiameter, height: NotebookTheme.swatchDiameter)
                .overlay {
                    if isSelected { NotebookSwatchCheckmark(color: store.tool.color) }
                }
                .frame(width: NotebookTheme.controlSize, height: NotebookTheme.controlSize)
                .background {
                    if isHighlighted { NotebookColorHighlight() }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(NotebookKeyStyle(isSelected: isSelected))
        .accessibilityLabel("Custom color")
        .accessibilityValue(isSelected ? store.tool.color.accessibilityName : "")
        .accessibilityHint("Opens the color picker. The color showing when you close it is added to your swatches.")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer {
            Label("Custom color", systemImage: "paintpalette")
        }
        .sheet(isPresented: $isPicking) {
            NotebookColorPicker(initial: store.tool.color, pick: pick) { isPicking = false }
                .presentationBackground(NotebookTheme.panelSurface.color)
        }
        .onChange(of: isPicking) { _, picking in
            if !picking { pick.finish(with: actions) }
        }
        .onChange(of: store.isToolbarAvailable) { _, available in
            if !available { isPicking = false }
        }
    }
}

/// One visit to the colour picker. The picker reports every colour the user passes on the
/// way, so only the one showing when it closes is kept, and only once.
@MainActor
final class NotebookColorPick {
    private var latest: EditorInkColor?

    func record(_ color: UIColor) {
        latest = NotebookSwatchShelf.color(from: color)
    }

    /// Adds the last colour shown as a swatch and selects it. A visit without a choice, or one
    /// already finished, changes nothing; so does one that ends while writing is paused.
    func finish(with actions: NotebookToolbarActions) {
        guard let latest else { return }
        self.latest = nil
        actions.addCustomColor(latest)
    }
}

/// The system colour picker. It reports colours to a `NotebookColorPick` and asks to be
/// closed when the user finishes; the well keeps the colour once the presentation has ended,
/// however it ended.
struct NotebookColorPicker: UIViewControllerRepresentable {
    let initial: EditorInkColor
    let pick: NotebookColorPick
    let close: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(pick: pick, close: close)
    }

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = false
        picker.selectedColor = initial.platformColor
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIColorPickerViewController, context: Context) {
        context.coordinator.close = close
    }

    @MainActor
    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        let pick: NotebookColorPick
        var close: @MainActor () -> Void

        init(pick: NotebookColorPick, close: @escaping @MainActor () -> Void) {
            self.pick = pick
            self.close = close
        }

        func colorPickerViewController(
            _ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool
        ) {
            pick.record(color)
        }

        func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
            close()
        }
    }
}

@MainActor
private struct NotebookWidthButton: View {
    let step: EditorWidthStep
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .modifier(NotebookKeyForeground())
                .frame(width: step.dotDiameter, height: step.dotDiameter)
                .frame(width: NotebookTheme.controlSize, height: NotebookTheme.controlSize)
                .overlay(alignment: .bottom) {
                    if isSelected { NotebookSelectionMark() }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(NotebookKeyStyle(isSelected: isSelected))
        .accessibilityLabel("\(step.title) width")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer {
            Label("\(step.title) width", systemImage: "circle.fill")
        }
    }
}

/// A tool symbol in a 44-point control, with the selection mark when selected. The well
/// behind it comes from `NotebookKeyStyle`.
@MainActor
struct NotebookToolGlyph: View {
    let symbol: String
    let isSelected: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(NotebookTheme.glyphFont)
            .modifier(NotebookKeyForeground())
            .frame(width: NotebookTheme.controlSize, height: NotebookTheme.controlSize)
            .overlay(alignment: .bottom) {
                if isSelected { NotebookSelectionMark() }
            }
            .contentShape(Rectangle())
    }
}

extension EditorInkFamily {
    var title: String {
        switch self {
        case .pen: "Pen"
        case .monoline: "Monoline"
        case .fountainPen: "Fountain pen"
        case .reed: "Reed pen"
        case .pencil: "Pencil"
        case .marker: "Marker"
        case .crayon: "Crayon"
        case .watercolor: "Watercolor"
        }
    }

    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .monoline: "line.diagonal"
        case .fountainPen: "signature"
        case .reed: "paintbrush.pointed"
        case .pencil: "pencil"
        case .marker: "highlighter"
        case .crayon: "scribble.variable"
        case .watercolor: "paintbrush"
        }
    }
}

extension EditorToolKind {
    /// The symbol the toolbar shows for this tool, as on its own key.
    var symbol: String {
        switch self {
        case let .ink(family): family.symbol
        case .eraser(.vector): "eraser"
        case .eraser(.bitmap): "eraser.line.dashed"
        case .lasso: "lasso"
        }
    }

    var title: String {
        switch self {
        case let .ink(family): family.title
        case .eraser(.vector): "Object eraser"
        case .eraser(.bitmap): "Pixel eraser"
        case .lasso: "Lasso"
        }
    }
}

private extension EditorWidthStep {
    var title: String {
        switch self {
        case .fine: "Fine"
        case .medium: "Medium"
        case .bold: "Bold"
        }
    }

    var dotDiameter: CGFloat {
        switch self {
        case .fine: 5
        case .medium: 9
        case .bold: 14
        }
    }
}

extension EditorInkColor {
    /// Spoken names for the quick swatches, in catalog order.
    private static let catalogNames: [EditorInkColor: String] = Dictionary(
        zip(EditorInkCatalog.swatches, ["Charcoal", "Sepia", "Rust", "Sage", "Dusty blue", "Plum", "Ochre"]),
        uniquingKeysWith: { first, _ in first }
    )

    var swiftUIColor: Color { Color(uiColor: platformColor) }

    var accessibilityName: String {
        Self.catalogNames[self] ?? platformColor.accessibilityName.localizedCapitalized
    }
}
