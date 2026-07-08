import SwiftUI

@main
struct VoiceMateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("VoiceMate", systemImage: "waveform") {
            StatusBarMenuView()
        }
        .menuBarExtraStyle(.window)
    }
}
