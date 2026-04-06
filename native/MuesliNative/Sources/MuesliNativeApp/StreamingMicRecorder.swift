import AudioToolbox
import AVFoundation
import Foundation
import os

/// Mic recorder using AVAudioEngine for real-time buffer access.
/// Used by MeetingSession for VAD-driven chunk rotation (zero-gap file switching).
final class StreamingMicRecorder {
    /// Called with 4096-sample Float chunks (256ms at 16kHz) for VAD processing.
    var onAudioBuffer: (([Float]) -> Void)?
    /// Called with 16-bit PCM mono samples for retained meeting recording.
    var onPCMSamples: (([Int16]) -> Void)?

    private let engine = AVAudioEngine()
    private let lock = OSAllocatedUnfairLock(initialState: FileState())
    private var isRunning = false

    private struct FileState {
        var fileHandle: FileHandle?
        var fileURL: URL?
        var bytesWritten: Int = 0
        var latestPowerDB: Float = -160
    }

    private static let sampleRate: Double = 16_000
    private static let bufferSize: AVAudioFrameCount = 4096 // 256ms at 16kHz

    func prepare() throws {
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw NSError(domain: "StreamingMicRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No audio input available",
            ])
        }
    }

    func start() throws {
        guard !isRunning else { return }

        let fileState = try createNewFile()
        lock.withLock { $0 = fileState }

        let inputNode = engine.inputNode

        // Enable Apple voice processing for echo cancellation
        do {
            try inputNode.setVoiceProcessingEnabled(true)
            fputs("[streaming-mic] voice processing enabled (AEC active)\n", stderr)
            configureMinimumDucking(inputNode: inputNode)
        } catch {
            fputs("[streaming-mic] voice processing unavailable: \(error)\n", stderr)
        }

        let hwFormat = inputNode.outputFormat(forBus: 0)

        // Target format: 16kHz mono Float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "StreamingMicRecorder", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not create target audio format",
            ])
        }

        // Install converter if sample rates differ
        let needsConversion = hwFormat.sampleRate != Self.sampleRate || hwFormat.channelCount != 1
        let converter: AVAudioConverter? = needsConversion
            ? AVAudioConverter(from: hwFormat, to: targetFormat)
            : nil

        inputNode.installTap(onBus: 0, bufferSize: Self.bufferSize, format: nil) { [weak self] buffer, _ in
            guard let self else { return }

            let monoBuffer: AVAudioPCMBuffer
            if let converter {
                let frameCapacity = AVAudioFrameCount(
                    Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate
                )
                guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }
                var error: NSError?
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                converter.convert(to: converted, error: &error, withInputFrom: inputBlock)
                if error != nil { return }
                monoBuffer = converted
            } else {
                monoBuffer = buffer
            }

            guard let floatData = monoBuffer.floatChannelData?[0] else { return }
            let frameCount = Int(monoBuffer.frameLength)

            // Write Int16 PCM to file
            var int16Samples = [Int16](repeating: 0, count: frameCount)
            for i in 0..<frameCount {
                let clamped = max(-1.0, min(1.0, floatData[i]))
                int16Samples[i] = Int16(clamped * 32767)
            }
            let pcmData = int16Samples.withUnsafeBufferPointer { Data(buffer: $0) }
            let powerDB: Float = {
                guard frameCount > 0 else { return -160 }
                var sumSquares: Float = 0
                for i in 0..<frameCount {
                    let sample = floatData[i]
                    sumSquares += sample * sample
                }
                let rms = sqrt(sumSquares / Float(frameCount))
                let rawDB = rms > 0.000_001 ? 20 * log10(rms) : -160
                return max(-160, min(0, rawDB))
            }()

            self.lock.withLock { state in
                state.fileHandle?.write(pcmData)
                state.bytesWritten += pcmData.count
                state.latestPowerDB = powerDB
            }

            self.onPCMSamples?(int16Samples)

            // Forward Float samples for VAD (in 4096-sample chunks)
            let floats = Array(UnsafeBufferPointer(start: floatData, count: frameCount))
            self.onAudioBuffer?(floats)
        }

        try engine.start()
        isRunning = true
    }

    /// Rotate to a new file. Returns the completed WAV URL. No audio gap.
    func rotateFile() -> URL? {
        guard isRunning else { return nil }

        let newState: FileState
        do {
            newState = try createNewFile()
        } catch {
            fputs("[streaming-mic] failed to create new file during rotation: \(error)\n", stderr)
            return nil
        }

        let completed = lock.withLock { state -> FileState in
            let old = state
            state = newState
            return old
        }

        return finalizeFile(completed)
    }

    /// Stop recording. Returns the final WAV URL.
    func stop() -> URL? {
        guard isRunning else { return nil }
        isRunning = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)

        let finalState = lock.withLock { state -> FileState in
            let old = state
            state = FileState()
            return old
        }

        return finalizeFile(finalState)
    }

    func cancel() {
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        onAudioBuffer = nil
        onPCMSamples = nil

        let state = lock.withLock { state -> FileState in
            let old = state
            state = FileState()
            return old
        }
        if let url = state.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Approximate current power level (dB) from recent samples.
    func currentPower() -> Float {
        lock.withLock { $0.latestPowerDB }
    }

    // MARK: - Voice Processing

    private func configureMinimumDucking(inputNode: AVAudioInputNode) {
        guard let audioUnit = inputNode.audioUnit else {
            fputs("[streaming-mic] no audio unit for ducking config\n", stderr)
            return
        }

        var duckingConfig = AUVoiceIOOtherAudioDuckingConfiguration(
            mEnableAdvancedDucking: true,
            mDuckingLevel: .min
        )
        let status = AudioUnitSetProperty(
            audioUnit,
            kAUVoiceIOProperty_OtherAudioDuckingConfiguration,
            kAudioUnitScope_Global,
            0,
            &duckingConfig,
            UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size)
        )
        if status == noErr {
            fputs("[streaming-mic] ducking set to minimum\n", stderr)
        } else {
            fputs("[streaming-mic] ducking config failed: \(status)\n", stderr)
        }
    }

    // MARK: - File Management

    private func createNewFile() throws -> FileState {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-meeting-mic", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw NSError(domain: "StreamingMicRecorder", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Could not open file for writing",
            ])
        }
        // Write placeholder WAV header (will be finalized on close)
        handle.write(Self.wavHeader(dataSize: 0))
        return FileState(fileHandle: handle, fileURL: url, bytesWritten: 0)
    }

    private func finalizeFile(_ state: FileState) -> URL? {
        guard let handle = state.fileHandle, let url = state.fileURL else { return nil }

        // Rewrite WAV header with correct data size
        handle.seek(toFileOffset: 0)
        handle.write(Self.wavHeader(dataSize: UInt32(state.bytesWritten)))
        handle.closeFile()

        if state.bytesWritten == 0 {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    private static func wavHeader(dataSize: UInt32) -> Data {
        let sampleRate = UInt32(Self.sampleRate)
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let chunkSize = 36 + dataSize

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // PCM
        header.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        return header
    }
}
