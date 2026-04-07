import AppKit
import Foundation

@MainActor
enum PostInstallChecker {
    private static var hasPresented = false
    // P2: hold a reference so the task isn't immediately discarded.
    private static var mountedDMGCheckTask: Task<Void, Never>?

    static func check() {
        guard !hasPresented else { return }
        hasPresented = true

        let bundlePath = Bundle.main.bundlePath

        if bundlePath.hasPrefix("/Volumes/") {
            // Confirm it's a read-only DMG mount, not an external SSD or network share.
            let bundleURL = URL(fileURLWithPath: bundlePath)
            let values = try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey])
            guard values?.volumeIsReadOnly == true else { return }

            // Case 1: running directly from DMG — offer to install
            offerInstall(from: bundlePath)
        } else {
            // Case 2: running from /Applications — check if DMG is still mounted
            mountedDMGCheckTask = Task { await checkForMountedDMG() }
        }
    }

    // MARK: - Case 1: Install from DMG

    private static func offerInstall(from bundlePath: String) {
        guard runAlert(
            message: NSLocalizedString("Install Muesli to Applications?",
                comment: "Alert title: user launched app directly from DMG"),
            info: NSLocalizedString("Muesli will copy itself to your Applications folder and relaunch automatically.",
                comment: "Alert body: explains what the install action does"),
            buttons: [
                NSLocalizedString("Install", comment: "Confirm install button"),
                NSLocalizedString("Cancel", comment: "Cancel install button"),
            ]
        ) == .alertFirstButtonReturn else { return }

        let destinationURL = URL(fileURLWithPath: "/Applications/Muesli.app")

        // P2: use isDirectory to confirm it's a bundle, not a stray file at that path.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: destinationURL.path, isDirectory: &isDir), isDir.boolValue {
            guard runAlert(
                message: NSLocalizedString("Replace existing Muesli?",
                    comment: "Alert title: an older Muesli.app is already in Applications"),
                info: NSLocalizedString("An older version of Muesli is already in Applications. Replace it?",
                    comment: "Alert body: confirms replacing existing install"),
                buttons: [
                    NSLocalizedString("Replace", comment: "Confirm replace button"),
                    NSLocalizedString("Cancel", comment: "Cancel replace button"),
                ]
            ) == .alertFirstButtonReturn else { return }

            do {
                try FileManager.default.trashItem(at: destinationURL, resultingItemURL: nil)
            } catch {
                showInstallError("Couldn't move existing Muesli to Trash: \(error.localizedDescription)")
                return
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [bundlePath, destinationURL.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            showInstallError(error.localizedDescription)
            return
        }
        guard process.terminationStatus == 0 else {
            showInstallError("ditto exited with status \(process.terminationStatus)")
            return
        }

        // P3: nudge Launch Services so it picks up the freshly-copied bundle immediately,
        // rather than waiting for the next Spotlight re-index or user login.
        let lsregister = Process()
        lsregister.executableURL = URL(
            fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework"
                + "/Frameworks/LaunchServices.framework/Support/lsregister"
        )
        lsregister.arguments = ["-f", destinationURL.path]
        try? lsregister.run()
        lsregister.waitUntilExit()

        // Derive the DMG volume path from our bundle path (/Volumes/Muesli/Muesli.app → /Volumes/Muesli)
        let volumePath = URL(fileURLWithPath: bundlePath).deletingLastPathComponent().path
        let sourceDMGPath = Self.findSourceDMGPathSync(volumePath: volumePath)

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: destinationURL, configuration: config) { _, error in
            if let error {
                fputs("[PostInstallChecker] relaunch failed: \(error.localizedDescription)\n", stderr)
            }
            DispatchQueue.main.async {
                // Eject the DMG volume and trash the source file
                NSWorkspace.shared.unmountAndEjectDevice(atPath: volumePath)
                if let dmgPath = sourceDMGPath {
                    try? FileManager.default.trashItem(
                        at: URL(fileURLWithPath: dmgPath), resultingItemURL: nil)
                }
                NSApp.terminate(nil)
            }
        }
        // Safety net: terminate after 4 s in case openApplication never calls back
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { NSApp.terminate(nil) }
    }

    private static func showInstallError(_ description: String) {
        fputs("[PostInstallChecker] install failed: \(description)\n", stderr)
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Installation failed.",
            comment: "Alert title: install error")
        alert.informativeText = description
        alert.runModal()
    }

    // MARK: - Case 2: Eject mounted DMG

    private static func checkForMountedDMG() async {
        guard let volumeURL = findMuesliVolume() else { return }
        let volumePath = volumeURL.path
        let sourceDMGPath = await findSourceDMGPath(for: volumePath)

        // App is installed and running — force-detach via hdiutil (handles busy Finder windows),
        // then trash the source .dmg file. Finder's window closes as a side-effect of unmount.
        let detached = hdiutilDetach(mountPoint: volumePath)
        if !detached {
            fputs("[PostInstallChecker] failed to eject volume at \(volumePath)\n", stderr)
        }
        if detached, let dmgPath = sourceDMGPath {
            await MainActor.run {
                do {
                    try FileManager.default.trashItem(
                        at: URL(fileURLWithPath: dmgPath), resultingItemURL: nil)
                    fputs("[PostInstallChecker] trashed DMG: \(dmgPath)\n", stderr)
                } catch {
                    fputs("[PostInstallChecker] trash failed: \(error.localizedDescription)\n", stderr)
                }
            }
        }
    }

    // Runs hdiutil detach with -force so a Finder window holding the volume isn't a blocker.
    private static func hdiutilDetach(mountPoint: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint, "-force", "-quiet"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            fputs("[PostInstallChecker] hdiutil detach error: \(error)\n", stderr)
            return false
        }
    }

    // P2: use mountedVolumeURLs instead of contentsOfDirectory("/Volumes") — avoids
    // stale symlinks, firmlinks, and hidden entries that can appear under /Volumes.
    private static func findMuesliVolume() -> URL? {
        guard let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) else { return nil }
        return volumes.first { url in
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? ""
            return name.hasPrefix("Muesli")
        }
    }

    private static func findSourceDMGPath(for volumePath: String) async -> String? {
        findSourceDMGPathSync(volumePath: volumePath)
    }

    // Synchronous — safe to call on the main thread (fast, single hdiutil invocation).
    private static func findSourceDMGPathSync(volumePath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return nil }

        for image in images {
            guard let entities = image["system-entities"] as? [[String: Any]] else { continue }
            for entity in entities {
                if let mountPoint = entity["mount-point"] as? String,
                   mountPoint == volumePath,
                   let imagePath = image["image-path"] as? String {
                    return imagePath
                }
            }
        }
        return nil
    }

    // MARK: - Alert helper

    // P3: shared helper to reduce the three identical NSAlert setup blocks to one site.
    @discardableResult
    private static func runAlert(
        message: String,
        info: String,
        buttons: [String]
    ) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal()
    }
}
