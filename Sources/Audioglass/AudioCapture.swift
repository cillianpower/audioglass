import AppKit
import CoreAudio
import DSPBridge
import AVFoundation

struct AudioSource: Equatable {
    let id: String
    let name: String
    static let stopped = AudioSource(id: "stopped", name: "Stopped")
    static let system = AudioSource(id: "system", name: "System Audio")
}

// This object is configured on the main thread. The worker retains only its
// transport handle; the delegate joins that worker before stop/deallocation.
@MainActor
final class AudioCapture {
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private(set) var transport: OpaquePointer?
    private(set) var format = AudioStreamBasicDescription()
    private var outputDevice: AudioObjectID = 0
    private var isInput = false

    static func sources() -> [AudioSource] {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        var seen = Set<String>()
        return [.stopped, .system] + inputSources() + apps.compactMap { app in
            guard let id = app.bundleIdentifier, seen.insert(id).inserted else { return nil }
            return AudioSource(id: id, name: app.localizedName ?? id)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func inputSources() -> [AudioSource] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.compactMap { id in
            var streamAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamAddress, 0, nil, &streamSize) == noErr, streamSize > 0,
                let uid = deviceString(id, selector: kAudioDevicePropertyDeviceUID),
                let name = deviceString(id, selector: kAudioObjectPropertyName),
                name != "Audioglass Capture", !uid.hasPrefix("com.cillianpower.audioglass.capture.") else { return nil }
            return AudioSource(id: "input:" + uid, name: "Input: " + name)
        }
    }
    private static func deviceString(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    func start(_ source: AudioSource) throws {
        stop()
        guard source != .stopped else { return }
        do {
            isInput = source.id.hasPrefix("input:")
            if isInput {
                guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                    throw CaptureError(message: "Allow microphone access to use audio interface or microphone inputs, then select the input again.")
                }
                guard let input = Self.inputSources().first(where: { $0.id == source.id }) else {
                    throw CaptureError(message: "This audio input is disconnected. Select another input.")
                }
                var uid = Unmanaged.passRetained(String(input.id.dropFirst(6)) as CFString)
                defer { uid.release() }
                var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var size = UInt32(MemoryLayout<AudioObjectID>.size)
                try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                    UInt32(MemoryLayout<Unmanaged<CFString>>.size), &uid, &size, &device), "Find audio input")
                format = try readFormat()
                try validateFormat()
                guard let ring = ag_transport_create() else { throw CaptureError(message: "Cannot allocate audio transport.") }
                transport = ring
                try check(ag_transport_start(ring, device), "Start input capture")
                return
            }
            let description = CATapDescription()
            description.name = "Audioglass \(source.name)"
            description.isPrivate = true
            description.isMixdown = true
            description.isMono = false
            description.isExclusive = source == .system
            description.bundleIDs = source == .system ? [Bundle.main.bundleIdentifier!] : [source.id]
            description.isProcessRestoreEnabled = true
            description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tap), "Create audio tap")
            format = try readFormat()
            try validateFormat()
            outputDevice = defaultOutput()
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Audioglass Capture",
                kAudioAggregateDeviceUIDKey: "com.cillianpower.audioglass.capture." + UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]
            try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &device), "Create capture device")
            guard let ring = ag_transport_create() else { throw CaptureError(message: "Cannot allocate audio transport.") }
            transport = ring
            try check(ag_transport_start(ring, device), "Start audio capture")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let transport { ag_transport_destroy(transport); self.transport = nil }
        if device != 0 { if !isInput { AudioHardwareDestroyAggregateDevice(device) }; device = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }

    // Poll on the control thread. Recreate the transport/engine on format or
    // default-device changes so old and new PCM never share an analysis history.
    func configurationChanged() -> Bool {
        guard tap != 0 || isInput && device != 0 else { return false }
        guard let current = try? readFormat() else { return true }
        return (!isInput && defaultOutput() != outputDevice) || current.mSampleRate != format.mSampleRate
            || current.mChannelsPerFrame != format.mChannelsPerFrame
            || current.mFormatFlags != format.mFormatFlags
    }

    private func readFormat() throws -> AudioStreamBasicDescription {
        var value = AudioStreamBasicDescription()
        var address = AudioObjectPropertyAddress(mSelector: isInput ? kAudioDevicePropertyStreamFormat : kAudioTapPropertyFormat,
            mScope: isInput ? kAudioDevicePropertyScopeInput : kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout.size(ofValue: value))
        try check(AudioObjectGetPropertyData(isInput ? device : tap, &address, 0, nil, &size, &value), "Read audio format")
        return value
    }
    private func validateFormat() throws {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32,
              format.mChannelsPerFrame > 0,
              (8000...384000).contains(format.mSampleRate) else {
            throw CaptureError(message: "This source returned an unsupported PCM format. Select a float32 audio input.")
        }
    }
    private func defaultOutput() -> AudioObjectID {
        var value: AudioObjectID = 0
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout.size(ofValue: value))
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value)
        return value
    }
    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw CaptureError(message: "\(operation) failed (\(status)). Check System Settings → Privacy & Security → Screen & System Audio Recording, then retry the source.") }
    }
}

struct CaptureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Immutable ring reference shared with the analysis queue. Its owner guarantees
// the queue has finished before replacing or destroying the transport.
struct CaptureInput: @unchecked Sendable {
    let transport: OpaquePointer
    let sampleRate: Float
}
