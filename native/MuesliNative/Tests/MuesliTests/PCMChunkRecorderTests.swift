import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("PCMChunkRecorder")
struct PCMChunkRecorderTests {

    @Test("rotateFile finalizes the current chunk and starts a new one")
    func rotatesChunks() throws {
        let recorder = try PCMChunkRecorder(directoryName: "pcm-chunk-recorder-tests")
        recorder.append([100, 200, 300])

        let firstChunkURL = try #require(recorder.rotateFile())
        recorder.append([400, 500])
        let secondChunkURL = try #require(recorder.stop())

        #expect(try readMonoPCM16WAVSamples(from: firstChunkURL) == [100, 200, 300])
        #expect(try readMonoPCM16WAVSamples(from: secondChunkURL) == [400, 500])
    }

    @Test("cancel removes the in-progress chunk file")
    func cancelRemovesTempFile() throws {
        let recorder = try PCMChunkRecorder(directoryName: "pcm-chunk-recorder-tests")
        recorder.append([100, 200, 300])

        recorder.cancel()
        #expect(recorder.stop() == nil)
    }

    private func readMonoPCM16WAVSamples(from url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        let sampleBytes = data.subdata(in: 44..<data.count)
        return sampleBytes.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Int16.self)).map(Int16.init(littleEndian:))
        }
    }
}
