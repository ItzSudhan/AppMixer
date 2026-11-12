import AppKit
import CoreAudio
import Combine

@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

struct AudioApp: Identifiable, Equatable {
    let id: String            // bundle ID (stable key for saved settings)
    let name: String
    let icon: NSImage
    let isSystem: Bool        // background / system process rather than a regular app
    var processObjects: [AudioObjectID]
    var isPlaying: Bool

    static func == (a: AudioApp, b: AudioApp) -> Bool {
        a.id == b.id && a.name == b.name && a.processObjects == b.processObjects && a.isPlaying == b.isPlaying
    }
}

struct AppSetting: Codable, Equatable {
    var volume: Float = 1.0       // slider position, 0...maxVolume
    var muted = false
    var balance: Float = 0        // -1 (left) ... +1 (right)
    var mono = false
    var deviceUID: String? = nil  // nil = follow system output
    var hidden = false
    var name: String? = nil       // last known display name (for the hidden-apps list)

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        balance = try c.decodeIfPresent(Float.self, forKey: .balance) ?? 0
        mono = try c.decodeIfPresent(Bool.self, forKey: .mono) ?? false
        deviceUID = try c.decodeIfPresent(String.self, forKey: .deviceUID)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        name = try c.decodeIfPresent(String.self, forKey: .name)
    }

    var isDefault: Bool {
        volume == 1 && !muted && balance == 0 && !mono && deviceUID == nil
    }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case playingFirst, alphabetical
    var id: String { rawValue }
    var label: String { self == .playingFirst ? "Playing first" : "Alphabetical" }
}

/// Level meter values live in their own object so 20 Hz updates don't re-render the whole UI.
@MainActor
final class LevelMeters: ObservableObject {
    @Published var levels: [String: Float] = [:]
}

@MainActor
final class Mixer: ObservableObject {
    // Discovered state
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var settings: [String: AppSetting] = [:]
    @Published private(set) var lastError: String?

    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var outputUID = ""
    @Published private(set) var inputUID = ""
    @Published private(set) var outputVolume: Float?
    @Published private(set) var outputMuted: Bool?
    @Published private(set) var inputVolume: Float?
    @Published private(set) var inputMuted: Bool?

    let meters = LevelMeters()

    // Preferences
    @Published var showInput: Bool { didSet { prefChanged("showInput", showInput) } }
    @Published var showMeters: Bool { didSet { prefChanged("showMeters", showMeters) } }
    @Published var showSystemProcesses: Bool { didSet { prefChanged("showSystemProcesses", showSystemProcesses) } }
    @Published var onlyPlaying: Bool { didSet { prefChanged("onlyPlaying", onlyPlaying) } }
    @Published var perceptualCurve: Bool { didSet { prefChanged("perceptualCurve", perceptualCurve) } }
    @Published var maxVolume: Float { didSet { prefChanged("maxVolume", maxVolume); clampVolumes() } }
    @Published var sortOrder: SortOrder { didSet { prefChanged("sortOrder", sortOrder.rawValue) } }

    private var taps: [String: AppTap] = [:]
    private var outputDevice = AudioObjectID(kAudioObjectUnknown)
    private var inputDevice = AudioObjectID(kAudioObjectUnknown)
    private var refreshTimer: Timer?
    private var meterTimer: Timer?
    private let defaults = UserDefaults.standard
    private let settingsKey = "AppMixerSettings"

    /// Demo mode shows sample data (for screenshots) and never touches audio or saved settings.
    let isDemo: Bool

    init(demo: Bool = false) {
        isDemo = demo
        if demo {
            showInput = true; showMeters = true; showSystemProcesses = true; onlyPlaying = false
            perceptualCurve = true; maxVolume = 2.0; sortOrder = .playingFirst
            loadDemoData()
            return
        }
        defaults.register(defaults: [
            "showInput": true, "showMeters": false, "showSystemProcesses": true,
            "onlyPlaying": false, "perceptualCurve": true, "maxVolume": Float(1.0),
            "sortOrder": SortOrder.playingFirst.rawValue,
        ])
        showInput = defaults.bool(forKey: "showInput")
        showMeters = defaults.bool(forKey: "showMeters")
        showSystemProcesses = defaults.bool(forKey: "showSystemProcesses")
        onlyPlaying = defaults.bool(forKey: "onlyPlaying")
        perceptualCurve = defaults.bool(forKey: "perceptualCurve")
        maxVolume = defaults.float(forKey: "maxVolume")
        sortOrder = SortOrder(rawValue: defaults.string(forKey: "sortOrder") ?? "") ?? .playingFirst

        if let data = defaults.data(forKey: settingsKey),
           let saved = try? JSONDecoder().decode([String: AppSetting].self, from: data) {
            settings = saved
        }
        refreshDevices()
        refresh()
        installListeners()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: Visible list

    var visibleApps: [AudioApp] {
        apps.filter { app in
            let s = setting(for: app.id)
            if s.hidden { return false }
            if app.isSystem && !showSystemProcesses { return false }
            if onlyPlaying && !app.isPlaying && s.isDefault { return false }
            return true
        }
    }

    var hiddenApps: [(id: String, name: String)] {
        settings.filter { $0.value.hidden }
            .map { (id: $0.key, name: $0.value.name ?? $0.key) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Per-app controls

    func setting(for id: String) -> AppSetting { settings[id] ?? AppSetting() }

    private func modify(_ id: String, _ change: (inout AppSetting) -> Void) {
        var s = setting(for: id)
        change(&s)
        if s.name == nil { s.name = apps.first { $0.id == id }?.name }
        settings[id] = s
        save()
        reconcile()
    }

    func setVolume(_ value: Float, for id: String) {
        modify(id) { s in
            s.volume = value
            if value > 0 { s.muted = false }
        }
    }

    func toggleMute(_ id: String) { modify(id) { $0.muted.toggle() } }
    func setBalance(_ value: Float, for id: String) { modify(id) { $0.balance = abs(value) < 0.04 ? 0 : value } }
    func setMono(_ value: Bool, for id: String) { modify(id) { $0.mono = value } }
    func setDevice(_ uid: String?, for id: String) { modify(id) { $0.deviceUID = uid } }
    func setHidden(_ value: Bool, for id: String) { modify(id) { $0.hidden = value } }

    func reset(_ id: String) {
        modify(id) { s in
            let hidden = s.hidden, name = s.name
            s = AppSetting()
            s.hidden = hidden
            s.name = name
        }
    }

    /// Mute every other visible app; unmute this one.
    func solo(_ id: String) {
        for app in apps {
            var s = setting(for: app.id)
            s.muted = app.id != id
            if s.name == nil { s.name = app.name }
            settings[app.id] = s
        }
        save()
        reconcile()
    }

    func muteAll(_ muted: Bool) {
        for app in apps {
            var s = setting(for: app.id)
            s.muted = muted
            if s.name == nil { s.name = app.name }
            settings[app.id] = s
        }
        save()
        reconcile()
    }

    var anySoloOrMute: Bool { apps.contains { setting(for: $0.id).muted } }

    func resetAll() {
        let hidden = settings.filter { $0.value.hidden }.mapValues { s -> AppSetting in
            var n = AppSetting(); n.hidden = true; n.name = s.name; return n
        }
        settings = hidden
        save()
        reconcile()
    }

    private func clampVolumes() {
        var changed = false
        for (id, var s) in settings where s.volume > maxVolume {
            s.volume = maxVolume
            settings[id] = s
            changed = true
        }
        if changed { save(); reconcile() }
    }

    // MARK: System device controls

    func selectOutput(_ uid: String) {
        guard !isDemo else { return }
        if let d = outputDevices.first(where: { $0.uid == uid }) { CA.setDefaultDevice(d.id, output: true) }
    }

    func selectInput(_ uid: String) {
        guard !isDemo else { return }
        if let d = inputDevices.first(where: { $0.uid == uid }) { CA.setDefaultDevice(d.id, output: false) }
    }

    func setOutputVolume(_ v: Float) {
        CA.setVolume(outputDevice, output: true, v)
        outputVolume = v
        if v > 0, outputMuted == true { setOutputMuted(false) }
    }

    func setOutputMuted(_ m: Bool) { CA.setMuted(outputDevice, output: true, m); outputMuted = m }

    func setInputVolume(_ v: Float) { CA.setVolume(inputDevice, output: false, v); inputVolume = v }
    func setInputMuted(_ m: Bool) { CA.setMuted(inputDevice, output: false, m); inputMuted = m }

    // MARK: Level meters

    func startMeters() {
        guard meterTimer == nil else { return }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMeters() }
        }
    }

    func stopMeters() {
        guard !isDemo else { return }
        meterTimer?.invalidate()
        meterTimer = nil
        meters.levels = [:]
    }

    private func updateMeters() {
        guard !isDemo else { return }
        var next: [String: Float] = [:]
        for (id, tap) in taps {
            let peak = min(1, tap.takePeak())
            let previous = meters.levels[id] ?? 0
            next[id] = max(peak, previous * 0.82)   // fast attack, smooth release
        }
        if next != meters.levels { meters.levels = next }
    }

    // MARK: Discovery

    private func refresh() {
        guard !isDemo else { return }
        let objects = CA.getArray(CA.system, kAudioHardwarePropertyProcessObjectList, initial: AudioObjectID(0))
        let me = getpid()
        var groups: [String: AudioApp] = [:]
        var order: [String] = []

        for obj in objects {
            guard let pid = CA.get(obj, kAudioProcessPropertyPID, initial: pid_t(0)), pid > 0, pid != me else { continue }
            let bundleID = CA.getString(obj, kAudioProcessPropertyBundleID) ?? ""
            let playing = (CA.get(obj, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0

            let key: String, name: String, icon: NSImage, isSystem: Bool
            if let owner = owningApp(pid: pid, bundleID: bundleID) {
                key = owner.bundleIdentifier ?? "pid:\(owner.processIdentifier)"
                if key == Bundle.main.bundleIdentifier { continue }
                name = owner.localizedName ?? key
                icon = owner.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
                isSystem = false
            } else {
                key = bundleID.isEmpty ? "pid:\(pid)" : bundleID
                // Background processes only show up while playing, unless the user has customised them.
                guard playing || !(settings[key]?.isDefault ?? true) || taps[key] != nil else { continue }
                name = processName(pid) ?? (bundleID.split(separator: ".").last.map(String.init) ?? "PID \(pid)")
                icon = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)!
                isSystem = true
            }

            if groups[key] == nil {
                groups[key] = AudioApp(id: key, name: name, icon: icon, isSystem: isSystem, processObjects: [], isPlaying: false)
                order.append(key)
            }
            groups[key]!.processObjects.append(obj)
            groups[key]!.isPlaying = groups[key]!.isPlaying || playing
        }

        var list = order.compactMap { groups[$0] }
        for i in list.indices { list[i].processObjects.sort() }
        list.sort {
            if sortOrder == .playingFirst, $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            if $0.isSystem != $1.isSystem { return !$0.isSystem }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if list != apps { apps = list }
        refreshDeviceLevels()
        reconcile()
    }

    private func owningApp(pid: pid_t, bundleID: String) -> NSRunningApplication? {
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
            return app
        }
        // Helper processes (WebKit GPU process for Safari, Chrome/Electron helpers) -> responsible app.
        let responsible = responsibility_get_pid_responsible_for_pid(pid)
        if responsible > 0, responsible != pid,
           let app = NSRunningApplication(processIdentifier: responsible), app.activationPolicy == .regular {
            return app
        }
        if !bundleID.isEmpty {
            return NSWorkspace.shared.runningApplications.first {
                $0.activationPolicy == .regular && $0.bundleIdentifier.map { bundleID.hasPrefix($0 + ".") } == true
            }
        }
        return nil
    }

    private func processName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    // MARK: Taps

    private func gain(for s: AppSetting) -> Float {
        if s.muted { return 0 }
        return perceptualCurve ? s.volume * s.volume : s.volume
    }

    /// Creates, updates or removes the tap for each app so its audio matches its settings.
    private func reconcile() {
        guard !isDemo else { return }
        let present = Set(apps.map(\.id))
        for id in taps.keys where !present.contains(id) {
            taps.removeValue(forKey: id)
        }

        var errors: [String] = []
        for app in apps {
            let s = setting(for: app.id)
            let g = gain(for: s)
            let gainL = g * (s.balance > 0 ? 1 - s.balance : 1)
            let gainR = g * (s.balance < 0 ? 1 + s.balance : 1)

            // Use the app's chosen device if it is connected, otherwise follow the system output.
            var uid = outputUID
            var device = outputDevice
            if let wanted = s.deviceUID, let d = outputDevices.first(where: { $0.uid == wanted }) {
                uid = d.uid
                device = d.id
            }

            let needsTap = abs(g - 1) > 0.001 || s.balance != 0 || s.mono || uid != outputUID
                || (showMeters && app.isPlaying)

            // Apps that don't need processing are left completely untouched.
            guard needsTap, !uid.isEmpty else {
                taps.removeValue(forKey: app.id)
                continue
            }
            if let tap = taps[app.id], tap.processObjects == app.processObjects, tap.outputUID == uid {
                tap.update(gainL: gainL, gainR: gainR, mono: s.mono)
                continue
            }
            taps.removeValue(forKey: app.id) // tear down the old one first
            do {
                taps[app.id] = try AppTap(processObjects: app.processObjects, outputUID: uid, outputDevice: device,
                                          gainL: gainL, gainR: gainR, mono: s.mono)
            } catch {
                errors.append("\(app.name): \(error)")
            }
        }
        let err = errors.isEmpty ? nil : errors.joined(separator: "\n")
        if err != lastError { lastError = err }
    }

    // MARK: Devices

    private func refreshDevices() {
        outputDevices = CA.devices(output: true)
        inputDevices = CA.devices(output: false)
        outputDevice = CA.defaultDevice(output: true)
        inputDevice = CA.defaultDevice(output: false)
        outputUID = CA.deviceUID(outputDevice) ?? ""
        inputUID = CA.deviceUID(inputDevice) ?? ""
        refreshDeviceLevels()
    }

    private func refreshDeviceLevels() {
        let ov = CA.volume(outputDevice, output: true), om = CA.isMuted(outputDevice, output: true)
        let iv = CA.volume(inputDevice, output: false), im = CA.isMuted(inputDevice, output: false)
        if ov != outputVolume { outputVolume = ov }
        if om != outputMuted { outputMuted = om }
        if iv != inputVolume { inputVolume = iv }
        if im != inputMuted { inputMuted = im }
    }

    private func installListeners() {
        func listen(_ selector: AudioObjectPropertySelector, _ handler: @escaping @MainActor (Mixer) -> Void) {
            var addr = CA.address(selector)
            AudioObjectAddPropertyListenerBlock(CA.system, &addr, .main) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handler(self)
                }
            }
        }
        listen(kAudioHardwarePropertyDefaultOutputDevice) { m in
            m.taps.removeAll()   // rebuild everything against the new device
            m.refreshDevices()
            m.refresh()
        }
        listen(kAudioHardwarePropertyDefaultInputDevice) { m in m.refreshDevices() }
        listen(kAudioHardwarePropertyDevices) { m in
            m.refreshDevices()
            m.refresh()
        }
        listen(kAudioHardwarePropertyProcessObjectList) { m in m.refresh() }
    }

    // MARK: Demo data

    private func loadDemoData() {
        func icon(_ path: String) -> NSImage { NSWorkspace.shared.icon(forFile: path) }
        let sys = "/System/Applications/"
        apps = [
            AudioApp(id: "com.apple.Music", name: "Music", icon: icon(sys + "Music.app"),
                     isSystem: false, processObjects: [1], isPlaying: true),
            AudioApp(id: "com.apple.Safari", name: "Safari", icon: icon("/Applications/Safari.app"),
                     isSystem: false, processObjects: [2], isPlaying: true),
            AudioApp(id: "com.apple.FaceTime", name: "FaceTime", icon: icon(sys + "FaceTime.app"),
                     isSystem: false, processObjects: [3], isPlaying: true),
            AudioApp(id: "com.apple.podcasts", name: "Podcasts", icon: icon(sys + "Podcasts.app"),
                     isSystem: false, processObjects: [4], isPlaying: false),
            AudioApp(id: "com.apple.TV", name: "TV", icon: icon(sys + "TV.app"),
                     isSystem: false, processObjects: [5], isPlaying: false),
            AudioApp(id: "com.apple.QuickTimePlayerX", name: "QuickTime Player",
                     icon: icon(sys + "QuickTime Player.app"),
                     isSystem: false, processObjects: [6], isPlaying: false),
        ]
        var music = AppSetting(); music.volume = 0.62
        var safari = AppSetting(); safari.volume = 1.0
        var facetime = AppSetting(); facetime.volume = 1.35; facetime.deviceUID = "demo-airpods"
        var podcasts = AppSetting(); podcasts.volume = 0.8; podcasts.mono = true; podcasts.balance = -0.3
        var tv = AppSetting(); tv.muted = true
        settings = ["com.apple.Music": music, "com.apple.Safari": safari, "com.apple.FaceTime": facetime,
                    "com.apple.podcasts": podcasts, "com.apple.TV": tv]
        settings["com.example.hidden"] = { var s = AppSetting(); s.hidden = true; s.name = "Some Game"; return s }()

        outputDevices = [AudioDevice(id: 1, uid: "demo-speakers", name: "MacBook Pro Speakers"),
                         AudioDevice(id: 2, uid: "demo-airpods", name: "AirPods Pro"),
                         AudioDevice(id: 3, uid: "demo-display", name: "Studio Display")]
        inputDevices = [AudioDevice(id: 4, uid: "demo-mic", name: "MacBook Pro Microphone")]
        outputUID = "demo-speakers"; inputUID = "demo-mic"
        outputVolume = 0.72; outputMuted = false
        inputVolume = 0.55; inputMuted = false
        meters.levels = ["com.apple.Music": 0.38, "com.apple.Safari": 0.62, "com.apple.FaceTime": 0.22]
    }

    // MARK: Persistence

    private func prefChanged(_ key: String, _ value: Any) {
        guard !isDemo else { return }
        defaults.set(value, forKey: key)
        reconcile()
    }

    private func save() {
        guard !isDemo else { return }
        // Don't store entries that are back to defaults (keeps the file tidy).
        let compact = settings.filter { !$0.value.isDefault || $0.value.hidden }
        if let data = try? JSONEncoder().encode(compact) {
            defaults.set(data, forKey: settingsKey)
        }
    }
}
