import Foundation

/// Serialises Profiler data to the Speedscope evented profile JSON format.
/// Spec: https://www.speedscope.app/file-format-schema.json
///
/// Groups events by thread — each thread becomes its own named profile in the file.
public enum SpeedscopeExporter {

    public struct Output {
        public let json: String
        public let path: URL
    }

    /// Build Speedscope JSON from current profiler state.
    public static func export(profiler: Profiler = .shared, name: String = "Muesli") -> String {
        let frames = profiler.capturedFrames()
        let events = profiler.capturedEvents()
        let totalMs = profiler.totalDurationMs()

        // Group events by thread, but route every "C" (close) event to the same thread
        // that emitted the matching "O" (open). This is necessary because measureAsync
        // opens on one thread and the defer-based close fires on whichever thread the
        // async continuation resumes on — a different thread. Speedscope validates each
        // thread's event list as an independent stack and rejects unmatched opens.
        var threadEvents: [UInt64: [Profiler.Event]] = [:]
        var threadOrder: [UInt64] = []
        // Stack per frameIndex tracks (threadID, at) of the most recent open for that frame.
        var openStack: [Int: [(threadID: UInt64, at: Double)]] = [:]

        for event in events {
            switch event.kind {
            case .open:
                // Register thread on first appearance.
                if threadEvents[event.threadID] == nil {
                    threadOrder.append(event.threadID)
                    threadEvents[event.threadID] = []
                }
                openStack[event.frameIndex, default: []].append((event.threadID, event.at))
                threadEvents[event.threadID]!.append(event)

            case .close:
                // Find the thread that opened this frame and route the close there.
                if var stack = openStack[event.frameIndex], !stack.isEmpty {
                    let (openThreadID, _) = stack.removeLast()
                    openStack[event.frameIndex] = stack
                    if threadEvents[openThreadID] == nil {
                        threadOrder.append(openThreadID)
                        threadEvents[openThreadID] = []
                    }
                    // Emit the close on the opening thread (reusing its at timestamp from event).
                    let routed = Profiler.Event(kind: .close, frameIndex: event.frameIndex, at: event.at, threadID: openThreadID)
                    threadEvents[openThreadID]!.append(routed)
                }
                // If no matching open is found, drop the orphaned close rather than corrupt the profile.
            }
        }

        // Frames array — shared across all profiles.
        var framesJSON: [[String: String]] = []
        for frame in frames {
            var obj: [String: String] = ["name": frame.name]
            if let cat = frame.category { obj["col"] = cat }
            framesJSON.append(obj)
        }

        // One evented profile per thread.
        var profilesJSON: [Any] = []
        for threadID in threadOrder {
            let threadEvts = threadEvents[threadID] ?? []
            let threadStart = threadEvts.first?.at ?? 0
            let threadEnd = threadEvts.last?.at ?? totalMs

            var eventsJSON: [[String: Any]] = []
            for evt in threadEvts {
                eventsJSON.append([
                    "type": evt.kind.rawValue,
                    "frame": evt.frameIndex,
                    "at": evt.at
                ])
            }

            profilesJSON.append([
                "type": "evented",
                "name": "Thread \(threadID)",
                "unit": "milliseconds",
                "startValue": threadStart,
                "endValue": threadEnd,
                "events": eventsJSON
            ] as [String: Any])
        }

        let root: [String: Any] = [
            "$schema": "https://www.speedscope.app/file-format-schema.json",
            "shared": ["frames": framesJSON],
            "profiles": profilesJSON,
            "name": name,
            "activeProfileIndex": 0,
            "exporter": "muesli-profiler@1"
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    /// Write to ~/Library/Application Support/Muesli/profiles/<timestamp>.speedscope.json
    /// Returns the written URL.
    @discardableResult
    public static func writeToSupportDirectory(profiler: Profiler = .shared, name: String = "Muesli") -> URL? {
        let json = export(profiler: profiler, name: name)
        guard let data = json.data(using: .utf8) else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let filename = "\(timestamp).speedscope.json"

        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Muesli/profiles")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename)

        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            fputs("[profiler] failed to write profile: \(error)\n", stderr)
            return nil
        }
    }
}
