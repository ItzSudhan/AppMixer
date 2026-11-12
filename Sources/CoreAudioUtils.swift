import CoreAudio
import AudioToolbox
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
}

/// Thin helpers around the C Core Audio property API.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func get<T>(_ id: AudioObjectID,
                       _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       initial: T) -> T? {
        var addr = address(selector, scope)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    @discardableResult
    static func set<T>(_ id: AudioObjectID,
                       _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       _ value: T) -> Bool {
        var addr = address(selector, scope)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var v = value
        let status = withUnsafeMutablePointer(to: &v) {
            AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
        return status == noErr
    }

    static func isSettable(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope) -> Bool {
        var addr = address(selector, scope)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &addr, &settable) == noErr && settable.boolValue
    }

    static func getArray<T>(_ id: AudioObjectID,
                            _ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                            initial: T) -> [T] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        var values = [T](repeating: initial, count: count)
        let status = values.withUnsafeMutableBufferPointer {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        return Array(values.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    static func getString(_ id: AudioObjectID,
                          _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>? = nil
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    // MARK: Devices

    static func defaultDevice(output: Bool) -> AudioObjectID {
        let sel = output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
        return get(system, sel, initial: AudioObjectID(kAudioObjectUnknown)) ?? AudioObjectID(kAudioObjectUnknown)
    }

    static func setDefaultDevice(_ device: AudioObjectID, output: Bool) {
        let sel = output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
        set(system, sel, device)
    }

    static func deviceUID(_ device: AudioObjectID) -> String? {
        getString(device, kAudioDevicePropertyDeviceUID)
    }

    static func deviceName(_ device: AudioObjectID) -> String {
        getString(device, kAudioObjectPropertyName) ?? "Unknown device"
    }

    static func devices(output: Bool) -> [AudioDevice] {
        let scope = output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
        return getArray(system, kAudioHardwarePropertyDevices, initial: AudioObjectID(0)).compactMap { id in
            var addr = address(kAudioDevicePropertyStreams, scope)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0,
                  let uid = deviceUID(id), !uid.hasPrefix("AppMixer") else { return nil }
            return AudioDevice(id: id, uid: uid, name: deviceName(id))
        }
    }

    static func device(forUID uid: String) -> AudioObjectID? {
        devices(output: true).first { $0.uid == uid }?.id
    }

    /// 0-based indices of the device's preferred stereo pair (usually 0 and 1).
    static func stereoChannels(_ device: AudioObjectID) -> (Int32, Int32) {
        let pair = getArray(device, kAudioDevicePropertyPreferredChannelsForStereo,
                            scope: kAudioDevicePropertyScopeOutput, initial: UInt32(0))
        guard pair.count == 2, pair[0] >= 1, pair[1] >= 1 else { return (0, 1) }
        return (Int32(pair[0] - 1), Int32(pair[1] - 1))
    }

    // MARK: Device volume / mute

    private static func scope(_ output: Bool) -> AudioObjectPropertyScope {
        output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
    }

    /// The "virtual main volume" is what the macOS volume keys / menu bar slider control.
    static func volume(_ device: AudioObjectID, output: Bool) -> Float? {
        guard isSettable(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope(output)) else { return nil }
        return get(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope(output), initial: Float32(0))
    }

    static func setVolume(_ device: AudioObjectID, output: Bool, _ value: Float) {
        set(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope(output), Float32(max(0, min(1, value))))
    }

    static func isMuted(_ device: AudioObjectID, output: Bool) -> Bool? {
        guard isSettable(device, kAudioDevicePropertyMute, scope: scope(output)) else { return nil }
        return get(device, kAudioDevicePropertyMute, scope: scope(output), initial: UInt32(0)).map { $0 != 0 }
    }

    static func setMuted(_ device: AudioObjectID, output: Bool, _ muted: Bool) {
        set(device, kAudioDevicePropertyMute, scope: scope(output), UInt32(muted ? 1 : 0))
    }
}
