import NottyCore
import SwiftUI

extension EditorChromeMode {
    var title: String {
        switch self {
        case .focus: "Focus"
        case .pinned: "Pinned"
        case .overlay: "Always-on tools"
        }
    }

    var summary: String {
        switch self {
        case .focus: "Title and tools hide while you write"
        case .pinned: "Title and tools stay in place"
        case .overlay: "Tools stay; the title scrolls away"
        }
    }

    var symbol: String {
        switch self {
        case .focus: "pencil.and.scribble"
        case .pinned: "pin"
        case .overlay: "pencil.tip.crop.circle"
        }
    }

    /// Chosen with Control-Command and this key.
    var shortcutKey: KeyEquivalent {
        switch self {
        case .focus: "1"
        case .pinned: "2"
        case .overlay: "3"
        }
    }

    var shortcutHint: String { "⌃⌘\(shortcutKey.character)" }
}

/// The one accent in the app: the key that ends the header and opens the notebook menu.
struct NotebookMenuKey: View {
    let session: NotebookSession
    @ObservedObject var chrome: NotebookWritingChrome
    /// The window's width and size class, which decide whether the toolbar docks can be told apart.
    let hostWidth: CGFloat
    let sizeClass: UserInterfaceSizeClass?
    /// True when the header is too narrow for its Redo key, which the menu then offers.
    let offersRedo: Bool
    let openRecoveryCopies: @MainActor () -> Void
    @State private var showsMenu = false
    @State private var opensRecoveryCopies = false

    var body: some View {
        Button { showsMenu = true } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: NotebookTheme.accentGlyphSize, weight: .semibold))
        }
        .buttonStyle(NotebookAccentKeyStyle())
        .accessibilityLabel("Notebook menu")
        .accessibilityValue(chrome.mode.title)
        .help("Notebook menu")
        .accessibilityShowsLargeContentViewer { Label("Notebook menu", systemImage: "line.3.horizontal") }
        .popover(isPresented: $showsMenu) {
            NotebookMenu(
                session: session, chrome: chrome, gate: session.gateModel, commands: session.commandModel,
                hostWidth: hostWidth, sizeClass: sizeClass, offersRedo: offersRedo
            ) {
                opensRecoveryCopies = true
                showsMenu = false
            }
            // The recovery sheet is presented only once the menu has gone, as one presentation
            // cannot start while another is still leaving.
            .onDisappear {
                guard opensRecoveryCopies else { return }
                opensRecoveryCopies = false
                openRecoveryCopies()
            }
        }
        .notebookChromePresentation(showsMenu, chrome: chrome)
    }
}

/// The matte panel the accent key opens: the writing view, the toolbar position, notebook actions
/// and the features planned for later.
struct NotebookMenu: View {
    /// In the order the menu lists them: the notebook-wide features, then the tools.
    static let comingLater = NotebookUpcomingFeature.placed(.menu) + NotebookUpcomingFeature.placed(.toolStrip)

    let session: NotebookSession
    @ObservedObject var chrome: NotebookWritingChrome
    @ObservedObject var gate: NotebookCanvasGateModel
    @ObservedObject var commands: NotebookCanvasCommandModel
    let hostWidth: CGFloat
    let sizeClass: UserInterfaceSizeClass?
    let offersRedo: Bool
    let openRecoveryCopies: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showsComingLater = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                section("Writing view") {
                    VStack(spacing: NotebookTheme.itemSpacing) {
                        ForEach(EditorChromeMode.allCases, id: \.self) { mode in
                            NotebookWritingViewRow(mode: mode, isSelected: chrome.mode == mode) {
                                chrome.setMode(mode)
                            }
                        }
                    }
                }
                separator
                section("Toolbar position") {
                    if let store = chrome.store {
                        NotebookToolbarPositionPicker(store: store, hostWidth: hostWidth, sizeClass: sizeClass)
                    } else {
                        NotebookToolbarPositionPicker.unavailable
                    }
                }
                separator
                section("Notebook") {
                    NotebookMenuActions(
                        session: session, gate: gate, commands: commands, offersRedo: offersRedo,
                        addPage: {
                            session.extendPaper()
                            dismiss()
                        },
                        openRecoveryCopies: openRecoveryCopies
                    )
                }
                separator
                NotebookComingLater(isExpanded: $showsComingLater)
            }
            .padding(NotebookTheme.popoverPadding)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: NotebookTheme.popoverWidth)
        .tint(NotebookTheme.controlTint.color)
        .presentationBackground(NotebookTheme.panelSurface.color)
        .presentationCompactAdaptation(.popover)
    }

    /// A page can be added only while writing is open and the notebook is below its page limit.
    static func canAddPage(_ state: NotebookCanvasGateModel.State) -> Bool {
        state.inputGate.allowsMutation && state.pageCount < NotebookViewController.maximumPageCount
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: NotebookTheme.sectionLabelSpacing) {
            NotebookSectionLabel(title)
            content()
        }
    }

    /// The row-seam inset of the divider is cancelled, so sections part across the whole panel.
    private var separator: some View {
        NotebookChromeDivider(axis: .horizontal)
            .padding(.horizontal, -NotebookTheme.rowDividerInset)
            .padding(.vertical, NotebookTheme.sectionSpacing)
    }
}

/// One writing view. The selected row sinks into a well with a mark at its leading edge, and all
/// its text darkens so it keeps its contrast on the well.
struct NotebookWritingViewRow: View {
    let mode: EditorChromeMode
    let isSelected: Bool
    let choose: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let secondary = (isSelected ? NotebookTheme.glyph : NotebookTheme.glyphSecondary).color
        Button(action: choose) {
            HStack(spacing: 0) {
                Image(systemName: mode.symbol)
                    .font(NotebookTheme.headerGlyphFont)
                    .frame(width: NotebookTheme.menuGlyphColumnWidth)
                    .padding(.trailing, NotebookTheme.menuRowInset)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    // At the standard size the longest description shrinks slightly to keep to one
                    // line beside the hint; larger text wraps rather than being cut off.
                    Text(mode.summary)
                        .font(.footnote)
                        .foregroundStyle(secondary)
                        .lineLimit(typeSize > .large ? nil : 1)
                        .minimumScaleFactor(NotebookTheme.menuDescriptionMinimumScale)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, NotebookTheme.menuRowTextPadding)
                Spacer(minLength: NotebookTheme.menuShortcutGap)
                Text(mode.shortcutHint)
                    .font(.footnote)
                    .foregroundStyle(secondary)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            .padding(.leading, NotebookTheme.menuGlyphInset)
            .padding(.trailing, NotebookTheme.menuRowInset)
            .frame(maxWidth: .infinity, minHeight: NotebookTheme.writingViewRowHeight, alignment: .leading)
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .frame(width: NotebookTheme.rowMarkSize.width, height: NotebookTheme.rowMarkSize.height)
                        .padding(.leading, NotebookTheme.selectionMarkInset)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(NotebookKeyStyle(isSelected: isSelected))
        .accessibilityLabel(mode.title)
        .accessibilityHint(mode.summary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The four places the toolbar can sit, as segment keys. These are the grip's own placement
/// actions made visible, so nobody has to drag.
struct NotebookToolbarPositionPicker: View {
    /// Where the Float segment places the toolbar, as the grip's Float action does.
    private static let floatingStart = CGPoint(x: 0.5, y: 0.25)

    private struct Segment: Identifiable {
        let placement: EditorToolbarPlacement
        let symbol: String
        let label: String
        let accessibilityLabel: String

        var id: String { label }
    }

    private static let segments = [
        Segment(
            placement: .docked(.topLeading), symbol: "rectangle.inset.topleading.filled", label: "Left",
            accessibilityLabel: "Dock top left"
        ),
        Segment(
            placement: .docked(.topCenter), symbol: "rectangle.topthird.inset.filled", label: "Center",
            accessibilityLabel: "Dock top center"
        ),
        Segment(
            placement: .docked(.topTrailing), symbol: "rectangle.inset.toptrailing.filled", label: "Right",
            accessibilityLabel: "Dock top right"
        ),
        Segment(
            placement: .floating(floatingStart), symbol: "rectangle.center.inset.filled", label: "Float",
            accessibilityLabel: "Float"
        ),
    ]

    @ObservedObject var store: NotebookSceneToolStore
    let hostWidth: CGFloat
    /// The window's, which the toolbar measures with; a popover can report its own as compact.
    let sizeClass: UserInterfaceSizeClass?

    /// Shown before the canvas has reported its toolbar.
    static var unavailable: some View {
        segmentRow(selected: nil, isEnabled: false) { _ in }
    }

    var body: some View {
        let actions = NotebookToolbarActions(store: store)
        VStack(alignment: .leading, spacing: NotebookTheme.sectionSpacing) {
            Self.segmentRow(selected: store.toolbar.placement, isEnabled: actions.isEnabled) { actions.place($0) }
            if Self.docksShared(preferences: store.toolbar, hostWidth: hostWidth, sizeClass: sizeClass) {
                Text("This window is too narrow to tell the docks apart; the toolbar sits in the centre.")
                    .font(.footnote)
                    .foregroundStyle(NotebookTheme.glyphSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// True when neighbouring docks would sit less than the least dock travel apart, so they show
    /// as one centred slot. The stored dock stays selected.
    static func docksShared(
        preferences: EditorToolbarPreferences, hostWidth: CGFloat, sizeClass: UserInterfaceSizeClass?
    ) -> Bool {
        var docked = preferences
        docked.place(.docked(.topCenter))
        let width = NotebookToolbarComposition(preferences: docked, horizontalSizeClass: sizeClass)
            .toolbarSize(forHostWidth: hostWidth).width
        let spare = hostWidth - 2 * EditorToolbarLayout.margin - width
        return spare / 2 < NotebookToolbarComposition.minimumDockTravel - 0.5
    }

    private static func segmentRow(
        selected: EditorToolbarPlacement?, isEnabled: Bool, place: @escaping (EditorToolbarPlacement) -> Void
    ) -> some View {
        HStack(spacing: NotebookTheme.itemSpacing) {
            ForEach(segments) { segment in
                let isSelected = selected.map { matches($0, segment.placement) } ?? false
                Button { place(segment.placement) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: segment.symbol)
                            .font(.system(size: NotebookTheme.menuSecondaryGlyphSize))
                        Text(segment.label)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(segmentLabelTone(isSelected: isSelected, isEnabled: isEnabled).color)
                            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: NotebookTheme.writingViewRowHeight)
                    .overlay(alignment: .bottom) {
                        if isSelected { NotebookSelectionMark() }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(NotebookKeyStyle(isSelected: isSelected))
                .accessibilityLabel(segment.accessibilityLabel)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .help(segment.accessibilityLabel)
            }
        }
        .disabled(!isEnabled)
    }

    private static func segmentLabelTone(isSelected: Bool, isEnabled: Bool) -> NotebookTheme.Tone {
        guard isEnabled else { return NotebookTheme.disabledGlyph }
        return isSelected ? NotebookTheme.glyph : NotebookTheme.glyphSecondary
    }

    private static func matches(_ placement: EditorToolbarPlacement, _ segment: EditorToolbarPlacement) -> Bool {
        switch (placement, segment) {
        case (.floating, .floating): true
        default: placement == segment
        }
    }
}

/// The notebook's own actions: Redo while the header has no room for its key, adding a page and
/// the recovery copies.
struct NotebookMenuActions: View {
    let session: NotebookSession
    @ObservedObject var gate: NotebookCanvasGateModel
    @ObservedObject var commands: NotebookCanvasCommandModel
    let offersRedo: Bool
    let addPage: () -> Void
    let openRecoveryCopies: () -> Void

    var body: some View {
        VStack(spacing: NotebookTheme.itemSpacing) {
            // The menu stays open, so several edits can be redone in turn.
            if offersRedo {
                NotebookMenuRow(title: "Redo", symbol: "arrow.uturn.forward", action: session.redo)
                    .disabled(!commands.state.canRedo)
            }
            NotebookMenuRow(title: "Add page at end", symbol: "rectangle.portrait.badge.plus", action: addPage)
                .disabled(!NotebookMenu.canAddPage(gate.state))
            NotebookMenuRow(title: "Recovery copies…", symbol: "lifepreserver", action: openRecoveryCopies)
                .disabled(!commands.state.canOpenRecoveryCopies)
        }
    }
}

/// A plain action row of the menu.
private struct NotebookMenuRow: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: NotebookTheme.menuRowInset) {
                Image(systemName: symbol)
                    .font(NotebookTheme.headerGlyphFont)
                    .frame(width: NotebookTheme.menuGlyphColumnWidth)
                Text(title)
                    .font(.body)
                Spacer(minLength: 0)
            }
            .padding(.leading, NotebookTheme.menuGlyphInset)
            .padding(.trailing, NotebookTheme.menuRowInset)
            .frame(maxWidth: .infinity, minHeight: NotebookTheme.menuRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotebookKeyStyle())
        .accessibilityLabel(title)
    }
}

/// The complete list of planned features, collapsed by default and drawn as unavailable text, so
/// nothing in the editor looks like a working control that does nothing.
struct NotebookComingLater: View {
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(NotebookMenu.comingLater) { feature in
                    HStack(spacing: NotebookTheme.menuRowInset) {
                        Image(systemName: feature.symbol)
                            .font(.system(size: NotebookTheme.menuSecondaryGlyphSize))
                            .frame(width: NotebookTheme.menuGlyphColumnWidth)
                        Text(feature.title)
                            .font(.subheadline)
                    }
                    .foregroundStyle(NotebookTheme.disabledGlyph.color)
                    .padding(.leading, NotebookTheme.menuGlyphInset)
                    .padding(.trailing, NotebookTheme.menuRowInset)
                    .frame(maxWidth: .infinity, minHeight: NotebookTheme.comingLaterRowHeight, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(feature.accessibilityLabel)
                }
            }
        } label: {
            HStack(spacing: NotebookTheme.menuRowInset) {
                Image(systemName: NotebookUpcomingFeature.menuSymbol)
                    .font(.system(size: NotebookTheme.menuSecondaryGlyphSize))
                    .frame(width: NotebookTheme.menuGlyphColumnWidth)
                Text("Coming later")
                    .font(.body)
            }
            .foregroundStyle(NotebookTheme.glyphSecondary.color)
        }
        .disclosureGroupStyle(NotebookDisclosureStyle())
    }
}

/// A disclosure row whose chevron takes the row's secondary glyph tone; the system style draws it
/// in black whatever the tint or foreground style.
private struct NotebookDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        NotebookDisclosure(configuration: configuration)
    }
}

private struct NotebookDisclosure: View {
    let configuration: DisclosureGroupStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .default) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 0) {
                    configuration.label
                    Spacer(minLength: NotebookTheme.menuShortcutGap)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(NotebookTheme.glyphSecondary.color)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.leading, NotebookTheme.menuGlyphInset)
                .padding(.trailing, NotebookTheme.menuRowInset)
                .frame(maxWidth: .infinity, minHeight: NotebookTheme.menuRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(NotebookKeyStyle())
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

/// The accent key: a periwinkle face with a navy glyph, lit along its top and rimmed below. A press
/// darkens it and drops the glyph a point; keyboard focus rings it in the glyph tone.
struct NotebookAccentKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        NotebookAccentKey(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct NotebookAccentKey<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pressed = isPressed && isEnabled
        let release: Animation? = pressed || reduceMotion ? nil : .easeOut(duration: NotebookTheme.keyReleaseDuration)
        let face = RoundedRectangle(cornerRadius: NotebookTheme.accentKeyCornerRadius, style: .continuous)
        label
            .foregroundStyle(NotebookTheme.accentGlyph.color)
            .animation(release) { $0.offset(y: pressed ? NotebookTheme.pressTravel : 0) }
            .frame(width: NotebookTheme.accentKeySize.width, height: NotebookTheme.accentKeySize.height)
            .background {
                face
                    .fill(NotebookTheme.accentFill.color)
                    .overlay {
                        face
                            .fill(NotebookTheme.accentRim.color)
                            .animation(release) { $0.opacity(pressed ? NotebookTheme.accentPressedOverlayOpacity : 0) }
                    }
                    .overlay {
                        if contrast == .increased {
                            face.strokeBorder(NotebookTheme.panelLowerEdge.color, lineWidth: NotebookTheme.shellBorderWidth)
                        } else {
                            face.strokeBorder(Self.edge, lineWidth: NotebookTheme.shellBorderWidth)
                        }
                    }
            }
            .overlay {
                if isFocused && isEnabled {
                    RoundedRectangle(cornerRadius: NotebookTheme.accentFocusCornerRadius, style: .continuous)
                        .strokeBorder(NotebookTheme.glyph.color, lineWidth: NotebookTheme.focusRingWidth)
                        .padding(-NotebookTheme.focusRingWidth)
                }
            }
            .frame(width: NotebookTheme.controlSize, height: NotebookTheme.controlSize)
            .contentShape(Rectangle())
    }

    /// A lit top edge and the rim along the bottom.
    private static var edge: LinearGradient {
        let highlight = Color.white.opacity(NotebookTheme.accentHighlightOpacity)
        let rim = NotebookTheme.accentRim.color
        return LinearGradient(
            stops: [
                .init(color: highlight, location: 0),
                .init(color: highlight.opacity(0), location: 0.3),
                .init(color: rim.opacity(0), location: 0.7),
                .init(color: rim, location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }
}
