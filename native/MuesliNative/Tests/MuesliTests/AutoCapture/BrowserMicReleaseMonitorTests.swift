import CoreAudio
import Foundation
import Testing
@testable import MuesliNativeApp

// MARK: - Fakes

@MainActor
private final class FakeListenerStore {
    struct Token: Equatable {
        let id: UUID = UUID()
        let kind: Kind
        enum Kind: Equatable {
            case processIsRunningInput(AudioObjectID)
            case processObjectList
        }
    }

    /// PID → process AudioObject ID. Production calls the HAL via
    /// `kAudioHardwarePropertyTranslatePIDToProcessObject`; the fake just looks
    /// the value up.
    var pidToProcessObject: [pid_t: AudioObjectID] = [:]

    /// Currently-installed listeners. Tests inspect this to assert that
    /// `stopWatching` removed everything.
    private(set) var installed: [UUID: (Token, () -> Void)] = [:]

    /// True if a global process-object-list listener is currently installed.
    var hasProcessObjectListListener: Bool {
        installed.values.contains { $0.0.kind == .processObjectList }
    }

    /// Number of per-process IsRunningInput listeners installed.
    var perProcessListenerCount: Int {
        installed.values.filter { token, _ in
            if case .processIsRunningInput = token.kind { return true }
            return false
        }.count
    }

    func installer() -> ListenerInstaller {
        ListenerInstaller(
            installProcessIsRunningInputListener: { [weak self] objectID, onChange in
                guard let self else { return nil }
                let token = Token(kind: .processIsRunningInput(objectID))
                self.installed[token.id] = (token, onChange)
                return token
            },
            installProcessObjectListListener: { [weak self] onChange in
                guard let self else { return nil }
                let token = Token(kind: .processObjectList)
                self.installed[token.id] = (token, onChange)
                return token
            },
            removeListener: { [weak self] anyToken in
                guard let self else { return }
                guard let token = anyToken as? Token else { return }
                self.installed.removeValue(forKey: token.id)
            },
            translatePIDToProcessObject: { [weak self] pid in
                self?.pidToProcessObject[pid] ?? AudioObjectID(kAudioObjectUnknown)
            }
        )
    }

    /// Fire every currently-installed listener (the monitor coalesces them
    /// internally so it's fine to call them all together — production gets the
    /// same effect when the HAL fires).
    func fireAllListeners() {
        let callbacks = installed.values.map { $0.1 }
        for callback in callbacks { callback() }
    }
}

@MainActor
private final class MonitorTestHarness {
    var attribution: [AudioProcessActivity] = []
    let store = FakeListenerStore()
    var endedBundles: [String] = []
    private var pendingSleeps: [CheckedContinuation<Void, Never>] = []
    private(set) var sleepInvocations: [Double] = []

    private(set) var monitor: BrowserMicReleaseMonitor!

    init(graceSeconds: Double = 8) {
        monitor = BrowserMicReleaseMonitor(
            attributionProvider: { [weak self] in self?.attribution ?? [] },
            graceSeconds: graceSeconds,
            listenerInstaller: store.installer(),
            sleep: { [weak self] seconds in
                self?.sleepInvocations.append(seconds)
                await withCheckedContinuation { continuation in
                    if let self {
                        self.pendingSleeps.append(continuation)
                    } else {
                        continuation.resume()
                    }
                }
            },
            onCallEnded: { [weak self] bundleID in
                self?.endedBundles.append(bundleID)
            }
        )
    }

    /// Release the next pending debounce sleep so the monitor can re-check.
    func releaseNextSleep() {
        guard !pendingSleeps.isEmpty else { return }
        pendingSleeps.removeFirst().resume()
    }

    /// Flush every pending sleep — useful at teardown so dangling tasks don't
    /// leak into the next test.
    func releaseAllSleeps() {
        let pending = pendingSleeps
        pendingSleeps.removeAll()
        pending.forEach { $0.resume() }
    }
}

private func activity(bundleID: String, pid: pid_t = 1234, isRunningInput: Bool = true) -> AudioProcessActivity {
    AudioProcessActivity(
        pid: pid,
        bundleID: bundleID,
        appName: bundleID,
        isRunningInput: isRunningInput,
        isRunningOutput: false,
        deviceIDs: []
    )
}

// MARK: - Tests

@Suite("BrowserMicReleaseMonitor")
@MainActor
struct BrowserMicReleaseMonitorTests {

    @Test("beginWatching installs per-process + global listeners for active parent bundle PIDs")
    func beginWatchingInstallsListeners() {
        let harness = MonitorTestHarness()
        harness.attribution = [
            activity(bundleID: "com.google.Chrome", pid: 11),
            activity(bundleID: "com.google.Chrome", pid: 12),
            activity(bundleID: "us.zoom.xos", pid: 99),
        ]
        harness.store.pidToProcessObject[11] = AudioObjectID(1011)
        harness.store.pidToProcessObject[12] = AudioObjectID(1012)

        harness.monitor.beginWatching(bundleID: "com.google.Chrome")

        #expect(harness.store.perProcessListenerCount == 2)
        #expect(harness.store.hasProcessObjectListListener)
    }

    @Test("parent still in input set after listener fires → no debounce + no callback")
    func parentStillActiveDoesNothing() async {
        let harness = MonitorTestHarness()
        harness.attribution = [activity(bundleID: "com.google.Chrome", pid: 11)]
        harness.store.pidToProcessObject[11] = AudioObjectID(1011)
        harness.monitor.beginWatching(bundleID: "com.google.Chrome")

        harness.store.fireAllListeners()
        await Task.yield()
        await Task.yield()
        await Task.yield()

        #expect(harness.endedBundles.isEmpty)
        #expect(harness.sleepInvocations.isEmpty)
    }

    @Test("parent drops out → debounce elapses → re-check confirms absent → onCallEnded fires once")
    func micReleaseFiresCallback() async {
        let harness = MonitorTestHarness()
        harness.attribution = [activity(bundleID: "com.google.Chrome", pid: 11)]
        harness.store.pidToProcessObject[11] = AudioObjectID(1011)
        harness.monitor.beginWatching(bundleID: "com.google.Chrome")

        // Mic released.
        harness.attribution = []
        harness.store.fireAllListeners()
        for _ in 0..<4 { await Task.yield() }

        #expect(harness.sleepInvocations == [8])

        // Release the debounce sleep so the monitor re-checks attribution.
        harness.releaseNextSleep()
        for _ in 0..<6 { await Task.yield() }

        #expect(harness.endedBundles == ["com.google.Chrome"])

        // Subsequent listener fires must not re-emit because watched bundle is
        // unchanged but parent is still absent — the monitor only fires once
        // per beginWatching/stopWatching cycle and any later fire would not
        // restart the debounce because debounceTask is consumed.
    }

    @Test("parent reappears during debounce → no callback")
    func micReacquiredDuringDebounce() async {
        let harness = MonitorTestHarness()
        harness.attribution = [activity(bundleID: "com.google.Chrome", pid: 11)]
        harness.store.pidToProcessObject[11] = AudioObjectID(1011)
        harness.monitor.beginWatching(bundleID: "com.google.Chrome")

        harness.attribution = []
        harness.store.fireAllListeners()
        for _ in 0..<4 { await Task.yield() }
        #expect(harness.sleepInvocations == [8])

        // Mic reappears (e.g., user briefly un-muted, AirPods swap finished).
        harness.attribution = [activity(bundleID: "com.google.Chrome", pid: 11)]
        harness.store.fireAllListeners()
        for _ in 0..<4 { await Task.yield() }

        // The reacquire fired its own listener callback while the debounce
        // was still suspended. Release the debounce so the re-check runs.
        harness.releaseNextSleep()
        for _ in 0..<6 { await Task.yield() }

        #expect(harness.endedBundles.isEmpty)
        harness.releaseAllSleeps()
    }

    @Test("stopWatching cancels in-flight debounce + removes all listeners")
    func stopWatchingCancelsDebounce() async {
        let harness = MonitorTestHarness()
        harness.attribution = [activity(bundleID: "com.google.Chrome", pid: 11)]
        harness.store.pidToProcessObject[11] = AudioObjectID(1011)
        harness.monitor.beginWatching(bundleID: "com.google.Chrome")

        harness.attribution = []
        harness.store.fireAllListeners()
        for _ in 0..<4 { await Task.yield() }
        #expect(harness.sleepInvocations == [8])

        harness.monitor.stopWatching()
        #expect(harness.store.installed.isEmpty)

        // Even if the debounce sleep resolves, the cancelled task should be a
        // no-op because Task.isCancelled is checked and watched is nil.
        harness.releaseNextSleep()
        for _ in 0..<6 { await Task.yield() }
        #expect(harness.endedBundles.isEmpty)
    }

    // MARK: PWA → parent mapping

    @Test("PWA bundle resolves to parent before installing listeners")
    func pwaResolvesToParent() {
        let harness = MonitorTestHarness()
        harness.attribution = [
            activity(bundleID: "com.google.Chrome", pid: 11),
            activity(bundleID: "com.apple.Safari", pid: 22),
        ]
        harness.store.pidToProcessObject[11] = AudioObjectID(1011)
        harness.store.pidToProcessObject[22] = AudioObjectID(1022)

        harness.monitor.beginWatching(bundleID: "com.google.Chrome.app.abcdef0123456789abcdef0123456789")

        // Only the Chrome PID (matching the resolved parent) should have a
        // per-process listener installed.
        #expect(harness.store.perProcessListenerCount == 1)
        #expect(harness.store.hasProcessObjectListListener)
    }

    @Test("parentBrowserBundleID maps known PWA prefixes back to browser families")
    func parentBrowserBundleIDMapsKnownPrefixes() {
        let cases: [(input: String, expected: String)] = [
            ("com.apple.Safari.WebApp.ABC", "com.apple.Safari"),
            ("com.google.Chrome.app.deadbeef", "com.google.Chrome"),
            ("com.microsoft.edgemac.app.feedface", "com.microsoft.edgemac"),
            ("com.brave.Browser.app.cafe", "com.brave.Browser"),
            ("company.thebrowser.Browser.app.beef", "company.thebrowser.Browser"),
            ("us.zoom.xos", "us.zoom.xos"),
            ("com.google.Chrome", "com.google.Chrome"),
        ]
        for testCase in cases {
            #expect(BrowserMicReleaseMonitor.parentBrowserBundleID(for: testCase.input) == testCase.expected)
        }
    }

    @Test("isEligibleForAutoStop covers browsers and PWA prefixes")
    func isEligibleCoversBrowsersAndPWAs() {
        #expect(BrowserMicReleaseMonitor.isEligibleForAutoStop(bundleID: "com.google.Chrome"))
        #expect(BrowserMicReleaseMonitor.isEligibleForAutoStop(bundleID: "com.apple.Safari.WebApp.xyz"))
        #expect(BrowserMicReleaseMonitor.isEligibleForAutoStop(bundleID: "company.thebrowser.Browser"))
        #expect(!BrowserMicReleaseMonitor.isEligibleForAutoStop(bundleID: "us.zoom.xos"))
        #expect(!BrowserMicReleaseMonitor.isEligibleForAutoStop(bundleID: nil))
        #expect(!BrowserMicReleaseMonitor.isEligibleForAutoStop(bundleID: ""))
    }
}
