import SwiftUI

/// The page the Notebook menu offers to delete, with the page count it was chosen from.
struct NotebookPageDeletionTarget: Equatable, Sendable {
    /// Counted from zero.
    let page: Int
    let pageCount: Int

    /// The page's number as the user counts it.
    var number: Int { page + 1 }
}

/// Confirms a page deletion the Notebook menu asks for. The alert opens only once the menu has
/// gone, as one presentation cannot start while another is still leaving, and the header and
/// tools stay in sight from the request until the alert closes.
@MainActor
final class NotebookPageDeletionPrompt: ObservableObject {
    static let confirmTitle = "Delete Page"
    static let message = "Its writing will be removed. You can undo this right away."
    /// Shown in place of the message when the page can no longer be deleted as the alert opens,
    /// as when writing paused after the menu asked; Delete Page is then disabled.
    static let unavailableMessage = "Writing paused or the notebook changed, so the page can't be deleted now."

    /// The page asked about, from the menu's request until the alert closes.
    @Published private(set) var target: NotebookPageDeletionTarget?
    /// The alert's title, kept as the alert closes so it never changes on the way out.
    @Published private(set) var title = ""
    /// Whether the alert shows.
    @Published private(set) var isPresented = false
    private let delete: @MainActor (NotebookPageDeletionTarget) -> Bool

    init(delete: @escaping @MainActor (NotebookPageDeletionTarget) -> Bool) {
        self.delete = delete
    }

    static func title(for target: NotebookPageDeletionTarget) -> String {
        "Delete page \(target.number) of \(target.pageCount)?"
    }

    static func refusalAnnouncement(for target: NotebookPageDeletionTarget) -> String {
        "Page \(target.number) wasn't deleted"
    }

    /// The menu's "Delete this page…" row, which then closes the menu.
    func request(_ target: NotebookPageDeletionTarget) {
        guard !isPresented else { return }
        self.target = target
        title = Self.title(for: target)
    }

    /// The menu has gone; opens the alert if the menu asked for one.
    func menuDidDisappear() {
        guard target != nil else { return }
        setPresented(true)
    }

    /// Drops a request whose alert has not opened, as when the menu opens again or the canvas the
    /// page was chosen on goes, so a page chosen from paper no longer in view is never offered and
    /// the header and tools are no longer held for it.
    func withdrawRequest() {
        guard target != nil, !isPresented else { return }
        target = nil
    }

    /// Shows or closes the alert. Only a change publishes: SwiftUI may write the same value to
    /// the alert's binding again inside its own update as the alert closes.
    func setPresented(_ presented: Bool) {
        guard presented != isPresented else { return }
        isPresented = presented
        if !presented { target = nil }
    }

    /// The alert's Delete Page button. An open alert keeps the buttons it opened with, and the
    /// notebook may have changed since; then nothing on the paper changes, so VoiceOver says the
    /// page stayed, and the header shows any pause in writing.
    func confirm(_ target: NotebookPageDeletionTarget) {
        guard !delete(target) else { return }
        AccessibilityNotification.Announcement(Self.refusalAnnouncement(for: target)).post()
    }
}

/// Shows the prompt's alert over the notebook and keeps the writing chrome pinned meanwhile. A
/// page that can no longer be deleted as the alert opens, by the rule the menu's row follows, is
/// offered with Delete Page disabled and a message saying why.
struct NotebookPageDeletionAlert: ViewModifier {
    @ObservedObject var prompt: NotebookPageDeletionPrompt
    @ObservedObject var gate: NotebookCanvasGateModel
    @ObservedObject var commands: NotebookCanvasCommandModel
    let chrome: NotebookWritingChrome

    func body(content: Content) -> some View {
        content
            .alert(
                prompt.title, isPresented: Binding(get: { prompt.isPresented }, set: { prompt.setPresented($0) }),
                presenting: prompt.target
            ) { target in
                Button(NotebookPageDeletionPrompt.confirmTitle, role: .destructive) { prompt.confirm(target) }
                    .disabled(!isDeletable(target))
                Button("Cancel", role: .cancel) {}
            } message: { target in
                Text(isDeletable(target)
                    ? NotebookPageDeletionPrompt.message : NotebookPageDeletionPrompt.unavailableMessage)
            }
            .notebookChromePresentation(prompt.target != nil, chrome: chrome)
    }

    private func isDeletable(_ target: NotebookPageDeletionTarget) -> Bool {
        NotebookMenu.canDeletePage(target, gate: gate.state, commands: commands.state)
    }
}
