import SwiftUI
import UIKit

/// The card a pull or a fling past the last page reveals on the near-black beneath it: the end of
/// the notebook, with exporting it, which is coming later, and adding a page. The controller places
/// it under the last page in the pass that moves the paper. A move only shifts this view; the
/// SwiftUI content inside is built again only when the card's state, width or text size changes.
@MainActor
final class NotebookEndOfNotebookCard: UIView {
    enum AddPage: Equatable {
        /// Adds a page when tapped.
        case available
        /// Writing is paused, so the key shows but adds nothing.
        case paused
        /// The notebook already has the most pages it can hold.
        case limitReached
    }

    /// Counts evaluations of the card's SwiftUI content.
    @MainActor
    final class Diagnostics {
        var bodyCount = 0
    }

    static let title = "End of notebook"
    static let exportTitle = "Export as PDF"
    static let exportNote = "Coming later"
    static let addTitle = "Add page"
    static let limitTitle = "Paper limit reached"
    static let addHint = "Adds a page at the end of the notebook."

    private(set) var addPage = AddPage.available
    /// Runs when the Add page key is tapped while it is available.
    var onAddPage: (() -> Void)?
    let diagnostics: Diagnostics
    /// Hosts the card's face. The view controller that shows the card adopts it as a child, so
    /// it receives the appearance and trait updates a hosted SwiftUI view expects.
    let host: UIHostingController<NotebookEndOfNotebookCardContent>
    /// The face the card shows now.
    var content: NotebookEndOfNotebookCardContent { host.rootView }
    private var configuration: Configuration?

    private struct Configuration: Equatable {
        let addPage: AddPage
        let contentSize: UIContentSizeCategory
        let width: CGFloat
    }

    override init(frame: CGRect) {
        let diagnostics = Diagnostics()
        self.diagnostics = diagnostics
        host = UIHostingController(rootView: NotebookEndOfNotebookCardContent(
            addPage: .available, contentSize: .large, diagnostics: diagnostics, onAddPage: {}
        ))
        super.init(frame: frame)
        isHidden = true
        // The shell's baked shadow reaches past the card on every side.
        clipsToBounds = false
        host.view.clipsToBounds = false
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        // Safe areas change as the card moves past the home indicator; ignoring them keeps a move
        // from laying the content out again.
        host.safeAreaRegions = []
        addSubview(host.view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(frame:).")
    }

    /// Sets the Add page key's state, the text size and the widest the card may be, building the
    /// content and measuring the card again only when one of them changes.
    func configure(addPage: AddPage, contentSize: UIContentSizeCategory, maximumWidth: CGFloat) {
        let width = max(min(NotebookTheme.endCardWidth, maximumWidth), 0).rounded(.down)
        let configuration = Configuration(addPage: addPage, contentSize: contentSize, width: width)
        guard configuration != self.configuration else { return }
        self.configuration = configuration
        self.addPage = addPage
        host.rootView = NotebookEndOfNotebookCardContent(
            addPage: addPage, contentSize: contentSize, diagnostics: diagnostics
        ) { [weak self] in
            self?.addPageTapped()
        }
        let fitted = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        let size = CGSize(width: width, height: fitted.height.rounded(.up))
        withoutAnimations {
            bounds.size = size
            host.view.frame = CGRect(origin: .zero, size: size)
        }
    }

    private func addPageTapped() {
        guard addPage == .available else { return }
        onAddPage?()
    }
}

/// The card's face: a caps label naming the end of the notebook, then the export key, shown
/// disabled with its note, beside the Add page key. A window too narrow for the two keys side by
/// side, or a text size too large, stacks them.
struct NotebookEndOfNotebookCardContent: View {
    let addPage: NotebookEndOfNotebookCard.AddPage
    /// Given rather than read from the traits, which the controller can be ahead of.
    let contentSize: UIContentSizeCategory
    let diagnostics: NotebookEndOfNotebookCard.Diagnostics
    let onAddPage: () -> Void

    var body: some View {
        let _ = diagnostics.bodyCount += 1
        VStack(alignment: .leading, spacing: NotebookTheme.sectionLabelSpacing) {
            NotebookSectionLabel(NotebookEndOfNotebookCard.title)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: NotebookTheme.endCardKeySpacing) {
                    export
                    add
                }
                VStack(spacing: NotebookTheme.endCardKeySpacing) {
                    export
                    add
                }
            }
        }
        .padding(NotebookTheme.detailPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { NotebookPanelShell() }
        .environment(\.dynamicTypeSize, DynamicTypeSize(contentSize) ?? .large)
    }

    /// Export is coming later, so its key never works and says so.
    var exportAccessibilityLabel: String {
        "\(NotebookEndOfNotebookCard.exportTitle), \(NotebookEndOfNotebookCard.exportNote.lowercased())"
    }
    var addTitle: String {
        addPage == .limitReached ? NotebookEndOfNotebookCard.limitTitle : NotebookEndOfNotebookCard.addTitle
    }
    var isAddEnabled: Bool { addPage == .available }
    var addHint: String? { isAddEnabled ? NotebookEndOfNotebookCard.addHint : nil }

    private var export: some View {
        VStack(spacing: NotebookTheme.endCardNoteSpacing) {
            Button {} label: {
                Text(NotebookEndOfNotebookCard.exportTitle)
            }
            .buttonStyle(NotebookActionKeyStyle(kind: .primary))
            .disabled(true)
            .accessibilityLabel(exportAccessibilityLabel)
            // The key's label already says it is coming later.
            Text(NotebookEndOfNotebookCard.exportNote)
                .notebookTypeface(NotebookTheme.sectionLabel)
                .textCase(.uppercase)
                .foregroundStyle(NotebookTheme.glyphSecondary.color)
                .accessibilityHidden(true)
        }
    }

    private var add: some View {
        Button(action: onAddPage) {
            Text(addTitle)
        }
        .buttonStyle(NotebookActionKeyStyle(kind: .secondary))
        .disabled(!isAddEnabled)
        .accessibilityHint(addHint ?? "")
    }
}
