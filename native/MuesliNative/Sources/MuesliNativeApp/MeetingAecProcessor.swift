import Foundation
import WebRTCAec3Bridge
import os

protocol MeetingAecProcessingEngine {
    func analyzeRenderFrame(_ frame: [Int16]) -> Bool
    func setAudioBufferDelayMs(_ delayMs: Int) -> Bool
    func processCaptureFrame(_ frame: [Int16]) -> [Int16]?
}

enum MeetingAecMode: Equatable {
    case enabled(delayMs: Int)
    case bypassed(reason: String)
}

enum MeetingAecCaptureHealth: Equatable, Sendable {
    case healthy
    case warmingUp
    case missingRenderReference
    case staleRenderReference
    case bypassed(reason: String)

    var shouldRunAec: Bool {
        switch self {
        case .healthy, .warmingUp:
            return true
        case .missingRenderReference, .staleRenderReference, .bypassed:
            return false
        }
    }

    var shouldTrustSegmentation: Bool {
        switch self {
        case .healthy, .bypassed:
            return true
        case .warmingUp, .missingRenderReference, .staleRenderReference:
            return false
        }
    }
}

struct MeetingAecProcessedCaptureBatch: Sendable {
    let samples: [Int16]
    let primaryHealth: MeetingAecCaptureHealth
    let allFramesTrustedForSegmentation: Bool

    static let empty = MeetingAecProcessedCaptureBatch(
        samples: [],
        primaryHealth: .healthy,
        allFramesTrustedForSegmentation: true
    )
}

struct MeetingAecDiagnosticsSnapshot: Sendable {
    let modeDescription: String
    let configuredDelayMs: Int
    let renderFramesSubmitted: Int
    let captureFramesProcessed: Int
    let captureFramesBeforeFirstRender: Int
    let renderStarvationCount: Int
    let warmingUpCaptureFrames: Int
    let staleRenderCaptureFrames: Int
    let bypassedCaptureFrames: Int

    var summaryLine: String {
        "[meeting] AEC diagnostics mode=\(modeDescription) delayMs=\(configuredDelayMs) " +
        "renderFrames=\(renderFramesSubmitted) captureFrames=\(captureFramesProcessed) " +
        "captureBeforeFirstRender=\(captureFramesBeforeFirstRender) renderStarvation=\(renderStarvationCount) " +
        "warmingUpFrames=\(warmingUpCaptureFrames) staleRenderFrames=\(staleRenderCaptureFrames) " +
        "bypassedFrames=\(bypassedCaptureFrames)"
    }
}

final class MeetingAecProcessor {
    private struct State {
        var pendingRender: [Int16] = []
        var pendingCapture: [Int16] = []
        var mode: MeetingAecMode = .enabled(delayMs: 0)
        var renderFramesSubmitted = 0
        var captureFramesProcessed = 0
        var captureFramesBeforeFirstRender = 0
        var renderStarvationCount = 0
        var warmingUpCaptureFrames = 0
        var staleRenderCaptureFrames = 0
        var bypassedCaptureFrames = 0
        var sawRenderFrame = false
        var lastRenderUptime: TimeInterval?
        var warmupCaptureFramesRemaining = 0
    }

    static let sampleRate = 16_000
    static let frameSampleCount = sampleRate / 100
    private static let defaultStaleRenderThresholdSeconds: TimeInterval = 0.2
    private static let defaultWarmupCaptureFrames = 20
    private static let defaultRecoveryWarmupCaptureFrames = 8

    private let engine: any MeetingAecProcessingEngine
    private let frameSampleCount: Int
    private let staleRenderThresholdSeconds: TimeInterval
    private let warmupCaptureFrames: Int
    private let recoveryWarmupCaptureFrames: Int
    private let lock = OSAllocatedUnfairLock(initialState: State())

    init(
        sampleRate: Int = sampleRate,
        engine: (any MeetingAecProcessingEngine)? = nil,
        staleRenderThresholdSeconds: TimeInterval = defaultStaleRenderThresholdSeconds,
        warmupCaptureFrames: Int = defaultWarmupCaptureFrames,
        recoveryWarmupCaptureFrames: Int = defaultRecoveryWarmupCaptureFrames
    ) throws {
        self.frameSampleCount = sampleRate / 100
        self.staleRenderThresholdSeconds = staleRenderThresholdSeconds
        self.warmupCaptureFrames = warmupCaptureFrames
        self.recoveryWarmupCaptureFrames = recoveryWarmupCaptureFrames

        if let engine {
            self.engine = engine
        } else if let engine = WebRTCAec3ProcessingEngine(sampleRate: sampleRate) {
            self.engine = engine
        } else {
            throw NSError(
                domain: "MeetingAecProcessor",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to initialize WebRTC AEC3."]
            )
        }
    }

    func updateMode(_ mode: MeetingAecMode) {
        lock.withLock { state in
            guard state.mode != mode else { return }

            state.mode = mode
            state.pendingRender.removeAll(keepingCapacity: false)
            state.pendingCapture.removeAll(keepingCapacity: false)
            state.lastRenderUptime = nil
            state.sawRenderFrame = false

            switch mode {
            case .enabled(let delayMs):
                state.warmupCaptureFramesRemaining = warmupCaptureFrames
                _ = engine.setAudioBufferDelayMs(delayMs)
            case .bypassed:
                state.warmupCaptureFramesRemaining = 0
            }
        }
    }

    func diagnosticsSnapshot() -> MeetingAecDiagnosticsSnapshot {
        lock.withLock { state in
            let configuredDelayMs: Int
            let modeDescription: String
            switch state.mode {
            case .enabled(let delayMs):
                configuredDelayMs = delayMs
                modeDescription = "enabled"
            case .bypassed(let reason):
                configuredDelayMs = 0
                modeDescription = "bypassed(\(reason))"
            }

            return MeetingAecDiagnosticsSnapshot(
                modeDescription: modeDescription,
                configuredDelayMs: configuredDelayMs,
                renderFramesSubmitted: state.renderFramesSubmitted,
                captureFramesProcessed: state.captureFramesProcessed,
                captureFramesBeforeFirstRender: state.captureFramesBeforeFirstRender,
                renderStarvationCount: state.renderStarvationCount,
                warmingUpCaptureFrames: state.warmingUpCaptureFrames,
                staleRenderCaptureFrames: state.staleRenderCaptureFrames,
                bypassedCaptureFrames: state.bypassedCaptureFrames
            )
        }
    }

    func appendRender(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        lock.withLock { state in
            guard case .enabled = state.mode else { return }

            let now = ProcessInfo.processInfo.systemUptime
            if let lastRenderUptime = state.lastRenderUptime,
               now - lastRenderUptime > staleRenderThresholdSeconds {
                state.warmupCaptureFramesRemaining = max(
                    state.warmupCaptureFramesRemaining,
                    recoveryWarmupCaptureFrames
                )
            }

            state.pendingRender.append(contentsOf: samples)
            while state.pendingRender.count >= frameSampleCount {
                let frame = Array(state.pendingRender.prefix(frameSampleCount))
                state.pendingRender.removeFirst(frameSampleCount)
                _ = engine.analyzeRenderFrame(frame)
                state.renderFramesSubmitted += 1
                state.sawRenderFrame = true
                state.lastRenderUptime = ProcessInfo.processInfo.systemUptime
            }
        }
    }

    func processCapture(_ samples: [Int16]) -> [Int16] {
        processCaptureBatch(samples).samples
    }

    func processCaptureBatch(_ samples: [Int16]) -> MeetingAecProcessedCaptureBatch {
        guard !samples.isEmpty else { return .empty }
        return lock.withLock { state in
            state.pendingCapture.append(contentsOf: samples)

            var output: [Int16] = []
            var primaryHealth: MeetingAecCaptureHealth?
            var allFramesTrustedForSegmentation = true

            while state.pendingCapture.count >= frameSampleCount {
                let frame = Array(state.pendingCapture.prefix(frameSampleCount))
                state.pendingCapture.removeFirst(frameSampleCount)
                state.captureFramesProcessed += 1

                let health: MeetingAecCaptureHealth
                switch state.mode {
                case .bypassed(let reason):
                    state.bypassedCaptureFrames += 1
                    health = .bypassed(reason: reason)
                case .enabled:
                    let now = ProcessInfo.processInfo.systemUptime
                    if !state.sawRenderFrame {
                        state.captureFramesBeforeFirstRender += 1
                        state.renderStarvationCount += 1
                        health = .missingRenderReference
                    } else if let lastRenderUptime = state.lastRenderUptime,
                              now - lastRenderUptime > staleRenderThresholdSeconds {
                        state.renderStarvationCount += 1
                        state.staleRenderCaptureFrames += 1
                        health = .staleRenderReference
                    } else if state.warmupCaptureFramesRemaining > 0 {
                        state.warmingUpCaptureFrames += 1
                        state.warmupCaptureFramesRemaining -= 1
                        health = .warmingUp
                    } else {
                        health = .healthy
                    }
                }
                if primaryHealth == nil || health != .healthy {
                    primaryHealth = health
                }
                allFramesTrustedForSegmentation = allFramesTrustedForSegmentation && health.shouldTrustSegmentation

                if health.shouldRunAec {
                    output.append(contentsOf: engine.processCaptureFrame(frame) ?? frame)
                } else {
                    output.append(contentsOf: frame)
                }
            }

            return MeetingAecProcessedCaptureBatch(
                samples: output,
                primaryHealth: primaryHealth ?? currentHealth(for: state),
                allFramesTrustedForSegmentation: allFramesTrustedForSegmentation
            )
        }
    }

    func flushCaptureRemainder() -> [Int16] {
        flushCaptureRemainderBatch().samples
    }

    func flushCaptureRemainderBatch() -> MeetingAecProcessedCaptureBatch {
        lock.withLock { state in
            guard !state.pendingCapture.isEmpty else { return MeetingAecProcessedCaptureBatch.empty }

            let originalCount = state.pendingCapture.count
            var padded = state.pendingCapture
            state.pendingCapture.removeAll(keepingCapacity: false)

            if padded.count < frameSampleCount {
                padded.append(contentsOf: repeatElement(0, count: frameSampleCount - padded.count))
            }

            state.captureFramesProcessed += 1
            let health: MeetingAecCaptureHealth
            switch state.mode {
            case .bypassed(let reason):
                state.bypassedCaptureFrames += 1
                health = .bypassed(reason: reason)
            case .enabled:
                let now = ProcessInfo.processInfo.systemUptime
                if !state.sawRenderFrame {
                    state.captureFramesBeforeFirstRender += 1
                    state.renderStarvationCount += 1
                    health = .missingRenderReference
                } else if let lastRenderUptime = state.lastRenderUptime,
                          now - lastRenderUptime > staleRenderThresholdSeconds {
                    state.renderStarvationCount += 1
                    state.staleRenderCaptureFrames += 1
                    health = .staleRenderReference
                } else if state.warmupCaptureFramesRemaining > 0 {
                    state.warmingUpCaptureFrames += 1
                    state.warmupCaptureFramesRemaining -= 1
                    health = .warmingUp
                } else {
                    health = .healthy
                }
            }
            let processed: [Int16]
            if health.shouldRunAec {
                processed = engine.processCaptureFrame(padded) ?? padded
            } else {
                processed = padded
            }

            return MeetingAecProcessedCaptureBatch(
                samples: Array(processed.prefix(originalCount)),
                primaryHealth: health,
                allFramesTrustedForSegmentation: health.shouldTrustSegmentation
            )
        }
    }

    func reset() {
        lock.withLock { state in
            let mode = state.mode
            state = State(mode: mode)
        }
    }

    private func currentHealth(for state: State) -> MeetingAecCaptureHealth {
        switch state.mode {
        case .bypassed(let reason):
            return .bypassed(reason: reason)
        case .enabled:
            if !state.sawRenderFrame {
                return .missingRenderReference
            }
            if state.warmupCaptureFramesRemaining > 0 {
                return .warmingUp
            }
            return .healthy
        }
    }
}

private final class WebRTCAec3ProcessingEngine: MeetingAecProcessingEngine {
    private let handle: OpaquePointer

    init?(sampleRate: Int, renderChannels: Int = 1, captureChannels: Int = 1) {
        guard let handle = WebRTCAec3Create(Int32(sampleRate), Int32(renderChannels), Int32(captureChannels)) else {
            return nil
        }
        self.handle = handle
    }

    deinit {
        WebRTCAec3Destroy(handle)
    }

    func analyzeRenderFrame(_ frame: [Int16]) -> Bool {
        frame.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            return WebRTCAec3AnalyzeRender(handle, baseAddress, Int32(frame.count))
        }
    }

    func setAudioBufferDelayMs(_ delayMs: Int) -> Bool {
        WebRTCAec3SetAudioBufferDelay(handle, Int32(delayMs))
    }

    func processCaptureFrame(_ frame: [Int16]) -> [Int16]? {
        var output = [Int16](repeating: 0, count: frame.count)
        let success = frame.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                guard let inputBaseAddress = inputBuffer.baseAddress,
                      let outputBaseAddress = outputBuffer.baseAddress else {
                    return false
                }
                return WebRTCAec3ProcessCapture(handle, inputBaseAddress, Int32(frame.count), outputBaseAddress)
            }
        }
        return success ? output : nil
    }
}
