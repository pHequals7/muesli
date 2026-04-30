import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import MuesliCore

/// Protocol for system audio capture backends (ScreenCaptureKit vs CoreAudio tap).
protocol SystemAudioCapturing: AnyObject {
    var onPCMSamples: (([Int16]) -> Void)? { get set }
    var isRecording: Bool { get }
    var isPaused: Bool { get }
    func start() async throws
    func pause()
    func resume()
    func stop() -> URL?
}

/// Captures system audio via CoreAudio process tap + aggregate device.
///
/// Replaces `SystemAudioRecorder` (ScreenCaptureKit) for meeting system audio capture.
/// Key advantages:
/// - No conflict with `CGWindowListCreateImage` (screenshot OCR works during meetings)
/// - Doesn't require "Screen & System Audio Recording" permission for audio capture
/// - Hardware-synchronized with mic input when used in an aggregate device
final class CoreAudioSystemRecorder: SystemAudioCapturing {
    var onPCMSamples: (([Int16]) -> Void)?

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var audioUnit: AudioUnit?
    private let processingQueue = DispatchQueue(label: "com.muesli.system-audio-tap")
    private var renderBuffer: UnsafeMutableRawPointer?
    private var renderBufferCapacity = 0

    private var outputFile: FileHandle?
    private var outputURL: URL?
    private var totalBytesWritten = 0
    private(set) var isRecording = false
    private(set) var isPaused = false

    private static let targetSampleRate: Double = 16_000
    private static let maxRenderFrames: UInt32 = 4096

    /// Source format from the tap (queried at setup time).
    private var sourceSampleRate: Double = 48_000
    private var sourceChannels: UInt32 = 2

    deinit {
        if isRecording || aggregateDeviceID != kAudioObjectUnknown || tapID != kAudioObjectUnknown {
            _ = stop()
        }
    }

    func start() async throws {
        guard !isRecording else { return }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-system-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let file = FileHandle(forWritingAtPath: url.path) else {
            throw RecorderError.fileCreationFailed
        }
        file.write(WAVHeader.create(dataSize: 0))
        outputFile = file
        outputURL = url
        totalBytesWritten = 0
        isRecording = true
        isPaused = false

        do {
            try createTapAndAggregateDevice()
            try setupAndStartAudioUnit()
            fputs("[system-audio] CoreAudio tap capture started\n", stderr)
        } catch {
            fputs("[system-audio] CoreAudio tap start failed: \(error)\n", stderr)
            cleanupFailedStart()
            throw error
        }
    }

    func stop() -> URL? {
        guard isRecording || outputFile != nil || outputURL != nil else { return nil }
        isRecording = false
        isPaused = false
        onPCMSamples = nil

        if let au = audioUnit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
        }
        audioUnit = nil
        releaseRenderBuffer()

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }

        // Drain any in-flight processing blocks before touching the file
        processingQueue.sync {}

        if let file = outputFile {
            let header = WAVHeader.create(dataSize: totalBytesWritten)
            file.seek(toFileOffset: 0)
            file.write(header)
            file.closeFile()
        }
        outputFile = nil

        let bytes = totalBytesWritten
        let url = outputURL
        outputURL = nil
        totalBytesWritten = 0

        fputs("[system-audio] CoreAudio tap stopped, \(bytes) bytes written\n", stderr)
        return url
    }

    func pause() {
        guard isRecording else { return }
        isPaused = true
    }

    func resume() {
        guard isRecording else { return }
        isPaused = false
    }

    // MARK: - Tap + Aggregate Device Setup

    private func createTapAndAggregateDevice() throws {
        // Tap all system audio output, excluding our own process
        // CATapDescription takes AudioObjectIDs from kAudioHardwarePropertyProcessObjectList,
        // NOT raw PIDs. Look up our process's AudioObjectID to exclude self.
        let excludeList: [AudioObjectID] = Self.currentProcessAudioObjectID().map { [$0] } ?? []
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludeList)
        tapDesc.name = "Muesli System Audio Tap"

        // Register the tap with the audio system first — this triggers the
        // system permission dialog on first use ("… would like to record audio
        // from other applications").
        var status = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw RecorderError.tapCreationFailed(status)
        }
        fputs("[system-audio] process tap \(tapID) created\n", stderr)

        // Create aggregate device referencing the registered tap by UUID.
        // The tap list must contain dictionaries with UID strings — NOT
        // CATapDescription objects (passing objects crashes CoreAudio).
        let tapUIDString = tapDesc.uuid.uuidString
        let aggUID = "com.muesli.system-audio-tap-\(UUID().uuidString)"
        let aggDesc: NSDictionary = [
            kAudioAggregateDeviceNameKey: "Muesli System Audio",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUIDString],
            ],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]

        status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateDeviceID)
        guard status == noErr, aggregateDeviceID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
            throw RecorderError.aggregateDeviceCreationFailed(status)
        }
        fputs("[system-audio] aggregate device \(aggregateDeviceID) created (uid: \(aggUID))\n", stderr)
    }

    private func setupAndStartAudioUnit() throws {
        // Find AUHAL component
        var componentDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &componentDesc) else {
            throw RecorderError.auhalNotFound
        }

        var au: AudioUnit?
        try osCheck(AudioComponentInstanceNew(component, &au), "create AUHAL")
        guard let au else { throw RecorderError.auhalNotFound }

        do {
            // Enable input (bus 1), disable output (bus 0) — input-only capture
            var one: UInt32 = 1
            var zero: UInt32 = 0
            try osCheck(AudioUnitSetProperty(
                au, kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input, 1, &one, Self.u32Size
            ), "enable input")
            try osCheck(AudioUnitSetProperty(
                au, kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output, 0, &zero, Self.u32Size
            ), "disable output")

            // Point at the aggregate device
            var devID = aggregateDeviceID
            try osCheck(AudioUnitSetProperty(
                au, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            ), "set device")

            // Query the native input format from the tap
            var nativeFormat = AudioStreamBasicDescription()
            var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try osCheck(AudioUnitGetProperty(
                au, kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input, 1, &nativeFormat, &fmtSize
            ), "get input format")

            sourceSampleRate = nativeFormat.mSampleRate
            sourceChannels = nativeFormat.mChannelsPerFrame
            fputs("[system-audio] tap format: \(sourceSampleRate)Hz, \(sourceChannels)ch\n", stderr)
            allocateRenderBuffer(for: sourceChannels)

            // Request float32 interleaved on the output scope of bus 1
            var outFormat = AudioStreamBasicDescription(
                mSampleRate: sourceSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: sourceChannels * 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: sourceChannels * 4,
                mChannelsPerFrame: sourceChannels,
                mBitsPerChannel: 32,
                mReserved: 0
            )
            try osCheck(AudioUnitSetProperty(
                au, kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output, 1, &outFormat, fmtSize
            ), "set output format")

            // Register input callback
            var cb = AURenderCallbackStruct(
                inputProc: Self.renderCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try osCheck(AudioUnitSetProperty(
                au, kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global, 0, &cb,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ), "set input callback")

            try osCheck(AudioUnitInitialize(au), "initialize AUHAL")
            try osCheck(AudioOutputUnitStart(au), "start AUHAL")
        } catch {
            AudioComponentInstanceDispose(au)
            throw error
        }

        audioUnit = au
    }

    // MARK: - Render Callback (real-time audio thread)

    private static let renderCallback: AURenderCallback = { (
        inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _
    ) -> OSStatus in
        let recorder = Unmanaged<CoreAudioSystemRecorder>.fromOpaque(inRefCon).takeUnretainedValue()
        guard recorder.isRecording, let au = recorder.audioUnit else { return noErr }

        let channels = Int(recorder.sourceChannels)
        let byteSize = Int(inNumberFrames) * channels * MemoryLayout<Float>.size
        guard let rawBuf = recorder.renderBuffer, byteSize <= recorder.renderBufferCapacity else {
            return kAudio_ParamError
        }

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(byteSize),
                mData: rawBuf
            )
        )

        let status = AudioUnitRender(
            au, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, &bufferList
        )
        guard status == noErr else { return status }
        guard !recorder.isPaused else { return noErr }

        // Copy rendered data and dispatch off the audio thread for conversion + I/O
        let data = Data(bytes: rawBuf, count: byteSize)

        let frameCount = Int(inNumberFrames)
        let srcRate = recorder.sourceSampleRate

        recorder.processingQueue.async { [weak recorder] in
            guard let recorder, recorder.isRecording, !recorder.isPaused else { return }
            recorder.processAudioData(data, frameCount: frameCount, channels: channels, sourceRate: srcRate)
        }

        return noErr
    }

    // MARK: - Audio Processing (processing queue)

    private func processAudioData(_ data: Data, frameCount: Int, channels: Int, sourceRate: Double) {
        guard isRecording, !isPaused else { return }
        data.withUnsafeBytes { rawBuffer in
            let floatPtr = rawBuffer.bindMemory(to: Float.self)

            // 1. Mix to mono
            var mono = [Float](repeating: 0, count: frameCount)
            if channels > 1 {
                let scale = 1.0 / Float(channels)
                for i in 0..<frameCount {
                    var sum: Float = 0
                    for ch in 0..<channels {
                        sum += floatPtr[i * channels + ch]
                    }
                    mono[i] = sum * scale
                }
            } else {
                for i in 0..<frameCount {
                    mono[i] = floatPtr[i]
                }
            }

            // 2. Resample to 16 kHz and convert to Int16
            let targetRate = Self.targetSampleRate
            let int16Samples: [Int16]

            if abs(sourceRate - targetRate) < 1.0 {
                int16Samples = mono.map { Int16(max(-1.0, min(1.0, $0)) * 32767.0) }
            } else {
                let ratio = sourceRate / targetRate
                let outputCount = Int(Double(frameCount) / ratio)
                guard outputCount > 0 else { return }
                var resampled = [Int16](repeating: 0, count: outputCount)
                for i in 0..<outputCount {
                    let srcPos = Double(i) * ratio
                    let idx = Int(srcPos)
                    let frac = Float(srcPos - Double(idx))
                    let sample: Float
                    if idx + 1 < frameCount {
                        sample = mono[idx] * (1.0 - frac) + mono[idx + 1] * frac
                    } else if idx < frameCount {
                        sample = mono[idx]
                    } else {
                        sample = 0
                    }
                    resampled[i] = Int16(max(-1.0, min(1.0, sample)) * 32767.0)
                }
                int16Samples = resampled
            }

            // 3. Write WAV data + deliver callback
            guard !int16Samples.isEmpty else { return }
            let rawData = int16Samples.withUnsafeBufferPointer { buf in
                Data(bytes: buf.baseAddress!, count: buf.count * MemoryLayout<Int16>.size)
            }
            outputFile?.write(rawData)
            totalBytesWritten += rawData.count
            onPCMSamples?(int16Samples)
        }
    }

    // MARK: - Permission

    /// Check whether system audio capture permission (`kTCCServiceAudioCapture`)
    /// is granted by attempting to create a process tap with self-exclusion.
    /// An empty exclude list bypasses the permission check entirely — only
    /// non-empty lists (process filtering) require `kTCCServiceAudioCapture`.
    static func checkSystemAudioPermission() -> Bool {
        guard let selfObjectID = currentProcessAudioObjectID() else { return false }
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [selfObjectID])
        tapDesc.name = "Muesli Permission Check"

        var testTapID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateProcessTap(tapDesc, &testTapID)
        if status == noErr, testTapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(testTapID)
            return true
        }
        return false
    }

    /// Look up our process's AudioObjectID from the HAL process object list.
    /// `CATapDescription` expects these IDs — not raw PIDs.
    private static func currentProcessAudioObjectID() -> AudioObjectID? {
        let myPID = ProcessInfo.processInfo.processIdentifier
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize
        ) == noErr else { return nil }

        let count = Int(propertySize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return nil }

        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &objects
        ) == noErr else { return nil }

        var pidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for obj in objects {
            var objPID: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(obj, &pidAddr, 0, nil, &pidSize, &objPID) == noErr,
               objPID == myPID {
                return obj
            }
        }
        return nil
    }

    /// Trigger the macOS "System Audio Recording" permission dialog by briefly
    /// starting a CoreAudio tap recording. Per Apple docs, the system prompts
    /// "the first time you start recording from an aggregate device that
    /// contains a tap" — but only if `NSAudioCaptureUsageDescription` is in
    /// Info.plist. Polls for permission for a short period so first-run users
    /// have time to respond before we fall back to Settings.
    @discardableResult
    static func requestSystemAudioAccess(timeout: Duration = .seconds(12)) async -> Bool {
        let recorder = CoreAudioSystemRecorder()
        let pollInterval = Duration.milliseconds(300)
        do {
            try await recorder.start()
        } catch {
            fputs("[system-audio] permission request failed: \(error)\n", stderr)
        }

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if checkSystemAudioPermission() {
                _ = recorder.stop()
                return true
            }
            try? await Task.sleep(for: pollInterval)
        }

        _ = recorder.stop()
        return checkSystemAudioPermission()
    }

    /// Open System Settings to the Screen & System Audio pane where the user
    /// can enable the app under "System Audio Recording Only".
    @MainActor
    static func openSystemAudioSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Stale Device Cleanup

    /// Remove any phantom aggregate devices left behind by a previous crash.
    /// Call once at app launch before starting any recording.
    static func cleanupStaleDevices() {
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize
        ) == noErr else { return }

        let count = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return }

        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &devices
        ) == noErr else { return }

        for deviceID in devices {
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(
                deviceID, &nameAddr, 0, nil, &nameSize, &name
            ) == noErr else { continue }

            if (name as String) == "Muesli System Audio" {
                fputs("[system-audio] cleaning up stale aggregate device \(deviceID)\n", stderr)
                AudioHardwareDestroyAggregateDevice(deviceID)
            }
        }
    }

    // MARK: - Helpers

    enum RecorderError: LocalizedError {
        case fileCreationFailed
        case tapCreationFailed(OSStatus)
        case aggregateDeviceCreationFailed(OSStatus)
        case auhalNotFound
        case auhalSetupFailed(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .fileCreationFailed:
                return "Could not create output file"
            case .tapCreationFailed(let s):
                return "Process tap creation failed (status: \(s))"
            case .aggregateDeviceCreationFailed(let s):
                return "Aggregate device creation failed (status: \(s))"
            case .auhalNotFound:
                return "AUHAL audio component not found"
            case .auhalSetupFailed(let step, let s):
                return "AUHAL setup failed at '\(step)' (status: \(s))"
            }
        }
    }

    private static let u32Size = UInt32(MemoryLayout<UInt32>.size)

    private func osCheck(_ status: OSStatus, _ label: String) throws {
        guard status == noErr else {
            throw RecorderError.auhalSetupFailed(label, status)
        }
    }

    private func allocateRenderBuffer(for channels: UInt32) {
        releaseRenderBuffer()
        renderBufferCapacity = Int(Self.maxRenderFrames) * Int(channels) * MemoryLayout<Float>.size
        renderBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: renderBufferCapacity,
            alignment: MemoryLayout<Float>.alignment
        )
    }

    private func releaseRenderBuffer() {
        renderBuffer?.deallocate()
        renderBuffer = nil
        renderBufferCapacity = 0
    }

    private func cleanupFailedStart() {
        isRecording = false
        isPaused = false
        onPCMSamples = nil

        if let au = audioUnit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
        }
        audioUnit = nil
        releaseRenderBuffer()

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }

        if let file = outputFile {
            file.closeFile()
        }
        outputFile = nil

        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        outputURL = nil
        totalBytesWritten = 0
    }

    // MARK: - WAV Header

    private enum WAVHeader {
        static func create(dataSize: Int) -> Data {
            let sampleRate = Int(CoreAudioSystemRecorder.targetSampleRate)
            let channels = 1
            let byteRate = sampleRate * channels * 16 / 8
            let blockAlign = channels * 16 / 8

            var header = Data()
            header.append(contentsOf: "RIFF".utf8)
            header.append(contentsOf: withUnsafeBytes(of: UInt32(36 + dataSize).littleEndian) { Array($0) })
            header.append(contentsOf: "WAVE".utf8)
            header.append(contentsOf: "fmt ".utf8)
            header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
            header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
            header.append(contentsOf: withUnsafeBytes(of: UInt16(channels).littleEndian) { Array($0) })
            header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
            header.append(contentsOf: withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Array($0) })
            header.append(contentsOf: withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { Array($0) })
            header.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
            header.append(contentsOf: "data".utf8)
            header.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
            return header
        }
    }
}
