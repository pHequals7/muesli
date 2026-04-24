import Foundation
import os

protocol MeetingHookDispatching {
    func dispatchCompletedMeetingHook(meetingID: Int64, completedAt: Date, config: AppConfig)
}

struct MeetingHookEvent: Codable, Equatable {
    let schemaVersion: Int
    let event: String
    let kind: String
    let id: Int64
    let completedAt: String
}

private final class BoundedOutputBuffer {
    private let capacity: Int
    private let queue = DispatchQueue(label: "com.muesli.native.meeting-hook-output-buffer")
    private var data = Data()

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        queue.sync {
            data.append(chunk)
            if data.count > capacity {
                data.removeFirst(data.count - capacity)
            }
        }
    }

    func stringValue() -> String? {
        queue.sync {
            guard !data.isEmpty else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

final class MeetingHookRunner: MeetingHookDispatching {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "MeetingHook")
    private static let maxLoggedStandardErrorBytes = 4096

    private let supportDirectory: URL
    private let fileManager: FileManager
    private let logQueue = DispatchQueue(label: "com.muesli.native.meeting-hook-log")
    private let dateProvider: () -> Date

    init(
        supportDirectory: URL = AppIdentity.supportDirectoryURL,
        fileManager: FileManager = .default,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.supportDirectory = supportDirectory
        self.fileManager = fileManager
        self.dateProvider = dateProvider
    }

    var logURL: URL {
        supportDirectory.appendingPathComponent("meeting-hook.log")
    }

    func dispatchCompletedMeetingHook(meetingID: Int64, completedAt: Date, config: AppConfig) {
        let event = MeetingHookEvent(
            schemaVersion: 1,
            event: "meeting.completed",
            kind: "meeting",
            id: meetingID,
            completedAt: Self.iso8601Formatter.string(from: completedAt)
        )

        Task.detached(priority: .utility) { [self] in
            executeIfConfigured(event: event, config: config)
        }
    }

    func executeIfConfigured(event: MeetingHookEvent, config: AppConfig) {
        guard config.meetingHookEnabled else { return }

        let trimmedPath = config.meetingHookPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            writeLog("skipped: hook enabled but no executable path configured")
            return
        }
        guard NSString(string: trimmedPath).isAbsolutePath else {
            writeLog("skipped: hook path must be absolute path=\(trimmedPath)")
            return
        }
        guard fileManager.fileExists(atPath: trimmedPath) else {
            writeLog("launch failed: executable does not exist path=\(trimmedPath)")
            return
        }
        guard fileManager.isExecutableFile(atPath: trimmedPath) else {
            writeLog("launch failed: executable is not runnable path=\(trimmedPath)")
            return
        }

        let payloadData: Data
        do {
            payloadData = try JSONEncoder().encode(event)
        } catch {
            writeLog("encoding failed: id=\(event.id) error=\(error.localizedDescription)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: trimmedPath)
        process.currentDirectoryURL = supportDirectory
        process.standardOutput = FileHandle.nullDevice
        let standardErrorPipe = Pipe()
        let standardErrorBuffer = BoundedOutputBuffer(capacity: Self.maxLoggedStandardErrorBytes)
        standardErrorPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            standardErrorBuffer.append(chunk)
        }
        process.standardError = standardErrorPipe

        let inputPipe = Pipe()
        process.standardInput = inputPipe

        let terminationSemaphore = DispatchSemaphore(value: 0)
        var terminationStatus: Int32 = -1
        process.terminationHandler = { terminatedProcess in
            terminationStatus = terminatedProcess.terminationStatus
            terminationSemaphore.signal()
        }

        do {
            try process.run()
        } catch {
            standardErrorPipe.fileHandleForReading.readabilityHandler = nil
            writeLog("launch failed: id=\(event.id) path=\(trimmedPath) error=\(error.localizedDescription)")
            return
        }

        let timeoutSeconds = max(config.meetingHookTimeoutSeconds, 1)
        writeLog("started: id=\(event.id) path=\(trimmedPath) timeout=\(timeoutSeconds)s")

        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: payloadData)
        } catch {
            writeLog("stdin write failed: id=\(event.id) path=\(trimmedPath) error=\(error.localizedDescription)")
            closeInputPipe(inputPipe, event: event, path: trimmedPath)
            standardErrorPipe.fileHandleForReading.readabilityHandler = nil
            terminate(process: process, semaphore: terminationSemaphore)
            drainStandardError(from: standardErrorPipe, into: standardErrorBuffer)
            return
        }
        closeInputPipe(inputPipe, event: event, path: trimmedPath)

        if terminationSemaphore.wait(timeout: .now() + .seconds(timeoutSeconds)) == .timedOut {
            standardErrorPipe.fileHandleForReading.readabilityHandler = nil
            terminate(process: process, semaphore: terminationSemaphore)
            drainStandardError(from: standardErrorPipe, into: standardErrorBuffer)
            writeLog("timed out: id=\(event.id) path=\(trimmedPath) timeout=\(timeoutSeconds)s\(standardErrorSuffix(from: standardErrorBuffer))")
            return
        }

        standardErrorPipe.fileHandleForReading.readabilityHandler = nil
        drainStandardError(from: standardErrorPipe, into: standardErrorBuffer)

        if terminationStatus == 0 {
            writeLog("completed: id=\(event.id) path=\(trimmedPath) exit=0")
        } else {
            writeLog("failed: id=\(event.id) path=\(trimmedPath) exit=\(terminationStatus)\(standardErrorSuffix(from: standardErrorBuffer))")
        }
    }

    private func terminate(process: Process, semaphore: DispatchSemaphore) {
        guard process.isRunning else { return }
        process.terminate()
        if semaphore.wait(timeout: .now() + .seconds(1)) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = semaphore.wait(timeout: .now() + .seconds(1))
        }
    }

    private func closeInputPipe(_ inputPipe: Pipe, event: MeetingHookEvent, path: String) {
        do {
            try inputPipe.fileHandleForWriting.close()
        } catch {
            writeLog("stdin close failed: id=\(event.id) path=\(path) error=\(error.localizedDescription)")
        }
    }

    private func drainStandardError(from pipe: Pipe, into buffer: BoundedOutputBuffer) {
        do {
            if let trailingData = try pipe.fileHandleForReading.readToEnd(), !trailingData.isEmpty {
                buffer.append(trailingData)
            }
            try pipe.fileHandleForReading.close()
        } catch {
            writeLog("stderr capture failed: error=\(error.localizedDescription)")
        }
    }

    private func standardErrorSuffix(from buffer: BoundedOutputBuffer) -> String {
        guard let value = buffer.stringValue() else { return "" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let singleLine = trimmed
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return " stderr=\(singleLine)"
    }

    private func writeLog(_ message: String) {
        let line = "[\(Self.iso8601Formatter.string(from: dateProvider()))] \(message)\n"
        Self.logger.log("\(line, privacy: .public)")

        logQueue.sync {
            do {
                try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
                if !fileManager.fileExists(atPath: logURL.path) {
                    fileManager.createFile(atPath: logURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } catch {
                fputs("[meeting-hook] log write failed: \(error)\n", stderr)
            }
        }
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
