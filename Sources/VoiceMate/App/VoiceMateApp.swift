import SwiftUI

@main
struct VoiceMateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("VoiceMate", systemImage: "waveform") {
            StatusBarMenu()
        }
        .menuBarExtraStyle(.menu)
    }
}
