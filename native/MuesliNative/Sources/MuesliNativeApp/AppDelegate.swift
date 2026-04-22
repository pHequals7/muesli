import AppKit
import Foundation
import Sparkle
import TelemetryDeck
import MuesliCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MuesliController?
    private(set) var updaterController: SPUStandardUpdaterController?
    private let updateFailureGuidancePresenter = UpdateFailureGuidancePresenter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let telemetryConfig = TelemetryDeck.Config(appID: "7F2B7846-1CB5-4FE6-8ABC-56F217B06A86")
        TelemetryDeck.initialize(config: telemetryConfig)
        TelemetryDeck.signal("app.launched")

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: updateFailureGuidancePresenter,
            userDriverDelegate: nil
        )

        do {
            let runtime = try RuntimePaths.resolve()
            AppFonts.registerIfNeeded(runtime: runtime)
            if let appIcon = runtime.appIcon, let image = NSImage(contentsOf: appIcon) {
                NSApplication.shared.applicationIconImage = image
            }
            let controller = MuesliController(runtime: runtime)
            controller.updaterController = updaterController
            self.controller = controller
            controller.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "\(AppIdentity.displayName) failed to start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }
}

@MainActor
final class UpdateFailureGuidancePresenter: NSObject, SPUUpdaterDelegate {
    private var lastPresentedAt: Date?

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        guard UpdateFailureGuidance.shouldShowFallback(for: nsError) else { return }

        // Sparkle shows its own error alert first. Delay briefly so this
        // recovery path appears after the generic updater failure alert.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.showManualInstallGuidance()
        }
    }

    private func showManualInstallGuidance() {
        if let lastPresentedAt, Date().timeIntervalSince(lastPresentedAt) < 60 {
            return
        }
        lastPresentedAt = Date()

        let alert = NSAlert()
        alert.messageText = "Update did not finish"
        alert.informativeText = UpdateFailureGuidance.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Download Page")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: UpdateFailureGuidance.downloadPageURLString) {
            NSWorkspace.shared.open(url)
        }
    }
}

enum UpdateFailureGuidance {
    static let downloadPageURLString = "https://phequals7.github.io/muesli/"

    static let message = """
    Please quit Muesli, reopen it from Applications, and try the update once more.

    If this keeps happening, download the latest DMG and replace Muesli manually. This usually means macOS blocked the local updater from replacing the app, not that the download failed.
    """

    static func shouldShowFallback(for error: NSError) -> Bool {
        guard error.domain == SUSparkleErrorDomain else { return false }

        let installStageCodes: Set<Int> = [
            4000, // SUFileCopyFailure
            4001, // SUAuthenticationFailure
            4002, // SUMissingUpdateError
            4003, // SUMissingInstallerToolError
            4004, // SURelaunchError
            4005, // SUInstallationError
            4009, // SUNotValidUpdateError
            4010, // SUAgentInvalidationError
            4012, // SUInstallationWriteNoPermissionError
        ]

        return installStageCodes.contains(error.code)
    }
}
