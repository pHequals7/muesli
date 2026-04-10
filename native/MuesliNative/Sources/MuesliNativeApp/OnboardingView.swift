import AVFoundation
import ApplicationServices
import SwiftUI
import MuesliCore

struct OnboardingView: View {
    let controller: MuesliController
    let appState: AppState

    @State private var currentStep = 0
    @State private var userName = ""
    @State private var selectedBackend: BackendOption = .parakeetMultilingual
    @State private var summaryBackend: MeetingSummaryBackendOption = .openRouter
    @State private var apiKey = ""
    @State private var isSigningInChatGPT = false
    @State private var chatGPTSignInDone = false
    @State private var chatGPTSignInError: String?

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

    // Google Calendar
    @State private var isSigningInGoogleCal = false
    @State private var googleCalSignInDone = false
    @State private var googleCalSignInError: String?

    private let totalSteps = 6

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: modelStep
                case 2: permissionsStep
                case 3: hotkeyStep
                case 4: meetingSummaryStep
                case 5: googleCalendarStep
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
                    withAnimation(.easeInOut(duration: 0.2)) { currentStep = 5 }
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

                onboardingButton("Continue", enabled: true) {
                    withAnimation(.easeInOut(duration: 0.2)) { currentStep = 5 }
                }
            }
        case 5:
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

                if appState.isChatGPTAuthenticated || chatGPTSignInDone {
                    HStack(spacing: 6) {
                        OpenAILogoShape()
                            .fill(.white)
                            .frame(width: 14, height: 14)
                        Text("Signed in with ChatGPT")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(MuesliTheme.success)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                } else if isSigningInChatGPT {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Signing in...")
                            .font(.system(size: 12))
                            .foregroundStyle(MuesliTheme.textSecondary)
                    }
                } else {
                    Button {
                        isSigningInChatGPT = true
                        chatGPTSignInError = nil
                        Task {
                            let error = await controller.signInWithChatGPT()
                            isSigningInChatGPT = false
                            chatGPTSignInDone = ChatGPTAuthManager.shared.isAuthenticated
                            chatGPTSignInError = error
                        }
                    } label: {
                        HStack(spacing: 6) {
                            OpenAILogoShape()
                                .fill(.white)
                                .frame(width: 14, height: 14)
                            Text("Sign in with ChatGPT")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(MuesliTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    }
                    .buttonStyle(.plain)

                    if let chatGPTSignInError {
                        Text(chatGPTSignInError)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
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

    private var googleCalendarStep: some View {
        VStack(spacing: MuesliTheme.spacing24) {
            Spacer()

            VStack(spacing: MuesliTheme.spacing8) {
                Text("Google Calendar")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)

                Text("Connect Google Calendar to see upcoming meetings.\nYou can set this up later in Settings.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: MuesliTheme.spacing12) {
                if googleCalSignInDone {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(MuesliTheme.success)
                        Text("Google Calendar connected")
                            .font(MuesliTheme.body())
                            .foregroundStyle(MuesliTheme.textPrimary)
                    }
                } else if isSigningInGoogleCal {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Connecting...")
                            .font(MuesliTheme.body())
                            .foregroundStyle(MuesliTheme.textSecondary)
                    }
                } else if appState.isGoogleCalendarAvailable {
                    Button {
                        isSigningInGoogleCal = true
                        googleCalSignInError = nil
                        Task {
                            let error = await controller.signInWithGoogleCalendar()
                            isSigningInGoogleCal = false
                            if let error {
                                googleCalSignInError = error
                            } else {
                                googleCalSignInDone = true
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar.badge.plus")
                                .font(.system(size: 14))
                            Text("Connect Google Calendar")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, MuesliTheme.spacing16)
                        .padding(.vertical, MuesliTheme.spacing8)
                        .background(MuesliTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    }
                    .buttonStyle(.plain)

                    if let googleCalSignInError {
                        Text(googleCalSignInError)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    Text("Google Calendar credentials not configured.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, MuesliTheme.spacing32)
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

// MARK: - OpenAI Logo

struct OpenAILogoShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24
        let sy = rect.height / 24
        var p = Path()
        p.move(to: CGPoint(x: 22.2819 * sx, y: 9.8211 * sy))
        p.addCurve(to: CGPoint(x: 21.7662 * sx, y: 4.9103 * sy), control1: CGPoint(x: 22.8248 * sx, y: 8.1862 * sy), control2: CGPoint(x: 22.6369 * sx, y: 6.3967 * sy))
        p.addCurve(to: CGPoint(x: 15.2564 * sx, y: 2.0103 * sy), control1: CGPoint(x: 20.4571 * sx, y: 2.6316 * sy), control2: CGPoint(x: 17.8260 * sx, y: 1.4595 * sy))
        p.addCurve(to: CGPoint(x: 4.9807 * sx, y: 4.1818 * sy), control1: CGPoint(x: 12.1364 * sx, y: -1.4602 * sy), control2: CGPoint(x: 6.4298 * sx, y: -0.2543 * sy))
        p.addCurve(to: CGPoint(x: 0.9830 * sx, y: 7.0818 * sy), control1: CGPoint(x: 3.2928 * sx, y: 4.5279 * sy), control2: CGPoint(x: 1.8360 * sx, y: 5.5847 * sy))
        p.addCurve(to: CGPoint(x: 1.7257 * sx, y: 14.1784 * sy), control1: CGPoint(x: -0.3404 * sx, y: 9.3568 * sy), control2: CGPoint(x: -0.0401 * sx, y: 12.2267 * sy))
        p.addCurve(to: CGPoint(x: 2.2367 * sx, y: 19.0891 * sy), control1: CGPoint(x: 1.1808 * sx, y: 15.8125 * sy), control2: CGPoint(x: 1.3670 * sx, y: 17.6022 * sy))
        p.addCurve(to: CGPoint(x: 8.7513 * sx, y: 21.9892 * sy), control1: CGPoint(x: 3.5475 * sx, y: 21.3686 * sy), control2: CGPoint(x: 6.1803 * sx, y: 22.5406 * sy))
        p.addCurve(to: CGPoint(x: 13.2599 * sx, y: 24.0000 * sy), control1: CGPoint(x: 9.8948 * sx, y: 23.2770 * sy), control2: CGPoint(x: 11.5377 * sx, y: 24.0097 * sy))
        p.addCurve(to: CGPoint(x: 19.0317 * sx, y: 19.7942 * sy), control1: CGPoint(x: 15.8937 * sx, y: 24.0024 * sy), control2: CGPoint(x: 18.2271 * sx, y: 22.3021 * sy))
        p.addCurve(to: CGPoint(x: 23.0294 * sx, y: 16.8941 * sy), control1: CGPoint(x: 20.7194 * sx, y: 19.4475 * sy), control2: CGPoint(x: 22.1760 * sx, y: 18.3908 * sy))
        p.addCurve(to: CGPoint(x: 22.2819 * sx, y: 9.8212 * sy), control1: CGPoint(x: 24.3368 * sx, y: 14.6231 * sy), control2: CGPoint(x: 24.0351 * sx, y: 11.7688 * sy))
        p.closeSubpath()
        p.move(to: CGPoint(x: 13.2599 * sx, y: 22.4292 * sy))
        p.addCurve(to: CGPoint(x: 10.3835 * sx, y: 21.3884 * sy), control1: CGPoint(x: 12.2086 * sx, y: 22.4309 * sy), control2: CGPoint(x: 11.1903 * sx, y: 22.0624 * sy))
        p.addLine(to: CGPoint(x: 10.5254 * sx, y: 21.3080 * sy))
        p.addLine(to: CGPoint(x: 15.3037 * sx, y: 18.5498 * sy))
        p.addCurve(to: CGPoint(x: 15.6964 * sx, y: 17.8685 * sy), control1: CGPoint(x: 15.5456 * sx, y: 18.4079 * sy), control2: CGPoint(x: 15.6949 * sx, y: 18.1490 * sy))
        p.addLine(to: CGPoint(x: 15.6964 * sx, y: 11.1316 * sy))
        p.addLine(to: CGPoint(x: 17.7164 * sx, y: 12.3002 * sy))
        p.addCurve(to: CGPoint(x: 17.7544 * sx, y: 12.3522 * sy), control1: CGPoint(x: 17.7367 * sx, y: 12.3105 * sy), control2: CGPoint(x: 17.7508 * sx, y: 12.3298 * sy))
        p.addLine(to: CGPoint(x: 17.7544 * sx, y: 17.9348 * sy))
        p.addCurve(to: CGPoint(x: 13.2599 * sx, y: 22.4292 * sy), control1: CGPoint(x: 17.7491 * sx, y: 20.4148 * sy), control2: CGPoint(x: 15.7399 * sx, y: 22.4240 * sy))
        p.closeSubpath()
        p.move(to: CGPoint(x: 3.5992 * sx, y: 18.3038 * sy))
        p.addCurve(to: CGPoint(x: 3.0646 * sx, y: 15.2901 * sy), control1: CGPoint(x: 3.0720 * sx, y: 17.3934 * sy), control2: CGPoint(x: 2.8827 * sx, y: 16.3263 * sy))
        p.addLine(to: CGPoint(x: 3.2066 * sx, y: 15.3753 * sy))
        p.addLine(to: CGPoint(x: 7.9896 * sx, y: 18.1335 * sy))
        p.addCurve(to: CGPoint(x: 8.7702 * sx, y: 18.1335 * sy), control1: CGPoint(x: 8.2306 * sx, y: 18.2749 * sy), control2: CGPoint(x: 8.5292 * sx, y: 18.2749 * sy))
        p.addLine(to: CGPoint(x: 14.6130 * sx, y: 14.7650 * sy))
        p.addLine(to: CGPoint(x: 14.6130 * sx, y: 17.0974 * sy))
        p.addCurve(to: CGPoint(x: 14.5798 * sx, y: 17.1589 * sy), control1: CGPoint(x: 14.6119 * sx, y: 17.1219 * sy), control2: CGPoint(x: 14.5997 * sx, y: 17.1445 * sy))
        p.addLine(to: CGPoint(x: 9.7400 * sx, y: 19.9502 * sy))
        p.addCurve(to: CGPoint(x: 3.5992 * sx, y: 18.3038 * sy), control1: CGPoint(x: 7.5893 * sx, y: 21.1891 * sy), control2: CGPoint(x: 4.8416 * sx, y: 20.4525 * sy))
        p.closeSubpath()
        p.move(to: CGPoint(x: 2.3408 * sx, y: 7.8956 * sy))
        p.addCurve(to: CGPoint(x: 4.7063 * sx, y: 5.9228 * sy), control1: CGPoint(x: 2.8717 * sx, y: 6.9794 * sy), control2: CGPoint(x: 3.7096 * sx, y: 6.2805 * sy))
        p.addLine(to: CGPoint(x: 4.7063 * sx, y: 11.6000 * sy))
        p.addCurve(to: CGPoint(x: 5.0942 * sx, y: 12.2765 * sy), control1: CGPoint(x: 4.7026 * sx, y: 11.8793 * sy), control2: CGPoint(x: 4.8513 * sx, y: 12.1386 * sy))
        p.addLine(to: CGPoint(x: 10.9086 * sx, y: 15.6308 * sy))
        p.addLine(to: CGPoint(x: 8.8885 * sx, y: 16.7993 * sy))
        p.addCurve(to: CGPoint(x: 8.8175 * sx, y: 16.7993 * sy), control1: CGPoint(x: 8.8663 * sx, y: 16.8111 * sy), control2: CGPoint(x: 8.8397 * sx, y: 16.8111 * sy))
        p.addLine(to: CGPoint(x: 3.9872 * sx, y: 14.0128 * sy))
        p.addCurve(to: CGPoint(x: 2.3408 * sx, y: 7.8720 * sy), control1: CGPoint(x: 1.8408 * sx, y: 12.7686 * sy), control2: CGPoint(x: 1.1047 * sx, y: 10.0230 * sy))
        p.closeSubpath()
        p.move(to: CGPoint(x: 18.9371 * sx, y: 11.7514 * sy))
        p.addLine(to: CGPoint(x: 13.1038 * sx, y: 8.3640 * sy))
        p.addLine(to: CGPoint(x: 15.1192 * sx, y: 7.2000 * sy))
        p.addCurve(to: CGPoint(x: 15.1902 * sx, y: 7.2000 * sy), control1: CGPoint(x: 15.1414 * sx, y: 7.1882 * sy), control2: CGPoint(x: 15.1680 * sx, y: 7.1882 * sy))
        p.addLine(to: CGPoint(x: 20.0205 * sx, y: 9.9913 * sy))
        p.addCurve(to: CGPoint(x: 19.3440 * sx, y: 18.0955 * sy), control1: CGPoint(x: 23.3136 * sx, y: 11.8915 * sy), control2: CGPoint(x: 22.9065 * sx, y: 16.7676 * sy))
        p.addLine(to: CGPoint(x: 19.3440 * sx, y: 12.4183 * sy))
        p.addCurve(to: CGPoint(x: 18.9370 * sx, y: 11.7513 * sy), control1: CGPoint(x: 19.3355 * sx, y: 12.1397 * sy), control2: CGPoint(x: 19.1808 * sx, y: 11.8863 * sy))
        p.closeSubpath()
        p.move(to: CGPoint(x: 20.9478 * sx, y: 8.7283 * sy))
        p.addLine(to: CGPoint(x: 20.8058 * sx, y: 8.6431 * sy))
        p.addLine(to: CGPoint(x: 16.0323 * sx, y: 5.8613 * sy))
        p.addCurve(to: CGPoint(x: 15.2469 * sx, y: 5.8613 * sy), control1: CGPoint(x: 15.7898 * sx, y: 5.7190 * sy), control2: CGPoint(x: 15.4894 * sx, y: 5.7190 * sy))
        p.addLine(to: CGPoint(x: 9.4090 * sx, y: 9.2297 * sy))
        p.addLine(to: CGPoint(x: 9.4090 * sx, y: 6.8974 * sy))
        p.addCurve(to: CGPoint(x: 9.4374 * sx, y: 6.8359 * sy), control1: CGPoint(x: 9.4065 * sx, y: 6.8732 * sy), control2: CGPoint(x: 9.4174 * sx, y: 6.8496 * sy))
        p.addLine(to: CGPoint(x: 14.2677 * sx, y: 4.0493 * sy))
        p.addCurve(to: CGPoint(x: 20.9479 * sx, y: 8.7093 * sy), control1: CGPoint(x: 17.5693 * sx, y: 2.1473 * sy), control2: CGPoint(x: 21.5928 * sx, y: 4.9539 * sy))
        p.closeSubpath()
        p.move(to: CGPoint(x: 8.3065 * sx, y: 12.8630 * sy))
        p.addLine(to: CGPoint(x: 6.2865 * sx, y: 11.6992 * sy))
        p.addCurve(to: CGPoint(x: 6.2485 * sx, y: 11.6425 * sy), control1: CGPoint(x: 6.2660 * sx, y: 11.6869 * sy), control2: CGPoint(x: 6.2521 * sx, y: 11.6661 * sy))
        p.addLine(to: CGPoint(x: 6.2485 * sx, y: 6.0742 * sy))
        p.addCurve(to: CGPoint(x: 13.6242 * sx, y: 2.6205 * sy), control1: CGPoint(x: 6.2535 * sx, y: 2.2647 * sy), control2: CGPoint(x: 10.6950 * sx, y: 0.1849 * sy))
        p.addLine(to: CGPoint(x: 13.4822 * sx, y: 2.7010 * sy))
        p.addLine(to: CGPoint(x: 8.7040 * sx, y: 5.4590 * sy))
        p.addCurve(to: CGPoint(x: 8.3113 * sx, y: 6.1403 * sy), control1: CGPoint(x: 8.4621 * sx, y: 5.6009 * sy), control2: CGPoint(x: 8.3128 * sx, y: 5.8598 * sy))
        p.closeSubpath()
        // Inner hexagon
        p.move(to: CGPoint(x: 9.4041 * sx, y: 10.4976 * sy))
        p.addLine(to: CGPoint(x: 12.0061 * sx, y: 8.9978 * sy))
        p.addLine(to: CGPoint(x: 14.6130 * sx, y: 10.4976 * sy))
        p.addLine(to: CGPoint(x: 14.6130 * sx, y: 13.4970 * sy))
        p.addLine(to: CGPoint(x: 12.0156 * sx, y: 14.9967 * sy))
        p.addLine(to: CGPoint(x: 9.4089 * sx, y: 13.4970 * sy))
        p.closeSubpath()
        return p
    }
}
