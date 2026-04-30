@preconcurrency import AVFoundation
import Foundation

final class MicrophoneRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var preparedURL: URL?

    func prepare() throws {
        if recorder != nil { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("muesli-native", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        self.preparedURL = fileURL
        self.recorder = recorder
    }

    func start() throws {
        try prepare()
        recorder?.record()
    }

    func stop() -> URL? {
        guard let recorder else { return nil }
        recorder.stop()
        let url = preparedURL
        self.recorder = nil
        self.preparedURL = nil
        return url
    }

    func pause() {
        recorder?.pause()
    }

    func resume() {
        guard recorder != nil else { return }
        recorder?.record()
    }

    func currentPower() -> Float {
        recorder?.updateMeters()
        return recorder?.averagePower(forChannel: 0) ?? -160
    }

    func cancel() {
        recorder?.stop()
        if let url = preparedURL {
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        preparedURL = nil
    }
}
