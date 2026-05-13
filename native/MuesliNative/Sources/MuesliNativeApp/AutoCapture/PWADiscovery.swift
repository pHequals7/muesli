import Foundation
import os

// MARK: - PWAEntry

/// One installed Progressive Web App that auto-capture can target. Mirrors a
/// single `.app` bundle on disk plus an optional start URL recovered from the
/// host browser's profile data.
struct PWAEntry: Codable, Equatable, Identifiable, Hashable {

    /// Which host produced the PWA. Used by the Settings UI to label the row
    /// and to pick the correct profile lookup at refresh time.
    enum Source: String, Codable, Equatable, Hashable {
        case chrome
        case safari
    }

    /// Bundle identifier from the `.app`'s Info.plist. Drives auto-capture
    /// allowlisting through `AutoCaptureConfig.allowedAppBundleIDs`.
    let bundleID: String

    /// Human-readable name. Pulled from `CFBundleDisplayName`, falling back to
    /// `CFBundleName` and finally the file name without its extension.
    let displayName: String

    /// Optional start URL when we can recover one from the host browser's
    /// profile cache. Nil when discovery only found the bundle and not the
    /// mapping (the user will still be able to toggle the entry on or off).
    let startURL: String?

    /// Origin host.
    let source: Source

    /// Identifiable conformance — bundle IDs are unique per .app.
    var id: String { bundleID }

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case displayName = "display_name"
        case startURL = "start_url"
        case source
    }
}

// MARK: - PWADiscovery

/// Filesystem scanner for installed Chrome PWAs and Safari Web Apps. Pure
/// value-returning code — no AppleScript, no spawned processes, no AppKit
/// dependencies — so it's safe to call from a background queue.
enum PWADiscovery {

    private static let chromeAppsRelativePath = "Applications/Chrome Apps.localized"
    private static let chromeProfilesRelativePath = "Library/Application Support/Google/Chrome"
    private static let safariWebAppBundleIDPrefix = "com.apple.Safari.WebApp."
    private static let systemApplicationsPath = "/Applications"
    private static let userApplicationsRelativePath = "Applications"

    /// Run a full scan using the current user's home directory. Synchronous —
    /// callers should dispatch to a background queue and marshal the result
    /// back to the main actor (see `MuesliController.refreshDiscoveredPWAs`).
    static func scan(
        fileManager: FileManager = .default,
        logger: Logger = Logger(subsystem: "com.muesli.native", category: "AutoCapture.PWADiscovery")
    ) -> [PWAEntry] {
        let home = fileManager.homeDirectoryForCurrentUser

        let chrome = scanChromePWAs(
            chromeAppsRoot: home.appendingPathComponent(chromeAppsRelativePath),
            chromeProfilesRoot: home.appendingPathComponent(chromeProfilesRelativePath),
            fileManager: fileManager,
            logger: logger
        )

        // Safari Web Apps can live in either /Applications or ~/Applications
        // depending on the install path the user picked; scan both and dedupe
        // by bundle ID.
        var safariSeen = Set<String>()
        var safari: [PWAEntry] = []
        for root in [
            URL(fileURLWithPath: systemApplicationsPath, isDirectory: true),
            home.appendingPathComponent(userApplicationsRelativePath, isDirectory: true),
        ] {
            for entry in scanSafariWebApps(at: root, fileManager: fileManager, logger: logger) {
                guard safariSeen.insert(entry.bundleID).inserted else { continue }
                safari.append(entry)
            }
        }

        return (chrome + safari).sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    // MARK: Chrome

    /// Scan `~/Applications/Chrome Apps.localized/` for `.app` bundles and
    /// pair each with its start URL from the matching profile cache when one
    /// is present.
    static func scanChromePWAs(
        chromeAppsRoot: URL,
        chromeProfilesRoot: URL?,
        fileManager: FileManager = .default,
        logger: Logger = Logger(subsystem: "com.muesli.native", category: "AutoCapture.PWADiscovery")
    ) -> [PWAEntry] {
        guard directoryExists(chromeAppsRoot, fileManager: fileManager) else { return [] }

        let urlIndex = chromeProfilesRoot.flatMap {
            buildChromeStartURLIndex(profilesRoot: $0, fileManager: fileManager, logger: logger)
        } ?? [:]

        let appURLs = bundleURLs(in: chromeAppsRoot, fileManager: fileManager)
        var entries: [PWAEntry] = []
        for appURL in appURLs {
            guard let info = readBundleInfo(at: appURL) else { continue }
            guard let bundleID = info.bundleID,
                  bundleID.hasPrefix("com.google.Chrome.app.") else { continue }
            let displayName = info.displayName ?? appURL.deletingPathExtension().lastPathComponent
            let startURL = urlIndex[chromeAppID(fromBundleID: bundleID)]
            entries.append(
                PWAEntry(
                    bundleID: bundleID,
                    displayName: displayName,
                    startURL: startURL,
                    source: .chrome
                )
            )
        }
        return entries
    }

    /// Walk every `Web Applications/_crx_<appid>/` subdirectory under each
    /// Chrome profile and return a map from the Chrome app ID (the suffix of
    /// the bundle ID) to the recovered `start_url`. Best-effort — missing or
    /// malformed manifest files silently skip.
    private static func buildChromeStartURLIndex(
        profilesRoot: URL,
        fileManager: FileManager,
        logger: Logger
    ) -> [String: String] {
        guard directoryExists(profilesRoot, fileManager: fileManager),
              let profiles = try? fileManager.contentsOfDirectory(at: profilesRoot, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return [:]
        }

        var index: [String: String] = [:]

        for profile in profiles {
            // Each Chrome profile (Default, Profile 1, …) has its own
            // Web Applications cache. Both legacy ("_crx_<appid>") and modern
            // ("<appid>/manifest.json") layouts have been observed across
            // Chromium versions; handle both.
            let webApps = profile.appendingPathComponent("Web Applications", isDirectory: true)
            guard directoryExists(webApps, fileManager: fileManager),
                  let webAppDirs = try? fileManager.contentsOfDirectory(at: webApps, includingPropertiesForKeys: [.isDirectoryKey]) else {
                continue
            }

            for webAppDir in webAppDirs {
                let name = webAppDir.lastPathComponent
                let appID: String?
                if name.hasPrefix("_crx_") {
                    appID = String(name.dropFirst("_crx_".count))
                } else if name.count == 32 {
                    appID = name
                } else {
                    appID = nil
                }
                guard let appID, !appID.isEmpty else { continue }

                if let startURL = readChromeStartURL(in: webAppDir, fileManager: fileManager) {
                    index[appID] = startURL
                }
            }
        }

        return index
    }

    private static func readChromeStartURL(in directory: URL, fileManager: FileManager) -> String? {
        let manifestCandidates = [
            "Manifest Resources/manifest.json",
            "manifest.json",
        ]
        for relative in manifestCandidates {
            let url = directory.appendingPathComponent(relative)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let startURL = json["start_url"] as? String, !startURL.isEmpty {
                return startURL
            }
        }
        return nil
    }

    /// Bundle IDs look like `com.google.Chrome.app.<appid>` — extract the trailing app ID.
    private static func chromeAppID(fromBundleID bundleID: String) -> String {
        let prefix = "com.google.Chrome.app."
        guard bundleID.hasPrefix(prefix) else { return bundleID }
        return String(bundleID.dropFirst(prefix.count))
    }

    // MARK: Safari

    /// Scan the supplied applications root for any `.app` whose bundle ID
    /// begins with `com.apple.Safari.WebApp.`.
    static func scanSafariWebApps(
        at root: URL,
        fileManager: FileManager = .default,
        logger: Logger = Logger(subsystem: "com.muesli.native", category: "AutoCapture.PWADiscovery")
    ) -> [PWAEntry] {
        guard directoryExists(root, fileManager: fileManager) else { return [] }

        let appURLs = bundleURLs(in: root, fileManager: fileManager)
        var entries: [PWAEntry] = []
        for appURL in appURLs {
            guard let info = readBundleInfo(at: appURL) else { continue }
            guard let bundleID = info.bundleID,
                  bundleID.hasPrefix(safariWebAppBundleIDPrefix) else { continue }
            let displayName = info.displayName ?? appURL.deletingPathExtension().lastPathComponent
            entries.append(
                PWAEntry(
                    bundleID: bundleID,
                    displayName: displayName,
                    startURL: info.urlSchemeFirstURL,
                    source: .safari
                )
            )
        }
        return entries
    }

    // MARK: Generic plist helpers

    private struct BundleInfo {
        let bundleID: String?
        let displayName: String?
        let urlSchemeFirstURL: String?
    }

    private static func readBundleInfo(at appURL: URL) -> BundleInfo? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        let bundleID = (plist["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
        let firstURL = (plist["CFBundleURLTypes"] as? [[String: Any]])?
            .compactMap { $0["CFBundleURLSchemes"] as? [String] }
            .flatMap { $0 }
            .first
        return BundleInfo(
            bundleID: (bundleID?.isEmpty ?? true) ? nil : bundleID,
            displayName: displayName,
            urlSchemeFirstURL: firstURL
        )
    }

    private static func bundleURLs(in directory: URL, fileManager: FileManager) -> [URL] {
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        return children.filter { $0.pathExtension == "app" }
    }

    private static func directoryExists(_ url: URL, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
