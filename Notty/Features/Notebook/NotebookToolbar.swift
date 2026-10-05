import NottyCore
import SwiftUI
import UIKit

/// Every toolbar change goes through here, so an unavailable toolbar cannot change the
/// tool or its own preferences, whichever control or gesture fired.
@MainActor
struct NotebookToolbarActions {
    let store: NotebookSceneToolStore

    var isEnabled: Bool { store.isToolbarAvailable }

    /// The controls stay visible while writing is paused, but dimmed so they read as unavailable.
    var contentOpacity: Double { isEnabled ? 1 : NotebookTheme.disabledOpacity }

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

    static func displayed(custom: [EditorInkColor]) -> [EditorInkColor] {
        var seen = Set<EditorInkColor>()
        return (EditorInkCatalog.swatches + custom).filter { seen.insert($0).inserted }
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

/// Which parts of the toolbar show and how much room it takes, decided from the stored
/// preferences and the window width.
struct NotebookToolbarComposition: Equatable {
    /// At compact width the colour and width row folds into one current-ink chip.
    let foldsInkOptions: Bool
    let isFloating: Bool
    let isCollapsed: Bool

    init(preferences: EditorToolbarPreferences, horizontalSizeClass: UserInterfaceSizeClass?) {
        foldsInkOptions = horizontalSizeClass == .compact
        if case .floating = preferences.placement { isFloating = true } else { isFloating = false }
        isCollapsed = preferences.isCollapsed
    }

    var showsRevealHandle: Bool { isCollapsed }
    /// The disabled placeholders that close the tool row; a collapsed toolbar shows none.
    var upcomingTools: [NotebookUpcomingFeature] { isCollapsed ? [] : NotebookUpcomingFeature.placed(.toolStrip) }
    var showsCollapseControl: Bool { isFloating && !isCollapsed }
    var rowCount: Int { foldsInkOptions ? 1 : 2 }

    var pencilRevealResponse: NotebookToolbarRevealResponse {
        if isCollapsed { return .expand }
        return foldsInkOptions ? .openInkPanel : .showInkRow
    }

    var expandedHeight: CGFloat {
        CGFloat(rowCount) * NotebookTheme.rowHeight + CGFloat(rowCount - 1) * NotebookTheme.rowSpacing
    }

    /// The least distance a toolbar keeps between neighbouring docks, by paging its planned
    /// tools when the window is too narrow for them as well, so a move between docks is plain.
    static let minimumDockTravel: CGFloat = 150

    /// Room for the drag handle, the whole tool row and the controls beside it, so every tool and
    /// planned-tool placeholder shows without paging.
    var preferredWidth: CGFloat { width(withToolRow: toolRowWidth(includingUpcoming: true)) }

    /// Room for the working tools alone, clear of the chevron and fade that stand for the planned
    /// tools paging in after them.
    var workingToolsWidth: CGFloat {
        let chevron = NotebookTheme.controlSize + NotebookStripOverflow.fadeLength
        return width(withToolRow: toolRowWidth(includingUpcoming: false) + chevron)
    }

    /// The preferred width where the window still leaves the docks `minimumDockTravel` apart,
    /// otherwise narrower down to the working tools, and never wider than the window.
    func toolbarSize(forHostWidth width: CGFloat) -> CGSize {
        if showsRevealHandle { return NotebookTheme.collapsedHandleSize }
        let available = max(width - 2 * EditorToolbarLayout.margin, 0)
        // Neighbouring docks lie half the spare width apart. A floating toolbar adds its collapse
        // control on top, so it shows the same tools as a docked one.
        let collapseControl = showsCollapseControl ? NotebookTheme.controlSize : 0
        let keepsDocksApart = available - 2 * Self.minimumDockTravel + collapseControl
        let toolbarWidth = min(preferredWidth, max(workingToolsWidth, keepsDocksApart), available)
        return CGSize(width: toolbarWidth, height: expandedHeight)
    }

    private func width(withToolRow toolRow: CGFloat) -> CGFloat {
        var width = NotebookTheme.dragHandleHitSize.width + toolRow
        if foldsInkOptions { width += NotebookTheme.currentInkChipWidth }
        if showsCollapseControl { width += NotebookTheme.controlSize }
        return width
    }

    /// The tool row's content as `NotebookToolbar` lays it out: the ink families, eraser, lasso
    /// and ruler, then the "Soon" mark and the placeholders, each a control wide, with a divider
    /// before the ruler and one before the planned tools.
    private func toolRowWidth(includingUpcoming: Bool) -> CGFloat {
        let upcoming = includingUpcoming ? upcomingTools : []
        let workingControls = EditorInkFamily.allCases.count + 3
        let upcomingControls = upcoming.isEmpty ? 0 : upcoming.count + 1
        let dividers = upcoming.isEmpty ? 1 : 2
        let controls = workingControls + upcomingControls
        return CGFloat(controls) * NotebookTheme.controlSize
            + CGFloat(dividers) * NotebookTheme.dividerThickness
            + CGFloat(controls + dividers - 1) * NotebookTheme.itemSpacing
            + NotebookTheme.stripInsets.left + NotebookTheme.stripInsets.right
    }
}

/// How far a scrolling strip's tools extend past either edge.
struct NotebookStripOverflow: Equatable {
    static let none = NotebookStripOverflow(offset: 0, contentWidth: 0, containerWidth: 0)
    /// Length of the fade in front of the chevron at an edge with hidden tools.
    static let fadeLength: CGFloat = 16

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

    /// Pages by most of the visible width, so a tool from the previous view stays in sight.
    var nextTrailingOffset: CGFloat { min(offset + containerWidth * 0.75, maximumOffset) }
    var nextLeadingOffset: CGFloat { max(offset - containerWidth * 0.75, 0) }

    private var maximumOffset: CGFloat { max(contentWidth - containerWidth, 0) }

    /// The part of the overflow the strip draws, which changes only when an edge is reached or left.
    struct HiddenEdges: Equatable {
        static let none = HiddenEdges(leading: false, trailing: false)

        let leading: Bool
        let trailing: Bool
    }
}

/// The strip's latest scroll geometry, kept out of view state so scrolling does not redraw
/// the strip on every frame; only the chevrons read it, when tapped.
@MainActor
private final class NotebookStripGeometry {
    var overflow = NotebookStripOverflow.none
}

/// The ivory tool rail: ink families, eraser, lasso, ruler and the disabled placeholders for
/// planned tools in the first row; widths, colours and presets in the second. The drag handle
/// comes from the host, which owns placement.
@MainActor
struct NotebookToolbar<Handle: View>: View {
    @ObservedObject var store: NotebookSceneToolStore
    let composition: NotebookToolbarComposition
    let collapse: () -> Void
    private let handle: Handle
    @State private var showsInkPanel = false
    @State private var inkRowReveals: UInt64 = 0
    @State private var highlightsColors = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        store: NotebookSceneToolStore, composition: NotebookToolbarComposition,
        collapse: @escaping () -> Void, @ViewBuilder handle: () -> Handle
    ) {
        self.store = store
        self.composition = composition
        self.collapse = collapse
        self.handle = handle()
    }

    private var actions: NotebookToolbarActions { NotebookToolbarActions(store: store) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NotebookTheme.toolbarCornerRadius, style: .continuous)
        HStack(spacing: 0) {
            handle
            VStack(spacing: 0) {
                NotebookToolStrip(label: "Tools") { toolRow }
                    .frame(height: NotebookTheme.rowHeight)
                if !composition.foldsInkOptions {
                    NotebookToolbarDivider(axis: .horizontal)
                        .frame(height: NotebookTheme.rowSpacing)
                    NotebookToolStrip(
                        label: "Ink", reveals: inkRowReveals, revealTarget: NotebookInkControls.colorsID
                    ) {
                        NotebookInkControls(store: store, layout: .strip, highlightsColors: highlightsColors)
                    }
                    .frame(height: NotebookTheme.rowHeight)
                }
            }
            if composition.foldsInkOptions {
                NotebookCurrentInkChip(store: store, showsOptions: $showsInkPanel)
            }
            if composition.showsCollapseControl {
                Button(action: collapse) {
                    NotebookToolGlyph(symbol: "arrow.down.right.and.arrow.up.left", isSelected: false)
                }
                .buttonStyle(NotebookToolbarButtonStyle())
                .accessibilityLabel("Hide tools")
            }
        }
        .opacity(actions.contentOpacity)
        .clipShape(shape)
        .background { NotebookToolbarShell() }
        .contentShape(shape)
        .disabled(!actions.isEnabled)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drawing tools")
        .onChange(of: store.revealRequest) { respondToPencilReveal() }
        .task(id: inkRowReveals) { await highlightColors() }
    }

    @ViewBuilder private var toolRow: some View {
        ForEach(EditorInkFamily.allCases, id: \.self) { family in
            NotebookToolButton(
                title: family.title, symbol: family.symbol, isSelected: store.tool.kind == .ink(family)
            ) {
                actions.select(.ink(family))
            }
        }
        NotebookEraserButton(kind: store.tool.kind, actions: actions)
        NotebookToolButton(title: "Lasso", symbol: "lasso", isSelected: store.tool.kind == .lasso) {
            actions.select(.lasso)
        }
        NotebookToolbarDivider(axis: .vertical)
        NotebookToolButton(title: "Ruler", symbol: "ruler", isSelected: store.tool.isRulerActive, isToggle: true) {
            actions.toggleRuler()
        }
        if !composition.upcomingTools.isEmpty {
            NotebookToolbarDivider(axis: .vertical)
            NotebookUpcomingMark()
            ForEach(composition.upcomingTools) { feature in
                NotebookUpcomingToolButton(feature: feature)
            }
        }
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

/// Widths, swatches, the custom colour well and presets, laid out in a strip or a panel.
/// The panel is presented in a popover, outside the toolbar's environment, so it disables
/// itself while writing is paused.
@MainActor
struct NotebookInkControls: View {
    enum Layout {
        case strip
        case panel
    }

    /// Identifies the colour group, which an Apple Pencil reveal scrolls into view.
    static let colorsID = "colors"
    /// How long the colours stay highlighted after an Apple Pencil gesture asks for them.
    static let highlightDuration = Duration.seconds(1.2)

    @ObservedObject var store: NotebookSceneToolStore
    let layout: Layout
    var highlightsColors = false

    private var actions: NotebookToolbarActions { NotebookToolbarActions(store: store) }
    private var marks: NotebookInkMarks { NotebookInkMarks(tool: store.tool, custom: store.toolbar.customSwatches) }

    var body: some View {
        let marks = marks
        switch layout {
        case .strip:
            // Widths lead because the colour group grows with custom colours; presets, the
            // widest and least frequent choice, come last.
            widths(marks)
            NotebookToolbarDivider(axis: .vertical)
            HStack(spacing: NotebookTheme.itemSpacing) { swatches(marks) }
                .background {
                    if highlightsColors {
                        RoundedRectangle(cornerRadius: NotebookTheme.selectedWellCornerRadius, style: .continuous)
                            .fill(NotebookTheme.selectedWell.color.opacity(NotebookTheme.pressedWellOpacity))
                            .accessibilityHidden(true)
                    }
                }
                .id(Self.colorsID)
            NotebookToolbarDivider(axis: .vertical)
            presets(marks)
        case .panel:
            VStack(alignment: .leading, spacing: NotebookTheme.inkPanelSectionSpacing) {
                section("Presets") {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: NotebookTheme.presetColumnMinimum), alignment: .leading)],
                        spacing: 0
                    ) { presets(marks) }
                }
                section("Colors") {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: NotebookTheme.controlSize), spacing: NotebookTheme.rowSpacing)],
                        spacing: NotebookTheme.rowSpacing
                    ) { swatches(marks) }
                }
                section("Width") {
                    HStack(spacing: NotebookTheme.itemSpacing) { widths(marks) }
                }
            }
            .padding(NotebookTheme.inkPanelPadding)
            .frame(width: NotebookTheme.inkPanelWidth)
            .disabled(!store.isToolbarAvailable)
        }
    }

    @ViewBuilder private func presets(_ marks: NotebookInkMarks) -> some View {
        ForEach(EditorInkCatalog.presets) { preset in
            NotebookPresetChip(preset: preset, isSelected: marks.presetID == preset.id) {
                actions.apply(preset)
            }
        }
    }

    @ViewBuilder private func swatches(_ marks: NotebookInkMarks) -> some View {
        ForEach(NotebookSwatchShelf.displayed(custom: store.toolbar.customSwatches), id: \.self) { color in
            NotebookSwatchButton(color: color, isSelected: marks.color == color) {
                actions.selectColor(color)
            }
        }
        NotebookCustomColorWell(store: store, isSelected: marks.marksCustomColor)
    }

    @ViewBuilder private func widths(_ marks: NotebookInkMarks) -> some View {
        ForEach(EditorWidthStep.allCases, id: \.self) { step in
            NotebookWidthButton(step: step, isSelected: marks.width == step) {
                actions.selectWidth(step)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: NotebookTheme.itemSpacing) {
            Text(title)
                .font(NotebookTheme.controlLabel.font)
                .foregroundStyle(NotebookTheme.glyph.color)
                .accessibilityAddTraits(.isHeader)
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
                    .overlay(NotebookSwatchOutline())
                    .frame(width: NotebookTheme.currentInkSwatchDiameter, height: NotebookTheme.currentInkSwatchDiameter)
                Circle()
                    .modifier(NotebookToolbarForeground())
                    .frame(width: store.tool.widthStep.dotDiameter, height: store.tool.widthStep.dotDiameter)
            }
            .frame(minWidth: NotebookTheme.currentInkChipWidth, minHeight: NotebookTheme.controlSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotebookToolbarButtonStyle())
        .accessibilityLabel("Ink options")
        .accessibilityValue("\(store.tool.color.accessibilityName), \(store.tool.widthStep.title) width")
        .popover(isPresented: $showsOptions) {
            NotebookInkControls(store: store, layout: .panel)
                .presentationCompactAdaptation(.popover)
        }
        .onChange(of: store.isToolbarAvailable) { _, available in
            if !available { showsOptions = false }
        }
    }
}

/// A horizontally scrolling row with hidden indicators, faded edges and chevrons that page
/// through tools hidden past either edge.
@MainActor
private struct NotebookToolStrip<Content: View>: View {
    let label: String
    /// Each change scrolls `revealTarget` to the leading edge.
    var reveals: UInt64 = 0
    var revealTarget: String?
    @ViewBuilder let content: Content
    @State private var position = ScrollPosition(edge: .leading)
    @State private var geometry = NotebookStripGeometry()
    @State private var hiddenEdges = NotebookStripOverflow.HiddenEdges.none
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: NotebookTheme.itemSpacing) { content }
                .scrollTargetLayout()
                .padding(NotebookTheme.stripEdgeInsets)
        }
        .scrollIndicators(.hidden)
        .scrollPosition($position)
        .onScrollGeometryChange(for: NotebookStripOverflow.self) { geometry in
            NotebookStripOverflow(geometry)
        } action: { _, value in
            geometry.overflow = value
            if hiddenEdges != value.hiddenEdges { hiddenEdges = value.hiddenEdges }
        }
        .mask { fade }
        .overlay(alignment: .leading) {
            if hiddenEdges.leading {
                chevron("chevron.left", label: "Show previous \(label.lowercased())") { $0.nextLeadingOffset }
            }
        }
        .overlay(alignment: .trailing) {
            if hiddenEdges.trailing {
                chevron("chevron.right", label: "Show more \(label.lowercased())") { $0.nextTrailingOffset }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .onChange(of: reveals) {
            guard let revealTarget else { return }
            withAnimation(pageAnimation) { position.scrollTo(id: revealTarget, anchor: .leading) }
        }
    }

    private var pageAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: NotebookTheme.stripPageDuration)
    }

    /// Clears the strip entirely under a chevron, so no tool shows through it as a composite
    /// glyph, and fades just before it so the strip still reads as continuing.
    private var fade: some View {
        HStack(spacing: 0) {
            if hiddenEdges.leading {
                Color.clear.frame(width: NotebookTheme.controlSize)
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: NotebookStripOverflow.fadeLength)
            }
            Color.black
            if hiddenEdges.trailing {
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: NotebookStripOverflow.fadeLength)
                Color.clear.frame(width: NotebookTheme.controlSize)
            }
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
                .modifier(NotebookToolbarForeground())
                .frame(width: NotebookTheme.controlSize, height: NotebookTheme.controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotebookToolbarButtonStyle())
        .accessibilityLabel(label)
    }
}

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
        .buttonStyle(NotebookToolbarButtonStyle(isSelected: isSelected))
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

    var body: some View {
        Menu {
            modeButton("Object eraser", mode: .vector)
            modeButton("Pixel eraser", mode: .bitmap)
        } label: {
            NotebookToolGlyph(
                symbol: selectedMode == .bitmap ? "eraser.line.dashed" : "eraser", isSelected: selectedMode != nil
            )
        } primaryAction: {
            actions.selectEraser()
        }
        .menuIndicator(.hidden)
        // A button-styled menu draws its label through the toolbar's button style, so the
        // eraser presses and focuses like every other control.
        .menuStyle(.button)
        .buttonStyle(NotebookToolbarButtonStyle(isSelected: selectedMode != nil))
        .help("Eraser")
        .accessibilityLabel("Eraser")
        .accessibilityValue(selectedMode.map { $0 == .vector ? "Object" : "Pixel" } ?? "")
        .accessibilityHint("Touch and hold to choose object or pixel erasing.")
        .accessibilityAddTraits(selectedMode == nil ? [] : .isSelected)
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

@MainActor
struct NotebookPresetChip: View {
    let preset: EditorInkPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: NotebookTheme.itemSpacing) {
                Image(systemName: "checkmark")
                    .font(.system(size: NotebookTheme.presetCheckmarkSize, weight: .bold))
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
                Circle()
                    .fill(preset.color.swiftUIColor)
                    .frame(width: NotebookTheme.presetDotDiameter, height: NotebookTheme.presetDotDiameter)
                Text(preset.name)
                    .font(NotebookTheme.controlLabel.font)
                    .lineLimit(1)
                    .fixedSize()
            }
            .modifier(NotebookToolbarForeground())
            .padding(.horizontal, NotebookTheme.presetChipPadding)
            .frame(height: NotebookTheme.presetChipHeight)
            .background {
                if !isSelected {
                    Capsule().strokeBorder(NotebookTheme.toolbarLowerEdge.color, lineWidth: NotebookTheme.shellBorderWidth)
                }
            }
            .frame(minHeight: NotebookTheme.controlSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotebookToolbarButtonStyle(isSelected: isSelected, shape: .capsule))
        .accessibilityLabel("\(preset.name) preset")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

@MainActor
private struct NotebookSwatchButton: View {
    let color: EditorInkColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color.swiftUIColor)
                .overlay(NotebookSwatchOutline())
                .frame(width: NotebookTheme.swatchDiameter, height: NotebookTheme.swatchDiameter)
                .overlay {
                    if isSelected { NotebookSwatchCheckmark(color: color) }
                }
                .frame(width: NotebookTheme.controlSize, height: NotebookTheme.controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotebookToolbarButtonStyle(isSelected: isSelected))
        .accessibilityLabel(color.accessibilityName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The checkmark on a selected colour, dark on light colours and light on dark ones.
private struct NotebookSwatchCheckmark: View {
    let color: EditorInkColor

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: NotebookTheme.swatchCheckmarkSize, weight: .bold))
            .foregroundStyle(tone.color)
            .accessibilityHidden(true)
    }

    private var tone: NotebookTheme.Tone {
        NotebookSwatchContrast.mark(for: color)
    }
}

/// Chooses a readable mark against the actual selected swatch, including transparent ink.
enum NotebookSwatchContrast {
    static func background(for color: EditorInkColor) -> EditorInkColor {
        let well = NotebookSwatchShelf.color(from: NotebookTheme.selectedWell.uiColor)
        let alpha = color.alpha
        return EditorInkColor(
            red: color.red * alpha + well.red * (1 - alpha),
            green: color.green * alpha + well.green * (1 - alpha),
            blue: color.blue * alpha + well.blue * (1 - alpha)
        )
    }

    static func mark(for color: EditorInkColor) -> NotebookTheme.Tone {
        let surface = background(for: color)
        let dark = NotebookSwatchShelf.color(from: NotebookTheme.glyph.uiColor)
        let light = NotebookSwatchShelf.color(from: NotebookTheme.paperIvory.uiColor)
        return dark.contrastRatio(against: surface) >= light.contrastRatio(against: surface)
            ? NotebookTheme.glyph : NotebookTheme.paperIvory
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
                .contentShape(Rectangle())
        }
        .buttonStyle(NotebookToolbarButtonStyle(isSelected: isSelected))
        .accessibilityLabel("Custom color")
        .accessibilityValue(isSelected ? store.tool.color.accessibilityName : "")
        .accessibilityHint("Opens the color picker. The color showing when you close it is added to your swatches.")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .sheet(isPresented: $isPicking) {
            NotebookColorPicker(initial: store.tool.color, pick: pick) { isPicking = false }
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
                .modifier(NotebookToolbarForeground())
                .frame(width: step.dotDiameter, height: step.dotDiameter)
                .frame(width: NotebookTheme.controlSize, height: NotebookTheme.controlSize)
                .overlay(alignment: .bottom) {
                    if isSelected { NotebookSelectionMark() }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(NotebookToolbarButtonStyle(isSelected: isSelected))
        .accessibilityLabel("\(step.title) width")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A tool symbol in a 44-point control, with the selection mark when selected. The well
/// behind it comes from `NotebookToolbarButtonStyle`.
@MainActor
struct NotebookToolGlyph: View {
    let symbol: String
    let isSelected: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(NotebookTheme.glyphFont)
            .modifier(NotebookToolbarForeground())
            .frame(width: NotebookTheme.controlSize, height: NotebookTheme.controlSize)
            .overlay(alignment: .bottom) {
                if isSelected { NotebookSelectionMark() }
            }
            .contentShape(Rectangle())
    }
}

/// The recessed well behind a selected control: a darker fill with an inner shadow.
struct NotebookSelectedWell<WellShape: Shape>: View {
    let shape: WellShape

    var body: some View {
        shape.fill(
            NotebookTheme.selectedWell.color.shadow(
                .inner(
                    color: NotebookTheme.toolbarShadowTone.color.opacity(NotebookTheme.wellShadowOpacity),
                    radius: NotebookTheme.wellShadowRadius, x: 0, y: NotebookTheme.wellShadowDepth
                )
            )
        )
    }
}

/// What a toolbar control draws behind and around itself in each interaction state. Every
/// state changes shape or depth, never only colour: selection is the inset well (the label
/// adds a mark or checkmark), a press sinks the control, and keyboard focus draws a ring.
struct NotebookControlBackground: View {
    enum Outline {
        /// The rounded square behind glyphs, swatches and widths.
        case well
        /// The capsule behind a preset.
        case capsule
    }

    /// As heavy as the selection mark, so focus reads at the same weight as selection.
    private static let focusRingWidth = NotebookTheme.selectionMarkSize.height

    let shape: Outline
    let isSelected: Bool
    let isPressed: Bool
    let isFocused: Bool

    var body: some View {
        switch shape {
        case .well:
            layers(RoundedRectangle(cornerRadius: NotebookTheme.selectedWellCornerRadius, style: .continuous))
        case .capsule:
            layers(Capsule())
        }
    }

    private func layers<S: InsettableShape>(_ outline: S) -> some View {
        ZStack {
            if isSelected {
                NotebookSelectedWell(shape: outline)
                if isPressed {
                    // A selected control is already sunk, so a press deepens its shadow.
                    outline.fill(NotebookTheme.toolbarShadowTone.color.opacity(NotebookTheme.wellShadowOpacity))
                }
            } else if isPressed {
                outline.fill(NotebookTheme.selectedWell.color.opacity(NotebookTheme.pressedWellOpacity))
            }
            if isFocused {
                outline.strokeBorder(NotebookTheme.glyph.color, lineWidth: Self.focusRingWidth)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The non-colour selection cue under a selected glyph.
private struct NotebookSelectionMark: View {
    var body: some View {
        Capsule()
            .modifier(NotebookToolbarForeground())
            .frame(width: NotebookTheme.selectionMarkSize.width, height: NotebookTheme.selectionMarkSize.height)
            .padding(.bottom, NotebookTheme.selectionMarkInset)
            .accessibilityHidden(true)
    }
}

/// The toolbar's raised ivory shell: a pale fill, a one-point bevel and a shallow shadow.
struct NotebookToolbarShell: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NotebookTheme.toolbarCornerRadius, style: .continuous)
        let shadow = NotebookTheme.toolbarShadow
        shape
            .fill(NotebookTheme.toolbarSurface.color)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [NotebookTheme.toolbarHighlight.color, NotebookTheme.toolbarLowerEdge.color],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: NotebookTheme.shellBorderWidth
                )
            }
            .shadow(color: shadow.color, radius: shadow.radius, x: shadow.offset.width, y: shadow.offset.height)
    }
}

/// A hairline around a colour so pale swatches stay visible on the ivory shell.
private struct NotebookSwatchOutline: View {
    var body: some View {
        Circle().strokeBorder(NotebookTheme.toolbarLowerEdge.color, lineWidth: NotebookTheme.shellBorderWidth)
    }
}

private struct NotebookToolbarDivider: View {
    let axis: Axis

    var body: some View {
        Group {
            switch axis {
            case .vertical:
                Rectangle()
                    .frame(width: NotebookTheme.dividerThickness, height: NotebookTheme.dividerLength)
            case .horizontal:
                Rectangle()
                    .frame(height: NotebookTheme.dividerThickness)
                    .padding(.horizontal, NotebookTheme.stripInsets.left)
            }
        }
        .foregroundStyle(NotebookTheme.toolbarDivider.color)
        .accessibilityHidden(true)
    }
}

/// Draws the selected, pressed and focused states of every toolbar control the same way.
struct NotebookToolbarButtonStyle: ButtonStyle {
    var isSelected = false
    var shape = NotebookControlBackground.Outline.well

    func makeBody(configuration: Configuration) -> some View {
        NotebookToolbarControl(
            label: configuration.label, isSelected: isSelected, isPressed: configuration.isPressed, shape: shape
        )
    }
}

private struct NotebookToolbarControl<Label: View>: View {
    let label: Label
    let isSelected: Bool
    let isPressed: Bool
    let shape: NotebookControlBackground.Outline
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        label.background {
            NotebookControlBackground(
                shape: shape, isSelected: isSelected, isPressed: isPressed && isEnabled, isFocused: isFocused && isEnabled
            )
            // A preset's capsule is shorter than its touch area.
            .frame(maxHeight: shape == .capsule ? NotebookTheme.presetChipHeight : .infinity)
        }
    }
}

/// Glyph and mark colour, turning to the disabled tone while writing is paused.
private struct NotebookToolbarForeground: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.foregroundStyle((isEnabled ? NotebookTheme.glyph : NotebookTheme.disabledGlyph).color)
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

private extension EditorInkColor {
    /// Spoken names for the quick swatches, in catalog order.
    static let catalogNames: [EditorInkColor: String] = Dictionary(
        zip(EditorInkCatalog.swatches, ["Charcoal", "Sepia", "Rust", "Sage", "Dusty blue", "Plum", "Ochre"]),
        uniquingKeysWith: { first, _ in first }
    )

    var swiftUIColor: Color { Color(uiColor: platformColor) }

    var accessibilityName: String {
        Self.catalogNames[self] ?? platformColor.accessibilityName.localizedCapitalized
    }
}
