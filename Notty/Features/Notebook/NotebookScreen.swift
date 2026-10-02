import SwiftUI

struct NotebookScreen: View {
    @State private var pageCount = 3

    var body: some View {
        NavigationStack {
            NotebookCanvas(pageCount: $pageCount)
                .background(Color(red: 0.98, green: 0.96, blue: 0.91))
                .navigationTitle("New notebook")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Text("notty")
                            .font(.system(.title3, design: .serif, weight: .semibold))
                            .foregroundStyle(Color(red: 0.28, green: 0.23, blue: 0.18))
                            .accessibilityLabel("Notty")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            pageCount += 1
                        } label: {
                            Label("Extend paper", systemImage: "plus")
                        }
                        .disabled(pageCount >= NotebookViewController.maximumPageCount)
                    }
                }
        }
        .tint(Color(red: 0.36, green: 0.29, blue: 0.22))
        .preferredColorScheme(.light)
    }
}
