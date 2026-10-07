import SwiftUI

/// A planned feature shown as a disabled placeholder, so the editor shows where the product
/// is heading without offering anything that does not work yet. Placeholders carry no action
/// and never read or change the tool store, the canvas or saved notebooks.
struct NotebookUpcomingFeature: Identifiable, Hashable, Sendable {
    enum Placement: CaseIterable, Sendable {
        /// After the ruler in the drawing toolbar's tool row.
        case toolStrip
        /// Before the wordmark in the navigation bar.
        case navigationLeading
        /// Inside the navigation bar's "Coming later" menu, so the bar stays uncluttered.
        case navigationTrailing
    }

    /// Symbol of the navigation bar menu that lists the trailing placeholders; an hourglass
    /// rather than the ellipsis, so it is not mistaken for a menu of working actions.
    static let menuSymbol = "hourglass"

    static let catalogue: [NotebookUpcomingFeature] = [
        NotebookUpcomingFeature(title: "Text", symbol: "textformat", placement: .toolStrip),
        NotebookUpcomingFeature(title: "Insert", symbol: "photo.badge.plus", placement: .toolStrip),
        NotebookUpcomingFeature(title: "Record audio", symbol: "mic", placement: .toolStrip),
        NotebookUpcomingFeature(title: "Bookmark", symbol: "bookmark", placement: .toolStrip),
        NotebookUpcomingFeature(title: "Notebooks", symbol: "books.vertical", placement: .navigationLeading),
        NotebookUpcomingFeature(title: "Search", symbol: "magnifyingglass", placement: .navigationTrailing),
        NotebookUpcomingFeature(
            title: "Summarize", symbol: "list.bullet.rectangle.portrait", placement: .navigationTrailing
        ),
        NotebookUpcomingFeature(title: "Export", symbol: "square.and.arrow.up", placement: .navigationTrailing),
        NotebookUpcomingFeature(title: "Backup", symbol: "archivebox", placement: .navigationTrailing),
    ]

    let title: String
    /// An SF Symbol present in the iOS 27 symbol set.
    let symbol: String
    let placement: Placement

    var id: String { title }

    var accessibilityLabel: String { "\(title), coming later" }

    static func placed(_ placement: Placement) -> [NotebookUpcomingFeature] {
        catalogue.filter { $0.placement == placement }
    }
}

/// A placeholder in the drawing toolbar: the toolbar's own control, permanently disabled, so
/// it takes the disabled glyph tone and never shows a pressed, focused or selected state.
@MainActor
struct NotebookUpcomingToolButton: View {
    let feature: NotebookUpcomingFeature

    var body: some View {
        Button {} label: {
            NotebookToolGlyph(symbol: feature.symbol, isSelected: false)
        }
        .buttonStyle(NotebookKeyStyle())
        .disabled(true)
        .accessibilityLabel(feature.accessibilityLabel)
        .help(feature.accessibilityLabel)
        .accessibilityShowsLargeContentViewer {
            Label(feature.accessibilityLabel, systemImage: feature.symbol)
        }
    }
}

/// The small caption that introduces the toolbar's placeholders: a muted tone that stays
/// legible on the shell (about 7:1) yet reads quieter than a working tool, dimming with the
/// toolbar while writing is paused. It is one control wide at every text size, so the toolbar
/// can reserve its room. The placeholders carry "coming later" in their own labels, so
/// VoiceOver skips the mark.
struct NotebookUpcomingMark: View {
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Text("Soon")
            .font(NotebookTheme.controlLabel.font)
            .foregroundStyle((isEnabled ? NotebookTheme.controlTint : NotebookTheme.disabledGlyph).color)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: NotebookTheme.controlSize, height: NotebookTheme.controlSize)
            .accessibilityHidden(true)
    }
}

/// A disabled navigation bar placeholder. The bar shows only its symbol and reads the title
/// aloud, so the title itself says the feature is coming later.
@MainActor
struct NotebookUpcomingBarButton: View {
    let feature: NotebookUpcomingFeature

    var body: some View {
        Button {} label: {
            Label(feature.accessibilityLabel, systemImage: feature.symbol)
        }
        .disabled(true)
    }
}

/// One navigation bar menu listing the trailing placeholders, every entry disabled. The menu's
/// own title says they are coming later, so each entry shows only its feature's name.
@MainActor
struct NotebookUpcomingMenu: View {
    static let title = "Coming later"
    static let entries = NotebookUpcomingFeature.placed(.navigationTrailing)

    var body: some View {
        Menu {
            ForEach(Self.entries) { feature in
                Button {} label: {
                    Label(feature.title, systemImage: feature.symbol)
                }
                .disabled(true)
            }
        } label: {
            Label(Self.title, systemImage: NotebookUpcomingFeature.menuSymbol)
        }
    }
}
