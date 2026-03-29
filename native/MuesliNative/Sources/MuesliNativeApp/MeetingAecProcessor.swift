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

struct MeetingAecDiagnosticsSnapshot: Sendable {
    let modeDescription: String
    let configuredDelayMs: Int
    let renderFramesSubmitted: Int
    let captureFramesProcessed: Int
    let captureFramesBeforeFirstRender: Int
    let renderStarvationCount: Int

    var summaryLine: String {
        "[meeting] AEC diagnostics mode=\(modeDescription) delayMs=\(configuredDelayMs) " +
        "renderFrames=\(renderFramesSubmitted) captureFrames=\(captureFramesProcessed) " +
        "captureBeforeFirstRender=\(captureFramesBeforeFirstRender) renderStarvation=\(renderStarvationCount)"
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
        var sawRenderFrame = false
        var lastRenderUptime: TimeInterval?
    }

    static let sampleRate = 16_000
    static let frameSampleCount = sampleRate / 100
    private static let staleRenderThresholdSeconds: TimeInterval = 0.25

    private let engine: any MeetingAecProcessingEngine
    private let frameSampleCount: Int
    private let lock = OSAllocatedUnfairLock(initialState: State())

    init(
        sampleRate: Int = sampleRate,
        engine: (any MeetingAecProcessingEngine)? = nil
    ) throws {
        self.frameSampleCount = sampleRate / 100
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
            if state.mode == mode {
                return
            }
            state.mode = mode
            state.pendingRender.removeAll(keepingCapacity: false)
            state.pendingCapture.removeAll(keepingCapacity: false)
            state.lastRenderUptime = nil
            state.sawRenderFrame = false

            if case .enabled(let delayMs) = mode {
                _ = engine.setAudioBufferDelayMs(delayMs)
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
                renderStarvationCount: state.renderStarvationCount
            )
        }
    }

    func appendRender(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        lock.withLock { state in
            guard case .enabled = state.mode else { return }
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
        guard !samples.isEmpty else { return [] }
        return lock.withLock { state in
            state.pendingCapture.append(contentsOf: samples)

            var output: [Int16] = []
            while state.pendingCapture.count >= frameSampleCount {
                let frame = Array(state.pendingCapture.prefix(frameSampleCount))
                state.pendingCapture.removeFirst(frameSampleCount)
                state.captureFramesProcessed += 1
                updateDiagnosticsForCapture(&state)

                switch state.mode {
                case .enabled:
                    output.append(contentsOf: engine.processCaptureFrame(frame) ?? frame)
                case .bypassed:
                    output.append(contentsOf: frame)
                }
            }
            return output
        }
    }

    func flushCaptureRemainder() -> [Int16] {
        lock.withLock { state in
            guard !state.pendingCapture.isEmpty else { return [] }

            let originalCount = state.pendingCapture.count
            var padded = state.pendingCapture
            state.pendingCapture.removeAll(keepingCapacity: false)

            if padded.count < frameSampleCount {
                padded.append(contentsOf: repeatElement(0, count: frameSampleCount - padded.count))
            }

            state.captureFramesProcessed += 1
            updateDiagnosticsForCapture(&state)

            let processed: [Int16]
            switch state.mode {
            case .enabled:
                processed = engine.processCaptureFrame(padded) ?? padded
            case .bypassed:
                processed = padded
            }
            return Array(processed.prefix(originalCount))
        }
    }

    func reset() {
        lock.withLock { state in
            state.pendingRender.removeAll(keepingCapacity: false)
            state.pendingCapture.removeAll(keepingCapacity: false)
        }
    }

    private func updateDiagnosticsForCapture(_ state: inout State) {
        let now = ProcessInfo.processInfo.systemUptime

        if !state.sawRenderFrame {
            state.captureFramesBeforeFirstRender += 1
            state.renderStarvationCount += 1
            return
        }

        if let lastRenderUptime = state.lastRenderUptime,
           now - lastRenderUptime > Self.staleRenderThresholdSeconds {
            state.renderStarvationCount += 1
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
