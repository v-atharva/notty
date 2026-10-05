import SwiftUI

@main
struct NottyApp: App {
    init() {
        // Rendering starts at launch, off the main thread, so a cold open usually finds the textures ready.
        NotebookMaterials.shared.prepare()
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                Color.clear
            } else {
                NotebookLibraryHost()
            }
        }
    }
}
