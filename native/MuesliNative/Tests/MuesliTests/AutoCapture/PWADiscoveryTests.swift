import Testing
import Foundation
@testable import MuesliNativeApp

// MARK: - Fixture helpers

private enum PWAFixture {

    /// Build a stub `.app` bundle on disk with the supplied Info.plist values.
    /// Returns the URL of the created bundle.
    @discardableResult
    static func writeAppBundle(
        named name: String,
        in directory: URL,
        bundleID: String?,
        displayName: String? = nil,
        bundleName: String? = nil,
        urlSchemes: [String]? = nil
    ) throws -> URL {
        let appURL = directory.appendingPathComponent("\(name).app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        var info: [String: Any] = [:]
        if let bundleID { info["CFBundleIdentifier"] = bundleID }
        if let displayName { info["CFBundleDisplayName"] = displayName }
        if let bundleName { info["CFBundleName"] = bundleName }
        if let urlSchemes {
            info["CFBundleURLTypes"] = [["CFBundleURLSchemes": urlSchemes]]
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return appURL
    }

    /// Write a Chrome `Web Applications/_crx_<appid>/manifest.json` for use by
    /// the Chrome start-URL mapping path.
    static func writeChromeManifest(
        profilesRoot: URL,
        profileName: String = "Default",
        appID: String,
        startURL: String,
        useLegacyCrxPrefix: Bool = true
    ) throws {
        let dirName = useLegacyCrxPrefix ? "_crx_\(appID)" : appID
        let manifestDir = profilesRoot
            .appendingPathComponent(profileName, isDirectory: true)
            .appendingPathComponent("Web Applications", isDirectory: true)
            .appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: manifestDir, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["start_url": startURL, "name": "Test"]
        let data = try JSONSerialization.data(withJSONObject: manifest)
        try data.write(to: manifestDir.appendingPathComponent("manifest.json"))
    }

    static func makeTempRoot(_ label: String = #function) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-pwa-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

// MARK: - PWADiscovery tests

@Suite("PWADiscovery")
struct PWADiscoveryTests {

    @Test("scanChromePWAs returns empty when directory doesn't exist")
    func chromeMissingDirectoryReturnsEmpty() throws {
        let root = try PWAFixture.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let chromeApps = root.appendingPathComponent("Chrome Apps.localized")
        // Don't create the directory.
        let entries = PWADiscovery.scanChromePWAs(
            chromeAppsRoot: chromeApps,
            chromeProfilesRoot: nil
        )
        #expect(entries.isEmpty)
    }

    @Test("scanChromePWAs picks up bundles with com.google.Chrome.app.* IDs")
    func chromeDiscoversAppBundles() throws {
        let root = try PWAFixture.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let chromeApps = root.appendingPathComponent("Chrome Apps.localized")
        try FileManager.default.createDirectory(at: chromeApps, withIntermediateDirectories: true)

        try PWAFixture.writeAppBundle(
            named: "Microsoft Teams",
            in: chromeApps,
            bundleID: "com.google.Chrome.app.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            displayName: "Microsoft Teams"
        )
        try PWAFixture.writeAppBundle(
            named: "NotAChromePWA",
            in: chromeApps,
            bundleID: "com.example.app",
            displayName: "Some Other App"
        )

        let entries = PWADiscovery.scanChromePWAs(
            chromeAppsRoot: chromeApps,
            chromeProfilesRoot: nil
        )
        #expect(entries.count == 1)
        #expect(entries.first?.bundleID == "com.google.Chrome.app.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(entries.first?.displayName == "Microsoft Teams")
        #expect(entries.first?.source == .chrome)
        #expect(entries.first?.startURL == nil)
    }

    @Test("scanChromePWAs resolves start_url from legacy _crx_<appid> manifest")
    func chromeStartURLLegacyLayout() throws {
        let root = try PWAFixture.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let chromeApps = root.appendingPathComponent("Chrome Apps.localized")
        let profiles = root.appendingPathComponent("Profiles")
        try FileManager.default.createDirectory(at: chromeApps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)

        let appID = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        try PWAFixture.writeAppBundle(
            named: "Google Meet",
            in: chromeApps,
            bundleID: "com.google.Chrome.app.\(appID)",
            displayName: "Google Meet"
        )
        try PWAFixture.writeChromeManifest(
            profilesRoot: profiles,
            profileName: "Default",
            appID: appID,
            startURL: "https://meet.google.com/?usp=installed_webapp",
            useLegacyCrxPrefix: true
        )

        let entries = PWADiscovery.scanChromePWAs(
            chromeAppsRoot: chromeApps,
            chromeProfilesRoot: profiles
        )
        #expect(entries.count == 1)
        #expect(entries.first?.startURL == "https://meet.google.com/?usp=installed_webapp")
    }

    @Test("scanChromePWAs resolves start_url from modern <appid>/manifest.json layout")
    func chromeStartURLModernLayout() throws {
        let root = try PWAFixture.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let chromeApps = root.appendingPathComponent("Chrome Apps.localized")
        let profiles = root.appendingPathComponent("Profiles")
        try FileManager.default.createDirectory(at: chromeApps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)

        let appID = "cccccccccccccccccccccccccccccccc"
        try PWAFixture.writeAppBundle(
            named: "Webex",
            in: chromeApps,
            bundleID: "com.google.Chrome.app.\(appID)",
            displayName: "Webex"
        )
        try PWAFixture.writeChromeManifest(
            profilesRoot: profiles,
            profileName: "Profile 1",
            appID: appID,
            startURL: "https://app.webex.com/",
            useLegacyCrxPrefix: false
        )

        let entries = PWADiscovery.scanChromePWAs(
            chromeAppsRoot: chromeApps,
            chromeProfilesRoot: profiles
        )
        #expect(entries.first?.startURL == "https://app.webex.com/")
    }

    @Test("scanSafariWebApps returns empty when directory doesn't exist")
    func safariMissingDirectoryReturnsEmpty() throws {
        let root = try PWAFixture.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = PWADiscovery.scanSafariWebApps(at: root.appendingPathComponent("Applications"))
        #expect(entries.isEmpty)
    }

    @Test("scanSafariWebApps picks up bundles with com.apple.Safari.WebApp.* IDs")
    func safariDiscoversWebApps() throws {
        let root = try PWAFixture.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)

        try PWAFixture.writeAppBundle(
            named: "Teams",
            in: apps,
            bundleID: "com.apple.Safari.WebApp.ABCDEF12",
            displayName: "Teams",
            urlSchemes: ["msteams"]
        )
        try PWAFixture.writeAppBundle(
            named: "Calculator",
            in: apps,
            bundleID: "com.apple.calculator",
            displayName: "Calculator"
        )

        let entries = PWADiscovery.scanSafariWebApps(at: apps)
        #expect(entries.count == 1)
        #expect(entries.first?.bundleID == "com.apple.Safari.WebApp.ABCDEF12")
        #expect(entries.first?.source == .safari)
    }

    @Test("scanSafariWebApps falls back to CFBundleName when display name is absent")
    func safariFallbackBundleName() throws {
        let root = try PWAFixture.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)

        try PWAFixture.writeAppBundle(
            named: "NoDisplayName",
            in: apps,
            bundleID: "com.apple.Safari.WebApp.FALLBACK",
            displayName: nil,
            bundleName: "Slack"
        )
        let entries = PWADiscovery.scanSafariWebApps(at: apps)
        #expect(entries.first?.displayName == "Slack")
    }

    @Test("scanSafariWebApps falls back to file name when both plist names absent")
    func safariFallbackFileName() throws {
        let root = try PWAFixture.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)

        try PWAFixture.writeAppBundle(
            named: "Friend",
            in: apps,
            bundleID: "com.apple.Safari.WebApp.FNL",
            displayName: nil,
            bundleName: nil
        )
        let entries = PWADiscovery.scanSafariWebApps(at: apps)
        #expect(entries.first?.displayName == "Friend")
    }

    @Test("scanSafariWebApps ignores app bundles missing an Info.plist")
    func safariSkipsBundlesWithoutInfoPlist() throws {
        let root = try PWAFixture.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        // Create an empty .app bundle (no Contents/Info.plist) and confirm it is skipped.
        let bogus = apps.appendingPathComponent("BogusApp.app")
        try FileManager.default.createDirectory(at: bogus, withIntermediateDirectories: true)
        let entries = PWADiscovery.scanSafariWebApps(at: apps)
        #expect(entries.isEmpty)
    }
}

// MARK: - PWAEntry / PWAConfig Codable tests

@Suite("PWAEntry Codable")
struct PWAEntryCodableTests {

    @Test("round-trips through snake_case JSON")
    func roundTrip() throws {
        let entry = PWAEntry(
            bundleID: "com.google.Chrome.app.deadbeef",
            displayName: "Google Meet",
            startURL: "https://meet.google.com/?usp=installed_webapp",
            source: .chrome
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entry)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"bundle_id\":\"com.google.Chrome.app.deadbeef\""))
        #expect(json.contains("\"display_name\":\"Google Meet\""))
        #expect(json.contains("\"start_url\":\"https:\\/\\/meet.google.com\\/?usp=installed_webapp\""))
        #expect(json.contains("\"source\":\"chrome\""))

        let decoded = try JSONDecoder().decode(PWAEntry.self, from: data)
        #expect(decoded == entry)
    }

    @Test("encodes nil start_url as null")
    func nilStartURL() throws {
        let entry = PWAEntry(
            bundleID: "com.apple.Safari.WebApp.X",
            displayName: "X",
            startURL: nil,
            source: .safari
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(PWAEntry.self, from: data)
        #expect(decoded.startURL == nil)
    }
}

@Suite("PWAConfig")
struct PWAConfigTests {

    @Test("defaults to empty")
    func defaultsEmpty() {
        let config = PWAConfig()
        #expect(config.enabled.isEmpty)
        #expect(config.cachedEntries.isEmpty)
        #expect(config == .empty)
    }

    @Test("isEnabled returns false for unknown bundle IDs")
    func isEnabledUnknown() {
        var config = PWAConfig()
        config.enabled["com.example"] = false
        #expect(!config.isEnabled(bundleID: "com.example"))
        #expect(!config.isEnabled(bundleID: "com.other"))
    }

    @Test("enabledBundleIDs lists only true values in stable order")
    func enabledBundleIDsList() {
        let config = PWAConfig(enabled: [
            "com.zzz": true,
            "com.aaa": true,
            "com.bbb": false,
        ])
        #expect(config.enabledBundleIDs == ["com.aaa", "com.zzz"])
    }

    @Test("decodes pre-v2 configs with missing pwa key")
    func decodesMissingPWA() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PWAConfig.self, from: json)
        #expect(decoded == .empty)
    }

    @Test("encodes pwa as snake_case nested object")
    func encodesNestedKeys() throws {
        let entry = PWAEntry(
            bundleID: "com.google.Chrome.app.x",
            displayName: "x",
            startURL: nil,
            source: .chrome
        )
        let config = PWAConfig(enabled: ["com.google.Chrome.app.x": true], cachedEntries: [entry])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(config)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"cached_entries\""))
        #expect(json.contains("\"enabled\""))
    }
}

@Suite("AutoCaptureConfig.pwa")
struct AutoCaptureConfigPWATests {

    @Test("defaults pwa to empty")
    func defaultsEmpty() {
        #expect(AutoCaptureConfig().pwa == .empty)
    }

    @Test("decodes pre-v2 configs with missing pwa key")
    func decodesPreV2() throws {
        let json = """
        {
          "enabled": true,
          "start_delay_seconds": 3
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AutoCaptureConfig.self, from: json)
        #expect(decoded.pwa == .empty)
        #expect(decoded.enabled == true)
        #expect(decoded.startDelaySeconds == 3)
    }

    @Test("encodes pwa as snake_case nested object")
    func encodesNested() throws {
        var config = AutoCaptureConfig()
        config.pwa.enabled["com.google.Chrome.app.x"] = true
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(config)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"pwa\""))
        #expect(json.contains("\"cached_entries\""))
    }
}
