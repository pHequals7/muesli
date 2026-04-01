import FluidAudio
import Foundation
import MuesliCore
import os

final class MeetingChunkCollector {
    private struct State {
        var tasks: [Task<[SpeechSegment], Never>] = []
        var isClosed = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func add(_ task: Task<[SpeechSegment], Never>) -> Bool {
        lock.withLock { state in
            guard !state.isClosed else { return false }
            state.tasks.append(task)
            return true
        }
    }

    func closeAndDrainSortedSegments() async -> [SpeechSegment] {
        let tasksToAwait = lock.withLock { state in
            state.isClosed = true
            let pendingTasks = state.tasks
            state.tasks.removeAll()
            return pendingTasks
        }

        var segments: [SpeechSegment] = []
        for task in tasksToAwait {
            segments.append(contentsOf: await task.value)
        }

        return segments.sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }
    }

    func cancelAll() {
        let tasksToCancel = lock.withLock { state in
            state.isClosed = true
            let pendingTasks = state.tasks
            state.tasks.removeAll()
            return pendingTasks
        }

        tasksToCancel.forEach { $0.cancel() }
    }
}

struct MeetingSessionResult {
    let title: String
    let calendarEventID: String?
    let startTime: Date
    let endTime: Date
    let durationSeconds: Double
    let rawTranscript: String
    let formattedNotes: String
    let retainedRecordingURL: URL?
    let retainedRecordingError: Error?
    let systemRecordingURL: URL?
    let templateSnapshot: MeetingTemplateSnapshot
}

enum MeetingProcessingStage {
    case transcribingAudio
    case generatingTitle
    case summarizingNotes
}

final class MeetingSession {
    private let title: String
    private let calendarEventID: String?
    private let backend: BackendOption
    private let runtime: RuntimePaths
    private let config: AppConfig
    private let transcriptionCoordinator: TranscriptionCoordinator
    private let systemAudioRecorder = SystemAudioRecorder()
    private let fullSessionMicRecorder = MicrophoneRecorder()

    /// Streaming mic recorder with real-time buffer access (AVAudioEngine)
    private var streamingMicRecorder = StreamingMicRecorder()
    private var processedMicChunkRecorder: PCMChunkRecorder?
    private var meetingAecProcessor: MeetingAecProcessor?
    private var retainedRecordingWriter: MeetingRecordingWriter?
    private var retainedRecordingWriterError: Error?
    private let outputRouteMonitor = AudioOutputRouteMonitor()
    private var latestOutputRoute: AudioOutputRouteSnapshot?
    /// VAD controller for speech-boundary chunk rotation
    private var vadController: StreamingVadController?
    private let micChunkCollector = MeetingChunkCollector()
    private let chunkRotationQueue = DispatchQueue(label: "MuesliNative.MeetingSession.chunkRotation")
    private var chunkTimingTracker = MeetingChunkTimingTracker()
    var onProgress: ((MeetingProcessingStage) -> Void)?

    /// Current mic power level for waveform visualization.
    func currentPower() -> Float {
        streamingMicRecorder.currentPower()
    }

    private(set) var startTime: Date?
    private(set) var isRecording = false

    init(
        title: String,
        calendarEventID: String?,
        backend: BackendOption,
        runtime: RuntimePaths,
        config: AppConfig,
        transcriptionCoordinator: TranscriptionCoordinator
    ) {
        self.title = title
        self.calendarEventID = calendarEventID
        self.backend = backend
        self.runtime = runtime
        self.config = config
        self.transcriptionCoordinator = transcriptionCoordinator
    }

    private var serializedCustomWords: [[String: Any]] {
        config.customWords.map { word in
            var dict: [String: Any] = ["word": word.word]
            if let replacement = word.replacement {
                dict["replacement"] = replacement
            }
            return dict
        }
    }

    func start() async throws {
        let vadManager = await transcriptionCoordinator.getVadManager()

        do {
            try prepareRealtimeAudioPipeline(vadManager: vadManager)
            try fullSessionMicRecorder.prepare()
            try streamingMicRecorder.prepare()
            setupRetainedRecordingWriterIfNeeded()
            try fullSessionMicRecorder.start()
            try streamingMicRecorder.start()
            try await systemAudioRecorder.start()
        } catch {
            vadController?.stop()
            vadController = nil
            streamingMicRecorder.onAudioBuffer = nil
            streamingMicRecorder.onPCMSamples = nil
            systemAudioRecorder.onPCMSamples = nil
            fullSessionMicRecorder.cancel()
            retainedRecordingWriter?.cancel()
            retainedRecordingWriter = nil
            processedMicChunkRecorder?.cancel()
            processedMicChunkRecorder = nil
            outputRouteMonitor.stop()
            meetingAecProcessor?.reset()
            meetingAecProcessor = nil
            streamingMicRecorder.cancel()
            if let url = systemAudioRecorder.stop() {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
        let now = Date()
        chunkRotationQueue.sync {
            startTime = now
            chunkTimingTracker.start()
            isRecording = true
        }
        if vadController != nil {
            fputs("[meeting] started with VAD-driven chunk rotation\n", stderr)
        } else {
            fputs("[meeting] VAD not available, using max-duration fallback only\n", stderr)
        }
    }

    /// Abandon the recording — stop everything, delete temp files, don't transcribe.
    func discard() {
        let chunkRecorder = chunkRotationQueue.sync { () -> PCMChunkRecorder? in
            isRecording = false
            chunkTimingTracker.discard()
            let recorder = processedMicChunkRecorder
            processedMicChunkRecorder = nil
            return recorder
        }
        vadController?.stop()
        vadController = nil
        retainedRecordingWriter?.cancel()
        retainedRecordingWriter = nil
        retainedRecordingWriterError = nil
        chunkRecorder?.cancel()
        outputRouteMonitor.stop()
        meetingAecProcessor?.reset()
        meetingAecProcessor = nil
        fullSessionMicRecorder.cancel()
        streamingMicRecorder.onAudioBuffer = nil
        streamingMicRecorder.onPCMSamples = nil
        streamingMicRecorder.cancel()
        systemAudioRecorder.onPCMSamples = nil
        if let url = systemAudioRecorder.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        micChunkCollector.cancelAll()
        fputs("[meeting] recording discarded\n", stderr)
    }

    func stop() async throws -> MeetingSessionResult {
        onProgress?(.transcribingAudio)
        let endTime = Date()
        var micSegments: [SpeechSegment] = []

        // Stop VAD controller
        vadController?.stop()
        vadController = nil
        streamingMicRecorder.onAudioBuffer = nil
        outputRouteMonitor.stop()

        let finalProcessedTailBatch = meetingAecProcessor?.flushCaptureRemainderBatch() ?? .empty
        let (meetingStart, lastChunkTiming, lastMicURL) = chunkRotationQueue.sync { () -> (Date, MeetingChunkTimingSnapshot?, URL?) in
            isRecording = false
            let meetingStart = self.startTime ?? Date()
            if !finalProcessedTailBatch.samples.isEmpty {
                processedMicChunkRecorder?.append(finalProcessedTailBatch.samples)
                chunkTimingTracker.append(sampleCount: finalProcessedTailBatch.samples.count)
            }
            let lastMicURL = processedMicChunkRecorder?.stop()
            processedMicChunkRecorder = nil
            let lastChunkTiming = chunkTimingTracker.finish()
            return (meetingStart, lastChunkTiming, lastMicURL)
        }
        let aecDiagnostics = meetingAecProcessor?.diagnosticsSnapshot()
        meetingAecProcessor?.reset()
        meetingAecProcessor = nil
        let rawStreamingMicURL = streamingMicRecorder.stop()
        streamingMicRecorder.onPCMSamples = nil
        let fullSessionMicURL = fullSessionMicRecorder.stop()
        let retainedRecordingURL = retainedRecordingWriter?.stop()
        retainedRecordingWriter = nil
        defer {
            if let rawStreamingMicURL {
                try? FileManager.default.removeItem(at: rawStreamingMicURL)
            }
            if let fullSessionMicURL {
                try? FileManager.default.removeItem(at: fullSessionMicURL)
            }
        }

        // Stop system audio
        let systemAudioURL = systemAudioRecorder.stop()
        systemAudioRecorder.onPCMSamples = nil
        do {
            // Transcribe last mic chunk
            if let lastMicURL {
                let chunkOffset = lastChunkTiming?.startTimeSeconds ?? 0
                let chunkDuration = lastChunkTiming?.durationSeconds ?? 0
                fputs("[meeting] transcribing final mic chunk (offset=\(String(format: "%.0f", chunkOffset))s)\n", stderr)
                do {
                    let result = try await transcriptionCoordinator.transcribeMeetingChunk(at: lastMicURL, backend: backend, customWords: serializedCustomWords)
                    micSegments.append(contentsOf: MeetingMicRepairPlanner.makeSpeechSegments(
                        from: result,
                        startTime: chunkOffset,
                        endTime: chunkOffset + max(chunkDuration, 0.1)
                    ))
                } catch {
                    fputs("[meeting] final mic chunk transcription failed: \(error)\n", stderr)
                }
                try? FileManager.default.removeItem(at: lastMicURL)
            }

            // Transcribe system audio (batch — this is the only wait after meeting ends)
            let systemResult: SpeechTranscriptionResult
            var diarizationSegments: [TimedSpeakerSegment]?
            if let systemAudioURL {
                fputs("[meeting] transcribing system audio (batch)\n", stderr)
                systemResult = try await transcriptionCoordinator.transcribeMeeting(at: systemAudioURL, backend: backend, customWords: serializedCustomWords)

                // Run speaker diarization on system audio (batch post-processing)
                if let diarizationResult = try? await transcriptionCoordinator.diarizeSystemAudio(at: systemAudioURL) {
                    diarizationSegments = diarizationResult.segments
                }
            } else {
                systemResult = SpeechTranscriptionResult(text: "", segments: [])
            }

            micSegments.append(contentsOf: await micChunkCollector.closeAndDrainSortedSegments())
            micSegments.sort { lhs, rhs in
                if lhs.start == rhs.start {
                    return lhs.text < rhs.text
                }
                return lhs.start < rhs.start
            }

            if let fullSessionMicURL {
                let repairedMicSegments = await repairMicSegmentsIfNeeded(
                    existingMicSegments: micSegments,
                    fullSessionMicURL: fullSessionMicURL,
                    meetingStart: meetingStart,
                    endTime: endTime
                )
                if !repairedMicSegments.isEmpty {
                    micSegments.append(contentsOf: repairedMicSegments)
                    micSegments.sort { lhs, rhs in
                        if lhs.start == rhs.start {
                            return lhs.text < rhs.text
                        }
                        return lhs.start < rhs.start
                    }
                }
            }

            fputs("[meeting] \(micSegments.count) mic chunks transcribed during meeting\n", stderr)

            let rawTranscript = TranscriptFormatter.merge(
                micSegments: micSegments,
                systemSegments: systemResult.segments,
                diarizationSegments: diarizationSegments,
                meetingStart: meetingStart
            )

            let generatedTitle: String
            onProgress?(.generatingTitle)
            if let autoTitle = await MeetingSummaryClient.generateTitle(transcript: rawTranscript, config: config),
               !autoTitle.isEmpty {
                generatedTitle = autoTitle
                fputs("[meeting] auto-generated title: \(generatedTitle)\n", stderr)
            } else {
                generatedTitle = title
            }

            let templateSnapshot = MeetingTemplates.resolveSnapshot(
                id: config.defaultMeetingTemplateID,
                customTemplates: config.customMeetingTemplates
            )
            onProgress?(.summarizingNotes)
            let formattedNotes = await MeetingSummaryClient.summarize(
                transcript: rawTranscript,
                meetingTitle: generatedTitle,
                config: config,
                template: templateSnapshot
            )

            if let aecDiagnostics {
                fputs("\(aecDiagnostics.summaryLine)\n", stderr)
            }

            return MeetingSessionResult(
                title: generatedTitle,
                calendarEventID: calendarEventID,
                startTime: meetingStart,
                endTime: endTime,
                durationSeconds: max(endTime.timeIntervalSince(meetingStart), 0),
                rawTranscript: rawTranscript,
                formattedNotes: formattedNotes,
                retainedRecordingURL: retainedRecordingURL,
                retainedRecordingError: retainedRecordingWriterError,
                systemRecordingURL: systemAudioURL,
                templateSnapshot: templateSnapshot
            )
        } catch {
            if let lastMicURL {
                try? FileManager.default.removeItem(at: lastMicURL)
            }
            if let retainedRecordingURL {
                try? FileManager.default.removeItem(at: retainedRecordingURL)
            }
            if let systemAudioURL {
                try? FileManager.default.removeItem(at: systemAudioURL)
            }
            throw error
        }
    }

    /// Called by VAD on speech boundaries or max-duration fallback.
    /// Rotates the streaming mic file and sends the completed chunk for transcription.
    private func rotateChunk() {
        let rotation = chunkRotationQueue.sync { () -> (chunkTiming: MeetingChunkTimingSnapshot, chunkURL: URL)? in
            guard isRecording else { return nil }
            guard let chunkURL = processedMicChunkRecorder?.rotateFile(),
                  let chunkTiming = chunkTimingTracker.rotate() else {
                return nil
            }
            return (chunkTiming, chunkURL)
        }

        // Transcribe the completed chunk async
        guard let rotation else { return }
        let chunkURL = rotation.chunkURL
        let chunkOffset = rotation.chunkTiming.startTimeSeconds
        let chunkDuration = rotation.chunkTiming.durationSeconds
        let backend = self.backend

        fputs("[meeting] rotating chunk at offset=\(String(format: "%.0f", chunkOffset))s\n", stderr)

        let task = Task { [weak self] () -> [SpeechSegment] in
            defer {
                try? FileManager.default.removeItem(at: chunkURL)
            }
            guard let self else { return [] }
            do {
                if Task.isCancelled {
                    return []
                }
                let result = try await self.transcriptionCoordinator.transcribeMeetingChunk(at: chunkURL, backend: backend, customWords: self.serializedCustomWords)
                if !result.text.isEmpty {
                    fputs("[meeting] chunk transcribed: \"\(String(result.text.prefix(60)))...\"\n", stderr)
                    return MeetingMicRepairPlanner.makeSpeechSegments(
                        from: result,
                        startTime: chunkOffset,
                        endTime: chunkOffset + max(chunkDuration, 0.1)
                    )
                }
            } catch {
                fputs("[meeting] chunk transcription failed: \(error)\n", stderr)
            }
            return []
        }
        if !micChunkCollector.add(task) {
            task.cancel()
        }
    }

    private func setupRetainedRecordingWriterIfNeeded() {
        retainedRecordingWriter = nil
        retainedRecordingWriterError = nil

        guard config.meetingRecordingSavePolicy != .never else { return }

        do {
            retainedRecordingWriter = try MeetingRecordingWriter()
        } catch {
            retainedRecordingWriterError = error
            fputs("[meeting] failed to prepare retained recording writer: \(error)\n", stderr)
        }
    }

    private func prepareRealtimeAudioPipeline(vadManager: VadManager?) throws {
        processedMicChunkRecorder = try PCMChunkRecorder(directoryName: "muesli-meeting-processed-mic")
        do {
            meetingAecProcessor = try MeetingAecProcessor()
            fputs("[meeting] WebRTC AEC3 enabled for mic transcription path\n", stderr)
            configureOutputRouteMonitoring()
        } catch {
            meetingAecProcessor = nil
            fputs("[meeting] WebRTC AEC3 unavailable, falling back to raw mic chunks: \(error)\n", stderr)
        }
        configureRealtimeMicCallbacks(vadManager: vadManager)
    }

    private func configureOutputRouteMonitoring() {
        outputRouteMonitor.stop()
        outputRouteMonitor.onRouteChanged = { [weak self] snapshot in
            self?.applyOutputRoute(snapshot)
        }
        outputRouteMonitor.start()
        if let currentRoute = outputRouteMonitor.currentRoute() {
            applyOutputRoute(currentRoute)
        } else {
            meetingAecProcessor?.updateMode(.enabled(delayMs: 0))
            fputs("[meeting] AEC route defaulted to speaker [delay=0ms]\n", stderr)
        }
    }

    private func applyOutputRoute(_ snapshot: AudioOutputRouteSnapshot) {
        guard latestOutputRoute != snapshot else { return }
        let previousRoute = latestOutputRoute
        latestOutputRoute = snapshot

        let mode: MeetingAecMode
        switch snapshot.routeKind {
        case .speakerLike:
            mode = .enabled(delayMs: snapshot.estimatedDelayMs)
        case .headphoneLike:
            mode = .bypassed(reason: snapshot.routeKind.rawValue)
        }
        meetingAecProcessor?.updateMode(mode)

        let routePrefix = previousRoute == nil ? "[meeting] AEC route:" : "[meeting] AEC route changed:"
        fputs("\(routePrefix) \(snapshot.description)\n", stderr)
    }

    private func configureRealtimeMicCallbacks(vadManager: VadManager?) {
        if let vadManager {
            let controller = StreamingVadController(vadManager: vadManager)
            controller.onChunkBoundary = { [weak self] in
                self?.rotateChunk()
            }
            controller.start()
            vadController = controller
        } else {
            vadController = nil
        }
        streamingMicRecorder.onAudioBuffer = nil

        streamingMicRecorder.onPCMSamples = { [weak self] samples in
            guard let self else { return }
            self.retainedRecordingWriter?.appendMic(samples)

            if let meetingAecProcessor = self.meetingAecProcessor {
                let batch = meetingAecProcessor.processCaptureBatch(samples)
                self.handleProcessedCaptureBatch(batch)
            } else {
                self.handleProcessedCaptureBatch(
                    MeetingAecProcessedCaptureBatch(
                        samples: samples,
                        primaryHealth: .bypassed(reason: "bridge-unavailable"),
                        allFramesTrustedForSegmentation: true
                    )
                )
            }
        }
        systemAudioRecorder.onPCMSamples = { [weak self] samples in
            self?.retainedRecordingWriter?.appendSystem(samples)
            self?.meetingAecProcessor?.appendRender(samples)
        }
    }

    private func handleProcessedCaptureBatch(_ batch: MeetingAecProcessedCaptureBatch) {
        guard !batch.samples.isEmpty else { return }

        chunkRotationQueue.sync {
            processedMicChunkRecorder?.append(batch.samples)
            chunkTimingTracker.append(sampleCount: batch.samples.count)
        }

        if batch.allFramesTrustedForSegmentation, let vadController {
            let floatSamples = batch.samples.map { Float($0) / 32767.0 }
            vadController.processAudio(floatSamples)
        }
    }

    private func durationSeconds(from start: Date, to end: Date) -> Double {
        max(end.timeIntervalSince(start), 0)
    }

    private func repairMicSegmentsIfNeeded(
        existingMicSegments: [SpeechSegment],
        fullSessionMicURL: URL,
        meetingStart: Date,
        endTime: Date
    ) async -> [SpeechSegment] {
        let totalDuration = durationSeconds(from: meetingStart, to: endTime)

        guard let vadManager = await transcriptionCoordinator.getVadManager() else {
            if existingMicSegments.isEmpty {
                return await fallbackToFullSessionMicTranscription(
                    fullSessionMicURL: fullSessionMicURL,
                    meetingDuration: totalDuration
                )
            }
            return []
        }

        do {
            let samples = try AudioConverter().resampleAudioFile(fullSessionMicURL)
            let speechSegments = try await vadManager.segmentSpeech(
                samples,
                config: VadSegmentationConfig(maxSpeechDuration: 10.0, speechPadding: 0.15)
            )
            let repairSegments = MeetingMicRepairPlanner.repairSegments(
                existingMicSegments: existingMicSegments,
                offlineSpeechSegments: speechSegments
            )

            guard !repairSegments.isEmpty else {
                return []
            }

            fputs("[meeting] repairing \(repairSegments.count) uncovered mic speech regions\n", stderr)

            var repairedSegments: [SpeechSegment] = []
            for speechSegment in repairSegments {
                let startSample = max(0, speechSegment.startSample(sampleRate: VadManager.sampleRate))
                let endSample = min(samples.count, speechSegment.endSample(sampleRate: VadManager.sampleRate))
                guard endSample > startSample else { continue }

                let segmentURL = try MeetingMicRepairPlanner.writeTemporaryWAV(
                    samples: Array(samples[startSample..<endSample])
                )
                defer { try? FileManager.default.removeItem(at: segmentURL) }

                let result = try await transcriptionCoordinator.transcribeMeeting(
                    at: segmentURL,
                    backend: backend,
                    customWords: serializedCustomWords
                )
                repairedSegments.append(contentsOf: MeetingMicRepairPlanner.makeSpeechSegments(
                    from: result,
                    startTime: speechSegment.startTime,
                    endTime: speechSegment.endTime
                ))
            }
            return repairedSegments
        } catch {
            fputs("[meeting] mic repair pass failed: \(error)\n", stderr)
            if existingMicSegments.isEmpty {
                return await fallbackToFullSessionMicTranscription(
                    fullSessionMicURL: fullSessionMicURL,
                    meetingDuration: totalDuration
                )
            }
            return []
        }
    }

    private func fallbackToFullSessionMicTranscription(
        fullSessionMicURL: URL,
        meetingDuration: Double
    ) async -> [SpeechSegment] {
        fputs("[meeting] no mic chunks survived, falling back to full-session mic transcription\n", stderr)
        do {
            let result = try await transcriptionCoordinator.transcribeMeeting(
                at: fullSessionMicURL,
                backend: backend,
                customWords: serializedCustomWords
            )
            return MeetingMicRepairPlanner.makeSpeechSegments(
                from: result,
                startTime: 0,
                endTime: meetingDuration
            )
        } catch {
            fputs("[meeting] full-session mic fallback transcription failed: \(error)\n", stderr)
            return []
        }
    }
}
