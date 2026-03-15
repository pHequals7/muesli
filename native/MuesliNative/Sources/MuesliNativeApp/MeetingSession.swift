import Foundation

struct MeetingSessionResult {
    let title: String
    let calendarEventID: String?
    let startTime: Date
    let endTime: Date
    let durationSeconds: Double
    let rawTranscript: String
    let formattedNotes: String
    let micAudioPath: String?
    let systemAudioPath: String?
}

final class MeetingSession {
    private let title: String
    private let calendarEventID: String?
    private let backend: BackendOption
    private let runtime: RuntimePaths
    private let config: AppConfig
    private let transcriptionCoordinator: TranscriptionCoordinator
    private let systemAudioRecorder = SystemAudioRecorder(toolURL: nil)

    /// Current mic recorder (rotated every chunk interval)
    private var micRecorder = MicrophoneRecorder()
    /// Timer that triggers chunk rotation
    private var chunkTimer: Timer?
    /// Accumulated mic transcript segments from completed chunks
    private var accumulatedMicSegments: [SpeechSegment] = []
    /// Track chunk start times for timestamp offsets
    private var currentChunkStartTime: Date?
    /// How often to rotate mic recording (seconds)
    private let chunkInterval: TimeInterval = 30

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

    func start() throws {
        try micRecorder.prepare()
        try micRecorder.start()
        try systemAudioRecorder.start()
        let now = Date()
        startTime = now
        currentChunkStartTime = now
        isRecording = true

        // Start chunk timer on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.chunkTimer = Timer.scheduledTimer(withTimeInterval: self.chunkInterval, repeats: true) { [weak self] _ in
                self?.rotateChunk()
            }
        }

        fputs("[meeting] started with \(chunkInterval)s chunk interval\n", stderr)
    }

    func stop() async throws -> MeetingSessionResult {
        isRecording = false
        let meetingStart = self.startTime ?? Date()
        let endTime = Date()

        // Stop chunk timer
        chunkTimer?.invalidate()
        chunkTimer = nil

        // Stop mic and get last chunk
        let lastMicURL = micRecorder.stop()
        let lastChunkStart = currentChunkStartTime ?? meetingStart

        // Stop system audio
        let systemAudioURL = systemAudioRecorder.stop()

        // Transcribe last mic chunk
        if let lastMicURL {
            let chunkOffset = lastChunkStart.timeIntervalSince(meetingStart)
            fputs("[meeting] transcribing final mic chunk (offset=\(String(format: "%.0f", chunkOffset))s)\n", stderr)
            do {
                let result = try await transcriptionCoordinator.transcribeMeetingChunk(at: lastMicURL, backend: backend, customWords: serializedCustomWords)
                if !result.text.isEmpty {
                    accumulatedMicSegments.append(SpeechSegment(start: chunkOffset, end: chunkOffset, text: result.text))
                }
            } catch {
                fputs("[meeting] final mic chunk transcription failed: \(error)\n", stderr)
            }
            try? FileManager.default.removeItem(at: lastMicURL)
        }

        // Transcribe system audio (batch — this is the only wait after meeting ends)
        let systemResult: SpeechTranscriptionResult
        if let systemAudioURL {
            fputs("[meeting] transcribing system audio (batch)\n", stderr)
            systemResult = try await transcriptionCoordinator.transcribeMeeting(at: systemAudioURL, backend: backend, customWords: serializedCustomWords)
            try? FileManager.default.removeItem(at: systemAudioURL)
        } else {
            systemResult = SpeechTranscriptionResult(text: "", segments: [])
        }

        fputs("[meeting] \(accumulatedMicSegments.count) mic chunks transcribed during meeting\n", stderr)

        let rawTranscript = TranscriptFormatter.merge(
            micSegments: accumulatedMicSegments,
            systemSegments: systemResult.segments,
            meetingStart: meetingStart
        )

        // Auto-generate meeting title from transcript
        let generatedTitle: String
        if let autoTitle = await MeetingSummaryClient.generateTitle(transcript: rawTranscript, config: config),
           !autoTitle.isEmpty {
            generatedTitle = autoTitle
            fputs("[meeting] auto-generated title: \(generatedTitle)\n", stderr)
        } else {
            generatedTitle = title
        }

        let formattedNotes = await MeetingSummaryClient.summarize(
            transcript: rawTranscript,
            meetingTitle: generatedTitle,
            config: config
        )

        return MeetingSessionResult(
            title: generatedTitle,
            calendarEventID: calendarEventID,
            startTime: meetingStart,
            endTime: endTime,
            durationSeconds: max(endTime.timeIntervalSince(meetingStart), 0),
            rawTranscript: rawTranscript,
            formattedNotes: formattedNotes,
            micAudioPath: nil,
            systemAudioPath: nil
        )
    }

    /// Called every chunkInterval seconds. Stops current mic recording,
    /// starts a new one, and sends the completed chunk for transcription.
    private func rotateChunk() {
        guard isRecording else { return }
        let meetingStart = self.startTime ?? Date()
        let chunkStart = currentChunkStartTime ?? meetingStart

        // Stop current recorder, get WAV
        let chunkURL = micRecorder.stop()

        // Start new recorder immediately (minimize gap)
        let newRecorder = MicrophoneRecorder()
        do {
            try newRecorder.prepare()
            try newRecorder.start()
        } catch {
            fputs("[meeting] chunk rotation recorder start failed: \(error)\n", stderr)
        }
        micRecorder = newRecorder
        currentChunkStartTime = Date()

        // Transcribe the completed chunk async
        guard let chunkURL else { return }
        let chunkOffset = chunkStart.timeIntervalSince(meetingStart)
        let backend = self.backend

        fputs("[meeting] rotating chunk at offset=\(String(format: "%.0f", chunkOffset))s\n", stderr)

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.transcriptionCoordinator.transcribeMeetingChunk(at: chunkURL, backend: backend, customWords: self.serializedCustomWords)
                if !result.text.isEmpty {
                    self.accumulatedMicSegments.append(SpeechSegment(start: chunkOffset, end: chunkOffset, text: result.text))
                    fputs("[meeting] chunk transcribed: \"\(String(result.text.prefix(60)))...\"\n", stderr)
                }
            } catch {
                fputs("[meeting] chunk transcription failed: \(error)\n", stderr)
            }
            try? FileManager.default.removeItem(at: chunkURL)
        }
    }
}
