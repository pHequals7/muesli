import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("MeetingHookRunner")
struct MeetingHookRunnerTests {

    @Test("disabled hook is a no-op")
    func disabledHookIsNoOp() async throws {
        let directory = makeTemporaryDirectory()
        let runner = MeetingHookRunner(supportDirectory: directory)
        let event = makeEvent(id: 101)

        await Task.detached {
            runner.executeIfConfigured(event: event, config: AppConfig())
        }.value

        #expect(FileManager.default.fileExists(atPath: runner.logURL.path) == false)
    }

    @Test("empty path logs a skipped entry")
    func emptyPathLogsSkippedEntry() async throws {
        let directory = makeTemporaryDirectory()
        let runner = MeetingHookRunner(supportDirectory: directory)
        var config = AppConfig()
        config.meetingHookEnabled = true

        await Task.detached {
            runner.executeIfConfigured(event: makeEvent(id: 102), config: config)
        }.value

        let log = try String(contentsOf: runner.logURL, encoding: .utf8)
        #expect(log.contains("skipped: hook enabled but no executable path configured"))
    }

    @Test("valid executable receives stdin payload")
    func validExecutableReceivesPayload() async throws {
        let directory = makeTemporaryDirectory()
        let outputURL = directory.appendingPathComponent("payload.json")
        let scriptURL = try makeScript(
            directory: directory,
            name: "capture-payload.sh",
            body: """
            #!/bin/sh
            cat > "\(outputURL.path)"
            """
        )
        let runner = MeetingHookRunner(supportDirectory: directory)
        var config = AppConfig()
        config.meetingHookEnabled = true
        config.meetingHookPath = scriptURL.path
        config.meetingHookTimeoutSeconds = 5

        await Task.detached {
            runner.executeIfConfigured(event: makeEvent(id: 125), config: config)
        }.value

        let payload = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(payload.contains("\"event\":\"meeting.completed\""))
        #expect(payload.contains("\"id\":125"))
    }

    @Test("timeout kills long running executable and logs timeout")
    func timeoutLogsAndTerminatesProcess() async throws {
        let directory = makeTemporaryDirectory()
        let scriptURL = try makeScript(
            directory: directory,
            name: "sleep-forever.sh",
            body: """
            #!/bin/sh
            sleep 10
            """
        )
        let runner = MeetingHookRunner(supportDirectory: directory)
        var config = AppConfig()
        config.meetingHookEnabled = true
        config.meetingHookPath = scriptURL.path
        config.meetingHookTimeoutSeconds = 1

        await Task.detached {
            runner.executeIfConfigured(event: makeEvent(id: 201), config: config)
        }.value

        let log = try String(contentsOf: runner.logURL, encoding: .utf8)
        #expect(log.contains("timed out: id=201"))
    }

    @Test("non-zero exit logs failure")
    func nonZeroExitLogsFailure() async throws {
        let directory = makeTemporaryDirectory()
        let scriptURL = try makeScript(
            directory: directory,
            name: "fail.sh",
            body: """
            #!/bin/sh
            echo "hook stderr" >&2
            exit 7
            """
        )
        let runner = MeetingHookRunner(supportDirectory: directory)
        var config = AppConfig()
        config.meetingHookEnabled = true
        config.meetingHookPath = scriptURL.path
        config.meetingHookTimeoutSeconds = 5

        await Task.detached {
            runner.executeIfConfigured(event: makeEvent(id: 301), config: config)
        }.value

        let log = try String(contentsOf: runner.logURL, encoding: .utf8)
        #expect(log.contains("failed: id=301"))
        #expect(log.contains("exit=7"))
        #expect(log.contains("stderr=hook stderr"))
    }

    private func makeEvent(id: Int64) -> MeetingHookEvent {
        MeetingHookEvent(
            schemaVersion: 1,
            event: "meeting.completed",
            kind: "meeting",
            id: id,
            completedAt: "2026-04-24T12:34:56Z"
        )
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-hook-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeScript(directory: URL, name: String, body: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
