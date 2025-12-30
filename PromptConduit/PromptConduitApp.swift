import SwiftUI

@main
struct PromptConduitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

struct SettingsView: View {
    var body: some View {
        Text("PromptConduit Settings")
            .frame(width: 400, height: 300)
    }
}
