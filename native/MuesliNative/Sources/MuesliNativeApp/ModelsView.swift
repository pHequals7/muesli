import SwiftUI
import MuesliCore

struct ModelsView: View {
    let appState: AppState
    let controller: MuesliController

    @State private var downloadingModels: Set<String> = []
    @State private var downloadProgress: [String: Double] = [:]
    @State private var downloadedModels: Set<String> = []
    @State private var modelToDelete: BackendOption?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                Text("Models")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)

                Text("Download and manage transcription models. The active model is used for dictation.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)

                VStack(spacing: MuesliTheme.spacing12) {
                    ForEach(BackendOption.all, id: \.model) { option in
                        modelCard(option: option)
                    }
                }

                if !BackendOption.comingSoon.isEmpty {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        Text("COMING SOON")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .textCase(.uppercase)
                            .padding(.leading, 2)
                            .padding(.top, MuesliTheme.spacing8)

                        VStack(spacing: MuesliTheme.spacing12) {
                            ForEach(BackendOption.comingSoon, id: \.model) { option in
                                comingSoonCard(option: option)
                            }
                        }
                    }
                }
            }
            .padding(MuesliTheme.spacing32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(MuesliTheme.backgroundBase)
        .onAppear { checkDownloadedModels() }
        .alert(
            "Delete \"\(modelToDelete?.label ?? "")\"?",
            isPresented: Binding(
                get: { modelToDelete != nil },
                set: { if !$0 { modelToDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                modelToDelete = nil
            }
            Button("Delete", role: .destructive) {
                guard let option = modelToDelete else { return }
                deleteModel(option)
                modelToDelete = nil
            }
        } message: {
            Text("The downloaded model files will be removed from this Mac. You can download the model again later.")
        }
    }

    private func modelCard(option: BackendOption) -> some View {
        let isActive = appState.selectedBackend == option
        let isDownloaded = downloadedModels.contains(option.model)
        let isDownloading = downloadingModels.contains(option.model)
        let progress = downloadProgress[option.model] ?? 0

        return VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    HStack(spacing: MuesliTheme.spacing8) {
                        Text(option.label)
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)

                        if option.recommended {
                            Text("Recommended")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(MuesliTheme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
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

                // Status badge
                if isActive {
                    Text("Active")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MuesliTheme.success)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(MuesliTheme.success.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else if isDownloaded {
                    Text("Downloaded")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            // Progress bar when downloading
            if isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                        .tint(MuesliTheme.accent)
                    Text("\(Int(progress * 100))% downloading...")
                        .font(.system(size: 11))
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
            }

            // Action buttons
            HStack(spacing: MuesliTheme.spacing8) {
                if isDownloading {
                    // No actions while downloading
                } else if isDownloaded {
                    if !isActive {
                        Button("Set Active") {
                            controller.selectBackend(option)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MuesliTheme.accent)
                        .padding(.horizontal, MuesliTheme.spacing12)
                        .padding(.vertical, 4)
                        .background(MuesliTheme.accentSubtle)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))

                        Button("Delete") {
                            modelToDelete = option
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MuesliTheme.recording)
                        .padding(.horizontal, MuesliTheme.spacing12)
                        .padding(.vertical, 4)
                        .background(MuesliTheme.recording.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    }
                } else {
                    Button("Download") {
                        startDownload(option)
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
        }
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(isActive ? MuesliTheme.accent.opacity(0.5) : MuesliTheme.surfaceBorder, lineWidth: isActive ? 1.5 : 1)
        )
    }

    private func comingSoonCard(option: BackendOption) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    HStack(spacing: MuesliTheme.spacing8) {
                        Text(option.label)
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textTertiary)

                        Text("Experimental")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(MuesliTheme.surfacePrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        Text(option.sizeLabel)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary.opacity(0.6))
                    }

                    Text(option.description)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary.opacity(0.7))
                }
                Spacer()
            }
        }
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.backgroundRaised.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder.opacity(0.5), lineWidth: 1)
        )
        .opacity(0.6)
    }

    // MARK: - Actions

    private func startDownload(_ option: BackendOption) {
        withAnimation { downloadingModels.insert(option.model) }
        downloadProgress[option.model] = 0.05  // Show initial progress immediately

        let startTime = Date()
        Task {
            await controller.transcriptionCoordinator.preload(backend: option) { progress, _ in
                DispatchQueue.main.async {
                    downloadProgress[option.model] = max(progress, 0.05)
                }
            }
            // Ensure the downloading state is visible for at least 1.5s
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed < 1.5 {
                try? await Task.sleep(nanoseconds: UInt64((1.5 - elapsed) * 1_000_000_000))
            }
            await MainActor.run {
                withAnimation {
                    downloadingModels.remove(option.model)
                    downloadedModels.insert(option.model)
                    downloadProgress.removeValue(forKey: option.model)
                }
            }
        }
    }

    private func deleteModel(_ option: BackendOption) {
        // Remove cached model files
        Task {
            await deleteModelFiles(option)
            await MainActor.run {
                downloadedModels.remove(option.model)
            }
        }
    }

    private func deleteModelFiles(_ option: BackendOption) async {
        let fm = FileManager.default
        switch option.backend {
        case "whisper":
            let filename = option.model.hasSuffix(".bin") ? option.model : "\(option.model).bin"
            let path = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/muesli/models/\(filename)")
            try? fm.removeItem(at: path)
        case "nemotron":
            let path = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/muesli/models/nemotron-560ms")
            try? fm.removeItem(at: path)
        case "canary":
            try? fm.removeItem(at: CanaryQwenModelStore.cacheDirectory())
        case "fluidaudio":
            // FluidAudio models are in ~/Library/Application Support/FluidAudio/Models/
            let supportDir = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/FluidAudio/Models")
            if option.model.contains("parakeet") {
                let version = option.model.contains("v2") ? "v2" : "v3"
                if let contents = try? fm.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil) {
                    for dir in contents where dir.lastPathComponent.contains("parakeet") && dir.lastPathComponent.contains(version) {
                        try? fm.removeItem(at: dir)
                    }
                }
            }
        default:
            break
        }
    }

    // MARK: - Check Downloaded Status

    private func checkDownloadedModels() {
        let fm = FileManager.default
        for option in BackendOption.all {
            if isModelDownloaded(option, fm: fm) {
                downloadedModels.insert(option.model)
            }
        }
    }

    private func isModelDownloaded(_ option: BackendOption, fm: FileManager) -> Bool {
        switch option.backend {
        case "whisper":
            let filename = option.model.hasSuffix(".bin") ? option.model : "\(option.model).bin"
            let path = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/muesli/models/\(filename)")
            return fm.fileExists(atPath: path.path)
        case "nemotron":
            let path = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/muesli/models/nemotron-560ms/encoder/encoder_int8.mlmodelc")
            return fm.fileExists(atPath: path.path)
        case "fluidaudio":
            // Check FluidAudio's cache
            let supportDir = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/FluidAudio/Models")
            if option.model.contains("parakeet") {
                let version = option.model.contains("v2") ? "v2" : "v3"
                if let contents = try? fm.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil) {
                    return contents.contains { $0.lastPathComponent.contains("parakeet") && $0.lastPathComponent.contains(version) }
                }
            }
            return false
        case "canary":
            return CanaryQwenModelStore.isAvailableLocally()
        default:
            return false
        }
    }
}
