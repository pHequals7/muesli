import AppKit
import Foundation
import Sparkle
import TelemetryDeck
import MuesliCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MuesliController?
    private(set) var updaterController: SPUStandardUpdaterController?
    private let sparkleUpdateDelegate = SparkleUpdateDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let telemetryConfig = TelemetryDeck.Config(appID: "7F2B7846-1CB5-4FE6-8ABC-56F217B06A86")
        TelemetryDeck.initialize(config: telemetryConfig)
        TelemetryDeck.signal("app.launched")

        do {
            let runtime = try RuntimePaths.resolve()
            AppFonts.registerIfNeeded(runtime: runtime)
            if let appIcon = runtime.appIcon, let image = NSImage(contentsOf: appIcon) {
                NSApplication.shared.applicationIconImage = image
            }
            let controller = MuesliController(runtime: runtime)
            sparkleUpdateDelegate.appState = controller.appState
            if Self.hasConfiguredSparkleFeed {
                let updaterController = SPUStandardUpdaterController(
                    startingUpdater: true,
                    updaterDelegate: sparkleUpdateDelegate,
                    userDriverDelegate: nil
                )
                controller.updaterController = updaterController
                self.updaterController = updaterController
            }
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if controller?.shouldTerminateApplication() == false {
            return .terminateCancel
        }
        return .terminateNow
    }

    private static var hasConfiguredSparkleFeed: Bool {
        guard let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
            return false
        }
        return !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

@MainActor
final class SparkleUpdateDelegate: NSObject, SPUUpdaterDelegate {
    weak var appState: AppState?
    private var lastPresentedAt: Date?

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        appState?.sparkleUpdateStatus = .checking
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        appState?.sparkleUpdateStatus = .available(version: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let nsError = error as NSError
        if UpdateFailureGuidance.isNoUpdateError(nsError) {
            appState?.sparkleUpdateStatus = .upToDate
        } else {
            appState?.sparkleUpdateStatus = .failed(message: nsError.localizedDescription)
        }
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        appState?.sparkleUpdateStatus = .downloaded(version: item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        appState?.sparkleUpdateStatus = .installing(version: item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        switch choice {
        case .install:
            appState?.sparkleUpdateStatus = .installing(version: item.displayVersionString)
        case .dismiss where state.stage == .downloaded:
            appState?.sparkleUpdateStatus = .downloaded(version: item.displayVersionString)
        case .dismiss:
            appState?.sparkleUpdateStatus = .available(version: item.displayVersionString)
        case .skip:
            appState?.sparkleUpdateStatus = .idle
        @unknown default:
            appState?.sparkleUpdateStatus = .available(version: item.displayVersionString)
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        if UpdateFailureGuidance.isNoUpdateError(nsError) {
            appState?.sparkleUpdateStatus = .upToDate
            return
        }

        appState?.sparkleUpdateStatus = .failed(message: nsError.localizedDescription)
        guard UpdateFailureGuidance.shouldShowFallback(for: nsError) else { return }

        // Sparkle shows its own error alert first. Delay briefly so this
        // recovery path appears after the generic updater failure alert.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.showManualInstallGuidance()
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        appState?.sparkleLastCheckedAt = Date()
        guard let error else { return }
        let nsError = error as NSError
        // didAbortWithError is the primary error callback; this keeps the
        // final-cycle handler self-contained for any Sparkle path that ends here.
        if UpdateFailureGuidance.isNoUpdateError(nsError) {
            appState?.sparkleUpdateStatus = .upToDate
        } else {
            appState?.sparkleUpdateStatus = .failed(message: nsError.localizedDescription)
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
    private static let noUpdateErrorCode = 1001

    static let downloadPageURLString = "https://phequals7.github.io/muesli/"

    static let message = """
    Please quit Muesli, reopen it from Applications, and try the update once more.

    If this keeps happening, download the latest DMG and replace Muesli manually. This can happen when the local updater cannot finish preparing or replacing the app.
    """

    static func isNoUpdateError(_ error: NSError) -> Bool {
        guard error.domain == SUSparkleErrorDomain else { return false }
        if error.code == noUpdateErrorCode { return true }
        return error.userInfo[SPUNoUpdateFoundReasonKey] != nil
    }

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
            4013, // SUInstallationTranslocationError
        ]

        return installStageCodes.contains(error.code)
    }
}
