import CoreAudio
import Foundation
import os

// MARK: - BrowserMicReleaseMonitoring

/// Stop-detection surface consumed by `AutoCaptureCoordinator`. Watches one
/// browser-family bundle at a time; emits `onCallEnded(bundleID:)` after the
/// browser has held no input device for `graceSeconds` (default 8). See
/// ADR 0009 for the rationale and known false-negatives.
@MainActor
protocol BrowserMicReleaseMonitoring: AnyObject {
    func beginWatching(bundleID: String)
    func stopWatching()
}

// MARK: - ListenerInstaller

/// Pluggable surface for the CoreAudio HAL listener install/remove calls.
/// Tests substitute a fake that drives the listener callback synchronously;
/// production wires through `AudioObjectAddPropertyListenerBlock` on a
/// dedicated dispatch queue.
struct ListenerInstaller {
    /// Install a listener on `(kAudioProcessPropertyIsRunningInput, global, main)`
    /// for the supplied per-process AudioObject. `onChange` is invoked on an
    /// arbitrary queue every time the property fires. Returns a token the
    /// caller must hand back to `removeListener`. Returns `nil` if installation
    /// failed.
    let installProcessIsRunningInputListener: (AudioObjectID, @escaping () -> Void) -> Any?

    /// Install a listener on `(kAudioHardwarePropertyProcessObjectList, global,
    /// main)` of `kAudioObjectSystemObject`. Used to reattach when a tracked
    /// process AudioObject is recreated (process restart, new helper spawn).
    let installProcessObjectListListener: (@escaping () -> Void) -> Any?

    /// Remove a previously-installed listener token. Must accept tokens
    /// returned by either install function above. Idempotent.
    let removeListener: (Any) -> Void

    /// Translate a Unix PID to a per-process AudioObject (macOS 14.2+).
    /// Returns `kAudioObjectUnknown` if the translation failed.
    let translatePIDToProcessObject: (pid_t) -> AudioObjectID

    /// Production installer using `AudioObjectAddPropertyListenerBlock`.
    static let production: ListenerInstaller = ListenerInstaller(
        installProcessIsRunningInputListener: { processObject, onChange in
            BrowserMicReleaseMonitorBackend.shared.installProcessIsRunningInputListener(processObject, onChange)
        },
        installProcessObjectListListener: { onChange in
            BrowserMicReleaseMonitorBackend.shared.installProcessObjectListListener(onChange)
        },
        removeListener: { token in
            BrowserMicReleaseMonitorBackend.shared.removeListener(token)
        },
        translatePIDToProcessObject: { pid in
            BrowserMicReleaseMonitorBackend.shared.translatePIDToProcessObject(pid)
        }
    )
}

// MARK: - BrowserMicReleaseMonitor

@MainActor
final class BrowserMicReleaseMonitor: BrowserMicReleaseMonitoring {

    typealias AttributionProvider = () -> [AudioProcessActivity]
    typealias SleepFunction = (Double) async -> Void
    typealias CallEndedHandler = @MainActor (_ bundleID: String) -> Void

    private let attributionProvider: AttributionProvider
    private let graceSeconds: Double
    private let listenerInstaller: ListenerInstaller
    private let sleepFn: SleepFunction
    private let logger: Logger
    private let onCallEnded: CallEndedHandler

    private struct WatchedBundle {
        /// The bundle the *caller* asked us to watch. May be a PWA bundle.
        let requestedBundleID: String
        /// The HAL-layer parent bundle. Listeners are installed against this.
        let parentBundleID: String
        var tokens: [Any] = []
        var debounceTask: Task<Void, Never>?
    }

    private var watched: WatchedBundle?

    init(
        attributionProvider: @escaping AttributionProvider = { AudioProcessAttributionCollector().activeInputProcesses() },
        graceSeconds: Double = 8,
        listenerInstaller: ListenerInstaller = .production,
        sleep: @escaping SleepFunction = { seconds in
            let nanos = UInt64(max(0, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
        },
        logger: Logger = Logger(subsystem: "com.muesli.native", category: "AutoCapture.BrowserMicRelease"),
        onCallEnded: @escaping CallEndedHandler
    ) {
        self.attributionProvider = attributionProvider
        self.graceSeconds = graceSeconds
        self.listenerInstaller = listenerInstaller
        self.sleepFn = sleep
        self.logger = logger
        self.onCallEnded = onCallEnded
    }

    // MARK: BrowserMicReleaseMonitoring

    func beginWatching(bundleID: String) {
        guard !bundleID.isEmpty else { return }
        let parentBundleID = Self.parentBrowserBundleID(for: bundleID)

        if let existing = watched, existing.requestedBundleID == bundleID { return }
        if watched != nil { stopWatching() }

        var entry = WatchedBundle(requestedBundleID: bundleID, parentBundleID: parentBundleID)
        installListeners(into: &entry)
        watched = entry
        logger.notice(
            "browser_mic_release watch_started requested=\(bundleID, privacy: .public) parent=\(parentBundleID, privacy: .public) tokens=\(entry.tokens.count, privacy: .public)"
        )
    }

    func stopWatching() {
        guard var entry = watched else { return }
        watched = nil
        entry.debounceTask?.cancel()
        entry.debounceTask = nil
        for token in entry.tokens {
            listenerInstaller.removeListener(token)
        }
        entry.tokens.removeAll()
        logger.notice("browser_mic_release watch_stopped bundle=\(entry.requestedBundleID, privacy: .public)")
    }

    // MARK: Listener wiring

    private func installListeners(into entry: inout WatchedBundle) {
        let parent = entry.parentBundleID
        let snapshot = attributionProvider()
        let pids = snapshot.compactMap { activity -> pid_t? in
            activity.bundleID == parent && activity.isRunningInput ? activity.pid : nil
        }
        for pid in pids {
            let processObject = listenerInstaller.translatePIDToProcessObject(pid)
            guard processObject != AudioObjectID(kAudioObjectUnknown) else { continue }
            if let token = listenerInstaller.installProcessIsRunningInputListener(processObject, { [weak self] in
                Task { @MainActor in
                    self?.handleProcessChange()
                }
            }) {
                entry.tokens.append(token)
            }
        }

        // Always install the global process-object-list listener so a process
        // restart or a newly-spawned browser helper is picked up.
        if let token = listenerInstaller.installProcessObjectListListener({ [weak self] in
            Task { @MainActor in
                self?.handleProcessChange()
            }
        }) {
            entry.tokens.append(token)
        }
    }

    private func handleProcessChange() {
        guard var entry = watched else { return }
        let parent = entry.parentBundleID
        let snapshot = attributionProvider()
        let parentStillActive = snapshot.contains { activity in
            activity.bundleID == parent && activity.isRunningInput
        }
        if parentStillActive {
            // Mic still held — cancel any pending debounce.
            entry.debounceTask?.cancel()
            entry.debounceTask = nil
            watched = entry
            return
        }
        // Mic absent. If we already have a debounce in flight, leave it.
        if entry.debounceTask != nil { return }

        let requested = entry.requestedBundleID
        let grace = graceSeconds
        entry.debounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sleepFn(grace)
            if Task.isCancelled { return }
            self.debounceElapsed(forRequested: requested)
        }
        watched = entry
        logger.notice(
            "browser_mic_release debounce_started bundle=\(requested, privacy: .public) seconds=\(grace, privacy: .public)"
        )
    }

    private func debounceElapsed(forRequested requestedBundleID: String) {
        guard var entry = watched, entry.requestedBundleID == requestedBundleID else { return }
        entry.debounceTask = nil
        watched = entry

        let parent = entry.parentBundleID
        let snapshot = attributionProvider()
        let parentStillActive = snapshot.contains { activity in
            activity.bundleID == parent && activity.isRunningInput
        }
        if parentStillActive {
            logger.notice(
                "browser_mic_release debounce_aborted bundle=\(requestedBundleID, privacy: .public) reason=parent_reacquired_mic"
            )
            return
        }

        logger.notice(
            "browser_mic_release call_ended bundle=\(requestedBundleID, privacy: .public) parent=\(parent, privacy: .public)"
        )
        onCallEnded(requestedBundleID)
    }
}

// MARK: - PWA → parent browser mapping

extension BrowserMicReleaseMonitor {
    /// Maps a PWA bundle ID back to its parent browser bundle. Returns the
    /// input unchanged for non-PWA bundle IDs. PWAs at the CoreAudio HAL layer
    /// report the *parent* browser's bundle, so any mic-release watcher must
    /// subscribe to the parent — not the PWA — process object. (See ADR 0009.)
    static func parentBrowserBundleID(for bundleID: String) -> String {
        if bundleID.hasPrefix("com.apple.Safari.WebApp.") { return "com.apple.Safari" }
        if bundleID.hasPrefix("com.google.Chrome.app.") { return "com.google.Chrome" }
        if bundleID.hasPrefix("com.microsoft.edgemac.app.") { return "com.microsoft.edgemac" }
        if bundleID.hasPrefix("com.brave.Browser.app.") { return "com.brave.Browser" }
        if bundleID.hasPrefix("company.thebrowser.Browser.app.") { return "company.thebrowser.Browser" }
        return bundleID
    }

    /// Browser bundle families v2.1 will auto-stop. PWAs map to one of these
    /// via `parentBrowserBundleID(for:)`.
    static let browserBundlesEligibleForAutoStop: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",
    ]

    /// True if v2.1 auto-stop should arm for the supplied bundle ID — either
    /// the bundle itself is one of the eligible browser families, or it is a
    /// PWA whose parent is one of those families.
    static func isEligibleForAutoStop(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        let parent = parentBrowserBundleID(for: bundleID)
        return browserBundlesEligibleForAutoStop.contains(parent)
    }
}

// MARK: - Production CoreAudio backend

/// Thin wrapper around `AudioObjectAddPropertyListenerBlock` /
/// `AudioObjectRemovePropertyListenerBlock`. All blocks fire on a dedicated
/// dispatch queue; the consumer is expected to hop to MainActor inside the
/// closure it hands us.
private final class BrowserMicReleaseMonitorBackend {
    static let shared = BrowserMicReleaseMonitorBackend()

    private let queue = DispatchQueue(label: "com.muesli.native.browser-mic")

    private final class Token {
        let objectID: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock

        init(objectID: AudioObjectID, address: AudioObjectPropertyAddress, block: @escaping AudioObjectPropertyListenerBlock) {
            self.objectID = objectID
            self.address = address
            self.block = block
        }
    }

    func installProcessIsRunningInputListener(_ processObject: AudioObjectID, _ onChange: @escaping () -> Void) -> Any? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        let status = AudioObjectAddPropertyListenerBlock(processObject, &address, queue, block)
        guard status == noErr else { return nil }
        return Token(objectID: processObject, address: address, block: block)
    }

    func installProcessObjectListListener(_ onChange: @escaping () -> Void) -> Any? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )
        guard status == noErr else { return nil }
        return Token(objectID: AudioObjectID(kAudioObjectSystemObject), address: address, block: block)
    }

    func removeListener(_ token: Any) {
        guard let token = token as? Token else { return }
        var address = token.address
        _ = AudioObjectRemovePropertyListenerBlock(token.objectID, &address, queue, token.block)
    }

    func translatePIDToProcessObject(_ pid: pid_t) -> AudioObjectID {
        var pid = pid
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &dataSize,
            &processObject
        )
        guard status == noErr else { return AudioObjectID(kAudioObjectUnknown) }
        return processObject
    }
}
