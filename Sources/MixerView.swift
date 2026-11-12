import SwiftUI

struct MixerView: View {
    @EnvironmentObject var mixer: Mixer
    @Environment(\.openWindow) private var openWindow
    var expandedID: String? = nil   // used for screenshots
    @State private var listHeight: CGFloat = CGFloat(0)

    var body: some View {
        let apps = mixer.visibleApps

        VStack(alignment: .leading, spacing: 10) {
            header

            DeviceSection(output: true)
            if mixer.showInput { DeviceSection(output: false) }

            Divider()

            HStack {
                Text("Applications").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if mixer.anySoloOrMute {
                    Button("Unmute all") { mixer.muteAll(false) }
                        .buttonStyle(.borderless).font(.caption)
                }
            }

            if apps.isEmpty {
                Text(mixer.onlyPlaying ? "Nothing is playing right now." : "No apps are using audio yet. Play something!")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(apps) { app in AppRow(app: app, initiallyExpanded: app.id == expandedID) }
                    }
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ListHeightKey.self, value: geo.size.height)
                    })
                }
                .frame(height: min(max(listHeight, 50), 480))
                .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
            }

            if let err = mixer.lastError {
                VStack(alignment: .leading, spacing: 4) {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(4)
                    Button("Check audio permission…") { PermissionHelper.openPrivacySettings() }
                        .buttonStyle(.link).font(.caption)
                }
            }

            Divider()
            HStack {
                Button("Reset all") { mixer.resetAll() }
                Spacer()
                Button("Quit AppMixer") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { mixer.startMeters() }
        .onDisappear { mixer.stopMeters() }
    }

    private var header: some View {
        HStack {
            Text("AppMixer").font(.headline)
            Spacer()
            Button {
                openWindow(id: "settings")
                NSApp.activate()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .keyboardShortcut(",")
        }
    }
}

private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - System output / input

struct DeviceSection: View {
    @EnvironmentObject var mixer: Mixer
    let output: Bool

    var body: some View {
        let devices = output ? mixer.outputDevices : mixer.inputDevices
        let selected = output ? mixer.outputUID : mixer.inputUID
        let volume = output ? mixer.outputVolume : mixer.inputVolume
        let muted = (output ? mixer.outputMuted : mixer.inputMuted) ?? false

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: output ? "hifispeaker.fill" : "mic.fill")
                    .foregroundStyle(.secondary).frame(width: 18)
                Picker("", selection: Binding(get: { selected },
                                              set: { output ? mixer.selectOutput($0) : mixer.selectInput($0) })) {
                    ForEach(devices) { Text($0.name).tag($0.uid) }
                    if !devices.contains(where: { $0.uid == selected }) { Text("—").tag(selected) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            if let volume {
                HStack(spacing: 6) {
                    Button {
                        output ? mixer.setOutputMuted(!muted) : mixer.setInputMuted(!muted)
                    } label: {
                        Image(systemName: muted || volume == 0
                              ? (output ? "speaker.slash.fill" : "mic.slash.fill")
                              : (output ? "speaker.wave.2.fill" : "mic.fill"))
                            .foregroundStyle(muted ? .red : .primary)
                            .frame(width: 18)
                    }
                    .buttonStyle(.borderless)
                    .help(muted ? "Unmute" : "Mute")

                    Slider(value: Binding(get: { Double(volume) },
                                          set: { output ? mixer.setOutputVolume(Float($0)) : mixer.setInputVolume(Float($0)) }))
                        .controlSize(.small)
                        .opacity(muted ? 0.5 : 1)
                    Text(muted ? "Muted" : "\(Int((volume * 100).rounded()))%")
                        .font(.caption).monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
            } else {
                Text(output ? "This device's volume is controlled by the device itself."
                            : "This device has no adjustable input level.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - App row

struct AppRow: View {
    @EnvironmentObject var mixer: Mixer
    @EnvironmentObject var meters: LevelMeters
    let app: AudioApp
    @State private var expanded: Bool

    init(app: AudioApp, initiallyExpanded: Bool = false) {
        self.app = app
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        let s = mixer.setting(for: app.id)
        let silent = s.muted || s.volume == 0

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 28, height: 28)
                    .opacity(silent ? 0.45 : 1)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(app.name).lineLimit(1)
                        if app.isPlaying {
                            Circle().fill(.green).frame(width: 6, height: 6).help("Playing audio")
                        }
                        badges(s)
                        Spacer(minLength: 0)
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                        } label: {
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .help("More options")
                    }
                    .font(.callout)

                    HStack(spacing: 6) {
                        Button { mixer.toggleMute(app.id) } label: {
                            Image(systemName: silent ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .frame(width: 18)
                                .foregroundStyle(silent ? .red : .primary)
                        }
                        .buttonStyle(.borderless)
                        .help(s.muted ? "Unmute" : "Mute")

                        VStack(spacing: 1) {
                            Slider(value: Binding(get: { Double(min(s.volume, mixer.maxVolume)) },
                                                  set: { mixer.setVolume(Float(snap($0)), for: app.id) }),
                                   in: 0...Double(mixer.maxVolume))
                                .controlSize(.small)
                                .opacity(s.muted ? 0.5 : 1)
                            if mixer.showMeters {
                                LevelBar(level: meters.levels[app.id] ?? 0)
                            }
                        }

                        Text(s.muted ? "Muted" : "\(Int((s.volume * 100).rounded()))%")
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(s.volume > 1 && !s.muted ? .orange : .primary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            }

            if expanded { details(s) }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(expanded ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contextMenu { menu(s) }
    }

    /// Snap to 100% when close, so it's easy to return to "untouched".
    private func snap(_ v: Double) -> Double { abs(v - 1) < 0.025 ? 1 : v }

    @ViewBuilder private func badges(_ s: AppSetting) -> some View {
        if s.mono { Text("MONO").badgeStyle() }
        if s.balance != 0 { Text(s.balance < 0 ? "L\(Int(-s.balance * 100))" : "R\(Int(s.balance * 100))").badgeStyle() }
        if let uid = s.deviceUID {
            let name = mixer.outputDevices.first { $0.uid == uid }?.name ?? "Disconnected"
            Text(name).badgeStyle().help("Plays through \(name)")
        }
    }

    @ViewBuilder private func details(_ s: AppSetting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Balance").font(.caption).frame(width: 52, alignment: .leading)
                Text("L").font(.caption2).foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(s.balance) }, set: { mixer.setBalance(Float($0), for: app.id) }),
                       in: -1...1)
                    .controlSize(.mini)
                Text("R").font(.caption2).foregroundStyle(.secondary)
                Button("Center") { mixer.setBalance(0, for: app.id) }
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(s.balance == 0)
            }

            HStack(spacing: 6) {
                Text("Output").font(.caption).frame(width: 52, alignment: .leading)
                Picker("", selection: Binding(get: { s.deviceUID ?? "" },
                                              set: { mixer.setDevice($0.isEmpty ? nil : $0, for: app.id) })) {
                    Text("System default").tag("")
                    Divider()
                    ForEach(mixer.outputDevices) { Text($0.name).tag($0.uid) }
                    if let uid = s.deviceUID, !mixer.outputDevices.contains(where: { $0.uid == uid }) {
                        Text("Disconnected device").tag(uid)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }

            HStack(spacing: 12) {
                Toggle("Mono", isOn: Binding(get: { s.mono }, set: { mixer.setMono($0, for: app.id) }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Solo") { mixer.solo(app.id) }.help("Mute every other app")
                Button("Reset") { mixer.reset(app.id) }.disabled(s.isDefault)
                Button("Hide") { mixer.setHidden(true, for: app.id) }
                    .help("Hide from this list (its volume is kept). Unhide in Settings.")
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(.leading, 38)
        .padding(.bottom, 2)
    }

    @ViewBuilder private func menu(_ s: AppSetting) -> some View {
        Button(s.muted ? "Unmute" : "Mute") { mixer.toggleMute(app.id) }
        Button("Solo (mute others)") { mixer.solo(app.id) }
        Divider()
        Menu("Volume") {
            ForEach([0, 25, 50, 75, 100, 150, 200].filter { Float($0) / 100 <= mixer.maxVolume }, id: \.self) { p in
                Button("\(p)%") { mixer.setVolume(Float(p) / 100, for: app.id) }
            }
        }
        Menu("Output device") {
            Button("System default") { mixer.setDevice(nil, for: app.id) }
            Divider()
            ForEach(mixer.outputDevices) { d in Button(d.name) { mixer.setDevice(d.uid, for: app.id) } }
        }
        Toggle("Mono", isOn: Binding(get: { s.mono }, set: { mixer.setMono($0, for: app.id) }))
        Divider()
        Button("Reset") { mixer.reset(app.id) }
        Button("Hide") { mixer.setHidden(true, for: app.id) }
    }
}

struct LevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(level > 0.95 ? Color.red : level > 0.7 ? Color.yellow : Color.green)
                    .frame(width: geo.size.width * CGFloat(sqrt(max(0, level))))  // sqrt ≈ more readable scale
            }
        }
        .frame(height: 3)
        .animation(.linear(duration: 0.05), value: level)
    }
}

extension Text {
    func badgeStyle() -> some View {
        self.font(.system(size: 9, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(Color.accentColor)
    }
}
