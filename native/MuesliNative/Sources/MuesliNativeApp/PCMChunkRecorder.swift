import Foundation
import os

final class PCMChunkRecorder {
    private struct State {
        var fileHandle: FileHandle?
        var fileURL: URL?
        var bytesWritten = 0
    }

    private let directoryName: String
    private let lock = OSAllocatedUnfairLock(initialState: State())

    init(directoryName: String) throws {
        self.directoryName = directoryName
        lock.withLock {
            $0 = (try? createFileState()) ?? State()
        }
        if lock.withLock({ $0.fileHandle == nil || $0.fileURL == nil }) {
            throw NSError(
                domain: "PCMChunkRecorder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create chunk recorder output file."]
            )
        }
    }

    func append(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        let pcmData = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.withLock { state in
            state.fileHandle?.write(pcmData)
            state.bytesWritten += pcmData.count
        }
    }

    func rotateFile() -> URL? {
        let newState: State
        do {
            newState = try createFileState()
        } catch {
            fputs("[pcm-chunk-recorder] failed to rotate file: \(error)\n", stderr)
            return nil
        }

        let completedState = lock.withLock { state -> State in
            let oldState = state
            state = newState
            return oldState
        }

        return finalizeFile(completedState)
    }

    func stop() -> URL? {
        let finalState = lock.withLock { state -> State in
            let completedState = state
            state = State()
            return completedState
        }
        return finalizeFile(finalState)
    }

    func cancel() {
        let tempURL = lock.withLock { state -> URL? in
            state.fileHandle?.closeFile()
            let fileURL = state.fileURL
            state = State()
            return fileURL
        }
        if let tempURL {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    private func createFileState() throws -> State {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let fileHandle = FileHandle(forWritingAtPath: fileURL.path) else {
            throw NSError(
                domain: "PCMChunkRecorder",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not open chunk recorder file for writing."]
            )
        }
        fileHandle.write(Self.wavHeader(dataSize: 0))
        return State(fileHandle: fileHandle, fileURL: fileURL, bytesWritten: 0)
    }

    private func finalizeFile(_ state: State) -> URL? {
        guard let fileHandle = state.fileHandle, let fileURL = state.fileURL else { return nil }

        fileHandle.seek(toFileOffset: 0)
        fileHandle.write(Self.wavHeader(dataSize: UInt32(state.bytesWritten)))
        fileHandle.closeFile()

        guard state.bytesWritten > 0 else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return fileURL
    }

    private static func wavHeader(dataSize: UInt32) -> Data {
        let sampleRate: UInt32 = 16_000
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
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
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
