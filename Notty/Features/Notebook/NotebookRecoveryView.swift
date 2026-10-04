import NottyCore
import PencilKit
import SwiftUI

@MainActor
struct NotebookRecoveryView: View {
    @ObservedObject var session: NotebookSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if session.isLoadingRecoveryCopies { ProgressView("Opening recovery copies") }
                if let failure = session.recoveryListFailure {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(failure.title).font(.headline)
                        Text(failure.message)
                        Button("Try again") { Task { await session.refreshRecoveryCopies() } }
                    }
                }
                if !session.isLoadingRecoveryCopies && session.recoveryListFailure == nil
                    && session.recoveryCopies.isEmpty && session.recoveryIssues.isEmpty
                    && session.unavailableRecoveryCopyIDs.isEmpty && session.unattributedRecoveryIssues.isEmpty {
                    Text("No recovery copies have been preserved for this notebook.")
                }
                if !session.recoveryIssues.isEmpty {
                    Section("Copies needing attention") {
                        ForEach(session.recoveryIssues, id: \.copyID) { issue in
                            recoveryIssue(issue)
                        }
                    }
                } else if !session.unavailableRecoveryCopyIDs.isEmpty {
                    Section("Unavailable copies") {
                        Text("These copies could not be verified. Their files remain stored.")
                        ForEach(session.unavailableRecoveryCopyIDs, id: \.self) { identity in
                            Label("Unavailable copy \(identity.uuidString.prefix(8))", systemImage: "exclamationmark.triangle")
                        }
                    }
                }
                if !session.unattributedRecoveryIssues.isEmpty {
                    Section("Unattributed records") {
                        Text("These records could not be assigned to a notebook. They remain stored and do not mark this notebook's copies as damaged.")
                        ForEach(session.unattributedRecoveryIssues, id: \.copyID) { issue in
                            recoveryIssue(issue)
                        }
                    }
                }
                ForEach(session.recoveryCopies, id: \.id) { receipt in
                    NavigationLink {
                        NotebookRecoveryInspector(session: session, receipt: receipt, close: { dismiss() })
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(receipt.savedAt.formatted(date: .abbreviated, time: .shortened))
                            Text("\(receipt.editCount) ordered edits")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Recovery copies")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
        return VStack(alignment: .leading, spacing: 4) {
            Text("Copy \(issue.copyID.uuidString.prefix(8))")
            Text(explanation).font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor
private struct NotebookRecoveryInspector: View {
    @ObservedObject var session: NotebookSession
    let receipt: NotebookRecoveryReceipt
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
                let summaries = try await session.inspectRecoveryCopy(id: receipt.id)
                guard summaries.count == receipt.editCount else { throw NotebookSaveFailure.corruptData }
                edits = summaries
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
                    .disabled(isOpening || index == 0)
                Spacer()
                VStack(spacing: 3) {
                    Text("Edit \(index + 1) of \(edits.count)")
                    Text(edits[index].stamp.capturedAt.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                    Text("Read only").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Next") { Task { await select(index + 1) } }
                    .disabled(isOpening || index == edits.count - 1)
            }
            NotebookRecoveryRestoreButton(
                session: session, model: session.commandModel, status: session.statusModel,
                copyID: receipt.id, editID: edits[index].id, isOpening: isOpening || failure != nil, close: close
            )
        }
        .font(.footnote).padding().background(.regularMaterial)
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
            let restored = try await session.openRecoveryDrawing(copyID: receipt.id, editID: edits[requested].id)
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
            .disabled(isOpening || !session.canRestoreRecovery)
            if let message = status.state.recoveryMessage { Text(message).foregroundStyle(.secondary) }
            if let failure = status.state.recoveryFailure { Text(failure.message).foregroundStyle(.secondary) }
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
