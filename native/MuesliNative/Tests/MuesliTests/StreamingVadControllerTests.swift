import FluidAudio
import Foundation
import Testing
@testable import MuesliNativeApp

private actor StreamingVadTestProbe {
    private(set) var processedCount = 0
    private(set) var inFlightCount = 0
    private(set) var maxConcurrentCount = 0
    private(set) var boundaryCount = 0

    func processingStarted() {
        inFlightCount += 1
        maxConcurrentCount = max(maxConcurrentCount, inFlightCount)
    }

    func processingFinished() {
        inFlightCount = max(0, inFlightCount - 1)
        processedCount += 1
    }

    func boundaryTriggered() {
        boundaryCount += 1
    }
}

@Suite("StreamingVadController")
struct StreamingVadControllerTests {
    @Test("serializes streaming VAD processing to a single in-flight chunk")
    func serializesChunkProcessing() async throws {
        let probe = StreamingVadTestProbe()
        let controller = StreamingVadController(
            minChunkDuration: 0,
            maxChunkDuration: 3600,
            makeInitialState: { VadStreamState.initial() },
            processStreamChunk: { _, state in
                await probe.processingStarted()
                try? await Task.sleep(for: .milliseconds(25))
                await probe.processingFinished()
                return VadStreamResult(state: state, event: nil, probability: 0.0)
            }
        )

        controller.start()
        for _ in 0..<10 {
            controller.processAudio([Float](repeating: 0, count: VadManager.chunkSize))
        }

        let deadline = ContinuousClock.now + .seconds(2)
        while await probe.processedCount < 10, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        controller.stop()

        #expect(await probe.processedCount == 10)
        #expect(await probe.maxConcurrentCount == 1)
    }

    @Test("buffers chunks that arrive before stream state initialization completes")
    func buffersChunksBeforeStateReady() async throws {
        let probe = StreamingVadTestProbe()
        let controller = StreamingVadController(
            minChunkDuration: 0,
            maxChunkDuration: 3600,
            makeInitialState: {
                try? await Task.sleep(for: .milliseconds(120))
                return VadStreamState.initial()
            },
            processStreamChunk: { _, state in
                await probe.processingStarted()
                try? await Task.sleep(for: .milliseconds(10))
                await probe.processingFinished()
                return VadStreamResult(state: state, event: nil, probability: 0.0)
            }
        )

        controller.start()
        for _ in 0..<3 {
            controller.processAudio([Float](repeating: 0, count: VadManager.chunkSize))
        }

        let deadline = ContinuousClock.now + .seconds(2)
        while await probe.processedCount < 3, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        controller.stop()

        #expect(await probe.processedCount == 3)
        #expect(await probe.maxConcurrentCount == 1)
    }

    @Test("emits a chunk boundary when streaming VAD detects speech end")
    func emitsChunkBoundaryOnSpeechEnd() async throws {
        let probe = StreamingVadTestProbe()
        let controller = StreamingVadController(
            minChunkDuration: 0,
            maxChunkDuration: 3600,
            makeInitialState: { VadStreamState.initial() },
            processStreamChunk: { _, state in
                await probe.processingStarted()
                await probe.processingFinished()
                return VadStreamResult(
                    state: state,
                    event: VadStreamEvent(kind: .speechEnd, sampleIndex: VadManager.chunkSize),
                    probability: 0.05
                )
            }
        )

        controller.onChunkBoundary = {
            Task { await probe.boundaryTriggered() }
        }

        controller.start()
        controller.processAudio([Float](repeating: 0, count: VadManager.chunkSize))

        let deadline = ContinuousClock.now + .seconds(1)
        while await probe.boundaryCount < 1, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        controller.stop()

        #expect(await probe.boundaryCount == 1)
    }
}
