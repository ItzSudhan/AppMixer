import AppKit
import SwiftUI

/// `AppMixer --screenshots <dir>` renders the UI with demo data to PNGs (used for the README).
@MainActor
enum ScreenshotRenderer {
    static func run(outputDir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let dir = URL(fileURLWithPath: outputDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mixer = Mixer(demo: true)

        for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            render(panel(MixerView().environmentObject(mixer).environmentObject(mixer.meters)),
                   appearance: appearance, to: dir.appendingPathComponent("mixer-\(suffix).png"))
            render(panel(MixerView(expandedID: "com.apple.FaceTime")
                            .environmentObject(mixer).environmentObject(mixer.meters)),
                   appearance: appearance, to: dir.appendingPathComponent("app-options-\(suffix).png"))
            render(panel(SettingsView().environmentObject(mixer)),
                   appearance: appearance, to: dir.appendingPathComponent("settings-\(suffix).png"))
        }
        print("Wrote screenshots to \(dir.path)")
    }

    /// Popover-like card with a soft shadow on a transparent background.
    private static func panel<V: View>(_ content: V) -> some View {
        content
            .environment(\.controlActiveState, .key)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
            .padding(32)
    }

    private static func render<V: View>(_ view: V, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view)
        let window = KeyableWindow(contentRect: NSRect(x: -10000, y: -10000, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        let initial = host.fittingSize
        window.setContentSize(initial)
        host.frame = NSRect(origin: .zero, size: initial)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)

        host.layoutSubtreeIfNeeded()
        // Let SwiftUI settle (measured list height etc.), then resize to the final layout.
        var size = host.fittingSize
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            size = host.fittingSize
            window.setContentSize(size)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
        }

        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                   pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}

/// Borderless windows can't normally become key; key state makes controls render in their active colors.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
