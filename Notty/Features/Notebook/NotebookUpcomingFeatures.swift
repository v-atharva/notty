import SwiftUI

/// A planned feature shown as a disabled placeholder, so the editor shows where the product
/// is heading without offering anything that does not work yet. Placeholders carry no action
/// and never read or change the tool store, the canvas or saved notebooks.
struct NotebookUpcomingFeature: Identifiable, Hashable, Sendable {
    enum Placement: CaseIterable, Sendable {
        /// After the ruler in the drawing toolbar's tool row, and in the notebook menu's list.
        case toolStrip
        /// Only in the notebook menu's "Coming later" list, so the header stays uncluttered.
        case menu
    }

    /// Symbol of the notebook menu's "Coming later" row; an hourglass rather than an ellipsis, so
    /// it is not mistaken for a menu of working actions.
    static let menuSymbol = "hourglass"

    static let catalogue: [NotebookUpcomingFeature] = [
        NotebookUpcomingFeature(title: "Text", symbol: "textformat", placement: .toolStrip),
        NotebookUpcomingFeature(title: "Insert", symbol: "photo.badge.plus", placement: .toolStrip),
        NotebookUpcomingFeature(title: "Record audio", symbol: "mic", placement: .toolStrip),
        NotebookUpcomingFeature(title: "Bookmark", symbol: "bookmark", placement: .toolStrip),
        NotebookUpcomingFeature(title: "Notebooks", symbol: "books.vertical", placement: .menu),
        NotebookUpcomingFeature(title: "Search", symbol: "magnifyingglass", placement: .menu),
        NotebookUpcomingFeature(title: "Summarize", symbol: "list.bullet.rectangle.portrait", placement: .menu),
        NotebookUpcomingFeature(title: "Export", symbol: "square.and.arrow.up", placement: .menu),
        NotebookUpcomingFeature(title: "Backup", symbol: "archivebox", placement: .menu),
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

/// The caption that introduces the toolbar's placeholders, centred in a control-sized cell so
/// the rail can count its room. It dims with the rail while writing is paused. The placeholders
/// carry "coming later" in their own labels, so VoiceOver skips the caption.
struct NotebookUpcomingMark: View {
    var body: some View {
        NotebookSectionLabel("Soon")
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: NotebookTheme.controlSize, height: NotebookTheme.controlSize)
            .accessibilityHidden(true)
    }
}
