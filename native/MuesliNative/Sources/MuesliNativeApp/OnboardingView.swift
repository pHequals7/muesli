import AVFoundation
import ApplicationServices
import SwiftUI
import MuesliCore

struct OnboardingView: View {
    let controller: MuesliController

    @State private var currentStep = 0
    @State private var userName = ""
    @State private var selectedBackend: BackendOption = .parakeetMultilingual
    @State private var summaryBackend: MeetingSummaryBackendOption = .openRouter
    @State private var apiKey = ""
    @State private var isChatGPTSignedIn = false

    // Permission states — pre-filled from OS on appear, then set to true after delay on Grant click
    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false
    @State private var screenRecordingGranted = false
    @State private var pendingPermissions: Set<String> = []

    // Hotkey recorder
    @State private var selectedHotkey: HotkeyConfig = .default
    @State private var isRecordingHotkey = false
    @State private var hotkeyEventMonitor: Any?

    private let totalSteps = 5

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: modelStep
                case 2: permissionsStep
                case 3: hotkeyStep
                case 4: meetingSummaryStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().background(MuesliTheme.surfaceBorder)

            // Bottom bar
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<totalSteps, id: \.self) { i in
                        Circle()
                            .fill(i == currentStep ? MuesliTheme.accent : MuesliTheme.textTertiary)
                            .frame(width: 7, height: 7)
                    }
                }

                Spacer()

                HStack(spacing: MuesliTheme.spacing12) {
                    if currentStep > 0 {
                        Button("Back") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                currentStep -= 1
                            }
                        }
                        .buttonStyle(.plain)
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .padding(.horizontal, MuesliTheme.spacing16)
                        .padding(.vertical, MuesliTheme.spacing8)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        .overlay(
                            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                        )
                    }

                    primaryButton
                }
            }
            .padding(.horizontal, MuesliTheme.spacing32)
            .padding(.vertical, MuesliTheme.spacing16)
        }
        .background(MuesliTheme.backgroundBase)
        .preferredColorScheme(.dark)
    }

    // MARK: - Primary Button

    @ViewBuilder
    private var primaryButton: some View {
        switch currentStep {
        case 0:
            onboardingButton("Continue", enabled: !userName.trimmingCharacters(in: .whitespaces).isEmpty) {
                withAnimation(.easeInOut(duration: 0.2)) { currentStep = 1 }
            }
        case 1:
            onboardingButton("Download & Continue", enabled: true) {
                startDownload()
            }
        case 2:
            onboardingButton("Continue", enabled: true) {
                withAnimation(.easeInOut(duration: 0.2)) { currentStep = 3 }
            }
        case 3:
            onboardingButton("Continue", enabled: true) {
                withAnimation(.easeInOut(duration: 0.2)) { currentStep = 4 }
            }
        case 4:
            HStack(spacing: MuesliTheme.spacing12) {
                Button("Skip") {
                    finishOnboarding(withKey: false)
                }
                .buttonStyle(.plain)
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textSecondary)
                .padding(.horizontal, MuesliTheme.spacing16)
                .padding(.vertical, MuesliTheme.spacing8)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )

                onboardingButton("Finish", enabled: true) {
                    finishOnboarding(withKey: true)
                }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func onboardingButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, MuesliTheme.spacing20)
                .padding(.vertical, MuesliTheme.spacing8)
                .background(enabled ? MuesliTheme.accent : MuesliTheme.accent.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: MuesliTheme.spacing24) {
            Spacer()

            MWaveformIcon(barCount: 13, spacing: 3)
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 80, height: 48)

            VStack(spacing: MuesliTheme.spacing8) {
                Text("Welcome to Muesli")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)

                Text("Local-first dictation and meeting transcription for macOS.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }

            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                Text("Your name")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)

                OnboardingTextField(text: $userName, placeholder: "Enter your name")
                    .frame(width: 280, height: 32)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Step 2: Model Selection

    private var modelStep: some View {
        VStack(spacing: MuesliTheme.spacing16) {
            VStack(spacing: MuesliTheme.spacing8) {
                Text("Choose your transcription model")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)

                Text("Pick a model to get started. You can download more from the Models tab later.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, MuesliTheme.spacing24)

            ScrollView {
                VStack(spacing: MuesliTheme.spacing8) {
                    ForEach(BackendOption.all, id: \.model) { option in
                        modelCard(option: option)
                    }
                }
                .padding(.horizontal, MuesliTheme.spacing32)
            }

        }
        .frame(maxWidth: .infinity)
    }

    private func modelCard(option: BackendOption) -> some View {
        let isSelected = selectedBackend == option
        return Button {
            selectedBackend = option
        } label: {
            HStack(spacing: MuesliTheme.spacing12) {
                Circle()
                    .fill(isSelected ? MuesliTheme.accent : Color.clear)
                    .frame(width: 16, height: 16)
                    .overlay(
                        Circle()
                            .strokeBorder(isSelected ? MuesliTheme.accent : MuesliTheme.textTertiary, lineWidth: 1.5)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.label)
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        if option.recommended {
                            Text("Recommended")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(MuesliTheme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        Text(option.sizeLabel)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }
                    Text(option.description)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }

                Spacer()
            }
            .padding(MuesliTheme.spacing12)
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                    .strokeBorder(isSelected ? MuesliTheme.accent : MuesliTheme.surfaceBorder, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 3: Permissions

    private var permissionsStep: some View {
        VStack(spacing: MuesliTheme.spacing24) {
            Spacer()

            VStack(spacing: MuesliTheme.spacing8) {
                Text("System Permissions")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)

                Text("Muesli needs a few macOS permissions to work properly. You can grant these now or later.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 0) {
                permissionRow(
                    icon: "mic.fill",
                    name: "Microphone",
                    description: "Record audio for dictation and meetings",
                    granted: micGranted,
                    pending: pendingPermissions.contains("mic"),
                    action: {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                        grantAfterDelay("mic") { micGranted = true }
                    }
                )
                Divider().background(MuesliTheme.surfaceBorder)
                permissionRow(
                    icon: "hand.raised.fill",
                    name: "Accessibility",
                    description: "Paste transcribed text into other apps",
                    granted: accessibilityGranted,
                    pending: pendingPermissions.contains("accessibility"),
                    action: {
                        openSystemSettings("Privacy_Accessibility")
                        grantAfterDelay("accessibility") { accessibilityGranted = true }
                    }
                )
                Divider().background(MuesliTheme.surfaceBorder)
                permissionRow(
                    icon: "keyboard.fill",
                    name: "Input Monitoring",
                    description: "Detect hotkey for push-to-talk dictation",
                    granted: inputMonitoringGranted,
                    pending: pendingPermissions.contains("input"),
                    action: {
                        if !CGPreflightListenEventAccess() {
                            CGRequestListenEventAccess()
                        }
                        // Delay opening Settings to avoid race with permission dialog
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            openSystemSettings("Privacy_ListenEvent")
                        }
                        grantAfterDelay("input") { inputMonitoringGranted = true }
                    }
                )
                Divider().background(MuesliTheme.surfaceBorder)
                permissionRow(
                    icon: "rectangle.dashed.badge.record",
                    name: "Screen Recording",
                    description: "Capture system audio during meetings",
                    granted: screenRecordingGranted,
                    pending: pendingPermissions.contains("screen"),
                    action: {
                        openSystemSettings("Privacy_ScreenCapture")
                        grantAfterDelay("screen") { screenRecordingGranted = true }
                    }
                )
            }
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
            .frame(width: 460)

            Text("Make sure to toggle on permissions in System Settings when prompted.")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear { refreshPermissions() }
    }

    private func permissionRow(icon: String, name: String, description: String, granted: Bool, pending: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(description)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }

            Spacer()

            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(MuesliTheme.success)
                    .transition(.scale.combined(with: .opacity))
            } else if pending {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18, height: 18)
            } else {
                Button("Grant") {
                    action()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .padding(.horizontal, MuesliTheme.spacing12)
                .padding(.vertical, 4)
                .background(MuesliTheme.accentSubtle)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
        }
        .padding(.horizontal, MuesliTheme.spacing16)
        .padding(.vertical, MuesliTheme.spacing12)
        .animation(.easeInOut(duration: 0.25), value: granted)
    }

    private func grantAfterDelay(_ key: String, grant: @escaping () -> Void) {
        pendingPermissions.insert(key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                pendingPermissions.remove(key)
                grant()
            }
        }
    }

    private func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
        inputMonitoringGranted = CGPreflightListenEventAccess()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    private func openSystemSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Step 4: Hotkey Configuration

    private var hotkeyStep: some View {
        VStack(spacing: MuesliTheme.spacing24) {
            Spacer()

            VStack(spacing: MuesliTheme.spacing8) {
                Text("Dictation Shortcut")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)

                Text("Choose the key you'll hold to dictate. Press and hold the key to record, release to transcribe.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: MuesliTheme.spacing16) {
                // Current hotkey display
                Text(selectedHotkey.label)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .padding(.horizontal, MuesliTheme.spacing32)
                    .padding(.vertical, MuesliTheme.spacing16)
                    .background(MuesliTheme.backgroundRaised)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
                    .overlay(
                        RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                            .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                    )

                // Change button
                Button {
                    if isRecordingHotkey {
                        stopRecordingHotkey()
                    } else {
                        startRecordingHotkey()
                    }
                } label: {
                    Text(isRecordingHotkey ? "Press a modifier key..." : "Change Shortcut")
                        .font(MuesliTheme.body())
                        .foregroundStyle(isRecordingHotkey ? MuesliTheme.accent : MuesliTheme.textPrimary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, MuesliTheme.spacing16)
                .padding(.vertical, MuesliTheme.spacing8)
                .background(isRecordingHotkey ? MuesliTheme.accentSubtle : MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(isRecordingHotkey ? MuesliTheme.accent.opacity(0.3) : MuesliTheme.surfaceBorder, lineWidth: 1)
                )
            }

            Text("Supported: Left Cmd, Right Cmd, Fn, Ctrl, Option, Shift")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onDisappear { stopRecordingHotkey() }
    }

    private func startRecordingHotkey() {
        isRecordingHotkey = true
        hotkeyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let keyCode = event.keyCode
            if let label = HotkeyConfig.label(for: keyCode) {
                selectedHotkey = HotkeyConfig(keyCode: keyCode, label: label)
                stopRecordingHotkey()
            }
            return event
        }
    }

    private func stopRecordingHotkey() {
        isRecordingHotkey = false
        if let monitor = hotkeyEventMonitor {
            NSEvent.removeMonitor(monitor)
            hotkeyEventMonitor = nil
        }
    }

    // MARK: - Step 5: Meeting Summaries

    private var meetingSummaryStep: some View {
        VStack(spacing: MuesliTheme.spacing24) {
            Spacer()

            VStack(spacing: MuesliTheme.spacing8) {
                Text("Meeting Summaries")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)

                Text("Connect an LLM provider to get AI-powered meeting notes.\nYou can set this up later in Settings.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 0) {
                providerTab("ChatGPT", selected: summaryBackend == .chatGPT) {
                    summaryBackend = .chatGPT
                    apiKey = ""
                }
                providerTab("OpenAI", selected: summaryBackend == .openAI) {
                    summaryBackend = .openAI
                    apiKey = ""
                }
                providerTab("OpenRouter", selected: summaryBackend == .openRouter) {
                    summaryBackend = .openRouter
                    apiKey = ""
                }
            }
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
            .frame(width: 320)

            if summaryBackend == .chatGPT {
                Text("Use your ChatGPT Plus or Pro subscription.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)

                if isChatGPTSignedIn {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(MuesliTheme.success)
                            .frame(width: 6, height: 6)
                        Text("Signed in with ChatGPT")
                            .font(.system(size: 11))
                            .foregroundStyle(MuesliTheme.success)
                    }
                } else {
                    Button {
                        Task {
                            await controller.signInWithChatGPT()
                            isChatGPTSignedIn = ChatGPTAuthManager.shared.isAuthenticated
                        }
                    } label: {
                        Text("Sign in with ChatGPT")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(MuesliTheme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                if summaryBackend == .openRouter {
                    Text("OpenRouter offers free models — no payment required.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.success)
                }

                VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    Text("API Key")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)

                    PastableSecureField(
                        text: apiKey,
                        placeholder: summaryBackend == .openAI ? "sk-..." : "sk-or-...",
                        onChange: { apiKey = $0 }
                    )
                    .frame(width: 320, height: 28)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(apiKey.isEmpty ? MuesliTheme.textTertiary : MuesliTheme.success)
                            .frame(width: 6, height: 6)
                        Text(apiKey.isEmpty ? "No API key" : "Key entered")
                            .font(.system(size: 11))
                            .foregroundStyle(apiKey.isEmpty ? MuesliTheme.textTertiary : MuesliTheme.success)
                    }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func providerTab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? MuesliTheme.textPrimary : MuesliTheme.textSecondary)
                .frame(width: 106)
                .padding(.vertical, MuesliTheme.spacing8)
                .background(selected ? MuesliTheme.surfacePrimary : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func startDownload() {
        // Start download in background, advance onboarding immediately
        Task {
            do {
                try await controller.downloadModelForOnboarding(selectedBackend) { _, _ in }
            } catch {
                fputs("[muesli-native] background model download failed: \(error)\n", stderr)
            }
        }
        withAnimation(.easeInOut(duration: 0.2)) { currentStep = 2 }
    }

    private func finishOnboarding(withKey: Bool) {
        controller.completeOnboarding(
            userName: userName.trimmingCharacters(in: .whitespaces),
            backend: selectedBackend,
            hotkey: selectedHotkey,
            summaryBackend: summaryBackend,
            apiKey: withKey ? apiKey : nil
        )
    }
}

// MARK: - Text Field

/// NSTextField subclass that handles Cmd+V/C/X/A without needing a standard Edit menu.
class EditableNSTextField: NSTextField {
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

struct OnboardingTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeNSView(context: Context) -> EditableNSTextField {
        let field = EditableNSTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 14)
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ nsView: EditableNSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }
    }
}
