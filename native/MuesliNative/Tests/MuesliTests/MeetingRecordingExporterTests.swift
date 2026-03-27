import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MeetingRecordingExporter")
struct MeetingRecordingExporterTests {

    @Test("single-source export moves the file into the meeting recordings directory with a slugged name")
    func singleSourceExportMovesFile() throws {
        let tempDirectory = makeTemporaryDirectory()
        let sourceURL = tempDirectory.appendingPathComponent("mic.wav")
        try writeMonoPCM16WAV(samples: [1200, -800, 400], to: sourceURL)

        let startedAt = Date(timeIntervalSince1970: 1_711_000_000)
        let outputURL = try MeetingRecordingExporter.exportMergedRecording(
            micURL: sourceURL,
            systemURL: nil,
            meetingTitle: "Weekly Product Sync! With Very Long Title Extra Words",
            startedAt: startedAt,
            supportDirectory: tempDirectory
        )

        #expect(outputURL != nil)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path) == false)
        #expect(outputURL?.deletingLastPathComponent().lastPathComponent == "meeting-recordings")
        #expect(outputURL?.lastPathComponent.hasSuffix("-weekly-product-sync-with-very-long.wav") == true)
        #expect(try readMonoPCM16WAVSamples(from: outputURL!) == [1200, -800, 400])
    }

    @Test("dual-source export averages tracks and removes temporary sources")
    func mergeExportAveragesTracks() throws {
        let tempDirectory = makeTemporaryDirectory()
        let micURL = tempDirectory.appendingPathComponent("mic.wav")
        let systemURL = tempDirectory.appendingPathComponent("system.wav")
        try writeMonoPCM16WAV(samples: [1000, 2000], to: micURL)
        try writeMonoPCM16WAV(samples: [3000, -2000, 500], to: systemURL)

        let outputURL = try MeetingRecordingExporter.exportMergedRecording(
            micURL: micURL,
            systemURL: systemURL,
            meetingTitle: "Customer Call",
            startedAt: Date(timeIntervalSince1970: 1_711_000_000),
            supportDirectory: tempDirectory
        )

        #expect(outputURL != nil)
        #expect(try readMonoPCM16WAVSamples(from: outputURL!) == [2000, 0, 500])
        #expect(FileManager.default.fileExists(atPath: micURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: systemURL.path) == false)
    }

    @Test("dual-source export rejects invalid wav input")
    func mergeExportRejectsInvalidInput() throws {
        let tempDirectory = makeTemporaryDirectory()
        let invalidURL = tempDirectory.appendingPathComponent("invalid.wav")
        let validURL = tempDirectory.appendingPathComponent("valid.wav")
        try Data("not-wav".utf8).write(to: invalidURL)
        try writeMonoPCM16WAV(samples: [1, 2, 3], to: validURL)

        #expect(throws: Error.self) {
            _ = try MeetingRecordingExporter.exportMergedRecording(
                micURL: invalidURL,
                systemURL: validURL,
                meetingTitle: "Broken Input",
                startedAt: Date(),
                supportDirectory: tempDirectory
            )
        }
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-exporter-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeMonoPCM16WAV(samples: [Int16], sampleRate: Int = 16_000, to url: URL) throws {
        let dataSize = samples.count * MemoryLayout<Int16>.size
        let byteRate = sampleRate * 2
        let blockAlign = 2
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        appendUInt32LE(UInt32(36 + dataSize), to: &data)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendUInt32LE(16, to: &data)
        appendUInt16LE(1, to: &data)
        appendUInt16LE(1, to: &data)
        appendUInt32LE(UInt32(sampleRate), to: &data)
        appendUInt32LE(UInt32(byteRate), to: &data)
        appendUInt16LE(UInt16(blockAlign), to: &data)
        appendUInt16LE(16, to: &data)
        data.append(contentsOf: "data".utf8)
        appendUInt32LE(UInt32(dataSize), to: &data)

        for sample in samples {
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        try data.write(to: url, options: .atomic)
    }

    private func readMonoPCM16WAVSamples(from url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        #expect(String(data: data.subdata(in: 0..<4), encoding: .ascii) == "RIFF")
        #expect(String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
        let sampleBytes = data.subdata(in: 44..<data.count)
        let count = sampleBytes.count / MemoryLayout<Int16>.size
        return sampleBytes.withUnsafeBytes { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: Int16.self)
            return Array(buffer.prefix(count)).map(Int16.init(littleEndian:))
        }
    }

    private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
