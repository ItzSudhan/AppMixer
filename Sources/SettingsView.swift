import SwiftUI
import ServiceManagement

enum PermissionHelper {
    static func openPrivacySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security",
        ]
        for s in urls {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var mixer: Mixer
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open AppMixer at login", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: setLaunchAtLogin))
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("Approve AppMixer in Login Items to finish.").font(.caption).foregroundStyle(.secondary)
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                            .buttonStyle(.link).font(.caption)
                    }
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Show input (microphone) controls", isOn: $mixer.showInput)
            }

            Section("Applications list") {
                Toggle("Show system & background processes", isOn: $mixer.showSystemProcesses)
                Toggle("Only show apps that are playing audio", isOn: $mixer.onlyPlaying)
                Picker("Sort", selection: $mixer.sortOrder) {
                    ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                }
            }

            Section {
                Picker("Maximum volume", selection: $mixer.maxVolume) {
                    Text("100%").tag(Float(1.0))
                    Text("150% (boost)").tag(Float(1.5))
                    Text("200% (boost)").tag(Float(2.0))
                }
                Picker("Volume scale", selection: $mixer.perceptualCurve) {
                    Text("Natural (perceptual)").tag(true)
                    Text("Linear").tag(false)
                }
                Toggle("Show level meters", isOn: $mixer.showMeters)
            } header: {
                Text("Volume")
            } footer: {
                Text("Boost uses a soft limiter to avoid harsh clipping. Level meters route every playing app through AppMixer; apps you haven't changed are otherwise left untouched.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Hidden apps") {
                if mixer.hiddenApps.isEmpty {
                    Text("None. Hide an app from its ▸ menu or by right-clicking it.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(mixer.hiddenApps, id: \.id) { app in
                        HStack {
                            Text(app.name)
                            Spacer()
                            Button("Unhide") { mixer.setHidden(false, for: app.id) }
                        }
                    }
                }
            }

            Section {
                HStack {
                    Text("System Audio Recording permission")
                    Spacer()
                    Button("Open Privacy Settings") { PermissionHelper.openPrivacySettings() }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("AppMixer needs this to change an app's volume. If an app goes silent when you move its slider, turn AppMixer on under Privacy & Security → Screen & System Audio Recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Reset all app volumes") { mixer.resetAll() }
                    Spacer()
                    Text("AppMixer \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { loginStatus = SMAppService.mainApp.status }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change login item: \(error.localizedDescription)"
        }
        loginStatus = SMAppService.mainApp.status
    }
}
