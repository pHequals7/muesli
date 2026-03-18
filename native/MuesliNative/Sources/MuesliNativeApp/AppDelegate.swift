import AppKit
import Foundation
import Sparkle
import TelemetryDeck
import MuesliCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MuesliController?
    private(set) var updaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let telemetryConfig = TelemetryDeck.Config(appID: "7F2B7846-1CB5-4FE6-8ABC-56F217B06A86")
        TelemetryDeck.initialize(config: telemetryConfig)
        TelemetryDeck.signal("app.launched")

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
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
