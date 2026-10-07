import NottyCore
import PencilKit
import SwiftUI

@MainActor
struct NotebookRecoveryView: View {
    @ObservedObject var session: NotebookSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NotebookTheme.sectionSpacing) {
                    if session.isLoadingRecoveryCopies {
                        NotebookStatusCard(loading: "Opening recovery copies")
                            .frame(maxWidth: .infinity)
                    }
                    if let failure = session.recoveryListFailure {
                        NotebookStatusCard(title: failure.title, message: failure.message) {
                            Button("Try again") { Task { await session.refreshRecoveryCopies() } }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    if !session.isLoadingRecoveryCopies && session.recoveryListFailure == nil
                        && session.recoveryCopies.isEmpty && session.recoveryIssues.isEmpty
                        && session.unavailableRecoveryCopyIDs.isEmpty && session.unattributedRecoveryIssues.isEmpty {
                        NotebookRecoveryCard {
                            NotebookRecoveryCardText("No recovery copies have been preserved for this notebook.")
                        }
                    }
                    if !session.recoveryIssues.isEmpty {
                        NotebookSectionLabel("Copies needing attention")
                        ForEach(session.recoveryIssues, id: \.copyID) { issue in
                            NotebookRecoveryCard {
                                recoveryIssue(issue)
                                if issue.kind == .damagedData {
                                    NavigationLink("Inspect preserved edits") {
                                        NotebookRecoveryInspector(
                                            session: session, copyID: issue.copyID, close: { dismiss() }
                                        )
                                    }
                                    .buttonStyle(NotebookActionKeyStyle(kind: .secondary))
                                    .accessibilityLabel("Inspect preserved edits of copy \(issue.copyID.uuidString.prefix(8))")
                                }
                            }
                        }
                    } else if !session.unavailableRecoveryCopyIDs.isEmpty {
                        NotebookSectionLabel("Unavailable copies")
                        NotebookRecoveryCard {
                            NotebookRecoveryCardText("These copies could not be verified. Their files remain stored.")
                            ForEach(session.unavailableRecoveryCopyIDs, id: \.self) { identity in
                                Label("Unavailable copy \(identity.uuidString.prefix(8))", systemImage: "exclamationmark.triangle")
                                    .font(.footnote)
                                    .foregroundStyle(NotebookTheme.alertGlyph.color)
                            }
                        }
                    }
                    if !session.unattributedRecoveryIssues.isEmpty {
                        NotebookSectionLabel("Unattributed records")
                        NotebookRecoveryCard {
                            NotebookRecoveryCardText("These records could not be assigned to a notebook. They remain stored and do not mark this notebook's copies as damaged.")
                        }
                        ForEach(session.unattributedRecoveryIssues, id: \.copyID) { issue in
                            NotebookRecoveryCard { recoveryIssue(issue) }
                        }
                    }
                    ForEach(session.recoveryCopies, id: \.id) { receipt in
                        let savedAt = receipt.savedAt.formatted(date: .abbreviated, time: .shortened)
                        // Copies preserved in the same minute differ by the second.
                        let preciseSavedAt = receipt.savedAt.formatted(date: .abbreviated, time: .standard)
                        NotebookRecoveryCard {
                            Text(savedAt)
                                .notebookTypeface(NotebookTheme.noteTitle)
                                .foregroundStyle(NotebookTheme.glyph.color)
                            NotebookRecoveryCardText("\(receipt.editCount) ordered edits")
                            NavigationLink("Inspect preserved edits") {
                                NotebookRecoveryInspector(
                                    session: session, copyID: receipt.id, expectedReceipt: receipt, close: { dismiss() }
                                )
                            }
                            .buttonStyle(NotebookActionKeyStyle(kind: .secondary))
                            // Every card has this key, so its name says which copy it opens while
                            // keeping the visible words Voice Control users speak.
                            .accessibilityLabel("Inspect preserved edits from \(preciseSavedAt)")
                        }
                    }
                }
                .padding(NotebookTheme.popoverPadding)
            }
            .background { NotebookTheme.backdropStone.color.ignoresSafeArea() }
            .navigationTitle("Recovery copies")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(NotebookTheme.controlTint.color)
        .presentationBackground(NotebookTheme.backdropStone.color)
        .task { await session.refreshRecoveryCopies() }
    }

    private func recoveryIssue(_ issue: NotebookRecoveryScanIssue) -> some View {
        let explanation: String
        switch issue.kind {
        case .damagedData: explanation = "Could not verify stored data."
        case .unsupportedVersion(let version): explanation = "Format version \(version) is not supported."
        case .unsafePath: explanation = "The storage path cannot be used safely."
        case .ioFailure: explanation = "Storage is temporarily unavailable. Try again."
        }
        return VStack(alignment: .leading, spacing: NotebookTheme.recoveryCardTitleSpacing) {
            Text("Copy \(issue.copyID.uuidString.prefix(8))")
                .notebookTypeface(NotebookTheme.noteTitle)
                .foregroundStyle(NotebookTheme.glyph.color)
            NotebookRecoveryCardText(explanation)
        }
    }
}

/// A preserved copy or a notice about the copies, as a card on the stone of the sheet.
private struct NotebookRecoveryCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: NotebookTheme.sectionSpacing) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(NotebookTheme.popoverPadding)
        .background { NotebookPanelShell(cornerRadius: NotebookTheme.compactPanelCornerRadius) }
    }
}

private struct NotebookRecoveryCardText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(NotebookTheme.glyphSecondary.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
private struct NotebookRecoveryInspector: View {
    @ObservedObject var session: NotebookSession
    let copyID: UUID
    var expectedReceipt: NotebookRecoveryReceipt? = nil
    let close: () -> Void
    @State private var edits: [NotebookSession.RecoveryEditMetadata] = []
    @State private var drawing: PKDrawing?
    @State private var index = 0
    @State private var isOpening = true
    @State private var failure: NotebookSaveFailure?
    @State private var requestID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if isOpening {
                    ProgressView("Opening preserved edit")
                } else if let failure {
                    ContentUnavailableView {
                        Label(failure.title, systemImage: "exclamationmark.triangle")
                    } description: { Text(failure.message) }
                } else if edits.indices.contains(index), let drawing {
                    let edit = edits[index]
                    if (1...NotebookViewController.maximumPageCount).contains(edit.pageCount) {
                        ReadOnlyNotebookCanvas(drawing: drawing, pageCount: edit.pageCount)
                            .id(edit.id)
                    } else {
                        ContentUnavailableView {
                            Label("Paper extent unavailable", systemImage: "doc")
                        } description: {
                            Text("This edit has \(edit.pageCount) sections. It remains preserved, but this viewer and normal restore support up to \(NotebookViewController.maximumPageCount).")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if edits.indices.contains(index) { editNavigation }
        }
        .navigationTitle("Preserved edits")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let metadata = try await session.inspectRecoveryCopy(id: copyID)
                guard metadata.receipt.id == copyID,
                      expectedReceipt == nil || expectedReceipt == metadata.receipt,
                      metadata.edits.count == metadata.receipt.editCount else {
                    throw NotebookSaveFailure.corruptData
                }
                edits = metadata.edits
                await select(0)
            } catch {
                if error is CancellationError { return }
                failure = NotebookSaveFailure.classify(error)
                isOpening = false
            }
        }
        .onDisappear { requestID = UUID() }
    }

    private var editNavigation: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                Button("Previous") { Task { await select(index - 1) } }
                    .buttonStyle(NotebookActionKeyStyle(kind: .secondary))
                    .fixedSize()
                    .disabled(isOpening || index == 0)
                Spacer()
                VStack(spacing: 3) {
                    Text("Edit \(index + 1) of \(edits.count)")
                    Text(edits[index].stamp.capturedAt.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                    Text("Read only").font(.caption).foregroundStyle(NotebookTheme.glyphSecondary.color)
                }
                Spacer()
                Button("Next") { Task { await select(index + 1) } }
                    .buttonStyle(NotebookActionKeyStyle(kind: .secondary))
                    .fixedSize()
                    .disabled(isOpening || index == edits.count - 1)
            }
            NotebookRecoveryRestoreButton(
                session: session, model: session.commandModel, status: session.statusModel,
                copyID: copyID, editID: edits[index].id, isOpening: isOpening || failure != nil, close: close
            )
        }
        .font(.footnote)
        .foregroundStyle(NotebookTheme.glyph.color)
        .padding(NotebookTheme.popoverPadding)
        .background {
            NotebookTheme.panelSurface.color
                .overlay(alignment: .top) { NotebookTheme.divider.color.frame(height: NotebookTheme.dividerThickness) }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func select(_ requested: Int) async {
        guard edits.indices.contains(requested) else { return }
        let request = UUID()
        requestID = request
        index = requested
        drawing = nil
        failure = nil
        isOpening = true
        do {
            let restored = try await session.openRecoveryDrawing(copyID: copyID, editID: edits[requested].id)
            guard requestID == request, !Task.isCancelled else { return }
            drawing = restored
        } catch {
            guard requestID == request else { return }
            if !(error is CancellationError) { failure = NotebookSaveFailure.classify(error) }
        }
        if requestID == request { isOpening = false }
    }
}

@MainActor
private struct NotebookRecoveryRestoreButton: View {
    let session: NotebookSession
    @ObservedObject var model: NotebookCanvasCommandModel
    @ObservedObject var status: NotebookSavePresentationModel
    let copyID: UUID
    let editID: UUID
    let isOpening: Bool
    let close: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Button("Restore as a new edit") {
                Task {
                    if await session.restoreRecoveryEdit(copyID: copyID, editID: editID) { close() }
                }
            }
            .buttonStyle(NotebookActionKeyStyle(kind: .primary))
            .disabled(isOpening || !session.canRestoreRecovery)
            if let message = status.state.recoveryMessage {
                Text(message).foregroundStyle(NotebookTheme.glyphSecondary.color)
            }
            if let failure = status.state.recoveryFailure {
                Text(failure.message).foregroundStyle(NotebookTheme.glyphSecondary.color)
            }
        }
    }
}

@MainActor
private struct ReadOnlyNotebookCanvas: UIViewControllerRepresentable {
    let drawing: PKDrawing
    let pageCount: Int

    func makeUIViewController(context: Context) -> NotebookViewController {
        NotebookViewController(pageCount: pageCount, initialDrawing: drawing, allowsEditing: false)
    }

    func updateUIViewController(_ controller: NotebookViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: NotebookViewController, coordinator: Void) {
        controller.tearDown()
    }
}
