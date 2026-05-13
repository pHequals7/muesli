import Testing
import Foundation
@testable import MuesliNativeApp

// MARK: - Test Doubles

@MainActor
private final class RecordingStarterSpy {
    private(set) var calls: [String?] = []
    var returnValue: Bool = true

    func start(_ title: String?) -> Bool {
        calls.append(title)
        return returnValue
    }
}

@MainActor
private final class ConfirmationPresenterDouble: AutoCaptureConfirmationPresenting {
    private(set) var presentations: [(appName: String, bundleID: String?, meetingTitle: String?)] = []
    var pendingCompletion: ((AutoCaptureConfirmationOutcome) -> Void)?

    func present(
        appName: String,
        bundleID: String?,
        meetingTitle: String?,
        completion: @escaping @MainActor (AutoCaptureConfirmationOutcome) -> Void
    ) {
        presentations.append((appName, bundleID, meetingTitle))
        pendingCompletion = completion
    }

    func resolve(with outcome: AutoCaptureConfirmationOutcome) {
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(outcome)
    }
}

@MainActor
private final class TestHarness {
    var config: AutoCaptureConfig {
        didSet { writes.append(config) }
    }
    var writes: [AutoCaptureConfig] = []
    var sleepInvocations: [Double] = []
    var releaseSleep: () -> Void = {}
    var isRecording = false
    var isFocusMode = false
    let starter = RecordingStarterSpy()
    let presenter = ConfirmationPresenterDouble()
    var clockNow = Date(timeIntervalSince1970: 1_700_000_000)
    private(set) var coordinator: AutoCaptureCoordinator!

    init(config: AutoCaptureConfig = AutoCaptureConfig(enabled: true, startDelaySeconds: 0)) {
        self.config = config
        self.coordinator = makeCoordinator()
        self.coordinator.start()
    }

    private func makeCoordinator() -> AutoCaptureCoordinator {
        AutoCaptureCoordinator(
            config: { [unowned self] in self.config },
            configWriter: { [unowned self] newConfig in self.config = newConfig },
            recordingStarter: { [unowned self] title in self.starter.start(title) },
            isRecordingNow: { [unowned self] in self.isRecording },
            isFocusModeActive: { [unowned self] in self.isFocusMode },
            confirmationPresenter: presenter,
            clock: { [unowned self] in self.clockNow },
            sleep: { [unowned self] seconds in
                self.sleepInvocations.append(seconds)
                await withCheckedContinuation { continuation in
                    self.releaseSleep = { continuation.resume() }
                }
            }
        )
    }
}

private func makeSignal(
    appName: String = "Zoom",
    bundleID: String? = "us.zoom.xos",
    meetingTitle: String? = nil,
    hasCalendarMatch: Bool = false
) -> AutoCaptureSignal {
    AutoCaptureSignal(
        appName: appName,
        bundleID: bundleID,
        meetingTitle: meetingTitle,
        hasCalendarMatch: hasCalendarMatch
    )
}

private func acknowledgedConfig(_ bundleIDs: String...) -> AutoCaptureConfig {
    AutoCaptureConfig(
        enabled: true,
        acknowledgedAppBundleIDs: Set(bundleIDs),
        startDelaySeconds: 0
    )
}

@Suite("AutoCaptureCoordinator")
@MainActor
struct AutoCaptureCoordinatorTests {

    // MARK: - Initial state

    @Test("starts in idle state")
    func startsInIdleState() {
        let harness = TestHarness()
        #expect(harness.coordinator.state == .idle)
        #expect(harness.coordinator.lastDecisionReason == .noSignal)
    }

    // MARK: - Master toggle

    @Test("master toggle off → no transition out of idle")
    func masterToggleOffStaysIdle() {
        let harness = TestHarness(config: AutoCaptureConfig(enabled: false))
        harness.coordinator.handle(makeSignal())
        #expect(harness.coordinator.state == .idle)
        #expect(harness.coordinator.lastDecisionReason == .masterToggleOff)
        #expect(harness.starter.calls.isEmpty)
    }

    @Test("master toggle flipped off mid-arm → returns to idle")
    func masterToggleFlippedOffMidArm() async {
        let harness = TestHarness(config: AutoCaptureConfig(enabled: true, startDelaySeconds: 5))
        harness.coordinator.handle(makeSignal())
        if case .armed = harness.coordinator.state {} else { Issue.record("expected armed"); return }

        harness.config.enabled = false
        harness.coordinator.handle(makeSignal())
        #expect(harness.coordinator.state == .idle)
        #expect(harness.coordinator.lastDecisionReason == .masterToggleOff)
    }

    // MARK: - idle → armed

    @Test("idle → armed when enabled and signal arrives")
    func idleToArmed() {
        let harness = TestHarness(config: AutoCaptureConfig(enabled: true, startDelaySeconds: 5))
        harness.coordinator.handle(makeSignal())
        if case .armed(let bundleID, let appName) = harness.coordinator.state {
            #expect(bundleID == "us.zoom.xos")
            #expect(appName == "Zoom")
        } else {
            Issue.record("expected armed state")
        }
        #expect(harness.coordinator.lastDecisionReason == .awaitingDelay)
    }

    // MARK: - armed → idle (debounce)

    @Test("armed → idle when detection clears")
    func armedToIdleOnClear() async {
        let harness = TestHarness(config: AutoCaptureConfig(enabled: true, startDelaySeconds: 5))
        harness.coordinator.handle(makeSignal())
        harness.coordinator.handle(nil)
        #expect(harness.coordinator.state == .idle)
        #expect(harness.coordinator.lastDecisionReason == .detectionCleared)
        #expect(harness.starter.calls.isEmpty)
    }

    // MARK: - armed → confirming (delay elapses)

    @Test("armed → confirming → recording when acknowledged")
    func armedToConfirmingToRecordingAcknowledged() async {
        let harness = TestHarness(
            config: AutoCaptureConfig(
                enabled: true,
                acknowledgedAppBundleIDs: ["us.zoom.xos"],
                startDelaySeconds: 1
            )
        )
        harness.coordinator.handle(makeSignal())
        // Release the simulated start-delay sleep so the coordinator can advance.
        await Task.yield()
        harness.releaseSleep()
        await Task.yield()
        await Task.yield()
        if case .recording = harness.coordinator.state {} else {
            Issue.record("expected recording state, got \(harness.coordinator.state)")
        }
        #expect(harness.starter.calls.count == 1)
        #expect(harness.coordinator.lastDecisionReason == .startedRecording)
    }

    // MARK: - armed → idle when delay elapses but master toggle gets disabled

    @Test("delay elapses with master toggle disabled → idle")
    func delayElapsesMasterOff() async {
        let harness = TestHarness(config: AutoCaptureConfig(enabled: true, startDelaySeconds: 1))
        harness.coordinator.handle(makeSignal())
        harness.config.enabled = false
        await Task.yield()
        harness.releaseSleep()
        await Task.yield()
        await Task.yield()
        #expect(harness.coordinator.state == .idle)
        #expect(harness.starter.calls.isEmpty)
    }

    // MARK: - confirming → awaitingUserConfirm → recording

    @Test("first-run modal approved (no remember) starts recording")
    func firstRunApproved() async {
        let harness = TestHarness(config: AutoCaptureConfig(enabled: true, startDelaySeconds: 1))
        harness.coordinator.handle(makeSignal())
        await Task.yield()
        harness.releaseSleep()
        await Task.yield()
        await Task.yield()
        // Modal should have been presented.
        #expect(harness.presenter.presentations.count == 1)
        harness.presenter.resolve(with: .approved(rememberForApp: false))
        if case .recording = harness.coordinator.state {} else {
            Issue.record("expected recording state, got \(harness.coordinator.state)")
        }
        #expect(harness.starter.calls.count == 1)
        #expect(harness.config.acknowledgedAppBundleIDs.isEmpty)
    }

    @Test("first-run modal approved with remember persists acknowledgement")
    func firstRunApprovedWithRemember() async {
        let harness = TestHarness(config: AutoCaptureConfig(enabled: true, startDelaySeconds: 1))
        harness.coordinator.handle(makeSignal())
        await Task.yield()
        harness.releaseSleep()
        await Task.yield()
        await Task.yield()
        harness.presenter.resolve(with: .approved(rememberForApp: true))
        #expect(harness.config.acknowledgedAppBundleIDs.contains("us.zoom.xos"))
        if case .recording = harness.coordinator.state {} else {
            Issue.record("expected recording state, got \(harness.coordinator.state)")
        }
    }

    @Test("first-run modal declined → idle")
    func firstRunDeclined() async {
        let harness = TestHarness(config: AutoCaptureConfig(enabled: true, startDelaySeconds: 1))
        harness.coordinator.handle(makeSignal())
        await Task.yield()
        harness.releaseSleep()
        await Task.yield()
        await Task.yield()
        harness.presenter.resolve(with: .declined(rememberForApp: false))
        #expect(harness.coordinator.state == .idle)
        #expect(harness.coordinator.lastDecisionReason == .userDeclined)
        #expect(harness.starter.calls.isEmpty)
    }

    @Test("first-run modal declined with remember persists acknowledgement")
    func firstRunDeclinedWithRemember() async {
        let harness = TestHarness(config: AutoCaptureConfig(enabled: true, startDelaySeconds: 1))
        harness.coordinator.handle(makeSignal())
        await Task.yield()
        harness.releaseSleep()
        await Task.yield()
        await Task.yield()
        harness.presenter.resolve(with: .declined(rememberForApp: true))
        #expect(harness.config.acknowledgedAppBundleIDs.contains("us.zoom.xos"))
        #expect(harness.coordinator.state == .idle)
    }

    @Test("first-run modal timeout → idle (default decline)")
    func firstRunTimeout() async {
        let harness = TestHarness(config: AutoCaptureConfig(enabled: true, startDelaySeconds: 1))
        harness.coordinator.handle(makeSignal())
        await Task.yield()
        harness.releaseSleep()
        await Task.yield()
        await Task.yield()
        harness.presenter.resolve(with: .timedOut)
        #expect(harness.coordinator.state == .idle)
        #expect(harness.coordinator.lastDecisionReason == .userDeclined)
    }

    // MARK: - recording → idle (manual stop)

    @Test("recording → idle when external recording stops")
    func recordingToIdleOnStop() async {
        let harness = TestHarness(
            config: AutoCaptureConfig(
                enabled: true,
                acknowledgedAppBundleIDs: ["us.zoom.xos"],
                startDelaySeconds: 1
            )
        )
        harness.coordinator.handle(makeSignal())
        await Task.yield()
        harness.releaseSleep()
        await Task.yield()
        await Task.yield()
        if case .recording = harness.coordinator.state {} else {
            Issue.record("expected recording, got \(harness.coordinator.state)")
            return
        }

        // Simulate user manually stopping the recording.
        harness.isRecording = false
        harness.coordinator.handle(makeSignal())
        #expect(harness.coordinator.state == .idle || {
            if case .armed = harness.coordinator.state { return true }
            return false
        }())
    }

    // MARK: - recording → idle (start failure)

    @Test("recording start failure → idle")
    func recordingStartFailure() async {
        let harness = TestHarness(
            config: AutoCaptureConfig(
                enabled: true,
                acknowledgedAppBundleIDs: ["us.zoom.xos"],
                startDelaySeconds: 1
            )
        )
        harness.starter.returnValue = false
        harness.coordinator.handle(makeSignal())
        await Task.yield()
        harness.releaseSleep()
        await Task.yield()
        await Task.yield()
        #expect(harness.coordinator.state == .idle)
        #expect(harness.coordinator.lastDecisionReason == .startFailed)
    }

    // MARK: - App not allowed

    @Test("signal from disallowed app → idle")
    func disallowedAppStaysIdle() {
        var config = AutoCaptureConfig(enabled: true, startDelaySeconds: 1)
        config.allowedAppBundleIDs = ["us.zoom.xos"]
        let harness = TestHarness(config: config)
        harness.coordinator.handle(makeSignal(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap"))
        #expect(harness.coordinator.state == .idle)
        #expect(harness.coordinator.lastDecisionReason == .appNotAllowed)
    }

    // MARK: - Focus mode

    @Test("Focus mode active and disableDuringFocus=true → idle")
    func focusModeBlocks() {
        let harness = TestHarness(config: AutoCaptureConfig(enabled: true, startDelaySeconds: 1, disableDuringFocus: true))
        harness.isFocusMode = true
        harness.coordinator.handle(makeSignal())
        #expect(harness.coordinator.state == .idle)
        #expect(harness.coordinator.lastDecisionReason == .focusModeActive)
    }

    @Test("Focus mode active but disableDuringFocus=false → still proceeds")
    func focusModeIgnoredWhenDisabled() {
        let harness = TestHarness(
            config: AutoCaptureConfig(enabled: true, startDelaySeconds: 1, disableDuringFocus: false)
        )
        harness.isFocusMode = true
        harness.coordinator.handle(makeSignal())
        if case .armed = harness.coordinator.state {} else {
            Issue.record("expected armed state")
        }
    }

    // MARK: - Strict mode (requireCalendarMatch)

    @Test("strict mode without calendar match → idle after delay")
    func strictModeWithoutCalendar() async {
        let harness = TestHarness(
            config: AutoCaptureConfig(
                enabled: true,
                acknowledgedAppBundleIDs: ["us.zoom.xos"],
                startDelaySeconds: 1,
                requireCalendarMatch: true
            )
        )
        harness.coordinator.handle(makeSignal(hasCalendarMatch: false))
        await Task.yield()
        harness.releaseSleep()
        await Task.yield()
        await Task.yield()
        #expect(harness.coordinator.state == .idle)
        #expect(harness.coordinator.lastDecisionReason == .calendarMatchRequired)
    }

    @Test("strict mode with calendar match bypasses first-run modal")
    func strictModeWithCalendarBypassesModal() async {
        let harness = TestHarness(
            config: AutoCaptureConfig(
                enabled: true,
                startDelaySeconds: 1,
                requireCalendarMatch: true
            )
        )
        harness.coordinator.handle(makeSignal(hasCalendarMatch: true))
        await Task.yield()
        harness.releaseSleep()
        await Task.yield()
        await Task.yield()
        if case .recording = harness.coordinator.state {} else {
            Issue.record("expected recording, got \(harness.coordinator.state)")
        }
        #expect(harness.presenter.presentations.isEmpty)
        #expect(harness.starter.calls.count == 1)
    }

    // MARK: - Already recording

    @Test("incoming signal while already recording → no-op")
    func alreadyRecordingDoesNothing() {
        let harness = TestHarness(config: AutoCaptureConfig(enabled: true, startDelaySeconds: 5))
        harness.isRecording = true
        harness.coordinator.handle(makeSignal())
        #expect(harness.coordinator.state == .idle)
        #expect(harness.coordinator.lastDecisionReason == .alreadyRecording)
        #expect(harness.starter.calls.isEmpty)
    }

    // MARK: - Re-arming when signal switches apps

    @Test("signal switches bundle ID → re-arm with new candidate")
    func reArmOnBundleSwitch() {
        let harness = TestHarness(config: AutoCaptureConfig(enabled: true, startDelaySeconds: 5))
        harness.coordinator.handle(makeSignal(appName: "Zoom", bundleID: "us.zoom.xos"))
        harness.coordinator.handle(makeSignal(appName: "Teams", bundleID: "com.microsoft.teams2"))
        if case .armed(let bundleID, _) = harness.coordinator.state {
            #expect(bundleID == "com.microsoft.teams2")
        } else {
            Issue.record("expected armed for Teams")
        }
    }

    // MARK: - Acknowledgement persistence helper

    @Test("acknowledge stores bundle ID exactly once")
    func acknowledgeOnce() {
        let harness = TestHarness()
        harness.coordinator.acknowledge(bundleID: "us.zoom.xos")
        let firstWriteCount = harness.writes.count
        harness.coordinator.acknowledge(bundleID: "us.zoom.xos")
        #expect(harness.writes.count == firstWriteCount)
        #expect(harness.config.acknowledgedAppBundleIDs.contains("us.zoom.xos"))
    }

    @Test("acknowledge ignores empty bundle ID")
    func acknowledgeIgnoresEmpty() {
        let harness = TestHarness()
        let before = harness.writes.count
        harness.coordinator.acknowledge(bundleID: "")
        #expect(harness.writes.count == before)
    }

    // MARK: - stop() lifecycle

    @Test("stop() cancels pending delay and returns to idle")
    func stopCancelsPendingDelay() async {
        let harness = TestHarness(config: AutoCaptureConfig(enabled: true, startDelaySeconds: 30))
        harness.coordinator.handle(makeSignal())
        if case .armed = harness.coordinator.state {} else {
            Issue.record("expected armed before stop")
            return
        }
        harness.coordinator.stop()
        #expect(harness.coordinator.state == .idle)

        // Signals received after stop should not transition out of idle.
        harness.coordinator.handle(makeSignal())
        #expect(harness.coordinator.state == .idle)
    }

    // MARK: - AutoCaptureConfig

    @Test("AutoCaptureConfig defaults match architecture §4.2")
    func configDefaults() {
        let config = AutoCaptureConfig()
        #expect(config.enabled == false)
        #expect(config.startDelaySeconds == 5)
        #expect(config.requireCalendarMatch == false)
        #expect(config.disableDuringFocus == true)
        #expect(config.acknowledgedAppBundleIDs.isEmpty)
        #expect(!config.allowedAppBundleIDs.isEmpty)
    }

    @Test("AutoCaptureConfig clamps startDelaySeconds")
    func configClampsDelay() {
        let tooSmall = AutoCaptureConfig(startDelaySeconds: -10)
        #expect(tooSmall.startDelaySeconds == AutoCaptureConfig.minStartDelaySeconds)
        let tooLarge = AutoCaptureConfig(startDelaySeconds: 9999)
        #expect(tooLarge.startDelaySeconds == AutoCaptureConfig.maxStartDelaySeconds)
    }

    @Test("AutoCaptureConfig isAllowed returns true for empty allow list")
    func isAllowedWithEmptyList() {
        var config = AutoCaptureConfig()
        config.allowedAppBundleIDs = []
        #expect(config.isAllowed(bundleID: "us.zoom.xos"))
        #expect(config.isAllowed(bundleID: nil))
    }

    @Test("AutoCaptureConfig isAllowed enforces non-empty list")
    func isAllowedWithList() {
        var config = AutoCaptureConfig()
        config.allowedAppBundleIDs = ["us.zoom.xos"]
        #expect(config.isAllowed(bundleID: "us.zoom.xos"))
        #expect(!config.isAllowed(bundleID: "com.tinyspeck.slackmacgap"))
        #expect(config.isAllowed(bundleID: nil))
    }

    @Test("AutoCaptureConfig decodes missing fields with defaults")
    func configDecodesMissingFieldsWithDefaults() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AutoCaptureConfig.self, from: json)
        let defaults = AutoCaptureConfig()
        #expect(decoded.enabled == defaults.enabled)
        #expect(decoded.startDelaySeconds == defaults.startDelaySeconds)
        #expect(decoded.requireCalendarMatch == defaults.requireCalendarMatch)
        #expect(decoded.disableDuringFocus == defaults.disableDuringFocus)
        #expect(decoded.allowedAppBundleIDs == defaults.allowedAppBundleIDs)
    }

    @Test("AutoCaptureConfig round-trips through Codable with snake_case keys")
    func configRoundTrip() throws {
        var config = AutoCaptureConfig(
            enabled: true,
            allowedAppBundleIDs: ["us.zoom.xos", "com.microsoft.teams2"],
            acknowledgedAppBundleIDs: ["us.zoom.xos"],
            startDelaySeconds: 7,
            requireCalendarMatch: true,
            disableDuringFocus: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode(config)
        let jsonString = String(data: encoded, encoding: .utf8) ?? ""
        #expect(jsonString.contains("\"start_delay_seconds\""))
        #expect(jsonString.contains("\"acknowledged_app_bundle_ids\""))
        #expect(jsonString.contains("\"require_calendar_match\""))
        #expect(!jsonString.contains("\"startDelaySeconds\""))

        let decoded = try JSONDecoder().decode(AutoCaptureConfig.self, from: encoded)
        config.startDelaySeconds = AutoCaptureConfig.clampedStartDelay(config.startDelaySeconds)
        #expect(decoded == config)
    }

    // MARK: - AutoCaptureState helpers

    @Test("state name strings cover every case")
    func stateNamesAreUnique() {
        let names: Set<String> = [
            AutoCaptureState.idle.name,
            AutoCaptureState.armed(bundleID: nil, appName: "x").name,
            AutoCaptureState.confirming(bundleID: nil, appName: "x").name,
            AutoCaptureState.awaitingUserConfirm(bundleID: nil, appName: "x").name,
            AutoCaptureState.recording(bundleID: nil, appName: "x").name,
        ]
        #expect(names.count == 5)
    }
}
