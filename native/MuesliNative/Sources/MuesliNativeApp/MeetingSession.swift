import FluidAudio
import Foundation
import MuesliCore
import os

final class MeetingChunkCollector {
    private struct State {
        var tasks: [Task<SpeechSegment?, Never>] = []
        var isClosed = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func add(_ task: Task<SpeechSegment?, Never>) -> Bool {
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
            if let segment = await task.value {
                segments.append(segment)
            }
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

final class MeetingSession {
    private let title: String
    private let calendarEventID: String?
    private let backend: BackendOption
    private let runtime: RuntimePaths
    private let config: AppConfig
    private let transcriptionCoordinator: TranscriptionCoordinator
    private let systemAudioRecorder = SystemAudioRecorder()

    /// Streaming mic recorder with real-time buffer access (AVAudioEngine)
    private var streamingMicRecorder = StreamingMicRecorder()
    private var retainedRecordingWriter: MeetingRecordingWriter?
    private var retainedRecordingWriterError: Error?
    /// VAD controller for speech-boundary chunk rotation
    private var vadController: StreamingVadController?
    private let micChunkCollector = MeetingChunkCollector()
    /// Track chunk start times for timestamp offsets
    private var currentChunkStartTime: Date?

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
        do {
            try streamingMicRecorder.prepare()
            setupRetainedRecordingWriterIfNeeded()
            try streamingMicRecorder.start()
            try await systemAudioRecorder.start()
        } catch {
            retainedRecordingWriter?.cancel()
            retainedRecordingWriter = nil
            streamingMicRecorder.cancel()
            if let url = systemAudioRecorder.stop() {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
        let now = Date()
        startTime = now
        currentChunkStartTime = now
        isRecording = true
        streamingMicRecorder.onPCMSamples = { [weak self] samples in
            self?.retainedRecordingWriter?.appendMic(samples)
        }
        systemAudioRecorder.onPCMSamples = { [weak self] samples in
            self?.retainedRecordingWriter?.appendSystem(samples)
        }

        // Set up VAD-driven chunk rotation
        Task { [weak self] in
            guard let self else { return }
            if let vadManager = await self.transcriptionCoordinator.getVadManager() {
                let controller = StreamingVadController(vadManager: vadManager)
                controller.onChunkBoundary = { [weak self] in
                    self?.rotateChunk()
                }
                controller.start()
                self.vadController = controller

                // Wire mic audio to VAD
                self.streamingMicRecorder.onAudioBuffer = { [weak controller] samples in
                    controller?.processAudio(samples)
                }
                fputs("[meeting] started with VAD-driven chunk rotation\n", stderr)
            } else {
                fputs("[meeting] VAD not available, using max-duration fallback only\n", stderr)
            }
        }
    }

    /// Abandon the recording — stop everything, delete temp files, don't transcribe.
    func discard() {
        isRecording = false
        vadController?.stop()
        vadController = nil
        retainedRecordingWriter?.cancel()
        retainedRecordingWriter = nil
        retainedRecordingWriterError = nil
        streamingMicRecorder.onAudioBuffer = nil
        streamingMicRecorder.cancel()
        systemAudioRecorder.onPCMSamples = nil
        if let url = systemAudioRecorder.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        micChunkCollector.cancelAll()
        fputs("[meeting] recording discarded\n", stderr)
    }

    func stop() async throws -> MeetingSessionResult {
        isRecording = false
        let meetingStart = self.startTime ?? Date()
        let endTime = Date()
        var micSegments: [SpeechSegment] = []

        // Stop VAD controller
        vadController?.stop()
        vadController = nil
        streamingMicRecorder.onAudioBuffer = nil

        // Stop mic and get last chunk
        let lastMicURL = streamingMicRecorder.stop()
        let lastChunkStart = currentChunkStartTime ?? meetingStart
        let retainedRecordingURL = retainedRecordingWriter?.stop()
        retainedRecordingWriter = nil

        // Stop system audio
        let systemAudioURL = systemAudioRecorder.stop()
        systemAudioRecorder.onPCMSamples = nil
        do {
            // Transcribe last mic chunk
            if let lastMicURL {
                let chunkOffset = lastChunkStart.timeIntervalSince(meetingStart)
                fputs("[meeting] transcribing final mic chunk (offset=\(String(format: "%.0f", chunkOffset))s)\n", stderr)
                do {
                    let result = try await transcriptionCoordinator.transcribeMeetingChunk(at: lastMicURL, backend: backend, customWords: serializedCustomWords)
                    if !result.text.isEmpty {
                        micSegments.append(SpeechSegment(start: chunkOffset, end: chunkOffset, text: result.text))
                    }
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

            fputs("[meeting] \(micSegments.count) mic chunks transcribed during meeting\n", stderr)

            let rawTranscript = TranscriptFormatter.merge(
                micSegments: micSegments,
                systemSegments: systemResult.segments,
                diarizationSegments: diarizationSegments,
                meetingStart: meetingStart
            )

            let generatedTitle: String
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
            let formattedNotes = await MeetingSummaryClient.summarize(
                transcript: rawTranscript,
                meetingTitle: generatedTitle,
                config: config,
                template: templateSnapshot
            )

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
        guard isRecording else { return }
        let meetingStart = self.startTime ?? Date()
        let chunkStart = currentChunkStartTime ?? meetingStart

        // Rotate file — no gap, AVAudioEngine tap keeps running
        let chunkURL = streamingMicRecorder.rotateFile()
        currentChunkStartTime = Date()

        // Transcribe the completed chunk async
        guard let chunkURL else { return }
        let chunkOffset = chunkStart.timeIntervalSince(meetingStart)
        let backend = self.backend

        fputs("[meeting] rotating chunk at offset=\(String(format: "%.0f", chunkOffset))s\n", stderr)

        let task = Task { [weak self] () -> SpeechSegment? in
            defer {
                try? FileManager.default.removeItem(at: chunkURL)
            }
            guard let self else { return nil }
            do {
                if Task.isCancelled {
                    return nil
                }
                let result = try await self.transcriptionCoordinator.transcribeMeetingChunk(at: chunkURL, backend: backend, customWords: self.serializedCustomWords)
                if !result.text.isEmpty {
                    fputs("[meeting] chunk transcribed: \"\(String(result.text.prefix(60)))...\"\n", stderr)
                    return SpeechSegment(start: chunkOffset, end: chunkOffset, text: result.text)
                }
            } catch {
                fputs("[meeting] chunk transcription failed: \(error)\n", stderr)
            }
            return nil
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
}
