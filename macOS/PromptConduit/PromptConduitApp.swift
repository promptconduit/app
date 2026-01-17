import SwiftUI

@main
struct PromptConduitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            AppSettingsView()
        }
    }
}
