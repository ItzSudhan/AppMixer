import CoreAudio
import AudioToolbox
import Foundation

enum TapError: Error, CustomStringConvertible {
    case createTap(OSStatus)
    case createAggregate(OSStatus)
    case ioProc(OSStatus)
    case start(OSStatus)

    var description: String {
        switch self {
        case .createTap(let s): return "could not create audio tap (\(s))"
        case .createAggregate(let s): return "could not create output device (\(s))"
        case .ioProc(let s): return "could not attach audio callback (\(s))"
        case .start(let s): return "could not start audio (\(s))"
        }
    }
}

/// Shared between the main thread (writes targets, reads peaks) and the real-time audio thread.
struct TapParams {
    var targetL: Float = 1, targetR: Float = 1   // final per-channel gain (volume × balance)
    var currentL: Float = 1, currentR: Float = 1 // ramped value actually applied
    var mono: Bool = false
    var peakL: Float = 0, peakR: Float = 0       // post-gain peaks for the level meter
    var outL: Int32 = 0, outR: Int32 = 1         // device channels for left / right
}

/// Captures the audio of one app's processes, mutes the original,
/// and plays it to an output device with volume / balance / mono applied.
///
///   app ──► process tap (original muted) ──► aggregate device IO proc ──(gain, pan, limiter)──► device
final class AppTap {
    let processObjects: [AudioObjectID]
    let outputUID: String

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "AppMixer.io", qos: .userInteractive)
    private let params = UnsafeMutablePointer<TapParams>.allocate(capacity: 1)

    init(processObjects: [AudioObjectID], outputUID: String, outputDevice: AudioObjectID,
         gainL: Float, gainR: Float, mono: Bool) throws {
        self.processObjects = processObjects
        self.outputUID = outputUID
        let (l, r) = CA.stereoChannels(outputDevice)
        params.initialize(to: TapParams(targetL: gainL, targetR: gainR, currentL: gainL, currentR: gainR,
                                        mono: mono, outL: l, outR: r))
        // If this throws, deinit still runs (all stored properties are set) and cleans up.
        try start()
    }

    func update(gainL: Float, gainR: Float, mono: Bool) {
        params.pointee.targetL = gainL
        params.pointee.targetR = gainR
        params.pointee.mono = mono
    }

    /// Returns the peak level since the last call and resets it.
    func takePeak() -> Float {
        let p = max(params.pointee.peakL, params.pointee.peakR)
        params.pointee.peakL = 0
        params.pointee.peakR = 0
        return p
    }

    private func start() throws {
        // 1. Process tap: stereo mixdown of this app's processes, muted at the source.
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = UUID()
        description.name = "AppMixer Tap"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw TapError.createTap(status) }

        // 2. Private aggregate device = the target output device + the tap as an input.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AppMixer",
            kAudioAggregateDeviceUIDKey: "AppMixer-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { throw TapError.createAggregate(status) }

        // 3. IO proc: tap input -> device output.
        let p = params
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, inData, _, outData, _ in
            AppTap.render(input: inData, output: outData, p: p)
        }
        guard status == noErr else { throw TapError.ioProc(status) }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { throw TapError.start(status) }
    }

    // MARK: Real-time rendering (no allocation, no locks)

    private typealias Channel = (ptr: UnsafeMutablePointer<Float>, stride: Int, frames: Int)

    /// Finds global channel `index` in a buffer list (works for interleaved and non-interleaved).
    @inline(__always)
    private static func channel(_ list: UnsafeMutableAudioBufferListPointer, _ index: Int) -> Channel? {
        var base = 0
        for b in list {
            let n = Int(b.mNumberChannels)
            if index < base + n {
                guard n > 0, let data = b.mData?.assumingMemoryBound(to: Float.self) else { return nil }
                let frames = Int(b.mDataByteSize) / (MemoryLayout<Float>.size * n)
                return (data + (index - base), n, frames)
            }
            base += n
        }
        return nil
    }

    /// Soft limiter: transparent below 0.8, smoothly saturates above (only used when boosting).
    @inline(__always)
    private static func limit(_ x: Float) -> Float {
        let a = abs(x)
        if a <= 0.8 { return x }
        let y = 0.8 + 0.2 * tanhf((a - 0.8) / 0.2)
        return x < 0 ? -y : y
    }

    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               p: UnsafeMutablePointer<TapParams>) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        for b in outList where b.mData != nil { memset(b.mData, 0, Int(b.mDataByteSize)) }

        // The tap's stereo channels are the last input channels of the aggregate device.
        var totalIn = 0
        for b in inList { totalIn += Int(b.mNumberChannels) }
        guard totalIn > 0 else { return }
        let tapStart = max(0, totalIn - 2)
        guard let inL = channel(inList, tapStart),
              let inR = channel(inList, totalIn - tapStart > 1 ? tapStart + 1 : tapStart) else { return }

        var totalOut = 0
        for b in outList { totalOut += Int(b.mNumberChannels) }
        guard totalOut > 0 else { return }
        let outLIndex = Int(p.pointee.outL) < totalOut ? Int(p.pointee.outL) : 0
        let outRIndex = Int(p.pointee.outR) < totalOut ? Int(p.pointee.outR) : min(1, totalOut - 1)
        guard let outL = channel(outList, outLIndex), let outR = channel(outList, outRIndex) else { return }
        let monoDevice = outLIndex == outRIndex

        let frames = min(inL.frames, inR.frames, outL.frames, outR.frames)
        guard frames > 0 else { return }

        let startL = p.pointee.currentL, startR = p.pointee.currentR
        let endL = p.pointee.targetL, endR = p.pointee.targetR
        let stepL = (endL - startL) / Float(frames), stepR = (endR - startR) / Float(frames)
        let mono = p.pointee.mono
        let boosting = max(startL, startR, endL, endR) > 1.0001
        var gl = startL, gr = startR
        var peakL = p.pointee.peakL, peakR = p.pointee.peakR

        for f in 0..<frames {
            var l = inL.ptr[f * inL.stride]
            var r = inR.ptr[f * inR.stride]
            if mono { let m = (l + r) * 0.5; l = m; r = m }
            l *= gl; r *= gr
            if boosting { l = limit(l); r = limit(r) }
            if monoDevice {
                outL.ptr[f * outL.stride] = (l + r) * 0.5
            } else {
                outL.ptr[f * outL.stride] = l
                outR.ptr[f * outR.stride] = r
            }
            peakL = max(peakL, abs(l)); peakR = max(peakR, abs(r))
            gl += stepL; gr += stepR
        }

        p.pointee.currentL = endL
        p.pointee.currentR = endR
        p.pointee.peakL = peakL
        p.pointee.peakR = peakR
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        ioProcID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit {
        teardown()
        params.deinitialize(count: 1)
        params.deallocate()
    }
}
