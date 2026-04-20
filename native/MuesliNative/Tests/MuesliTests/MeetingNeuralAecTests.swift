import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MeetingNeuralAec")
struct MeetingNeuralAecTests {

    @Test("bundle candidates prefer Contents/Resources in packaged apps")
    func candidateURLsPreferResourceDirectory() throws {
        let fixture = try makeTemporaryAppBundle()
        defer { fixture.cleanup() }
        let appBundle = fixture.bundle
        let candidates = MeetingAecModelBundle.candidateURLs(mainBundle: appBundle)

        #expect(candidates.count >= 2)
        #expect(candidates[0].path == appBundle.resourceURL?
            .appendingPathComponent(MeetingAecModelBundle.bundleName, isDirectory: true).path)
        #expect(candidates[1].path == appBundle.bundleURL
            .appendingPathComponent(MeetingAecModelBundle.bundleName, isDirectory: true).path)
    }

    @Test("resolver loads packaged app bundle from Contents/Resources")
    func resolverLoadsResourceBundle() throws {
        let fixture = try makeTemporaryAppBundle()
        defer { fixture.cleanup() }
        let appBundle = fixture.bundle
        let resourceBundleURL = try createResourceBundle(
            at: appBundle.resourceURL!.appendingPathComponent(MeetingAecModelBundle.bundleName, isDirectory: true)
        )

        let resolved = try MeetingAecModelBundle.resolve(mainBundle: appBundle)

        #expect(resolved.bundleURL.standardizedFileURL == resourceBundleURL.standardizedFileURL)
    }

    @Test("resolver falls back to app-root bundle when needed")
    func resolverFallsBackToBundleRoot() throws {
        let fixture = try makeTemporaryAppBundle()
        defer { fixture.cleanup() }
        let appBundle = fixture.bundle
        let rootBundleURL = try createResourceBundle(
            at: appBundle.bundleURL.appendingPathComponent(MeetingAecModelBundle.bundleName, isDirectory: true)
        )

        let resolved = try MeetingAecModelBundle.resolve(mainBundle: appBundle)

        #expect(resolved.bundleURL.standardizedFileURL == rootBundleURL.standardizedFileURL)
    }

    private func makeTemporaryAppBundle() throws -> TemporaryAppBundle {
        let appURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-aec-\(UUID().uuidString)", isDirectory: true)
            .appendingPathExtension("app")
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)

        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        try Data().write(to: macOSURL.appendingPathComponent("TestApp"))

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundlePackageType</key>
          <string>APPL</string>
          <key>CFBundleExecutable</key>
          <string>TestApp</string>
          <key>CFBundleIdentifier</key>
          <string>com.muesli.tests.MeetingAec</string>
          <key>CFBundleName</key>
          <string>TestApp</string>
        </dict>
        </plist>
        """
        try plist.write(to: contentsURL.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        let bundle = try #require(Bundle(url: appURL))
        return TemporaryAppBundle(url: appURL, bundle: bundle)
    }

    private func createResourceBundle(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "{}".write(to: url.appendingPathComponent("Manifest.json"), atomically: true, encoding: .utf8)
        return url
    }
}

private struct TemporaryAppBundle {
    let url: URL
    let bundle: Bundle

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}
