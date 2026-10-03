import SwiftUI

@main
struct NottyApp: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                Color.clear
            } else {
                NotebookScreen()
            }
        }
    }
}
