import SwiftUI

// MARK: - AutoCaptureSettingsView

/// Settings pane for Auto-Capture v0. Master toggle defaults to off; the rest
/// of the controls are disabled while the master toggle is off so the pane
/// communicates a single clear opt-in step.
struct AutoCaptureSettingsView: View {

    let appState: AppState
    let controller: MuesliController

    @State private var automationStatuses: [String: AutomationPermissionStatus] = [:]
    @State private var automationProbeTask: Task<Void, Never>?
    @State private var isRefreshingPWAs: Bool = false

    private static let controlWidth: CGFloat = 275
    private static let automationRefreshInterval: TimeInterval = 5

    private var config: AutoCaptureConfig {
        appState.config.autoCapture
    }

    private var browserUrlPolling: BrowserURLPollingConfig {
        config.browserUrlPolling
    }

    private var pwaConfig: PWAConfig {
        config.pwa
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
            masterSection
            behaviourSection
            allowedAppsSection
            browserUrlPollingSection
            pwaSection
            footerNotes
        }
        .onAppear {
            startAutomationProbe()
            // Kick a non-blocking refresh whenever the user opens the pane so
            // the list reflects PWAs added since the last app launch.
            triggerPWARefresh()
        }
        .onDisappear { stopAutomationProbe() }
    }

    // MARK: Master toggle

    private var masterSection: some View {
        sectionContainer("Auto-Capture") {
            settingsRow("Automatically start recordings") {
                Toggle("", isOn: Binding(
                    get: { config.enabled },
                    set: { newValue in update { $0.enabled = newValue } }
                ))
                .toggleStyle(.switch)
                .tint(MuesliTheme.accent)
                .labelsHidden()
            }
            Divider().background(MuesliTheme.surfaceBorder)
            descriptionText(
                "When Muesli detects a meeting in one of the apps below, recording starts after the configured delay. The first detection from each app asks for permission."
            )
        }
    }

    // MARK: Behaviour

    private var behaviourSection: some View {
        sectionContainer("Behaviour") {
            settingsRow("Start delay") {
                HStack(spacing: 12) {
                    Slider(
                        value: Binding(
                            get: { config.startDelaySeconds },
                            set: { newValue in
                                update { $0.startDelaySeconds = AutoCaptureConfig.clampedStartDelay(newValue) }
                            }
                        ),
                        in: AutoCaptureConfig.minStartDelaySeconds...AutoCaptureConfig.maxStartDelaySeconds,
                        step: 1
                    )
                    .disabled(!config.enabled)
                    Text("\(Int(config.startDelaySeconds))s")
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Require calendar match") {
                Toggle("", isOn: Binding(
                    get: { config.requireCalendarMatch },
                    set: { newValue in update { $0.requireCalendarMatch = newValue } }
                ))
                .toggleStyle(.switch)
                .tint(MuesliTheme.accent)
                .labelsHidden()
                .disabled(!config.enabled)
            }
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Pause during Focus / Do Not Disturb") {
                Toggle("", isOn: Binding(
                    get: { config.disableDuringFocus },
                    set: { newValue in update { $0.disableDuringFocus = newValue } }
                ))
                .toggleStyle(.switch)
                .tint(MuesliTheme.accent)
                .labelsHidden()
                .disabled(!config.enabled)
            }
        }
    }

    // MARK: Per-app list

    private var allowedAppsSection: some View {
        sectionContainer("Apps") {
            descriptionText("Auto-capture only runs for the apps you allow here.")
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
            ], alignment: .leading, spacing: 8) {
                ForEach(AutoCaptureAppCatalog.options) { option in
                    appToggleButton(option)
                }
            }
            .padding(.top, 4)
        }
    }

    private func appToggleButton(_ option: AutoCaptureAppCatalog.Option) -> some View {
        let enabled = config.allowedAppBundleIDs.contains(option.bundleID)
        return Button {
            update { current in
                if current.allowedAppBundleIDs.contains(option.bundleID) {
                    current.allowedAppBundleIDs.remove(option.bundleID)
                } else {
                    current.allowedAppBundleIDs.insert(option.bundleID)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: enabled ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(enabled ? MuesliTheme.accent : MuesliTheme.textTertiary)
                    .frame(width: 16)
                Image(systemName: option.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(width: 14)
                Text(option.name)
                    .font(.system(size: 12))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(MuesliTheme.backgroundBase)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
        .buttonStyle(.plain)
        .disabled(!config.enabled)
    }

    // MARK: Browser URL polling (v1)

    private var browserUrlPollingSection: some View {
        sectionContainer("Browser URL polling (v1)") {
            descriptionText(
                "Detect meetings hosted in browser tabs by reading the active tab's URL via AppleScript. Polling only runs while the browser is using the microphone."
            )
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
            ], alignment: .leading, spacing: 8) {
                browserPollingToggle(
                    bundleID: BrowserURLPollingConfig.chromeBundleID,
                    label: "Chrome",
                    isOn: Binding(
                        get: { browserUrlPolling.chrome },
                        set: { newValue in update { $0.browserUrlPolling.chrome = newValue } }
                    )
                )
                browserPollingToggle(
                    bundleID: BrowserURLPollingConfig.edgeBundleID,
                    label: "Edge",
                    isOn: Binding(
                        get: { browserUrlPolling.edge },
                        set: { newValue in update { $0.browserUrlPolling.edge = newValue } }
                    )
                )
                browserPollingToggle(
                    bundleID: BrowserURLPollingConfig.braveBundleID,
                    label: "Brave",
                    isOn: Binding(
                        get: { browserUrlPolling.brave },
                        set: { newValue in update { $0.browserUrlPolling.brave = newValue } }
                    )
                )
                browserPollingToggle(
                    bundleID: BrowserURLPollingConfig.arcBundleID,
                    label: "Arc",
                    isOn: Binding(
                        get: { browserUrlPolling.arc },
                        set: { newValue in update { $0.browserUrlPolling.arc = newValue } }
                    )
                )
                browserPollingToggle(
                    bundleID: BrowserURLPollingConfig.safariBundleID,
                    label: "Safari",
                    isOn: Binding(
                        get: { browserUrlPolling.safari },
                        set: { newValue in update { $0.browserUrlPolling.safari = newValue } }
                    )
                )
            }
            .padding(.top, 4)
            .disabled(!config.enabled)
            automationDeniedBanner
        }
    }

    private func browserPollingToggle(bundleID: String, label: String, isOn: Binding<Bool>) -> some View {
        let denied = automationStatuses[bundleID] == .denied
        return Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isOn.wrappedValue ? MuesliTheme.accent : MuesliTheme.textTertiary)
                    .frame(width: 16)
                Image(systemName: "globe")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .lineLimit(1)
                if denied {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MuesliTheme.recording)
                        .accessibilityLabel("Automation permission denied")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(MuesliTheme.backgroundBase)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var automationDeniedBanner: some View {
        if anyAutomationDeniedForEnabledBrowsers {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(MuesliTheme.recording)
                    Text("Automation permission denied")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                }
                Text("macOS denied Muesli permission to read URLs from one or more enabled browsers. Open System Settings → Privacy & Security → Automation to grant access. Until granted, browser URL polling stays inert for the denied browsers.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                Button("Open Automation Settings") {
                    openAutomationSettings()
                }
                .buttonStyle(.link)
                .font(MuesliTheme.caption())
            }
            .padding(MuesliTheme.spacing12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MuesliTheme.recording.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.recording.opacity(0.35), lineWidth: 1)
            )
            .padding(.top, MuesliTheme.spacing8)
        }
    }

    private var anyAutomationDeniedForEnabledBrowsers: Bool {
        for bundleID in BrowserURLPollingConfig.supportedBundleIDs {
            guard browserUrlPolling.isEnabled(forBundleID: bundleID) else { continue }
            if automationStatuses[bundleID] == .denied { return true }
        }
        return false
    }

    private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startAutomationProbe() {
        refreshAutomationStatuses()
        automationProbeTask?.cancel()
        automationProbeTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.automationRefreshInterval * 1_000_000_000))
                if Task.isCancelled { return }
                refreshAutomationStatuses()
            }
        }
    }

    private func stopAutomationProbe() {
        automationProbeTask?.cancel()
        automationProbeTask = nil
    }

    private func refreshAutomationStatuses() {
        var statuses: [String: AutomationPermissionStatus] = [:]
        for bundleID in BrowserURLPollingConfig.supportedBundleIDs {
            statuses[bundleID] = AutomationPermissionProbe.status(forBundleID: bundleID)
        }
        automationStatuses = statuses
    }

    // MARK: PWAs (v2)

    private var pwaSection: some View {
        sectionContainer("PWAs (v2)") {
            HStack(alignment: .firstTextBaseline, spacing: MuesliTheme.spacing8) {
                Text("Installed Chrome PWAs and Safari Web Apps detected on this Mac.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                Spacer(minLength: MuesliTheme.spacing8)
                Button {
                    triggerPWARefresh()
                } label: {
                    HStack(spacing: 4) {
                        if isRefreshingPWAs {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        Text("Refresh")
                            .font(MuesliTheme.caption())
                    }
                }
                .buttonStyle(.link)
                .disabled(isRefreshingPWAs)
            }

            if pwaConfig.cachedEntries.isEmpty {
                Text("No installed PWAs found. Install one in Chrome or Safari (Safari → File → Add to Dock), then click Refresh.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .padding(.top, 6)
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                ], alignment: .leading, spacing: 8) {
                    ForEach(pwaConfig.cachedEntries) { entry in
                        pwaToggleButton(entry)
                    }
                }
                .padding(.top, 4)
                .disabled(!config.enabled)
            }
        }
    }

    private func pwaToggleButton(_ entry: PWAEntry) -> some View {
        let enabled = pwaConfig.isEnabled(bundleID: entry.bundleID)
        let sourceLabel: String = {
            switch entry.source {
            case .chrome: return "Chrome"
            case .safari: return "Safari"
            }
        }()
        return Button {
            update { current in
                let nextEnabled = !current.pwa.isEnabled(bundleID: entry.bundleID)
                current.pwa.enabled[entry.bundleID] = nextEnabled
                if nextEnabled {
                    current.allowedAppBundleIDs.insert(entry.bundleID)
                } else {
                    current.allowedAppBundleIDs.remove(entry.bundleID)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: enabled ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(enabled ? MuesliTheme.accent : MuesliTheme.textTertiary)
                    .frame(width: 16)
                Image(systemName: "app.dashed")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayName)
                        .font(.system(size: 12))
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .lineLimit(1)
                    Text(sourceLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(MuesliTheme.backgroundBase)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
        .buttonStyle(.plain)
        .help(entry.startURL ?? entry.bundleID)
    }

    private func triggerPWARefresh() {
        guard !isRefreshingPWAs else { return }
        isRefreshingPWAs = true
        controller.refreshDiscoveredPWAs { [self] in
            isRefreshingPWAs = false
        }
    }

    private var footerNotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Auto-capture is local-only. It calls the same start-recording path you use manually; no audio leaves this Mac for detection.")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
            if !config.acknowledgedAppBundleIDs.isEmpty {
                Text("Acknowledged apps: \(config.acknowledgedAppBundleIDs.sorted().joined(separator: ", "))")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                Button("Reset first-run prompts") {
                    update { $0.acknowledgedAppBundleIDs.removeAll() }
                }
                .buttonStyle(.link)
                .font(MuesliTheme.caption())
                .disabled(!config.enabled)
            }
        }
        .padding(.horizontal, MuesliTheme.spacing16)
    }

    // MARK: Layout helpers

    private func sectionContainer<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MuesliTheme.textTertiary)
                .textCase(.uppercase)
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(MuesliTheme.spacing16)
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
    }

    private func settingsRow<Control: View>(
        _ label: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center) {
            Text(label)
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)
                .layoutPriority(1)
            Spacer(minLength: 20)
            ZStack(alignment: .trailing) {
                Color.clear.frame(width: Self.controlWidth, height: 1)
                control()
                    .frame(maxWidth: Self.controlWidth)
            }
        }
        .frame(minHeight: 32)
    }

    private func descriptionText(_ text: String) -> some View {
        Text(text)
            .font(MuesliTheme.caption())
            .foregroundStyle(MuesliTheme.textTertiary)
            .padding(.top, 4)
    }

    // MARK: Mutation

    private func update(_ mutate: (inout AutoCaptureConfig) -> Void) {
        controller.updateConfig { config in
            var next = config.autoCapture
            mutate(&next)
            config.autoCapture = next
        }
    }
}

// MARK: - AutoCaptureAppCatalog

/// Static catalog of apps surfaced in the Auto-Capture per-app list. Mirrors
/// the bundle IDs that `MeetingDetector` recognises today. Kept local to the
/// AutoCapture module so adding a row here cannot accidentally change
/// detection behaviour.
enum AutoCaptureAppCatalog {
    struct Option: Identifiable {
        let bundleID: String
        let name: String
        let icon: String

        var id: String { bundleID }
    }

    static let options: [Option] = [
        Option(bundleID: "us.zoom.xos", name: "Zoom", icon: "video.fill"),
        Option(bundleID: "com.microsoft.teams2", name: "Teams", icon: "person.2.fill"),
        Option(bundleID: "com.apple.FaceTime", name: "FaceTime", icon: "video.fill"),
        Option(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", icon: "message.fill"),
        Option(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", icon: "phone.fill"),
        Option(bundleID: "com.webex.meetingmanager", name: "Webex", icon: "video.fill"),
        Option(bundleID: "com.google.Chrome", name: "Chrome", icon: "globe"),
        Option(bundleID: "company.thebrowser.Browser", name: "Arc", icon: "globe"),
        Option(bundleID: "com.apple.Safari", name: "Safari", icon: "globe"),
        Option(bundleID: "com.microsoft.edgemac", name: "Edge", icon: "globe"),
        Option(bundleID: "com.brave.Browser", name: "Brave", icon: "globe"),
    ]
}
