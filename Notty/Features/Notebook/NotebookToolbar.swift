import NottyCore
import SwiftUI
import UIKit

/// Every toolbar change goes through here, so an unavailable toolbar cannot change the
/// tool or its own preferences, whichever control or gesture fired.
@MainActor
struct NotebookToolbarActions {
    /// Where Float, from the grip's actions or the notebook menu, places a docked toolbar: centred,
    /// near the top of the page.
    nonisolated static let floatingPlacement = EditorToolbarPlacement.floating(CGPoint(x: 0.5, y: 0.25))

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

    /// Selects a tool. The eraser and lasso have no settings on the rail's second row, so choosing
    /// either closes it; an ink chosen here leaves the row as it is.
    func select(_ kind: EditorToolKind) {
        guard isEnabled else { return }
        store.update { $0.select(kind) }
        if case .ink = kind { return }
        store.setInkRowOpen(false)
    }

    /// What an ink's key does. On a rail with a second row, which holds the ink's presets and
    /// colours, it selects the ink and opens the row; the key of the ink in use closes an open row
    /// instead, so the same key shows and hides its settings. Without that row, as at compact width
    /// where the current-ink chip holds them, it only selects the ink.
    func chooseInk(_ family: EditorInkFamily, opensSettings: Bool = true) {
        guard isEnabled else { return }
        let closes = store.isInkRowOpen && store.tool.kind == .ink(family)
        store.update { $0.select(.ink(family)) }
        if opensSettings { store.setInkRowOpen(!closes) }
    }

    /// Opens the second row, as an Apple Pencil gesture asking for the colours does.
    func openInkRow() {
        guard isEnabled else { return }
        store.setInkRowOpen(true)
    }

    /// Selects the eraser in the mode used last, and closes the second row. The tool state keeps
    /// that mode privately and restores it through the same switch the Apple Pencil gesture uses.
    func selectEraser() {
        guard isEnabled else { return }
        store.update { $0.selectEraser() }
        store.setInkRowOpen(false)
    }

    /// The ruler is a tool key of the first row without settings on the second, so it closes the
    /// row like the eraser and lasso: only the ink keys keep it open.
    func toggleRuler() {
        guard isEnabled else { return }
        store.update { $0.isRulerActive.toggle() }
        store.setInkRowOpen(false)
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
/// preferences, the text size and the window size.
struct NotebookToolbarComposition: Equatable {
    /// The rail stops growing with the text size here and shows the Large Content Viewer instead.
    static let textSizeLimit = DynamicTypeSize.xxLarge
    /// A divider with its padding, laid out like a control.
    static let dividerWidth = NotebookTheme.dividerThickness + 2 * NotebookTheme.dividerPadding
    /// The grip column at the rail's leading edge, or at the screen edge of a vertical rail.
    static let gripColumnWidth = NotebookTheme.controlSize
    /// Key edge to key edge across a divider.
    static let groupGap = dividerWidth + 2 * NotebookTheme.itemSpacing

    /// At compact width the colour and width row folds into one current-ink chip.
    let foldsInkOptions: Bool
    /// Where the preferences keep the toolbar.
    let placement: EditorToolbarPlacement
    let isFloating: Bool
    let isCollapsed: Bool
    /// The dock stored in the preferences, nil while the toolbar floats.
    let storedDock: EditorToolbarDock?
    /// The colours on the shelf, quick swatches first.
    let swatches: [EditorInkColor]
    /// The text size the preset labels are set at, never above `textSizeLimit`.
    let dynamicTypeSize: DynamicTypeSize
    /// True under Bold Text, which sets the preset labels heavier and so wider.
    let isBoldText: Bool
    /// Whether the rail shows its second row. Only a rail with an ink row has one; at compact
    /// width the ink folds into the current-ink chip instead.
    let showsInkRow: Bool

    init(
        preferences: EditorToolbarPreferences, horizontalSizeClass: UserInterfaceSizeClass?,
        dynamicTypeSize: DynamicTypeSize = .large, legibilityWeight: LegibilityWeight? = nil, isInkRowOpen: Bool = false
    ) {
        foldsInkOptions = horizontalSizeClass == .compact
        showsInkRow = isInkRowOpen && !foldsInkOptions
        placement = preferences.placement
        switch preferences.placement {
        case let .docked(dock):
            isFloating = false
            storedDock = dock
        case .floating:
            isFloating = true
            storedDock = nil
        }
        isCollapsed = preferences.isCollapsed
        swatches = NotebookSwatchShelf.displayed(custom: preferences.customSwatches)
        self.dynamicTypeSize = min(dynamicTypeSize, Self.textSizeLimit)
        isBoldText = legibilityWeight == .bold
    }

    /// The side docks stand the rail on end in two full columns. At compact width the ink folds
    /// into one chip that a column cannot hold, so there a rail stored at a side rests at the top
    /// until the window widens, and the stored dock is kept.
    var offersSideDocks: Bool { !foldsInkOptions }

    /// Where a docked rail rests in this window; nil while floating.
    var shownDock: EditorToolbarDock? {
        guard let storedDock else { return nil }
        return storedDock.axis == .vertical && !offersSideDocks ? .topCenter : storedDock
    }

    /// Which way the rail's rows run where it rests.
    var axis: EditorToolbarAxis { shownDock?.axis ?? .horizontal }

    /// How the rail lays out where it rests: on end against a side dock, in rows otherwise.
    var orientation: NotebookRailOrientation {
        switch shownDock {
        case .leftEdge: .leftEdge
        case .rightEdge: .rightEdge
        case .topCenter, nil: .horizontal
        }
    }

    var showsRevealHandle: Bool { isCollapsed }
    /// A floating rail ends its first row with its collapse key, after the current-ink chip on the
    /// single compact row, so the key shows whether or not the second row does.
    var showsCollapseControl: Bool { isFloating && !isCollapsed }
    var rowCount: Int { foldsInkOptions ? 1 : 2 }

    var pencilRevealResponse: NotebookToolbarRevealResponse {
        if isCollapsed { return .expand }
        return foldsInkOptions ? .openInkPanel : .showInkRow
    }

    /// The rail's depth across its rows: two rows and the seam between them.
    var expandedHeight: CGFloat {
        CGFloat(rowCount) * NotebookTheme.rowHeight + CGFloat(rowCount - 1) * NotebookTheme.rowSpacing
    }

    /// The size the toolbar keeps for itself: the collapsed handle, or the expanded rail with its
    /// second row whether or not that row shows, so opening it never moves the page or the rail.
    func toolbarSize(forHostWidth width: CGFloat) -> CGSize {
        toolbarSize(of: rail(forHostWidth: width))
    }

    func toolbarSize(of rail: NotebookToolbarRail) -> CGSize {
        showsRevealHandle ? NotebookTheme.collapsedHandleSize : rail.size
    }

    /// Where the collapsed handle, and the stand-in a hidden floating rail leaves, centre from the
    /// rail's stored point: up by half the second row's room, across the middle of the first row,
    /// so collapsing or hiding the rail and bringing it back move nothing that stays in sight.
    var handleOffset: CGSize {
        CGSize(width: 0, height: (NotebookTheme.rowHeight - expandedHeight) / 2)
    }

    /// Where the toolbar as shown centres from a floating rail's stored point.
    var centreOffset: CGSize { showsRevealHandle ? handleOffset : .zero }

    /// The collapsed handle, or the stand-in a hidden floating rail leaves, in `usable`. It keeps
    /// inside the margins at its own size, so it can rest wherever the user leaves it.
    func handleFrame(in usable: CGRect) -> CGRect {
        EditorToolbarLayout.frame(
            for: placement, size: NotebookTheme.collapsedHandleSize, in: usable, centreOffset: handleOffset
        )
    }

    /// The rail laid out for where it rests in `usable`.
    func rail(in usable: CGSize) -> NotebookToolbarRail {
        switch orientation {
        case .horizontal: rail(forHostWidth: usable.width)
        case let side: verticalRail(forHostHeight: usable.height, orientation: side)
        }
    }

    /// The sizes the expanded rail takes at the top dock and at the side docks of `usable`, which
    /// place the dock slots a drag measures against. A docked rail has no collapse key, so a
    /// floating rail measures them without its own.
    func dockSizes(in usable: CGSize) -> EditorToolbarLayout.DockSizes {
        EditorToolbarLayout.DockSizes(
            horizontal: rail(forHostWidth: usable.width, endsWithCollapseKey: false).size,
            vertical: verticalRail(forHostHeight: usable.height, orientation: .leftEdge).size
        )
    }

    /// The sizes the docked rail is drawn at in those docks, with its second row as it is now,
    /// which the dock targets outline.
    func shownDockSizes(in usable: CGSize) -> EditorToolbarLayout.DockSizes {
        EditorToolbarLayout.DockSizes(
            horizontal: rail(forHostWidth: usable.width, endsWithCollapseKey: false).shownSize,
            vertical: verticalRail(forHostHeight: usable.height, orientation: .leftEdge).shownSize
        )
    }

    /// Where the toolbar rests in `usable`: at its shown dock, where it floats, or as its collapsed
    /// handle.
    func frame(in usable: CGRect) -> CGRect {
        frame(of: rail(in: usable.size), in: usable)
    }

    /// The same, for a rail already laid out for `usable`.
    func frame(of rail: NotebookToolbarRail, in usable: CGRect) -> CGRect {
        if showsRevealHandle { return handleFrame(in: usable) }
        let shown = shownDock.map { .docked($0) } ?? placement
        return EditorToolbarLayout.frame(for: shown, size: rail.size, in: usable)
    }

    /// The horizontal rail for a window `width` wide, at the top dock or floating.
    ///
    /// The rail grows to show every tool, including the planned ones, up to the window's width
    /// inside its margins. The planned tools show as a whole group or not at all, and the rows
    /// scroll whatever does not fit. The single compact row always scrolls on to the planned tools.
    /// A floating rail ends its first row with its collapse key. A working control comes before the
    /// planned ones, so where the window cannot fit the key and the whole group, the group gives
    /// way; where the second row is the wider, the key takes room the first row leaves.
    func rail(forHostWidth width: CGFloat) -> NotebookToolbarRail {
        rail(forHostWidth: width, endsWithCollapseKey: showsCollapseControl)
    }

    private func rail(forHostWidth width: CGFloat, endsWithCollapseKey: Bool) -> NotebookToolbarRail {
        let available = max(width - 2 * EditorToolbarLayout.margin, 0)
        let grip = Self.gripColumnWidth
        let cap = toolCapWidth(endsWithCollapseKey: endsWithCollapseKey)
        let working = toolRow(includingUpcoming: false)
        let complete = toolRow(includingUpcoming: true)
        let ink = foldsInkOptions ? nil : inkRow(swatches)
        let inkWidth = ink.map { $0.contentWidth + Self.inkCapWidth } ?? 0
        var railWidth = min(grip + max(complete.contentWidth + cap, inkWidth), available)
        let showsUpcoming = foldsInkOptions || grip + complete.contentWidth + cap <= railWidth
        if !showsUpcoming {
            railWidth = min(grip + max(working.contentWidth + cap, inkWidth), available)
        }
        let tools = showsUpcoming ? complete : working
        let rows = railWidth - grip
        return NotebookToolbarRail(
            orientation: .horizontal, size: CGSize(width: railWidth, height: expandedHeight),
            showsInkRow: showsInkRow, showsUpcoming: showsUpcoming, toolRow: tools, inkRow: ink,
            toolRowOverflows: tools.contentWidth + cap > rows + 0.5,
            inkRowOverflows: ink != nil && inkWidth > rows + 0.5
        )
    }

    /// The rail on end at a side dock of a window `height` tall: the grip column against the
    /// screen edge, then the tools, then the ink column nearest the page, where the second row
    /// opens. The columns run as the rows do and grow to show every tool up to the height inside
    /// the margins, the planned tools as a whole group or not at all; the columns scroll whatever
    /// does not fit.
    func verticalRail(forHostHeight height: CGFloat, orientation: NotebookRailOrientation) -> NotebookToolbarRail {
        let available = max(height - 2 * EditorToolbarLayout.margin, 0)
        let cap = NotebookTheme.stripInsets.right
        let working = toolRow(includingUpcoming: false)
        let complete = toolRow(includingUpcoming: true)
        let ink = inkRow(swatches, axis: .vertical)
        let inkLength = ink.contentWidth + Self.inkCapWidth
        var length = min(max(complete.contentWidth + cap, inkLength), available)
        let showsUpcoming = complete.contentWidth + cap <= length
        if !showsUpcoming {
            length = min(max(working.contentWidth + cap, inkLength), available)
        }
        let tools = showsUpcoming ? complete : working
        let columns = 2 * NotebookTheme.rowHeight + NotebookTheme.rowSpacing
        return NotebookToolbarRail(
            orientation: orientation, size: CGSize(width: Self.gripColumnWidth + columns, height: length),
            showsInkRow: showsInkRow, showsUpcoming: showsUpcoming, toolRow: tools, inkRow: ink,
            toolRowOverflows: tools.contentWidth + cap > length + 0.5,
            inkRowOverflows: inkLength > length + 0.5
        )
    }

    /// Room after the tool strip, which never scrolls: a divider before the current-ink chip at
    /// compact width and before any collapse key, those controls, and the trailing inset.
    var toolCapWidth: CGFloat {
        toolCapWidth(endsWithCollapseKey: showsCollapseControl)
    }

    private func toolCapWidth(endsWithCollapseKey: Bool) -> CGFloat {
        let inset = NotebookTheme.stripInsets.right
        let controls = (foldsInkOptions ? [NotebookTheme.currentInkChipWidth] : [])
            + (endsWithCollapseKey ? [NotebookTheme.controlSize] : [])
        guard !controls.isEmpty else { return inset }
        let spacing = CGFloat(controls.count - 1) * NotebookTheme.itemSpacing
        return Self.groupGap + controls.reduce(0, +) + spacing + inset
    }

    /// Room after the ink strip, which never scrolls: a divider, the custom colour well and the
    /// trailing inset.
    static let inkCapWidth = groupGap + NotebookTheme.controlSize + NotebookTheme.stripInsets.right

    /// The ink families, then the eraser, lasso and ruler, then the widths, then the planned
    /// tools after a caption. At compact width the widths live in the current-ink chip's panel.
    /// Every control is square, so the row measures the same along either axis.
    func toolRow(includingUpcoming: Bool) -> NotebookStripRow {
        var items: [NotebookStripItem] = EditorInkFamily.allCases.map { .family($0) }
        items += [.divider(0), .eraser, .lasso, .ruler]
        if !foldsInkOptions { items += [.divider(1)] + EditorWidthStep.allCases.map { .width($0) } }
        if includingUpcoming {
            items += [.divider(2), .upcomingLabel] + NotebookUpcomingFeature.placed(.toolStrip).map { .upcoming($0) }
        }
        return row(items, axis: .horizontal)
    }

    /// The presets lead, so they show at rest on every regular-width window; the swatches
    /// follow, custom colours newest first. On end the presets are square keys, as a column has
    /// no room for their labels.
    func inkRow(_ swatches: [EditorInkColor], axis: Axis = .horizontal) -> NotebookStripRow {
        row(EditorInkCatalog.presets.map { .preset($0) } + [.divider(0)] + swatches.map { .swatch($0) }, axis: axis)
    }

    private func row(_ items: [NotebookStripItem], axis: Axis) -> NotebookStripRow {
        NotebookStripRow(items: items) { item in
            switch item {
            case .divider: Self.dividerWidth
            case let .preset(preset) where axis == .horizontal:
                NotebookPresetChip.width(for: preset, at: dynamicTypeSize, isBold: isBoldText)
            default: NotebookTheme.controlSize
            }
        }
    }
}

/// How the expanded rail lays out.
enum NotebookRailOrientation: Equatable {
    /// At the top or floating: the grip column at the leading end, the tools above the ink.
    case horizontal
    /// On end against the left edge: the grip column at the screen edge, then the tools, then the
    /// ink nearest the page.
    case leftEdge
    /// The mirror image against the right edge.
    case rightEdge

    var axis: Axis { self == .horizontal ? .horizontal : .vertical }

    /// Where the rail is drawn inside the room it keeps: against the edge it rests at, so the
    /// second row opens toward the page and the first never moves.
    var anchor: Alignment {
        switch self {
        case .horizontal: .top
        case .leftEdge: .leading
        case .rightEdge: .trailing
        }
    }

    /// The columns of a rail on end from left to right: the grip against the screen edge, the tools
    /// beside it, and the ink nearest the page, where the second row opens. A rail in rows has none.
    var columns: [NotebookRailColumn] {
        switch self {
        case .horizontal: []
        case .leftEdge: [.grip, .tools, .ink]
        case .rightEdge: [.ink, .tools, .grip]
        }
    }
}

/// A column of a rail on end.
enum NotebookRailColumn: Hashable {
    case grip
    case tools
    /// The second row on end, with the seam on its side toward the tools.
    case ink
}

/// The rail in one window.
struct NotebookToolbarRail: Equatable {
    let orientation: NotebookRailOrientation
    /// The expanded rail, with its second row: the room the toolbar keeps whether or not that row
    /// shows.
    let size: CGSize
    /// Whether the second row shows: the ink row below the tools, or the ink column beside them on
    /// end. A rail without an ink row has none.
    let showsInkRow: Bool
    /// Whether the planned tools close the tool row: at regular width only where the whole group
    /// fits, and always on the scrolling compact row.
    let showsUpcoming: Bool
    let toolRow: NotebookStripRow
    /// Nil at compact width, where the ink controls fold into the current-ink chip.
    let inkRow: NotebookStripRow?
    /// A row wider than its strip keeps room for a trailing chevron that pages it.
    let toolRowOverflows: Bool
    let inkRowOverflows: Bool

    init(
        orientation: NotebookRailOrientation, size: CGSize, showsInkRow: Bool, showsUpcoming: Bool,
        toolRow: NotebookStripRow, inkRow: NotebookStripRow?, toolRowOverflows: Bool, inkRowOverflows: Bool
    ) {
        self.orientation = orientation
        self.size = size
        self.showsInkRow = showsInkRow && inkRow != nil
        self.showsUpcoming = showsUpcoming
        self.toolRow = toolRow
        self.inkRow = inkRow
        self.toolRowOverflows = toolRowOverflows
        self.inkRowOverflows = inkRowOverflows
    }

    /// The rail as drawn: the first row alone, the grip and the tools on end, until the second opens.
    var shownSize: CGSize { showsInkRow ? size : firstRowSize }

    /// The grip column and the first row, the part of the rail that always shows.
    var firstRowSize: CGSize {
        guard inkRow != nil else { return size }
        return switch orientation {
        case .horizontal: CGSize(width: size.width, height: NotebookTheme.rowHeight)
        case .leftEdge, .rightEdge:
            CGSize(width: NotebookToolbarComposition.gripColumnWidth + NotebookTheme.rowHeight, height: size.height)
        }
    }

    /// What an ink's key tells assistive technologies about the second row it opens and closes:
    /// whether the row shows the selected ink's settings, and what a tap does to it.
    func inkKeyAccessibility(isSelected: Bool) -> (value: String?, hint: String?) {
        guard inkRow != nil else { return (nil, nil) }
        guard isSelected else { return (nil, "Selects this ink and shows its presets and colors.") }
        return showsInkRow
            ? ("Presets and colors shown", "Hides the presets and colors.")
            : ("Presets and colors hidden", "Shows the presets and colors.")
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

    /// A planned tool's key, which is never available.
    var isPlaceholder: Bool {
        if case .upcoming = self { return true }
        return false
    }
}

/// One item of a strip at the length the strip lays it out at. A strip on end measures down the
/// column the same way, so `minX` and `width` run along the strip whichever way it lies.
struct NotebookStripSlot: Equatable, Identifiable {
    let item: NotebookStripItem
    /// Start in the strip's content, after the leading inset.
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

    /// Measured along `axis`, so a strip on end reads its vertical scrolling.
    init(_ geometry: ScrollGeometry, axis: Axis = .horizontal) {
        switch axis {
        case .horizontal:
            self.init(
                offset: geometry.contentOffset.x, contentWidth: geometry.contentSize.width,
                containerWidth: geometry.containerSize.width
            )
        case .vertical:
            self.init(
                offset: geometry.contentOffset.y, contentWidth: geometry.contentSize.height,
                containerWidth: geometry.containerSize.height
            )
        }
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
    let axis: Axis

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let size = context.containerSize
        switch axis {
        case .horizontal: target.rect.origin.x = row.restingOffset(near: target.rect.minX, containerWidth: size.width)
        case .vertical: target.rect.origin.y = row.restingOffset(near: target.rect.minY, containerWidth: size.height)
        }
    }
}

/// A scrolling row of controls with hidden indicators, lying along the rail or on end in a column.
/// At rest only whole controls show; while it moves its edges fade instead. Separate chevrons page
/// through controls hidden past either end: the leading one over the strip's start, the trailing
/// one in a slot after it that the row keeps while it is too long.
@MainActor
private struct NotebookToolStrip<Control: View>: View {
    let label: String
    let axis: Axis
    let row: NotebookStripRow
    let reservesTrailingChevron: Bool
    /// How far a paused rail dims the controls and chevrons. Placeholders are unavailable whether
    /// or not writing is paused, so they keep their disabled tone at full strength.
    let contentOpacity: Double
    /// Each change scrolls `revealTarget` into view just clear of the leading edge.
    var reveals: UInt64 = 0
    var revealTarget: NotebookStripItem.ID?
    @ViewBuilder let control: (NotebookStripItem) -> Control
    @State private var position: ScrollPosition
    @StateObject private var geometry = NotebookStripGeometry()
    /// Changes only when the strip is resized, which sets its trailing room.
    @State private var containerWidth: CGFloat = 0
    @State private var hiddenEdges = NotebookStripOverflow.HiddenEdges.none
    /// Nil until the strip is first measured, when it shows in full.
    @State private var restingMask: NotebookStripMask?
    @State private var isMoving = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        label: String, axis: Axis = .horizontal, row: NotebookStripRow, reservesTrailingChevron: Bool,
        contentOpacity: Double, reveals: UInt64 = 0, revealTarget: NotebookStripItem.ID? = nil,
        @ViewBuilder control: @escaping (NotebookStripItem) -> Control
    ) {
        self.label = label
        self.axis = axis
        self.row = row
        self.reservesTrailingChevron = reservesTrailingChevron
        self.contentOpacity = contentOpacity
        self.reveals = reveals
        self.revealTarget = revealTarget
        self.control = control
        _position = State(initialValue: ScrollPosition(edge: axis == .horizontal ? .leading : .top))
    }

    var body: some View {
        stack(spacing: 0) {
            ScrollView(axis == .horizontal ? .horizontal : .vertical) {
                stack(spacing: NotebookTheme.itemSpacing) {
                    ForEach(row.slots) { slot in
                        control(slot.item)
                            .frame(
                                width: axis == .horizontal ? slot.width : NotebookTheme.controlSize,
                                height: axis == .horizontal ? NotebookTheme.controlSize : slot.width
                            )
                            .opacity(slot.item.isPlaceholder ? 1 : contentOpacity)
                    }
                }
                .padding(startEdge, NotebookTheme.stripInsets.left)
                .padding(endEdge, row.trailingRoom(containerWidth: containerWidth))
                .padding(axis == .horizontal ? .vertical : .horizontal, NotebookTheme.stripInsets.top)
            }
            .scrollIndicators(.hidden)
            // The system's edge effect would blur the shell's edge wherever the rail meets the
            // window's; the strip draws its own ends.
            .scrollEdgeEffectHidden()
            .scrollPosition($position)
            .scrollTargetBehavior(NotebookStripSnapping(row: row, axis: axis))
            .onScrollGeometryChange(for: NotebookStripOverflow.self) { [axis] geometry in
                NotebookStripOverflow(geometry, axis: axis)
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
            .overlay(alignment: axis == .horizontal ? .leading : .top) {
                if hiddenEdges.leading {
                    let symbol = axis == .horizontal ? "chevron.left" : "chevron.up"
                    chevron(symbol, label: "Show previous \(label.lowercased())") { row.leadingPage(from: $0) }
                }
            }
            if reservesTrailingChevron {
                ZStack {
                    if hiddenEdges.trailing {
                        let symbol = axis == .horizontal ? "chevron.right" : "chevron.down"
                        chevron(symbol, label: "Show more \(label.lowercased())") { row.trailingPage(from: $0) }
                    }
                }
                .frame(
                    width: axis == .horizontal ? NotebookTheme.controlSize : nil,
                    height: axis == .horizontal ? nil : NotebookTheme.controlSize
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .onChange(of: reveals) {
            guard let revealTarget else { return }
            let target = row.offset(showing: revealTarget, containerWidth: geometry.overflow.containerWidth)
            withAnimation(pageAnimation) { scroll(to: target) }
        }
    }

    private var startEdge: Edge.Set { axis == .horizontal ? .leading : .top }
    private var endEdge: Edge.Set { axis == .horizontal ? .trailing : .bottom }

    /// A row along the strip's axis.
    private func stack<Content: View>(spacing: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: spacing)) : AnyLayout(VStackLayout(spacing: spacing))
        return layout(content)
    }

    private func scroll(to offset: CGFloat) {
        switch axis {
        case .horizontal: position.scrollTo(x: offset)
        case .vertical: position.scrollTo(y: offset)
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
    /// chevron up to the first whole one; while moving, a short fade at each end with hidden
    /// controls. The two cross-fade as the strip starts and settles.
    private var mask: some View {
        let isHorizontal = axis == .horizontal
        return ZStack(alignment: isHorizontal ? .leading : .top) {
            Group {
                if let restingMask {
                    let length = max(restingMask.end - restingMask.start, 0)
                    Color.black
                        .frame(width: isHorizontal ? length : nil, height: isHorizontal ? nil : length)
                        .offset(x: isHorizontal ? restingMask.start : 0, y: isHorizontal ? 0 : restingMask.start)
                        .frame(
                            maxWidth: .infinity, maxHeight: .infinity, alignment: isHorizontal ? .leading : .top
                        )
                } else {
                    Color.black
                }
            }
            .opacity(isMoving ? 0 : 1)
            stack(spacing: 0) {
                if hiddenEdges.leading {
                    Color.clear.frame(
                        width: isHorizontal ? NotebookTheme.controlSize : nil,
                        height: isHorizontal ? nil : NotebookTheme.controlSize
                    )
                    fade(from: .clear, to: .black)
                }
                Color.black
                if hiddenEdges.trailing {
                    fade(from: .black, to: .clear)
                }
            }
            .opacity(isMoving ? 1 : 0)
        }
    }

    private func fade(from start: Color, to end: Color) -> some View {
        let isHorizontal = axis == .horizontal
        return LinearGradient(
            colors: [start, end],
            startPoint: isHorizontal ? .leading : .top, endPoint: isHorizontal ? .trailing : .bottom
        )
        .frame(
            width: isHorizontal ? NotebookStripMask.fadeLength : nil,
            height: isHorizontal ? nil : NotebookStripMask.fadeLength
        )
    }

    private func chevron(
        _ symbol: String, label: String, offset: @escaping (NotebookStripOverflow) -> CGFloat
    ) -> some View {
        Button {
            withAnimation(pageAnimation) { scroll(to: offset(geometry.overflow)) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: NotebookTheme.chevronSize, weight: .semibold))
                .modifier(NotebookKeyForeground())
                .frame(width: NotebookTheme.controlSize, height: NotebookTheme.controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotebookKeyStyle())
        .opacity(contentOpacity)
        .accessibilityLabel(label)
        .accessibilityShowsLargeContentViewer {
            Label(label, systemImage: symbol)
        }
    }
}

// MARK: - Rail

/// The tool rail on one pane of glass. The first row holds the ink families, the eraser, lasso
/// and ruler, the widths and the planned tools; the second the presets and colours, with the
/// custom colour well fixed at its end. The second row shows only while the user has opened it
/// from an ink's key, and opens toward the page inside the room the toolbar keeps for it. At a
/// side dock the rows stand on end as columns: the grip against the screen edge, then the tools,
/// then the ink. The grip comes from the host, which owns placement; a floating rail ends its first
/// row with its collapse key, after the current-ink chip on the single compact row. While writing
/// is paused the content dims, except the planned tools, which are unavailable either way.
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
        let dimming = actions.contentOpacity(for: contrast)
        let transition = NotebookInkRowTransition(reduceMotion: reduceMotion)
        lanes(marks: marks, dimming: dimming, transition: transition)
            .animation(transition.extent(opening: rail.showsInkRow)) {
                $0.modifier(NotebookRailExtent(
                    openAmount: rail.showsInkRow ? 1 : 0, closed: rail.firstRowSize, open: rail.size,
                    anchor: rail.orientation.anchor
                ))
            }
            .clipShape(shape)
            .notebookGlass(in: shape)
            .contentShape(shape)
            .disabled(!actions.isEnabled)
            .environment(\.notebookKeysPaused, !actions.isEnabled)
            .dynamicTypeSize(...NotebookToolbarComposition.textSizeLimit)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Drawing tools")
            .onChange(of: store.revealRequest) { respondToPencilReveal() }
            .task(id: inkRowReveals) { await highlightColors() }
            // The room the toolbar keeps, its second row's included, with the rail drawn against
            // the edge it rests at; the rest of the room leaves its touches to the page.
            .frame(width: rail.size.width, height: rail.size.height, alignment: rail.orientation.anchor)
    }

    /// The grip, the rows and the seam between them, in rows along the top and on end at a side,
    /// mirrored so the tools always sit beside the grip and the second row opens toward the page.
    @ViewBuilder
    private func lanes(marks: NotebookInkMarks, dimming: Double, transition: NotebookInkRowTransition) -> some View {
        let hiddenOffset = transition.hiddenOffset(for: rail.orientation)
        let gripColumn = grip
            .frame(width: NotebookToolbarComposition.gripColumnWidth)
            .opacity(dimming)
        switch rail.orientation {
        case .horizontal:
            HStack(alignment: .top, spacing: 0) {
                gripColumn
                VStack(spacing: 0) {
                    toolRow(marks, dimming: dimming)
                        .frame(height: NotebookTheme.rowHeight)
                    if let inkRow = rail.inkRow {
                        VStack(spacing: 0) {
                            seam(.horizontal, dimming: dimming)
                            inkLane(inkRow, axis: .horizontal, marks: marks, dimming: dimming)
                                .frame(height: NotebookTheme.rowHeight)
                        }
                        .modifier(NotebookInkRowDisclosure(
                            isShown: rail.showsInkRow, hiddenOffset: hiddenOffset, animation: transition.content
                        ))
                    }
                }
            }
        case .leftEdge, .rightEdge:
            HStack(spacing: 0) {
                ForEach(rail.orientation.columns, id: \.self) { column in
                    switch column {
                    case .grip:
                        gripColumn
                    case .tools:
                        toolColumn(marks, dimming: dimming)
                    case .ink:
                        if let inkRow = rail.inkRow {
                            inkColumn(inkRow, marks: marks, dimming: dimming)
                                .modifier(NotebookInkRowDisclosure(
                                    isShown: rail.showsInkRow, hiddenOffset: hiddenOffset, animation: transition.content
                                ))
                        }
                    }
                }
            }
        }
    }

    /// The second row on end, with the seam between it and the tools.
    private func inkColumn(_ inkRow: NotebookStripRow, marks: NotebookInkMarks, dimming: Double) -> some View {
        let seamLeads = rail.orientation == .leftEdge
        return HStack(spacing: 0) {
            if seamLeads { seam(.vertical, dimming: dimming) }
            inkLane(inkRow, axis: .vertical, marks: marks, dimming: dimming)
                .frame(width: NotebookTheme.rowHeight)
            if !seamLeads { seam(.vertical, dimming: dimming) }
        }
    }

    /// The hairline between the rows, or between the columns of a rail on end.
    private func seam(_ axis: Axis, dimming: Double) -> some View {
        NotebookChromeDivider(axis: axis, kind: .seam)
            .frame(
                width: axis == .vertical ? NotebookTheme.rowSpacing : nil,
                height: axis == .horizontal ? NotebookTheme.rowSpacing : nil
            )
            .opacity(dimming)
    }

    /// The presets and colours, then the custom colour well fixed at the strip's end.
    private func inkLane(_ inkRow: NotebookStripRow, axis: Axis, marks: NotebookInkMarks, dimming: Double) -> some View {
        let isHorizontal = axis == .horizontal
        let lane = isHorizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        let cap = isHorizontal
            ? AnyLayout(HStackLayout(spacing: NotebookTheme.itemSpacing))
            : AnyLayout(VStackLayout(spacing: NotebookTheme.itemSpacing))
        return lane {
            NotebookToolStrip(
                label: "Ink", axis: axis, row: inkRow, reservesTrailingChevron: rail.inkRowOverflows,
                contentOpacity: dimming, reveals: inkRowReveals, revealTarget: firstSwatchID(in: inkRow)
            ) { control($0, marks: marks, axis: axis) }
            cap {
                NotebookChromeDivider(axis: isHorizontal ? .vertical : .horizontal, kind: .group)
                NotebookCustomColorWell(
                    store: store, isSelected: marks.marksCustomColor, isHighlighted: highlightsColors
                )
            }
            .padding(isHorizontal ? .leading : .top, NotebookTheme.itemSpacing)
            .padding(isHorizontal ? .trailing : .bottom, NotebookTheme.stripInsets.right)
            .opacity(dimming)
        }
    }

    /// The tool strip on end, beside the grip.
    private func toolColumn(_ marks: NotebookInkMarks, dimming: Double) -> some View {
        VStack(spacing: 0) {
            NotebookToolStrip(
                label: "Tools", axis: .vertical, row: rail.toolRow, reservesTrailingChevron: rail.toolRowOverflows,
                contentOpacity: dimming
            ) { control($0, marks: marks, axis: .vertical) }
            Color.clear.frame(height: NotebookTheme.stripInsets.right)
        }
        .frame(width: NotebookTheme.rowHeight)
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

    private func toolRow(_ marks: NotebookInkMarks, dimming: Double) -> some View {
        HStack(spacing: 0) {
            NotebookToolStrip(
                label: "Tools", row: rail.toolRow, reservesTrailingChevron: rail.toolRowOverflows,
                contentOpacity: dimming
            ) { control($0, marks: marks) }
            if composition.foldsInkOptions || composition.showsCollapseControl {
                HStack(spacing: NotebookTheme.itemSpacing) {
                    NotebookChromeDivider(axis: .vertical)
                    if composition.foldsInkOptions {
                        NotebookCurrentInkChip(store: store, showsOptions: $showsInkPanel)
                    }
                    if composition.showsCollapseControl { collapseKey }
                }
                .padding(.leading, NotebookTheme.itemSpacing)
                .padding(.trailing, NotebookTheme.stripInsets.right)
                .opacity(dimming)
            } else {
                Color.clear.frame(width: NotebookTheme.stripInsets.right)
            }
        }
    }

    /// One strip item as drawn in a strip lying along `axis`.
    @ViewBuilder
    private func control(_ item: NotebookStripItem, marks: NotebookInkMarks, axis: Axis = .horizontal) -> some View {
        switch item {
        case let .family(family):
            let isSelected = store.tool.kind == .ink(family)
            let accessibility = rail.inkKeyAccessibility(isSelected: isSelected)
            NotebookToolButton(
                title: family.title, symbol: family.symbol, isSelected: isSelected,
                value: accessibility.value, hint: accessibility.hint
            ) {
                actions.chooseInk(family, opensSettings: rail.inkRow != nil)
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
        case let .preset(preset) where axis == .vertical:
            NotebookPresetKey(preset: preset, isSelected: marks.presetID == preset.id) {
                actions.apply(preset)
            }
        case let .preset(preset):
            NotebookPresetChip(preset: preset, isSelected: marks.presetID == preset.id) {
                actions.apply(preset)
            }
        case let .swatch(color):
            NotebookSwatchButton(color: color, isSelected: marks.color == color, isHighlighted: highlightsColors) {
                actions.selectColor(color)
            }
        case .divider:
            NotebookChromeDivider(axis: axis == .horizontal ? .vertical : .horizontal, kind: .group)
        }
    }

    private func firstSwatchID(in row: NotebookStripRow) -> NotebookStripItem.ID? {
        row.slots.first { if case .swatch = $0.item { true } else { false } }?.id
    }

    /// The store only counts gestures while the toolbar is available, so every count deserves an
    /// answer. The host opens the second row for it; here the colours come into view on it.
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

/// How the second row opens and closes. The rail grows toward the page on a spring as the row
/// fades in, slipping a little out from under the first, and shrinks back as it fades out. Under
/// Reduce Motion the row only fades: the rail takes its new size at once as the row opens, and
/// once the row has faded as it closes.
struct NotebookInkRowTransition: Equatable {
    let reduceMotion: Bool

    /// Where the hidden row rests relative to its place: tucked toward the first row.
    func hiddenOffset(for orientation: NotebookRailOrientation) -> CGSize {
        guard !reduceMotion else { return .zero }
        let travel = NotebookTheme.inkRowTravel
        return switch orientation {
        case .horizontal: CGSize(width: 0, height: -travel)
        case .leftEdge: CGSize(width: -travel, height: 0)
        case .rightEdge: CGSize(width: travel, height: 0)
        }
    }

    /// How the rail's drawn size follows the row. A closing rail under Reduce Motion holds its size
    /// while the row fades, then takes the new one within a frame; SwiftUI applies an animation
    /// without duration at once, delay and all.
    func extent(opening: Bool) -> Animation? {
        guard reduceMotion else { return .spring(duration: NotebookTheme.inkRowDuration, bounce: 0) }
        return opening ? nil : .linear(duration: NotebookTheme.frameDuration).delay(NotebookTheme.toolsFadeDuration)
    }

    /// How the row's content fades and moves.
    var content: Animation {
        reduceMotion
            ? .linear(duration: NotebookTheme.toolsFadeDuration)
            : .spring(duration: NotebookTheme.inkRowDuration, bounce: 0)
    }
}

/// Draws the rail at its first row's size, its second row's or any size between, against the
/// edge it rests at. Only the amount open animates, so a rail resized with its window or its text
/// takes its new size at once.
private struct NotebookRailExtent: ViewModifier, Animatable {
    /// 0 with the first row alone, 1 with the second open.
    var openAmount: Double
    let closed: CGSize
    let open: CGSize
    let anchor: Alignment

    nonisolated var animatableData: Double {
        get { openAmount }
        set { openAmount = newValue }
    }

    func body(content: Content) -> some View {
        content.frame(
            width: closed.width + (open.width - closed.width) * openAmount,
            height: closed.height + (open.height - closed.height) * openAmount,
            alignment: anchor
        )
    }
}

/// Shows or hides the second row in its place. Hidden, it leaves keyboard focus and assistive
/// technologies to the rest of the rail, and its keys keep their look while they fade; it lies
/// outside the glass's shape, which leaves its touches to the page.
private struct NotebookInkRowDisclosure: ViewModifier {
    let isShown: Bool
    let hiddenOffset: CGSize
    let animation: Animation

    func body(content: Content) -> some View {
        content
            .transformEnvironment(\.notebookKeysHiding) { $0 = $0 || !isShown }
            .animation(animation) {
                $0.opacity(isShown ? 1 : 0).offset(isShown ? .zero : hiddenOffset)
            }
            // Applied outside the animation's body, where SwiftUI refreshes a changed `disabled`.
            .disabled(!isShown)
            .accessibilityHidden(!isShown)
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
        // The panel is a matte popover, though the glass rail presents it.
        .environment(\.notebookKeysOnGlass, false)
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
                    .modifier(NotebookKeyForeground(isMark: true))
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
        .notebookToolbarPresentation(showsOptions, store: store)
        // Every change arrives, however many fall within one frame, so a pause always closes it.
        .onReceive(store.$isToolbarAvailable) { available in
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
    var value: String?
    var hint: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            NotebookToolGlyph(symbol: symbol, isSelected: isSelected)
        }
        .buttonStyle(NotebookKeyStyle(isSelected: isSelected))
        // Several inks share similar glyphs, so pointer and Pencil hover name them.
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(value ?? "")
        .accessibilityHint(hint ?? "")
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

/// Opens the eraser in its last mode on tap; touch and hold chooses object or pixel erasing. The
/// key draws like every other, while a UIKit button over it takes the touches: a SwiftUI menu never
/// reports that it is open, and the writing view must keep the tools in sight beneath it.
@MainActor
private struct NotebookEraserButton: View {
    let kind: EditorToolKind
    let actions: NotebookToolbarActions
    @State private var isPressed = false
    @State private var isFocused = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.notebookKeysHiding) private var isHiding

    private var selectedMode: EditorEraserMode? {
        if case let .eraser(mode) = kind { return mode }
        return nil
    }

    var body: some View {
        let isSelected = selectedMode != nil
        NotebookKey(
            label: NotebookToolGlyph(symbol: NotebookEraserMenuButton.symbol(for: selectedMode), isSelected: isSelected),
            isSelected: isSelected, isPressed: isPressed, shape: .well
        )
        .overlay {
            // A button style rings the key from its own focus; here the UIKit button reports it.
            if isFocused && isEnabled {
                NotebookKeyStyle.Background(shape: .well, isSelected: false, isPressed: false, isFocused: true)
            }
        }
        .accessibilityHidden(true)
        .overlay {
            NotebookEraserKey(
                selectedMode: selectedMode, actions: actions, isEnabled: isEnabled, isHiding: isHiding,
                isPressed: $isPressed, isFocused: $isFocused
            )
        }
    }
}

/// The eraser key's touch target. It draws nothing; the key beneath it shows its press and focus.
@MainActor
private struct NotebookEraserKey: UIViewRepresentable {
    let selectedMode: EditorEraserMode?
    let actions: NotebookToolbarActions
    let isEnabled: Bool
    /// True while the writing view hides the rail.
    let isHiding: Bool
    @Binding var isPressed: Bool
    @Binding var isFocused: Bool

    func makeUIView(context: Context) -> NotebookEraserMenuButton {
        NotebookEraserMenuButton()
    }

    func updateUIView(_ button: NotebookEraserMenuButton, context: Context) {
        let pressed = $isPressed
        let focused = $isFocused
        button.update(
            selectedMode: selectedMode, actions: actions, isEnabled: isEnabled, isHiding: isHiding,
            reportPress: { pressed.wrappedValue = $0 }, reportFocus: { focused.wrappedValue = $0 }
        )
    }

    static func dismantleUIView(_ button: NotebookEraserMenuButton, coordinator: ()) {
        button.dismantle()
    }
}

/// A button without a look of its own: a tap selects the eraser in its last mode, and a touch and
/// hold opens the menu of eraser modes. While that menu is open the toolbar's store keeps the
/// writing view's tools and header in sight, as it does for the toolbar's popovers and sheets.
/// A scroll view never takes back a touch it has handed to a control, so a finger that rests on
/// the key before dragging leaves an overflowing strip where it is; a quick drag still scrolls it.
final class NotebookEraserMenuButton: UIButton {
    static func symbol(for mode: EditorEraserMode?) -> String {
        mode == .bitmap ? "eraser.line.dashed" : "eraser"
    }

    /// Identifies the menu to the writing view while it is open.
    private let presentationID = UUID()
    private var actions: NotebookToolbarActions?
    private var builtMode: EditorEraserMode??
    private var reportPress: @MainActor (Bool) -> Void = { _ in }
    private var reportFocus: @MainActor (Bool) -> Void = { _ in }
    /// True while SwiftUI updates the button, when its state must not be reported back at once.
    private var isUpdating = false
    private var isShowingFocus = false
    private var isHidingRail = false
    private(set) var isMenuPresented = false
    /// The store told that the menu opened, which is told when it ends.
    private weak var presentationStore: NotebookSceneToolStore?

    init() {
        super.init(frame: .zero)
        showsMenuAsPrimaryAction = false
        accessibilityLabel = "Eraser"
        accessibilityHint = "Touch and hold to choose object or pixel erasing."
        addInteraction(UIToolTipInteraction(defaultToolTip: "Eraser"))
        // The key beneath draws the toolbar's own focus ring.
        focusEffect = nil
        showsLargeContentViewer = true
        largeContentTitle = "Eraser"
        scalesLargeContentImage = true
        addInteraction(UILargeContentViewerInteraction())
        addAction(UIAction { [weak self] _ in self?.actions?.selectEraser() }, for: .primaryActionTriggered)
    }

    required init?(coder: NSCoder) {
        fatalError("Use init().")
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            report { $0.reportPress($0.isHighlighted) }
        }
    }

    override var canBecomeFocused: Bool {
        super.canBecomeFocused && !isHidingRail
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        guard isShowingFocus != focused else { return }
        isShowingFocus = focused
        report { $0.reportFocus($0.isShowingFocus) }
    }

    /// - Parameter isHiding: true while the writing view hides the rail, from the moment the hide
    ///   begins. SwiftUI's hit testing and accessibility hiding never reach inside a UIKit view, so
    ///   the button itself gives up its touches, keyboard focus and place among assistive
    ///   technology's elements, whether or not the rail is disabled by then.
    func update(
        selectedMode: EditorEraserMode?, actions: NotebookToolbarActions, isEnabled: Bool, isHiding: Bool,
        reportPress: @escaping @MainActor (Bool) -> Void, reportFocus: @escaping @MainActor (Bool) -> Void
    ) {
        isUpdating = true
        defer { isUpdating = false }
        self.actions = actions
        self.reportPress = reportPress
        self.reportFocus = reportFocus
        self.isEnabled = isEnabled
        // A disabled key leaves its touches to what lies beneath: a paused rail's shell, which keeps
        // them, or a hidden rail's page.
        isUserInteractionEnabled = isEnabled && !isHiding
        isAccessibilityElement = !isHiding
        if isHidingRail != isHiding {
            isHidingRail = isHiding
            setNeedsFocusUpdate()
        }
        isSelected = selectedMode != nil
        var traits: UIAccessibilityTraits = isSelected ? [.button, .selected] : .button
        if !isEnabled { traits.insert(.notEnabled) }
        accessibilityTraits = traits
        accessibilityValue = selectedMode.map { $0 == .vector ? "Object" : "Pixel" }
        guard builtMode != .some(selectedMode) else { return }
        builtMode = .some(selectedMode)
        largeContentImage = UIImage(systemName: Self.symbol(for: selectedMode))
        menu = UIMenu(children: [
            modeAction("Object eraser", mode: .vector, selectedMode: selectedMode),
            modeAction("Pixel eraser", mode: .bitmap, selectedMode: selectedMode),
        ])
    }

    /// SwiftUI is removing the button, possibly with its menu open, and with it the key it reports to.
    func dismantle() {
        reportPress = { _ in }
        reportFocus = { _ in }
        contextMenuInteraction?.dismissMenu()
        setMenuPresented(false)
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        setMenuPresented(true)
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        setMenuPresented(false)
    }

    private func modeAction(_ title: String, mode: EditorEraserMode, selectedMode: EditorEraserMode?) -> UIAction {
        UIAction(title: title, image: selectedMode == mode ? UIImage(systemName: "checkmark") : nil) { [weak self] _ in
            self?.actions?.select(.eraser(mode))
        }
    }

    /// The menu opens only at the user's touch, so its pin applies at once. It also ends as the
    /// button leaves its window, which can happen inside a SwiftUI update, so the end is reported
    /// a turn later, unless the menu has opened again by then.
    private func setMenuPresented(_ presented: Bool) {
        guard isMenuPresented != presented else { return }
        isMenuPresented = presented
        let id = presentationID
        guard !presented else {
            presentationStore = actions?.store
            presentationStore?.setToolbarPresentation(id, isPresented: true)
            return
        }
        let store = presentationStore
        Task { [weak self] in
            if self?.isMenuPresented == true { return }
            store?.setToolbarPresentation(id, isPresented: false)
        }
    }

    /// Hands a change of the button's state to the key beneath, a turn later if SwiftUI is updating
    /// the button, as its state must not change during that update.
    private func report(_ change: @escaping @MainActor (NotebookEraserMenuButton) -> Void) {
        guard isUpdating else { return change(self) }
        Task { [weak self] in
            guard let self else { return }
            change(self)
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

    /// What Voice Control answers to. Users say the word the chip shows, which a swatch of the same
    /// colour may share, so it leads as a preset; the full name follows.
    nonisolated static func inputLabels(for preset: EditorInkPreset) -> [String] {
        ["\(shortTitle(for: preset)) preset", preset.name, "\(preset.name) preset"]
    }

    /// The chip's width at a text size, and under Bold Text when `isBold`, which the rail's width
    /// rule counts and the chip lays out.
    nonisolated static func width(for preset: EditorInkPreset, at size: DynamicTypeSize, isBold: Bool = false) -> CGFloat {
        2 * NotebookTheme.presetChipPadding + NotebookTheme.presetDotDiameter + NotebookTheme.presetDotSpacing
            + labelWidth(shortTitle(for: preset), at: size, isBold: isBold)
    }

    /// The label's width in the control label face at a text size, rounded up to whole points.
    nonisolated static func labelWidth(_ text: String, at size: DynamicTypeSize, isBold: Bool = false) -> CGFloat {
        let setting = LabelSetting(size: min(size, NotebookToolbarComposition.textSizeLimit), isBold: isBold)
        return measuredLabelWidths[setting]?[text] ?? measureLabel(text, in: setting)
    }

    /// A text size and whether Bold Text is on: everything a label's width depends on.
    private struct LabelSetting: Hashable {
        let size: DynamicTypeSize
        let isBold: Bool
    }

    /// Every short title in every setting the rail is laid out in, measured once, as the rail's
    /// width rule asks for them on each layout.
    nonisolated private static let measuredLabelWidths: [LabelSetting: [String: CGFloat]] = {
        let titles = EditorInkCatalog.presets.map(shortTitle)
        let settings = DynamicTypeSize.allCases.filter { $0 <= NotebookToolbarComposition.textSizeLimit }
            .flatMap { size in [false, true].map { LabelSetting(size: size, isBold: $0) } }
        return Dictionary(uniqueKeysWithValues: settings.map { setting in
            (setting, Dictionary(uniqueKeysWithValues: titles.map { ($0, measureLabel($0, in: setting)) }))
        })
    }()

    /// The face takes its text style's size at the text size, as SwiftUI sets it. Bold Text sets
    /// its medium weight in bold.
    nonisolated private static func measureLabel(_ text: String, in setting: LabelSetting) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(setting.size))
        let style = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits)
        let font = UIFont.systemFont(ofSize: style.pointSize, weight: setting.isBold ? .bold : .medium)
        return (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    let preset: EditorInkPreset
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.notebookKeysShowSelection) private var showsSelection

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
                    .frame(
                        width: Self.labelWidth(title, at: dynamicTypeSize, isBold: legibilityWeight == .bold),
                        height: NotebookTheme.presetChipHeight
                    )
                    .overlay(alignment: .bottom) {
                        if isSelected {
                            Capsule()
                                .modifier(NotebookKeyForeground(isMark: true))
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
                if !(isSelected && showsSelection) {
                    Capsule().strokeBorder(NotebookTheme.panelLowerEdge.color, lineWidth: NotebookTheme.shellBorderWidth)
                }
            }
            .frame(minHeight: NotebookTheme.controlSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotebookKeyStyle(isSelected: isSelected, shape: .capsule))
        .help(preset.name)
        .accessibilityLabel("\(preset.name) preset")
        .accessibilityInputLabels(Self.inputLabels(for: preset))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer {
            Label(preset.name, systemImage: "circle.fill")
        }
    }
}

/// A preset as a square key, for a rail on end where a labelled chip has no room: the preset's
/// ink family with a bead of its colour, as the collapsed handle shows the tool in use. The full
/// name stays its label, its pointer help and its Large Content Viewer title.
@MainActor
private struct NotebookPresetKey: View {
    let preset: EditorInkPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            NotebookToolGlyph(symbol: preset.family.symbol, isSelected: isSelected)
                .overlay {
                    Circle()
                        .fill(preset.color.swiftUIColor)
                        .overlay(NotebookSwatchRing(color: preset.color))
                        .frame(width: NotebookTheme.presetDotDiameter, height: NotebookTheme.presetDotDiameter)
                        .offset(NotebookTheme.presetKeyBeadOffset)
                        .accessibilityHidden(true)
                }
        }
        .buttonStyle(NotebookKeyStyle(isSelected: isSelected))
        .help(preset.name)
        .accessibilityLabel("\(preset.name) preset")
        .accessibilityInputLabels(NotebookPresetChip.inputLabels(for: preset))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer {
            Label(preset.name, systemImage: preset.family.symbol)
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

/// Opens the colour screen. Selected, it shows the colour in use, which is not on the shelf.
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
        .accessibilityHint("Opens the color picker. Try a color on the scratchpad; once it shows Ready, leaving writes with it and adds it to your swatches.")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer {
            Label("Custom color", systemImage: "paintpalette")
        }
        .notebookColorScreen(isPresented: $isPicking, store: store)
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
                .modifier(NotebookKeyForeground(isMark: true))
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
