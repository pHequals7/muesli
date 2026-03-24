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
    @State private var pendingDataDestruction: PendingDataDestruction?

    // Uniform width for all right-side controls
    private let controlWidth: CGFloat = 220

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
                    settingsRow("Dark mode") {
                        settingsSwitch(isOn: appState.config.darkMode) { newValue in
                            controller.updateConfig { $0.darkMode = newValue }
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
                            options: BackendOption.all.map(\.label)
                        ) { label in
                            if let option = BackendOption.all.first(where: { $0.label == label }) {
                                controller.selectBackend(option)
                            }
                        }
                    }
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
                            .frame(width: controlWidth, height: 22)
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
                            .frame(width: controlWidth, height: 22)
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

                settingsSection("Privacy") {
                    settingsRow("Don't modify clipboard when pasting") {
                        settingsSwitch(isOn: appState.config.disableClipboardCopy) { newValue in
                            controller.updateConfig { $0.disableClipboardCopy = newValue }
                        }
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

    /// Standardized row: label on left, control on right, consistent 36pt height
    @ViewBuilder
    private func settingsRow(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)
            Spacer()
            control()
        }
        .frame(minHeight: 32)
    }

    // MARK: - Controls

    @ViewBuilder
    private func settingsSwitch(isOn: Bool, onChange: @escaping (Bool) -> Void) -> some View {
        Toggle("", isOn: Binding(get: { isOn }, set: { onChange($0) }))
            .toggleStyle(.switch)
            .tint(MuesliTheme.accent)
            .labelsHidden()
    }

    @ViewBuilder
    private func settingsMenu(selection: String, options: [String], onChange: @escaping (String) -> Void) -> some View {
        Picker("", selection: Binding(get: { selection }, set: { onChange($0) })) {
            ForEach(options, id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.menu)
        .frame(width: controlWidth)
    }

    @ViewBuilder
    private func meetingTemplateMenu(selectionID: String, onChange: @escaping (String) -> Void) -> some View {
        Picker(
            "",
            selection: Binding(
                get: { selectionID },
                set: { onChange($0) }
            )
        ) {
            Text(MeetingTemplates.auto.title)
                .tag(MeetingTemplates.autoID)
            Section("Built-in Templates") {
                ForEach(controller.builtInMeetingTemplates()) { template in
                    Text(template.title)
                        .tag(template.id)
                }
            }

            if !controller.customMeetingTemplates().isEmpty {
                Section("Custom Templates") {
                    ForEach(controller.customMeetingTemplates()) { template in
                        Text(template.name)
                            .tag(template.id)
                    }
                }
            }
        }
        .pickerStyle(.menu)
        .frame(width: controlWidth)
    }

    @ViewBuilder
    private func settingsModelMenu(currentModel: String, presets: [SummaryModelPreset], onChange: @escaping (String) -> Void) -> some View {
        Picker("", selection: Binding(
            get: { currentModel.isEmpty ? (presets.first?.id ?? "") : currentModel },
            set: { onChange($0 == presets.first?.id ? "" : $0) }
        )) {
            ForEach(presets, id: \.id) { Text($0.label).tag($0.id) }
        }
        .pickerStyle(.menu)
        .frame(width: controlWidth)
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
