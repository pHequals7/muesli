import CoreAudio
import Foundation

enum AudioOutputRouteKind: String, Equatable, Sendable {
    case speakerLike = "speaker"
    case headphoneLike = "headphones"
}

struct AudioOutputRouteSnapshot: Equatable, Sendable {
    let deviceID: AudioDeviceID
    let name: String
    let uid: String?
    let transportType: UInt32?
    let routeKind: AudioOutputRouteKind
    let estimatedDelayMs: Int

    var description: String {
        "\(name) [\(routeKind.rawValue), delay=\(estimatedDelayMs)ms]"
    }
}

final class AudioOutputRouteMonitor {
    var onRouteChanged: ((AudioOutputRouteSnapshot) -> Void)?

    private var currentDeviceID: AudioDeviceID = 0
    private var currentSnapshot: AudioOutputRouteSnapshot?
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var devicePropertyListenerBlock: AudioObjectPropertyListenerBlock?

    func start() {
        installDefaultOutputDeviceListener()
        refreshCurrentDevice(reinstallingPropertyListener: true, notify: true)
    }

    func stop() {
        removeDevicePropertyListener()
        removeDefaultOutputDeviceListener()
        currentDeviceID = 0
        currentSnapshot = nil
    }

    func currentRoute() -> AudioOutputRouteSnapshot? {
        if currentSnapshot == nil {
            refreshCurrentDevice(reinstallingPropertyListener: false, notify: false)
        }
        return currentSnapshot
    }

    static func classifyRoute(
        name: String,
        uid: String?,
        transportType: UInt32?
    ) -> AudioOutputRouteKind {
        let joinedDescription = [name, uid ?? ""].joined(separator: " ").lowercased()
        let headphoneKeywords = [
            "headphone", "headphones", "headset", "airpods", "earbud", "earbuds",
            "earphone", "earphones", "buds", "beats",
        ]
        if headphoneKeywords.contains(where: { joinedDescription.contains($0) }) {
            return .headphoneLike
        }

        return .speakerLike
    }

    static func estimateDelayMs(
        latencyFrames: UInt32,
        bufferFrames: UInt32,
        sampleRate: Float64
    ) -> Int {
        guard sampleRate > 0 else { return 0 }
        let totalFrames = Double(latencyFrames + bufferFrames)
        return max(Int((1000.0 * totalFrames / sampleRate).rounded()), 0)
    }

    private func installDefaultOutputDeviceListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshCurrentDevice(reinstallingPropertyListener: true, notify: true)
            }
        }
        defaultOutputListenerBlock = block

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            block
        )
    }

    private func removeDefaultOutputDeviceListener() {
        guard let block = defaultOutputListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            block
        )
        defaultOutputListenerBlock = nil
    }

    private func installDevicePropertyListener(deviceID: AudioDeviceID) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshCurrentDevice(reinstallingPropertyListener: false, notify: true)
            }
        }
        devicePropertyListenerBlock = block

        for selector in [
            kAudioDevicePropertyLatency,
            kAudioDevicePropertyBufferFrameSize,
            kAudioDevicePropertyNominalSampleRate,
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(deviceID, &address, nil, block)
        }
    }

    private func removeDevicePropertyListener() {
        guard currentDeviceID != 0, let block = devicePropertyListenerBlock else { return }

        for selector in [
            kAudioDevicePropertyLatency,
            kAudioDevicePropertyBufferFrameSize,
            kAudioDevicePropertyNominalSampleRate,
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(currentDeviceID, &address, nil, block)
        }

        devicePropertyListenerBlock = nil
    }

    private func refreshCurrentDevice(reinstallingPropertyListener: Bool, notify: Bool) {
        guard let deviceID = defaultOutputDeviceID() else { return }

        if reinstallingPropertyListener && deviceID != currentDeviceID {
            removeDevicePropertyListener()
            currentDeviceID = deviceID
            installDevicePropertyListener(deviceID: deviceID)
        } else if currentDeviceID == 0 {
            currentDeviceID = deviceID
        }

        guard let snapshot = makeSnapshot(for: deviceID) else { return }
        let changed = snapshot != currentSnapshot
        currentSnapshot = snapshot

        if notify, changed || reinstallingPropertyListener {
            onRouteChanged?(snapshot)
        }
    }

    private func makeSnapshot(for deviceID: AudioDeviceID) -> AudioOutputRouteSnapshot? {
        let name = readStringProperty(
            deviceID: deviceID,
            selector: kAudioObjectPropertyName,
            scope: kAudioObjectPropertyScopeGlobal
        ) ?? "Unknown Output"
        let uid = readStringProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyDeviceUID,
            scope: kAudioObjectPropertyScopeGlobal
        )
        let transportType = readUInt32Property(
            deviceID: deviceID,
            selector: kAudioDevicePropertyTransportType,
            scope: kAudioObjectPropertyScopeGlobal
        )
        let latencyFrames = readUInt32Property(
            deviceID: deviceID,
            selector: kAudioDevicePropertyLatency,
            scope: kAudioDevicePropertyScopeOutput
        ) ?? 0
        let bufferFrames = readUInt32Property(
            deviceID: deviceID,
            selector: kAudioDevicePropertyBufferFrameSize,
            scope: kAudioDevicePropertyScopeOutput
        ) ?? 0
        let sampleRate = readFloat64Property(
            deviceID: deviceID,
            selector: kAudioDevicePropertyNominalSampleRate,
            scope: kAudioObjectPropertyScopeGlobal
        ) ?? 16_000
        let routeKind = Self.classifyRoute(name: name, uid: uid, transportType: transportType)
        let estimatedDelayMs = Self.estimateDelayMs(
            latencyFrames: latencyFrames,
            bufferFrames: bufferFrames,
            sampleRate: sampleRate
        )

        return AudioOutputRouteSnapshot(
            deviceID: deviceID,
            name: name,
            uid: uid,
            transportType: transportType,
            routeKind: routeKind,
            estimatedDelayMs: estimatedDelayMs
        )
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != 0 else {
            return nil
        }
        return deviceID
    }

    private func readUInt32Property(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private func readFloat64Property(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> Float64? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private func readStringProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              let value else {
            return nil
        }
        let string = value.takeUnretainedValue() as String
        return string.isEmpty ? nil : string
    }
}
