import SwiftUI
import MuesliCore

struct SettingsView: View {
    private enum PendingDataDestruction {
        case dictations
        case meetings

        var title: String {
            switch self {
            case .dictations:
                return "Clear dictation history?"
            case .meetings:
                return "Clear meeting history?"
            }
        }

        var message: String {
            switch self {
            case .dictations:
                return "This will permanently remove all saved dictations. This cannot be undone."
            case .meetings:
                return "This will permanently remove all saved meetings, notes, transcripts, and retained audio recordings. This cannot be undone."
            }
        }

        var confirmLabel: String {
            switch self {
            case .dictations:
                return "Clear Dictations"
            case .meetings:
                return "Clear Meetings"
            }
        }
    }

    let appState: AppState
    let controller: MuesliController

    @State private var chatGPTSignInError: String?
    @State private var isSigningInChatGPT = false
    @State private var googleCalSignInError: String?
    @State private var isSigningInGoogleCal = false
    @State private var pendingDataDestruction: PendingDataDestruction?
    @State private var recordingColorInput: String = ""
    @State private var isPreviewingClip = false
    @State private var availableBackendOptions: [BackendOption] = []
    @State private var downloadedPostProcOptions: [PostProcessorOption] = []

    // Uniform width for all right-side controls
    private let controlWidth: CGFloat = 220

    private var displayedBackendOptions: [BackendOption] {
        availableBackendOptions.isEmpty ? [appState.selectedBackend] : availableBackendOptions
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                Text("Settings")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)

                settingsSection("General") {
                    settingsRow("Launch at login") {
                        settingsSwitch(isOn: appState.config.launchAtLogin) { newValue in
                            controller.updateConfig { $0.launchAtLogin = newValue }
                        }
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Open dashboard on launch") {
                        settingsSwitch(isOn: appState.config.openDashboardOnLaunch) { newValue in
                            controller.updateConfig { $0.openDashboardOnLaunch = newValue }
                        }
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Show floating indicator") {
                        settingsSwitch(isOn: appState.config.showFloatingIndicator) { newValue in
                            controller.updateConfig { $0.showFloatingIndicator = newValue }
                            controller.refreshIndicatorVisibility()
                        }
                    }
                }

                settingsSection("Transcription") {
                    settingsRow("Backend") {
                        settingsMenu(
                            selection: appState.selectedBackend.label,
                            options: displayedBackendOptions.map(\.label)
                        ) { label in
                            if let option = displayedBackendOptions.first(where: { $0.label == label }) {
                                controller.selectBackend(option)
                            }
                        }
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("AI transcript cleanup") {
                        settingsSwitch(isOn: appState.config.enablePostProcessor) { newValue in
                            controller.setPostProcessorEnabled(newValue)
                        }
                    }
                    if appState.config.enablePostProcessor && !downloadedPostProcOptions.isEmpty {
                        Divider().background(MuesliTheme.surfaceBorder)
                        settingsRow("Cleanup model") {
                            let selection = downloadedPostProcOptions.contains(where: { $0.id == appState.activePostProcessor.id })
                                ? appState.activePostProcessor.label
                                : (downloadedPostProcOptions.first?.label ?? "")
                            settingsMenu(
                                selection: selection,
                                options: downloadedPostProcOptions.map(\.label)
                            ) { label in
                                if let option = downloadedPostProcOptions.first(where: { $0.label == label }) {
                                    controller.selectPostProcessor(option)
                                }
                            }
                        }
                    } else if appState.config.enablePostProcessor {
                        Divider().background(MuesliTheme.surfaceBorder)
                        settingsRow("Cleanup model") {
                            Text("Download a cleanup model in Models")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(MuesliTheme.textTertiary)
                                .multilineTextAlignment(.trailing)
                                .frame(width: controlWidth, alignment: .trailing)
                        }
                    }
                }

                settingsSection("Context") {
                    settingsRow("Screen context") {
                        settingsSwitch(isOn: appState.config.enableScreenContext) { newValue in
                            controller.updateConfig { $0.enableScreenContext = newValue }
                        }
                    }
                    Text("Reads app name and nearby text via the Accessibility API to improve dictation formatting and meeting summaries. No screenshots. All processing stays on-device.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .padding(.horizontal, MuesliTheme.spacing16)
                }

                settingsSection("Meetings") {
                    settingsRow("Summary backend") {
                        settingsMenu(
                            selection: appState.selectedMeetingSummaryBackend.label,
                            options: MeetingSummaryBackendOption.all.map(\.label)
                        ) { label in
                            if let option = MeetingSummaryBackendOption.all.first(where: { $0.label == label }) {
                                controller.selectMeetingSummaryBackend(option)
                            }
                        }
                    }
                    Divider().background(MuesliTheme.surfaceBorder)

                    if appState.selectedMeetingSummaryBackend == .chatGPT {
                        settingsRow("Account") {
                            if appState.isChatGPTAuthenticated {
                                Button {
                                    controller.signOutChatGPT()
                                } label: {
                                    HStack(spacing: 5) {
                                        OpenAILogoShape()
                                            .fill(.white)
                                            .frame(width: 10, height: 10)
                                        Text("Signed in · Sign Out")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(MuesliTheme.success)
                                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                                }
                                .buttonStyle(.plain)
                            } else if isSigningInChatGPT {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Signing in...")
                                        .font(.system(size: 11))
                                        .foregroundStyle(MuesliTheme.textSecondary)
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 4) {
                                    Button {
                                        isSigningInChatGPT = true
                                        chatGPTSignInError = nil
                                        Task {
                                            let error = await controller.signInWithChatGPT()
                                            isSigningInChatGPT = false
                                            chatGPTSignInError = error
                                        }
                                    } label: {
                                        HStack(spacing: 5) {
                                            OpenAILogoShape()
                                                .fill(.white)
                                                .frame(width: 10, height: 10)
                                            Text("Sign in with ChatGPT")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(.white)
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(MuesliTheme.accent)
                                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                                    }
                                    .buttonStyle(.plain)

                                    if let chatGPTSignInError {
                                        Text(chatGPTSignInError)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.red)
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }
                        Divider().background(MuesliTheme.surfaceBorder)
                        settingsRow("Model") {
                            settingsModelMenu(
                                currentModel: appState.config.chatGPTModel,
                                presets: SummaryModelPreset.chatGPTModels
                            ) { val in controller.updateConfig { $0.chatGPTModel = val } }
                        }
                    } else if appState.selectedMeetingSummaryBackend == .openAI {
                        settingsRow("API Key") {
                            PastableSecureField(
                                text: appState.config.openAIAPIKey,
                                placeholder: "sk-...",
                                onChange: { val in controller.updateConfig { $0.openAIAPIKey = val } }
                            )
                            .frame(height: 22)
                        }
                        Divider().background(MuesliTheme.surfaceBorder)
                        settingsRow("Model") {
                            settingsModelMenu(
                                currentModel: appState.config.openAIModel,
                                presets: SummaryModelPreset.openAIModels
                            ) { val in controller.updateConfig { $0.openAIModel = val } }
                        }
                        keyStatusRow(key: appState.config.openAIAPIKey)
                    } else {
                        settingsRow("API Key") {
                            PastableSecureField(
                                text: appState.config.openRouterAPIKey,
                                placeholder: "sk-or-...",
                                onChange: { val in controller.updateConfig { $0.openRouterAPIKey = val } }
                            )
                            .frame(height: 22)
                        }
                        Divider().background(MuesliTheme.surfaceBorder)
                        settingsRow("Model") {
                            settingsModelMenu(
                                currentModel: appState.config.openRouterModel,
                                presets: SummaryModelPreset.openRouterModels
                            ) { val in controller.updateConfig { $0.openRouterModel = val } }
                        }
                        keyStatusRow(key: appState.config.openRouterAPIKey)
                    }

                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Default template") {
                        meetingTemplateMenu(selectionID: appState.config.defaultMeetingTemplateID) { id in
                            controller.updateDefaultMeetingTemplate(id: id)
                        }
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Templates") {
                        actionButton("Manage Templates…") {
                            controller.showMeetingTemplatesManager()
                        }
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Auto-record calendar meetings") {
                        settingsSwitch(isOn: appState.config.autoRecordMeetings) { newValue in
                            controller.updateConfig { $0.autoRecordMeetings = newValue }
                        }
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Notify when meeting detected") {
                        settingsSwitch(isOn: appState.config.showMeetingDetectionNotification) { newValue in
                            controller.updateConfig { $0.showMeetingDetectionNotification = newValue }
                        }
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Save meeting recording") {
                        settingsMenu(
                            selection: recordingSaveLabel(for: appState.config.meetingRecordingSavePolicy),
                            options: MeetingRecordingSavePolicy.allCases.map(recordingSaveLabel(for:))
                        ) { label in
                            guard let policy = recordingSavePolicy(for: label) else { return }
                            controller.updateConfig { $0.meetingRecordingSavePolicy = policy }
                        }
                    }
                }

                if appState.isGoogleCalendarAvailable {
                    settingsSection("Calendar") {
                        settingsRow("Google Calendar") {
                            if appState.isGoogleCalendarAuthenticated {
                                Button {
                                    controller.signOutGoogleCalendar()
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "calendar")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.white)
                                        Text("Connected · Disconnect")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(MuesliTheme.success)
                                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                                }
                                .buttonStyle(.plain)
                            } else if isSigningInGoogleCal {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Connecting...")
                                        .font(.system(size: 11))
                                        .foregroundStyle(MuesliTheme.textSecondary)
                                }
                            } else if !appState.isGoogleCalendarVerified {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 5) {
                                        Image(systemName: "calendar.badge.plus")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.white.opacity(0.4))
                                        Text("Connect Google Calendar")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.4))
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(MuesliTheme.textTertiary.opacity(0.3))
                                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))

                                    Text("Google OAuth verification pending")
                                        .font(.system(size: 10))
                                        .foregroundStyle(MuesliTheme.textTertiary)
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 4) {
                                    Button {
                                        isSigningInGoogleCal = true
                                        googleCalSignInError = nil
                                        Task {
                                            let error = await controller.signInWithGoogleCalendar()
                                            isSigningInGoogleCal = false
                                            googleCalSignInError = error
                                        }
                                    } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: "calendar.badge.plus")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.white)
                                            Text("Connect Google Calendar")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(.white)
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(MuesliTheme.accent)
                                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                                    }
                                    .buttonStyle(.plain)

                                    if let googleCalSignInError {
                                        Text(googleCalSignInError)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.red)
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }
                    }
                }

                settingsSection("Appearance") {
                    settingsRow("Menu bar icon") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(MenuBarIconRenderer.options, id: \.id) { option in
                                    let isSelected = appState.config.menuBarIcon == option.id
                                    Button {
                                        controller.updateConfig { $0.menuBarIcon = option.id }
                                    } label: {
                                        Group {
                                            if option.id == "muesli",
                                               let img = MenuBarIconRenderer.make(choice: "muesli") {
                                                Image(nsImage: img)
                                                    .resizable()
                                                    .scaledToFit()
                                                    .frame(width: 14, height: 14)
                                            } else {
                                                Image(systemName: option.id)
                                                    .font(.system(size: 12))
                                            }
                                        }
                                        .foregroundStyle(isSelected ? MuesliTheme.accent : MuesliTheme.textSecondary)
                                        .frame(width: 26, height: 26)
                                        .background(
                                            RoundedRectangle(cornerRadius: 5)
                                                .fill(isSelected ? MuesliTheme.surfaceSelected : Color.clear)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 5)
                                                .strokeBorder(Color.white.opacity(isSelected ? 0.3 : 0.08), lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .help(option.label)
                                }
                            }
                        }
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Accent color") {
                        glassTintPicker
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Play sound effects") {
                        settingsSwitch(isOn: appState.config.soundEnabled) { newValue in
                            controller.updateConfig { $0.soundEnabled = newValue }
                        }
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Show next meeting in menu bar") {
                        settingsSwitch(isOn: appState.config.showNextMeetingInMenuBar) { newValue in
                            controller.updateConfig { $0.showNextMeetingInMenuBar = newValue }
                        }
                    }
                }

                if appState.config.maraudersMapUnlocked {
                    settingsSection("Marauder\u{2019}s Map") {
                        settingsRow("Meeting countdown audio") {
                            HStack(spacing: MuesliTheme.spacing8) {
                                settingsMenu(
                                    selection: SoundController.labelForClip(
                                        id: appState.config.maraudersMapAudioClip,
                                        customPath: appState.config.maraudersMapCustomAudioPath
                                    ),
                                    options: SoundController.maraudersMapClipLabels
                                ) { label in
                                    if label == "Custom\u{2026}" {
                                        pickCustomAudioFile()
                                    } else if let preset = SoundController.maraudersMapPresets
                                        .first(where: { $0.label == label }) {
                                        SoundController.stopMaraudersMapClip()
                                        isPreviewingClip = false
                                        controller.updateConfig {
                                            $0.maraudersMapAudioClip = preset.id
                                            $0.maraudersMapCustomAudioPath = nil
                                        }
                                        controller.updateMaraudersMapAudioClip()
                                    }
                                }
                                Button {
                                    if isPreviewingClip {
                                        SoundController.stopMaraudersMapClip()
                                        isPreviewingClip = false
                                    } else {
                                        SoundController.playMaraudersMapClip(
                                            id: appState.config.maraudersMapAudioClip,
                                            customPath: appState.config.maraudersMapCustomAudioPath
                                        ) {
                                            isPreviewingClip = false
                                        }
                                        isPreviewingClip = true
                                    }
                                } label: {
                                    Image(systemName: isPreviewingClip ? "stop.fill" : "play.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(MuesliTheme.textSecondary)
                                        .frame(width: 24, height: 24)
                                }
                                .buttonStyle(.plain)
                                .contentShape(Rectangle())
                            }
                        }
                        Divider().background(MuesliTheme.surfaceBorder)
                        settingsRow("") {
                            Button {
                                SoundController.stopMaraudersMapClip()
                                isPreviewingClip = false
                                controller.resetMaraudersMap()
                            } label: {
                                Text("Mischief Managed")
                                    .font(.system(size: 11))
                                    .foregroundColor(MuesliTheme.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onDisappear {
                        SoundController.stopMaraudersMapClip()
                        isPreviewingClip = false
                    }
                }

                settingsSection("Data") {
                    HStack(spacing: MuesliTheme.spacing12) {
                        actionButton("Clear dictation history", role: .destructive) {
                            pendingDataDestruction = .dictations
                        }
                        actionButton("Clear meeting history", role: .destructive) {
                            pendingDataDestruction = .meetings
                        }
                        .disabled(controller.isMeetingRecording())
                        .help("Stop the current meeting recording before clearing meeting history.")
                    }
                }
            }
            .padding(MuesliTheme.spacing32)
        }
        .background(MuesliTheme.backgroundBase)
        .onAppear {
            refreshDownloadedModelOptions()
        }
        .onChange(of: appState.selectedTab) { _, tab in
            if tab == .settings {
                refreshDownloadedModelOptions()
            }
        }
        .onChange(of: appState.selectedBackend) { _, _ in
            refreshAvailableBackendOptions()
        }
        .alert(
            pendingDataDestruction?.title ?? "Confirm Destructive Action",
            isPresented: Binding(
                get: { pendingDataDestruction != nil },
                set: { if !$0 { pendingDataDestruction = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingDataDestruction = nil
            }
            Button(pendingDataDestruction?.confirmLabel ?? "Delete", role: .destructive) {
                switch pendingDataDestruction {
                case .dictations:
                    controller.clearDictationHistory()
                case .meetings:
                    controller.clearMeetingHistory()
                case nil:
                    break
                }
                pendingDataDestruction = nil
            }
        } message: {
            Text(pendingDataDestruction?.message ?? "")
        }
    }

    private func refreshDownloadedModelOptions() {
        refreshAvailableBackendOptions()
        downloadedPostProcOptions = PostProcessorOption.downloaded
    }

    private func refreshAvailableBackendOptions() {
        var options = BackendOption.downloaded
        if !options.contains(where: { $0 == appState.selectedBackend }) {
            options.insert(appState.selectedBackend, at: 0)
        }
        availableBackendOptions = options
    }

    private static let accentPresets: [(hex: String, name: String)] = [
        ("2563eb", "Blue"),
        ("ef4444", "Red"),
        ("f59e0b", "Amber"),
        ("10b981", "Green"),
        ("8b5cf6", "Purple"),
        ("ec4899", "Pink"),
        ("1e1e2e", "Dark"),
    ]

    private var glassTintPicker: some View {
        HStack(spacing: 6) {
            ForEach(Self.accentPresets, id: \.hex) { preset in
                let isSelected = appState.config.recordingColorHex.lowercased() == preset.hex
                Button {
                    controller.updateConfig { $0.recordingColorHex = preset.hex }
                } label: {
                    Circle()
                        .fill(Color(hex: preset.hex))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle().strokeBorder(Color.white.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
                        )
                        .overlay(
                            Circle().strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help(preset.name)
            }
        }
    }

    // MARK: - Marauder's Map

    private func pickCustomAudioFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose an audio clip"
        panel.allowedContentTypes = [.mp3, .mpeg4Audio, .wav, .aiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let appSupportBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fputs("[muesli-native] Could not resolve Application Support directory\n", stderr)
            return
        }

        do {
            let supportDir = appSupportBase
                .appendingPathComponent(Bundle.main.infoDictionary?["MuesliSupportDirectoryName"] as? String ?? "Muesli")
            let destPath = try SoundController.importCustomClip(from: url, supportDir: supportDir)
            controller.updateConfig {
                $0.maraudersMapAudioClip = SoundController.customClipID
                $0.maraudersMapCustomAudioPath = destPath
            }
            controller.updateMaraudersMapAudioClip()
        } catch {
            fputs("[muesli-native] Failed to import custom audio: \(error)\n", stderr)
        }
    }

    // MARK: - Layout Primitives

    @ViewBuilder
    private func settingsSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
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

    /// Standardized row: label on left, control on right.
    /// Controls share a fixed-width column so they all right-align consistently.
    @ViewBuilder
    private func settingsRow(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(alignment: .center) {
            Text(label)
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)
                .layoutPriority(1)
            Spacer(minLength: 20)
            ZStack(alignment: .trailing) {
                // Invisible spacer forces the ZStack to exactly controlWidth
                Color.clear.frame(width: controlWidth, height: 1)
                control()
                    .frame(maxWidth: controlWidth)
            }
        }
        .frame(minHeight: 32)
    }

    // MARK: - Controls

    @ViewBuilder
    private func settingsSwitch(isOn: Bool, onChange: @escaping (Bool) -> Void) -> some View {
        HStack {
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: { onChange($0) }))
                .toggleStyle(.switch)
                .tint(MuesliTheme.accent)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private func settingsMenu(selection: String, options: [String], onChange: @escaping (String) -> Void) -> some View {
        FixedWidthPopUp(selection: selection, options: options, onChange: onChange)
            .frame(height: 24)
    }

    @ViewBuilder
    private func meetingTemplateMenu(selectionID: String, onChange: @escaping (String) -> Void) -> some View {
        let allItems: [(id: String, label: String)] = {
            var items: [(String, String)] = [(MeetingTemplates.autoID, MeetingTemplates.auto.title)]
            items += controller.builtInMeetingTemplates().map { ($0.id, $0.title) }
            items += controller.customMeetingTemplates().map { ($0.id, $0.name) }
            return items
        }()
        let selectedLabel = allItems.first(where: { $0.id == selectionID })?.label ?? "Auto"
        FixedWidthPopUp(
            selection: selectedLabel,
            options: allItems.map(\.label),
            onSelectIndex: { index in
                guard index >= 0 && index < allItems.count else { return }
                onChange(allItems[index].id)
            }
        )
        .frame(height: 24)
    }

    @ViewBuilder
    private func settingsModelMenu(currentModel: String, presets: [SummaryModelPreset], onChange: @escaping (String) -> Void) -> some View {
        let effectiveModel = currentModel.isEmpty ? (presets.first?.id ?? "") : currentModel
        let selectedLabel = presets.first(where: { $0.id == effectiveModel })?.label ?? presets.first?.label ?? ""
        FixedWidthPopUp(
            selection: selectedLabel,
            options: presets.map(\.label),
            onSelectIndex: { index in
                guard index >= 0 && index < presets.count else { return }
                let selectedId = presets[index].id
                onChange(selectedId == presets.first?.id ? "" : selectedId)
            }
        )
        .frame(height: 24)
    }

    @ViewBuilder
    private func keyStatusRow(key: String) -> some View {
        HStack(spacing: 6) {
            Spacer()
            Circle()
                .fill(key.isEmpty ? MuesliTheme.textTertiary : MuesliTheme.success)
                .frame(width: 6, height: 6)
            Text(key.isEmpty ? "No API key configured" : "Key configured")
                .font(.system(size: 11))
                .foregroundStyle(key.isEmpty ? MuesliTheme.textTertiary : MuesliTheme.success)
        }
        .frame(minHeight: 20)
    }

    @ViewBuilder
    private func actionButton(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        let isDestructive = role == .destructive
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isDestructive ? MuesliTheme.recording : MuesliTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, MuesliTheme.spacing16)
                .padding(.vertical, MuesliTheme.spacing8)
                .background(isDestructive ? MuesliTheme.recording.opacity(0.1) : MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(
                            isDestructive ? MuesliTheme.recording.opacity(0.2) : MuesliTheme.surfaceBorder,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private func recordingSaveLabel(for policy: MeetingRecordingSavePolicy) -> String {
        switch policy {
        case .never:
            return "Never"
        case .prompt:
            return "Ask every time"
        case .always:
            return "Always"
        }
    }

    private func recordingSavePolicy(for label: String) -> MeetingRecordingSavePolicy? {
        let policy = MeetingRecordingSavePolicy.allCases.first { recordingSaveLabel(for: $0) == label }
        if policy == nil {
            assertionFailure("Unexpected recording save label: \(label)")
        }
        return policy
    }
}

// MARK: - Pastable Secure Field (NSViewRepresentable)

/// NSSecureTextField subclass that handles Cmd+V/C/X/A without needing a standard Edit menu.
/// Required because the app runs as .accessory (no menu bar), so key equivalents
/// don't route to text fields by default.
class EditableNSSecureTextField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "v":
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
            case "c":
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
            case "x":
                if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
            case "a":
                if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self) { return true }
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// NSPopUpButton wrapper that respects width constraints (SwiftUI Picker with .menu style ignores them).
struct FixedWidthPopUp: NSViewRepresentable {
    let selection: String
    let options: [String]
    /// Reports the selected index, avoiding label collision issues.
    let onSelectionIndex: (Int) -> Void

    init(selection: String, options: [String], onChange: @escaping (String) -> Void) {
        self.selection = selection
        self.options = options
        self.onSelectionIndex = { index in
            guard index >= 0 && index < options.count else { return }
            onChange(options[index])
        }
    }

    init(selection: String, options: [String], onSelectIndex: @escaping (Int) -> Void) {
        self.selection = selection
        self.options = options
        self.onSelectionIndex = onSelectIndex
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.removeAllItems()
        button.addItems(withTitles: options)
        button.selectItem(withTitle: selection)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let currentTitles = button.itemTitles
        if currentTitles != options {
            button.removeAllItems()
            button.addItems(withTitles: options)
        }
        if button.titleOfSelectedItem != selection {
            button.selectItem(withTitle: selection)
        }
        context.coordinator.onSelectionIndex = onSelectionIndex
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelectionIndex: onSelectionIndex) }

    class Coordinator: NSObject {
        var onSelectionIndex: (Int) -> Void
        init(onSelectionIndex: @escaping (Int) -> Void) { self.onSelectionIndex = onSelectionIndex }
        @objc func selectionChanged(_ sender: NSPopUpButton) {
            onSelectionIndex(sender.indexOfSelectedItem)
        }
    }
}

/// A text field that supports Cmd+V paste and masks the value when not focused.
struct PastableSecureField: NSViewRepresentable {
    let text: String
    let placeholder: String
    let onChange: (String) -> Void

    func makeNSView(context: Context) -> EditableNSSecureTextField {
        let field = EditableNSSecureTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ nsView: EditableNSSecureTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        let onChange: (String) -> Void

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            onChange(field.stringValue)
        }
    }
}

private extension Color {
    init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        h = h.hasPrefix("#") ? String(h.dropFirst()) : h
        guard h.count == 6, let value = UInt64(h, radix: 16) else {
            self = .black; return
        }
        self = Color(
            red:   Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8)  & 0xFF) / 255,
            blue:  Double( value        & 0xFF) / 255
        )
    }
}

private extension NSColor {
    func toHexString() -> String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        let r = Int((rgb.redComponent   * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent  * 255).rounded())
        return String(format: "%02x%02x%02x", r, g, b)
    }
}
