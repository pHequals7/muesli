import SwiftUI
import MuesliCore

struct SettingsView: View {
    let appState: AppState
    let controller: MuesliController

    @State private var chatGPTSignInError: String?
    @State private var isSigningInChatGPT = false
    @State private var isCreatingTemplate = false
    @State private var editingTemplateID: String?
    @State private var draftTemplateName = ""
    @State private var draftTemplatePrompt = ""

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
                    customTemplatesBlock
                }

                settingsSection("Data") {
                    HStack(spacing: MuesliTheme.spacing12) {
                        actionButton("Clear dictation history", role: .destructive) {
                            controller.clearDictationHistory()
                        }
                        actionButton("Clear meeting history", role: .destructive) {
                            controller.clearMeetingHistory()
                        }
                    }
                }
            }
            .padding(MuesliTheme.spacing32)
        }
        .background(MuesliTheme.backgroundBase)
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
        let selected = MeetingTemplates.resolveDefinition(
            id: selectionID,
            customTemplates: appState.config.customMeetingTemplates
        )
        Menu {
            Button {
                onChange(MeetingTemplates.autoID)
            } label: {
                templateMenuItem(
                    title: MeetingTemplates.auto.title,
                    icon: MeetingTemplates.auto.icon,
                    isSelected: selectionID == MeetingTemplates.autoID
                )
            }

            Section("Built-in Templates") {
                ForEach(controller.builtInMeetingTemplates()) { template in
                    Button {
                        onChange(template.id)
                    } label: {
                        templateMenuItem(
                            title: template.title,
                            icon: template.icon,
                            isSelected: selectionID == template.id
                        )
                    }
                }
            }

            if !controller.customMeetingTemplates().isEmpty {
                Section("Custom Templates") {
                    ForEach(controller.customMeetingTemplates()) { template in
                        Button {
                            onChange(template.id)
                        } label: {
                            templateMenuItem(
                                title: template.name,
                                icon: "square.and.pencil",
                                isSelected: selectionID == template.id
                            )
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selected.icon)
                    .font(.system(size: 10))
                Text(selected.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            .foregroundStyle(MuesliTheme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: controlWidth)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
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

    private func templateMenuItem(title: String, icon: String, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark" : icon)
                .frame(width: 12)
            Text(title)
        }
    }

    @ViewBuilder
    private var customTemplatesBlock: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom templates")
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Create reusable prompt-based note formats for meetings.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
                Spacer()
                if isCreatingTemplate || editingTemplateID != nil {
                    actionButton("Cancel") {
                        resetTemplateEditor()
                    }
                } else {
                    actionButton("New template") {
                        beginCreatingTemplate()
                    }
                }
            }

            if controller.customMeetingTemplates().isEmpty {
                Text("No custom templates yet.")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: MuesliTheme.spacing8) {
                    ForEach(controller.customMeetingTemplates()) { template in
                        customTemplateRow(template)
                    }
                }
            }

            if isCreatingTemplate || editingTemplateID != nil {
                customTemplateEditor
            }
        }
        .padding(.top, MuesliTheme.spacing4)
    }

    @ViewBuilder
    private func customTemplateRow(_ template: CustomMeetingTemplate) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 10))
                            .foregroundStyle(MuesliTheme.accent)
                        Text(template.name)
                            .font(MuesliTheme.captionMedium())
                            .foregroundStyle(MuesliTheme.textPrimary)
                    }
                    Text(template.prompt)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
                HStack(spacing: MuesliTheme.spacing8) {
                    actionButton("Edit") {
                        beginEditingTemplate(template)
                    }
                    actionButton("Delete", role: .destructive) {
                        controller.deleteCustomMeetingTemplate(id: template.id)
                        if editingTemplateID == template.id {
                            resetTemplateEditor()
                        }
                    }
                }
            }
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.backgroundBase)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var customTemplateEditor: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            Text(isCreatingTemplate ? "New template" : "Edit template")
                .font(MuesliTheme.captionMedium())
                .foregroundStyle(MuesliTheme.textPrimary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                TextField("Customer follow-up", text: $draftTemplateName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Prompt")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                TextEditor(text: $draftTemplatePrompt)
                    .font(.system(size: 12))
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .padding(MuesliTheme.spacing8)
                    .background(MuesliTheme.backgroundBase)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                            .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                    )
            }

            HStack {
                Spacer()
                actionButton(isCreatingTemplate ? "Create template" : "Save changes") {
                    saveTemplateEditor()
                }
            }
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.surfacePrimary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private func beginCreatingTemplate() {
        isCreatingTemplate = true
        editingTemplateID = nil
        draftTemplateName = ""
        draftTemplatePrompt = ""
    }

    private func beginEditingTemplate(_ template: CustomMeetingTemplate) {
        isCreatingTemplate = false
        editingTemplateID = template.id
        draftTemplateName = template.name
        draftTemplatePrompt = template.prompt
    }

    private func resetTemplateEditor() {
        isCreatingTemplate = false
        editingTemplateID = nil
        draftTemplateName = ""
        draftTemplatePrompt = ""
    }

    private func saveTemplateEditor() {
        let trimmedName = draftTemplateName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = draftTemplatePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else { return }

        if let editingTemplateID {
            controller.updateCustomMeetingTemplate(
                id: editingTemplateID,
                name: trimmedName,
                prompt: trimmedPrompt
            )
        } else {
            controller.createCustomMeetingTemplate(
                name: trimmedName,
                prompt: trimmedPrompt
            )
        }
        resetTemplateEditor()
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
