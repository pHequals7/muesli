import AppKit
import CoreAudio
import Foundation
import MuesliCore

@MainActor
final class MicActivityMonitor {
    /// Called when a meeting is detected. Passes the detection result.
    var onMeetingDetected: ((MeetingDetection) -> Void)?
    /// Called whenever the current meeting-detection state changes.
    var onMeetingDetectionStateChanged: ((MeetingDetection?) -> Void)?
    /// Injected by MuesliController — returns the current or nearby calendar event.
    var calendarEventProvider: (() -> CalendarEventContext?)?

    let detector = MeetingDetector()
    let cameraMonitor = CameraActivityMonitor()

    private var micListenerDeviceID: AudioDeviceID = 0
    private var micListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?
    private var maintenanceTimer: Timer?
    private var currentDetection: MeetingDetection?

    func start() {
        installMicListener()
        installDeviceChangeListener()

        cameraMonitor.onCameraStateChanged = { [weak self] _ in
            self?.evaluateNow()
        }
        cameraMonitor.start()

        // Slow maintenance timer for idle reset and cleanup (every 5s)
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.evaluateNow() }
        }
    }

    func stop() {
        removeMicListener()
        removeDeviceChangeListener()
        cameraMonitor.stop()
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
    }

    func suppress(for duration: TimeInterval = 120) {
        detector.suppress(for: duration)
    }

    func suppressWhileActive() {
        detector.suppressWhileActive()
    }

    func resumeAfterCooldown() {
        detector.resumeAfterCooldown()
    }

    func refreshState() {
        evaluateNow()
    }

    // MARK: - Evaluation

    /// Build current signals from system state and evaluate.
    private func evaluateNow() {
        let signals = MeetingSignals(
            micActive: isMicActive(),
            cameraActive: cameraMonitor.isCameraActive,
            calendarEvent: calendarEventProvider?(),
            runningApps: currentRunningApps()
        )
        let detectionState = detector.currentDetection(signals)
        if detectionState != currentDetection {
            currentDetection = detectionState
            onMeetingDetectionStateChanged?(detectionState)
        }
        if let detection = detector.evaluate(signals) {
            fputs("[mic-monitor] detected: \(detection.appName)" +
                  (detection.meetingTitle.map { " (\($0))" } ?? "") + "\n", stderr)
            onMeetingDetected?(detection)
        }
    }

    // MARK: - CoreAudio Mic Listener (event-driven)

    private func installMicListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return }

        micListenerDeviceID = deviceID

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.evaluateNow() }
        }
        micListenerBlock = block

        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(deviceID, &runningAddress, nil, block)
    }

    private func removeMicListener() {
        guard micListenerDeviceID != 0, let block = micListenerBlock else { return }
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(micListenerDeviceID, &runningAddress, nil, block)
        micListenerDeviceID = 0
        micListenerBlock = nil
    }

    // MARK: - Default Device Change Listener

    private func installDeviceChangeListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.removeMicListener()
                self?.installMicListener()
            }
        }
        deviceChangeListenerBlock = block

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, nil, block
        )
    }

    private func removeDeviceChangeListener() {
        guard let block = deviceChangeListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, nil, block
        )
        deviceChangeListenerBlock = nil
    }

    // MARK: - System queries

    private func isMicActive() -> Bool {
        guard micListenerDeviceID != 0 else { return false }

        var isRunning: UInt32 = 0
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)

        guard AudioObjectGetPropertyData(
            micListenerDeviceID, &runningAddress, 0, nil, &size, &isRunning
        ) == noErr else { return false }

        return isRunning != 0
    }

    private func currentRunningApps() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier else { return nil }
            return RunningAppInfo(bundleID: bundleID, isActive: app.isActive)
        }
    }
}
