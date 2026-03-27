import Foundation

/// Lightweight span-based profiler. Zero overhead when disabled (isEnabled == false).
/// Emits Speedscope evented profile JSON on export.
///
/// Usage:
///   Profiler.shared.begin("transcription")
///   defer { Profiler.shared.end("transcription") }
///
///   // or with the convenience wrapper:
///   let result = Profiler.shared.measure("transcription") { ... }
public final class Profiler: @unchecked Sendable {
    public static let shared = Profiler()

    public var isEnabled: Bool = false

    // MARK: - Internal event model

    public enum EventKind: String { case open = "O", close = "C" }

    public struct Event {
        public let kind: EventKind
        public let frameIndex: Int
        public let at: Double        // milliseconds since profilerStart
        public let threadID: UInt64
    }

    public struct Frame: Equatable, Hashable {
        public let name: String
        public let category: String?
    }

    // MARK: - Storage

    private let lock = NSLock()
    private var frames: [Frame] = []
    private var frameIndex: [Frame: Int] = [:]
    private var events: [Event] = []
    private var profilerStart: Date = Date()

    private init() {}

    // MARK: - Public API

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        frames = []
        frameIndex = [:]
        events = []
        profilerStart = Date()
    }

    public func begin(_ name: String, category: String? = nil) {
        guard isEnabled else { return }
        record(kind: .open, name: name, category: category)
    }

    public func end(_ name: String, category: String? = nil) {
        guard isEnabled else { return }
        record(kind: .close, name: name, category: category)
    }

    /// Synchronous convenience wrapper — records open/close around a throwing block.
    @discardableResult
    public func measure<T>(_ name: String, category: String? = nil, _ block: () throws -> T) rethrows -> T {
        begin(name, category: category)
        defer { end(name, category: category) }
        return try block()
    }

    /// Async convenience wrapper — records open/close around an async throwing block.
    @discardableResult
    public func measureAsync<T>(_ name: String, category: String? = nil, _ block: () async throws -> T) async rethrows -> T {
        begin(name, category: category)
        defer { end(name, category: category) }
        return try await block()
    }

    // MARK: - Internal recording

    private func record(kind: EventKind, name: String, category: String?) {
        let now = Date().timeIntervalSince(profilerStart) * 1000  // ms
        let threadID = pthread_mach_thread_np(pthread_self())
        let frame = Frame(name: name, category: category)

        lock.lock()
        let idx: Int
        if let existing = frameIndex[frame] {
            idx = existing
        } else {
            idx = frames.count
            frames.append(frame)
            frameIndex[frame] = idx
        }
        events.append(Event(kind: kind, frameIndex: idx, at: now, threadID: UInt64(threadID)))
        lock.unlock()
    }

    // MARK: - Export

    public func capturedEvents() -> [Event] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    public func capturedFrames() -> [Frame] {
        lock.lock(); defer { lock.unlock() }
        return frames
    }

    public func totalDurationMs() -> Double {
        lock.lock(); defer { lock.unlock() }
        return events.last?.at ?? 0
    }
}
