import NottyCore
import SwiftUI
import UIKit

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

    /// The point size that gives this mode's glyph the same optical size as the others.
    var symbolSize: CGFloat {
        switch self {
        case .focus: NotebookTheme.focusGlyphSize
        case .pinned, .overlay: NotebookTheme.headerGlyphSize
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
    /// The window's width, which sizes the menu, and its size class, which decides whether the
    /// toolbar's side docks are offered.
    let hostWidth: CGFloat
    let sizeClass: UserInterfaceSizeClass?
    /// True when the header is too narrow for its Redo key, which the menu then offers.
    let offersRedo: Bool
    let openRecoveryCopies: @MainActor () -> Void
    @State private var showsMenu = false
    @State private var handOff = NotebookMenuHandOff()
    /// The page the menu offers to delete, chosen as it opens; the popover keeps the paper still.
    @State private var pageToDelete: NotebookPageDeletionTarget?

    var body: some View {
        Button {
            pageToDelete = Self.pageToDelete(openingMenuOver: session)
            showsMenu = true
        } label: {
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
                hostWidth: hostWidth, sizeClass: sizeClass, offersRedo: offersRedo, close: { showsMenu = false },
                openRecoveryCopies: { handOff.requestRecoveryCopies { showsMenu = false } }, pageToDelete: pageToDelete
            )
            .onDisappear {
                handOff.menuDidDisappear(open: openRecoveryCopies)
                session.pageDeletionPrompt.menuDidDisappear()
            }
        }
        .notebookChromePresentation(showsMenu, chrome: chrome)
    }

    /// The page the menu offers to delete as it opens: the one in view now. A deletion asked for
    /// from an earlier opening whose alert never opened is dropped first.
    static func pageToDelete(openingMenuOver session: NotebookSession) -> NotebookPageDeletionTarget? {
        session.pageDeletionPrompt.withdrawRequest()
        return session.pageDeletionTarget()
    }
}

/// Passes the recovery copies on from the notebook menu to their sheet. One presentation cannot
/// start while another is still leaving, so the sheet is asked for only once the menu has gone.
@MainActor
final class NotebookMenuHandOff {
    private var opensRecoveryCopies = false

    /// The menu's "Recovery copies" row: remembers the request, then closes the menu.
    func requestRecoveryCopies(closing close: () -> Void) {
        opensRecoveryCopies = true
        close()
    }

    /// The menu has gone; opens the recovery copies if the menu asked for them.
    func menuDidDisappear(open: () -> Void) {
        guard opensRecoveryCopies else { return }
        opensRecoveryCopies = false
        open()
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
    /// Closes the menu, as dismissing its popover does.
    let close: () -> Void
    let openRecoveryCopies: () -> Void
    /// The page "Delete this page…" deletes; nil while no canvas can say which page is in view.
    var pageToDelete: NotebookPageDeletionTarget?
    @State private var showsComingLater = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.legibilityWeight) private var legibilityWeight

    var body: some View {
        let width = Self.width(for: typeSize, hostWidth: hostWidth)
        let rowLayout = NotebookWritingViewRow.Layout(
            rowWidth: width - 2 * NotebookTheme.popoverPadding, typeSize: typeSize, isBold: legibilityWeight == .bold
        )
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                section("Writing view") {
                    VStack(spacing: NotebookTheme.itemSpacing) {
                        ForEach(EditorChromeMode.allCases, id: \.self) { mode in
                            writingViewRow(mode, layout: rowLayout)
                        }
                    }
                }
                separator
                section("Toolbar position") {
                    if let store = chrome.store {
                        NotebookToolbarPositionPicker(store: store, sizeClass: sizeClass)
                    } else {
                        NotebookToolbarPositionPicker.unavailable
                    }
                }
                separator
                section("Notebook") {
                    NotebookMenuActions(
                        session: session, gate: gate, commands: commands, offersRedo: offersRedo,
                        addPage: addPage, openRecoveryCopies: openRecoveryCopies,
                        pageToDelete: pageToDelete, deletePage: deletePage
                    )
                }
                separator
                NotebookComingLater(isExpanded: $showsComingLater)
            }
            .padding(NotebookTheme.popoverPadding)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: width)
        .tint(NotebookTheme.controlTint.color)
        .presentationBackground(NotebookTheme.panelSurface.color)
        .presentationCompactAdaptation(.popover)
    }

    /// UIKit keeps a popover at least this far inside the window, narrowing one that would come closer.
    static let systemPopoverMargin: CGFloat = 10

    /// The standard popover width, widened at accessibility text sizes as far as the window allows,
    /// so the writing views keep their names whole. A window too narrow for the standard width, as
    /// in Slide Over, gets the widest popover UIKit will show, so the menu lays out at the width
    /// it is drawn.
    static func width(for typeSize: DynamicTypeSize, hostWidth: CGFloat) -> CGFloat {
        let widest = hostWidth - 2 * systemPopoverMargin
        guard typeSize.isAccessibilitySize else { return min(NotebookTheme.popoverWidth, widest) }
        let room = hostWidth - 2 * NotebookTheme.popoverWindowMargin
        return min(max(NotebookTheme.popoverWidth, min(NotebookTheme.accessibilityPopoverWidth, room)), widest)
    }

    /// A page can be added only while writing is open and the notebook is below its page limit.
    static func canAddPage(_ state: NotebookCanvasGateModel.State) -> Bool {
        state.inputGate.allowsMutation && state.pageCount < NotebookViewController.maximumPageCount
    }

    /// The page under view can be deleted only while writing is open, no stroke is under way and
    /// another page would remain, with the page count it was chosen from.
    static func canDeletePage(
        _ target: NotebookPageDeletionTarget?, gate: NotebookCanvasGateModel.State,
        commands: NotebookCanvasCommandModel.State
    ) -> Bool {
        guard let target else { return false }
        return gate.inputGate.allowsMutation && gate.pageCount > 1 && target.pageCount == gate.pageCount
            && !commands.isUsingTool
    }

    /// The row that chooses and stores `mode` as the writing view.
    func writingViewRow(
        _ mode: EditorChromeMode, layout: NotebookWritingViewRow.Layout = .init()
    ) -> NotebookWritingViewRow {
        NotebookWritingViewRow(mode: mode, isSelected: chrome.mode == mode, layout: layout) {
            chrome.setMode(mode)
        }
    }

    /// Adds a page at the end of the notebook and closes the menu over it.
    func addPage() {
        session.extendPaper()
        close()
    }

    /// Asks to delete the page under view and closes the menu; an alert confirms the deletion
    /// once the menu has gone.
    func deletePage() {
        guard let pageToDelete else { return }
        session.pageDeletionPrompt.request(pageToDelete)
        close()
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
    /// How the rows set their glyphs, names and descriptions in the menu's width. The menu decides
    /// once for all three rows, so their glyphs and names line up.
    struct Layout: Equatable {
        /// The glyph sits above the name, scaled with it, so the name and description take the
        /// row's whole width.
        var stacksGlyph = false
        /// Where a word of some name is too wide for even the row's whole width, as "Always-on"
        /// is at the largest text size in Slide Over, hyphenated words break at their hyphens;
        /// otherwise every hyphenated word stays whole.
        var breaksAtHyphens = false
        /// False where the menu is narrower than its standard width, as in Slide Over, where the
        /// descriptions wrap at every text size rather than shrink.
        var isStandardWidth = true

        /// The standard popover's layout.
        init() {}

        /// The glyph moves above the name where a word of some writing view's name would not fit
        /// beside it, as at the largest text sizes in a narrow window, so names still wrap only
        /// between their words; where even the whole row is too narrow, a hyphenated word breaks
        /// at its hyphen.
        init(rowWidth: CGFloat, typeSize: DynamicTypeSize, isBold: Bool) {
            isStandardWidth = rowWidth >= NotebookTheme.popoverWidth - 2 * NotebookTheme.popoverPadding
            guard typeSize.isAccessibilitySize else { return }
            let widest = NotebookWritingViewRow.longestNameWord(typeSize: typeSize, isBold: isBold)
            stacksGlyph = widest > Self.nameColumn(rowWidth: rowWidth, stacksGlyph: false)
            breaksAtHyphens = widest > Self.nameColumn(rowWidth: rowWidth, stacksGlyph: stacksGlyph)
        }

        /// The width the name and description wrap in: beside the glyph, less its inset and column,
        /// the gap after it and the least gap before the trailing inset, or below it, less an inset
        /// at each side. At accessibility sizes, where these apply, the shortcut hint is hidden.
        static func nameColumn(rowWidth: CGFloat, stacksGlyph: Bool) -> CGFloat {
            guard !stacksGlyph else { return rowWidth - 2 * NotebookTheme.menuRowInset }
            return rowWidth - NotebookTheme.menuGlyphInset - NotebookTheme.menuGlyphColumnWidth
                - 2 * NotebookTheme.menuRowInset - NotebookTheme.menuShortcutGap
        }
    }

    let mode: EditorChromeMode
    let isSelected: Bool
    var layout = Layout()
    let choose: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    /// At accessibility text sizes the keyboard shortcut gives its room to the name and description;
    /// the shortcut stays listed in the keyboard shortcut overlay.
    static func showsShortcutHint(at typeSize: DynamicTypeSize) -> Bool {
        !typeSize.isAccessibilitySize
    }

    /// The widest word of any writing view's name in the name's face at `typeSize`, set in bold
    /// under Bold Text.
    nonisolated static func longestNameWord(typeSize: DynamicTypeSize, isBold: Bool) -> CGFloat {
        let font = nameFont(typeSize: typeSize, isBold: isBold)
        let words = EditorChromeMode.allCases.flatMap { $0.title.split(separator: " ") }
        return words.map { (String($0) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    }

    /// The name's face at `typeSize`, set in bold under Bold Text.
    nonisolated static func nameFont(typeSize: DynamicTypeSize, isBold: Bool) -> UIFont {
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits(typeSize))
        return UIFont.systemFont(ofSize: body.pointSize, weight: isBold ? .bold : .medium)
    }

    /// The point size of `mode`'s glyph: its own beside the name, and scaled as the name is when
    /// set above it, so it keeps its size relative to the name.
    nonisolated static func glyphSize(of mode: EditorChromeMode, typeSize: DynamicTypeSize, stacked: Bool) -> CGFloat {
        guard stacked else { return mode.symbolSize }
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: mode.symbolSize, compatibleWith: traits(typeSize))
    }

    nonisolated private static func traits(_ typeSize: DynamicTypeSize) -> UITraitCollection {
        UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
    }

    var body: some View {
        Button(action: choose) {
            Group {
                if layout.stacksGlyph {
                    VStack(alignment: .leading, spacing: NotebookTheme.menuRowTextPadding) {
                        glyph
                        text
                    }
                    .padding(.vertical, NotebookTheme.menuRowTextPadding)
                    // The mark sits in the row's leading inset, clear of the glyph and text alike.
                    .padding(.horizontal, NotebookTheme.menuRowInset)
                } else {
                    HStack(spacing: 0) {
                        glyph
                            .padding(.trailing, NotebookTheme.menuRowInset)
                        text
                            .padding(.vertical, NotebookTheme.menuRowTextPadding)
                        Spacer(minLength: NotebookTheme.menuShortcutGap)
                        if Self.showsShortcutHint(at: typeSize) {
                            Text(mode.shortcutHint)
                                .font(.footnote)
                                .foregroundStyle(secondaryTone)
                                .fixedSize()
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.leading, NotebookTheme.menuGlyphInset)
                    .padding(.trailing, NotebookTheme.menuRowInset)
                }
            }
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

    private var secondaryTone: Color {
        (isSelected ? NotebookTheme.glyph : NotebookTheme.glyphSecondary).color
    }

    /// Beside the name the glyph keeps its column; above it, it sets its own width.
    private var glyph: some View {
        let size = Self.glyphSize(of: mode, typeSize: typeSize, stacked: layout.stacksGlyph)
        return Image(systemName: mode.symbol)
            .font(.system(size: size, weight: .regular))
            .frame(width: layout.stacksGlyph ? nil : NotebookTheme.menuGlyphColumnWidth)
    }

    /// Larger text wraps rather than being cut off. At the standard size and width the longest
    /// description shrinks slightly to keep to one line beside the hint.
    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Text(mode.summary)
                .font(.footnote)
                .foregroundStyle(secondaryTone)
                .lineLimit(typeSize > .large || !layout.isStandardWidth ? nil : 1)
                .minimumScaleFactor(NotebookTheme.menuDescriptionMinimumScale)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Line breaking would rather split "Always-on" at its hyphen than leave "tools" alone on a
    /// line, so a non-breaking hyphen keeps every word whole wherever the word fits.
    private var name: String {
        layout.breaksAtHyphens ? mode.title : mode.title.replacingOccurrences(of: "-", with: "\u{2011}")
    }
}

/// The four places the toolbar can sit, as segment keys. These are the grip's own placement
/// actions made visible, so nobody has to drag.
struct NotebookToolbarPositionPicker: View {
    static let segments = NotebookToolbarPlacementChoice.all

    @ObservedObject var store: NotebookSceneToolStore
    /// The window's, which the toolbar measures with; a popover can report its own as compact.
    let sizeClass: UserInterfaceSizeClass?

    /// Shown before the canvas has reported its toolbar.
    static var unavailable: some View {
        segmentRow(selected: nil, isEnabled: false) { _ in }
    }

    var body: some View {
        let actions = NotebookToolbarActions(store: store)
        VStack(alignment: .leading, spacing: NotebookTheme.sectionSpacing) {
            Self.segmentRow(selected: store.toolbar.placement, isEnabled: actions.isEnabled) { choose($0) }
            if Self.restsAtTopInstead(preferences: store.toolbar, sizeClass: sizeClass) {
                Text("This window is too narrow for the side docks, so the toolbar sits at the top.")
                    .font(.footnote)
                    .foregroundStyle(NotebookTheme.glyphSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What a segment does. Float keeps a floating toolbar where it is, as a dock segment keeps
    /// the dock already chosen.
    func choose(_ placement: EditorToolbarPlacement) {
        let actions = NotebookToolbarActions(store: store)
        if case .floating = placement, case .floating = store.toolbar.placement {
            actions.place(store.toolbar.placement)
        } else {
            actions.place(placement)
        }
    }

    /// The segment that shows as selected for `placement`.
    static func segment(for placement: EditorToolbarPlacement) -> NotebookToolbarPlacementChoice? {
        segments.first { matches(placement, $0.placement) }
    }

    /// Whether a toolbar stored at a side rests at the top in this window, decided by the toolbar
    /// itself so the note always agrees with what it does. The stored dock stays selected.
    static func restsAtTopInstead(preferences: EditorToolbarPreferences, sizeClass: UserInterfaceSizeClass?) -> Bool {
        let composition = NotebookToolbarComposition(preferences: preferences, horizontalSizeClass: sizeClass)
        return composition.storedDock != composition.shownDock
    }

    private static func segmentRow(
        selected: EditorToolbarPlacement?, isEnabled: Bool, place: @escaping (EditorToolbarPlacement) -> Void
    ) -> some View {
        let selectedID = selected.flatMap(segment(for:))?.id
        return HStack(spacing: NotebookTheme.itemSpacing) {
            ForEach(segments) { segment in
                let isSelected = segment.id == selectedID
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
                .accessibilityLabel(segment.actionName)
                .accessibilityInputLabels(segment.inputLabels)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .help(segment.actionName)
                .accessibilityShowsLargeContentViewer {
                    Label(segment.actionName, systemImage: segment.symbol)
                }
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

/// The notebook's own actions: Redo while the header has no room for its key, adding and deleting
/// a page, and the recovery copies.
struct NotebookMenuActions: View {
    let session: NotebookSession
    @ObservedObject var gate: NotebookCanvasGateModel
    @ObservedObject var commands: NotebookCanvasCommandModel
    let offersRedo: Bool
    let addPage: () -> Void
    let openRecoveryCopies: () -> Void
    var pageToDelete: NotebookPageDeletionTarget?
    var deletePage: () -> Void = {}

    /// What VoiceOver reads for the deletion row: the page it deletes.
    static func deletionLabel(for target: NotebookPageDeletionTarget?) -> String {
        target.map { "Delete page \($0.number)" } ?? "Delete this page"
    }

    var body: some View {
        VStack(spacing: NotebookTheme.itemSpacing) {
            // The menu stays open, so several edits can be redone in turn.
            if offersRedo {
                NotebookMenuRow(title: "Redo", symbol: "arrow.uturn.forward", action: session.redo)
                    .disabled(!commands.state.canRedo)
            }
            NotebookMenuRow(title: "Add page at end", symbol: "rectangle.portrait.badge.plus", action: addPage)
                .disabled(!NotebookMenu.canAddPage(gate.state))
            NotebookMenuRow(
                title: "Delete this page…", symbol: "trash", isDestructive: true,
                spokenTitle: Self.deletionLabel(for: pageToDelete), action: deletePage
            )
            .disabled(!NotebookMenu.canDeletePage(pageToDelete, gate: gate.state, commands: commands.state))
            NotebookMenuRow(title: "Recovery copies…", symbol: "lifepreserver", action: openRecoveryCopies)
                .disabled(!commands.state.canOpenRecoveryCopies)
        }
    }
}

/// A plain action row of the menu. A destructive row draws its glyph and title in the alert tone
/// while it is available, and the disabled tone otherwise, as every row does.
private struct NotebookMenuRow: View {
    let title: String
    let symbol: String
    var isDestructive = false
    /// What VoiceOver reads instead of the title, where the title alone would leave out what the row acts on.
    var spokenTitle: String?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

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
            .modifier(NotebookDestructiveTone(isActive: isDestructive && isEnabled))
            .padding(.leading, NotebookTheme.menuGlyphInset)
            .padding(.trailing, NotebookTheme.menuRowInset)
            .frame(maxWidth: .infinity, minHeight: NotebookTheme.menuRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotebookKeyStyle())
        .accessibilityLabel(spokenTitle ?? title)
    }
}

/// The alert tone for a destructive control, inside the key's own foreground so it takes precedence.
private struct NotebookDestructiveTone: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.foregroundStyle(NotebookTheme.alertGlyph.color)
        } else {
            content
        }
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
        .disclosureGroupStyle(NotebookDisclosureStyle(title: "Coming later"))
    }
}

/// A disclosure row whose chevron takes the row's secondary glyph tone; the system style draws it
/// in black whatever the tint or foreground style. The row is read by its title alone, as its glyph
/// would otherwise be read by its symbol name first.
private struct NotebookDisclosureStyle: DisclosureGroupStyle {
    let title: String

    func makeBody(configuration: Configuration) -> some View {
        NotebookDisclosure(configuration: configuration, title: title)
    }
}

private struct NotebookDisclosure: View {
    let configuration: DisclosureGroupStyleConfiguration
    let title: String
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
            .accessibilityLabel(title)
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
        let release = NotebookKeyRelease.animation(pressed: pressed, reduceMotion: reduceMotion)
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
