import SwiftUI

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--screenshots"), i + 1 < args.count {
            MainActor.assumeIsolated { ScreenshotRenderer.run(outputDir: args[i + 1]) }
        } else {
            MixerApp.main()
        }
    }
}

struct MixerApp: App {
    @StateObject private var mixer = Mixer()

    var body: some Scene {
        MenuBarExtra {
            MixerView()
                .environmentObject(mixer)
                .environmentObject(mixer.meters)
        } label: {
            Image(systemName: "slider.vertical.3")
        }
        .menuBarExtraStyle(.window)

        Window("AppMixer Settings", id: "settings") {
            SettingsView().environmentObject(mixer)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}
