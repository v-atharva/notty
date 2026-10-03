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
                if session.isLoadingRecoveryCopies {
                    ProgressView("Opening recovery copies")
                }
                if let failure = session.recoveryListFailure {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(failure.title).font(.headline)
                        Text(failure.message)
                        Button("Try again") { Task { await session.refreshRecoveryCopies() } }
                    }
                }
                if !session.isLoadingRecoveryCopies && session.recoveryListFailure == nil
                    && session.recoveryCopies.isEmpty && session.unavailableRecoveryCopyIDs.isEmpty {
                    Text("No recovery copies have been preserved for this notebook.")
                }
                if !session.unavailableRecoveryCopyIDs.isEmpty {
                    Section("Unavailable copies") {
                        Text("\(session.unavailableRecoveryCopyIDs.count) preserved copies could not be verified. Their files remain stored. Available copies can still be opened below.")
                        ForEach(session.unavailableRecoveryCopyIDs, id: \.self) { identity in
                            Label("Unavailable copy \(identity.uuidString.prefix(8))", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(session.recoveryCopies, id: \.id) { receipt in
                    NavigationLink {
                        NotebookRecoveryInspector(session: session, receipt: receipt)
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
}

@MainActor
private struct NotebookRecoveryInspector: View {
    @ObservedObject var session: NotebookSession
    let receipt: NotebookRecoveryReceipt
    @State private var batch: NotebookRecoveryBatch?
    @State private var drawing: PKDrawing?
    @State private var index = 0
    @State private var isOpening = true
    @State private var failure: NotebookSaveFailure?
    private let codec = NotebookRecoveryCodec()

    var body: some View {
        Group {
            if let failure {
                ContentUnavailableView {
                    Label(failure.title, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure.message)
                }
            } else if let batch, batch.edits.indices.contains(index), let drawing {
                let edit = batch.edits[index]
                if (1...NotebookViewController.maximumPageCount).contains(edit.pageCount) {
                    ReadOnlyNotebookCanvas(drawing: drawing, pageCount: edit.pageCount)
                        .id(edit.id)
                        .safeAreaInset(edge: .bottom) { editNavigation(batch: batch) }
                } else {
                    ContentUnavailableView {
                        Label("Paper extent unavailable", systemImage: "doc")
                    } description: {
                        Text("This preserved edit has \(edit.pageCount) sections. This viewer supports up to \(NotebookViewController.maximumPageCount). The complete recovery copy is retained.")
                    }
                    .safeAreaInset(edge: .bottom) { editNavigation(batch: batch) }
                }
            } else {
                ProgressView("Opening preserved edit")
            }
        }
        .navigationTitle("Preserved edits")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let opened = try await session.openRecoveryCopy(id: receipt.id)
                guard !opened.edits.isEmpty, opened.edits.count == receipt.editCount else {
                    throw NotebookSaveFailure.corruptData
                }
                batch = opened
                await select(0, batch: opened)
            } catch {
                failure = NotebookSaveFailure.classify(error)
                isOpening = false
            }
        }
    }

    private func editNavigation(batch: NotebookRecoveryBatch) -> some View {
        HStack(spacing: 16) {
            Button("Previous") { Task { await select(index - 1, batch: batch) } }
                .disabled(isOpening || index == 0)
            Spacer()
            VStack(spacing: 3) {
                Text("Edit \(index + 1) of \(batch.edits.count)")
                Text(batch.edits[index].stamp.capturedAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                Text("Read only").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Next") { Task { await select(index + 1, batch: batch) } }
                .disabled(isOpening || index == batch.edits.count - 1)
        }
        .font(.footnote)
        .padding()
        .background(.regularMaterial)
    }

    private func select(_ requested: Int, batch: NotebookRecoveryBatch) async {
        guard batch.edits.indices.contains(requested) else { return }
        isOpening = true
        defer { isOpening = false }
        do {
            let restored = try await codec.decode(batch.edits[requested])
            index = requested
            drawing = restored
        } catch {
            failure = NotebookSaveFailure.classify(error)
        }
    }
}

@MainActor
private struct ReadOnlyNotebookCanvas: UIViewControllerRepresentable {
    let drawing: PKDrawing
    let pageCount: Int

    func makeUIViewController(context: Context) -> NotebookViewController {
        let controller = NotebookViewController(pageCount: pageCount, initialDrawing: drawing)
        controller.setEditingEnabled(false)
        return controller
    }

    func updateUIViewController(_ controller: NotebookViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: NotebookViewController, coordinator: Void) {
        controller.tearDown()
    }
}
