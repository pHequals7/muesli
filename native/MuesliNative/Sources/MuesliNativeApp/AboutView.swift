import SwiftUI

struct AboutView: View {
    let controller: MuesliController

    private let controlWidth: CGFloat = 220
    private let githubURL = "https://github.com/pHequals7/muesli"
    private let donateURL = "https://buymeacoffee.com/phequals7"

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
        return "v\(v)"
    }

    private var appDataPath: String {
        AppIdentity.supportDirectoryURL.path
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                Text("About")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)

                aboutSection {
                    aboutRow("Version") {
                        Text(version)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundStyle(MuesliTheme.textSecondary)
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    aboutRow("Support Development") {
                        linkButton("Donate", color: MuesliTheme.recording, url: donateURL)
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    aboutRow("Source Code") {
                        linkButton("View on GitHub", url: githubURL)
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        Text("App Data Directory")
                            .font(MuesliTheme.body())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        HStack {
                            Text(appDataPath)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(MuesliTheme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            openButton { openInFinder(appDataPath) }
                        }
                    }
                }

                sectionHeader("Acknowledgements")
                aboutSection {
                    acknowledgement(
                        name: "MLX by Apple",
                        description: "On-device machine learning framework for Apple Silicon."
                    )
                    Divider().background(MuesliTheme.surfaceBorder)
                    acknowledgement(
                        name: "mlx-whisper by Apple",
                        description: "Whisper speech-to-text engine powering local transcription."
                    )
                    Divider().background(MuesliTheme.surfaceBorder)
                    acknowledgement(
                        name: "ScreenCaptureKit by Apple",
                        description: "System audio capture for meeting transcription."
                    )
                }
            }
            .padding(MuesliTheme.spacing32)
        }
        .background(MuesliTheme.backgroundBase)
    }

    // MARK: - Components

    @ViewBuilder
    private func aboutSection(@ViewBuilder content: () -> some View) -> some View {
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

    @ViewBuilder
    private func aboutRow(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)
            Spacer()
            control()
        }
        .frame(minHeight: 32)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(MuesliTheme.textTertiary)
            .textCase(.uppercase)
            .padding(.leading, 2)
    }

    @ViewBuilder
    private func acknowledgement(name: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
            Text(name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MuesliTheme.textPrimary)
            Text(description)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, MuesliTheme.spacing4)
    }

    @ViewBuilder
    private func linkButton(_ title: String, color: Color = MuesliTheme.textPrimary, url: String) -> some View {
        Button {
            if let url = URL(string: url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(color == MuesliTheme.recording ? .white : color)
                .padding(.horizontal, MuesliTheme.spacing16)
                .padding(.vertical, MuesliTheme.spacing8)
                .background(color == MuesliTheme.recording ? color : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(color == MuesliTheme.recording ? color : MuesliTheme.surfaceBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func openButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Open")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MuesliTheme.textSecondary)
                .padding(.horizontal, MuesliTheme.spacing12)
                .padding(.vertical, MuesliTheme.spacing4)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func openInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
}
