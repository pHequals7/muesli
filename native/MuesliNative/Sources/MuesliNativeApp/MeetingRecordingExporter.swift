import Foundation

enum MeetingRecordingExporter {
    private struct PCMTrack {
        let sampleRate: Int
        let channels: Int
        let bitsPerSample: Int
        let samples: [Int16]
    }

    static func exportMergedRecording(
        micURL: URL?,
        systemURL: URL?,
        meetingTitle: String,
        startedAt: Date,
        supportDirectory: URL
    ) throws -> URL? {
        guard micURL != nil || systemURL != nil else { return nil }

        let recordingsDirectory = supportDirectory
            .appendingPathComponent("meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true
        )

        let destinationURL = recordingsDirectory.appendingPathComponent(
            "\(fileNamePrefix(for: startedAt, title: meetingTitle)).wav"
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        if let micURL, systemURL == nil {
            try FileManager.default.moveItem(at: micURL, to: destinationURL)
            return destinationURL
        }
        if let systemURL, micURL == nil {
            try FileManager.default.moveItem(at: systemURL, to: destinationURL)
            return destinationURL
        }

        guard let micURL, let systemURL else {
            return nil
        }

        let micTrack = try loadPCMTrack(from: micURL)
        let systemTrack = try loadPCMTrack(from: systemURL)

        guard micTrack.sampleRate == systemTrack.sampleRate,
              micTrack.channels == systemTrack.channels,
              micTrack.bitsPerSample == systemTrack.bitsPerSample else {
            throw NSError(
                domain: "MeetingRecordingExporter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Meeting audio tracks use incompatible WAV formats."]
            )
        }

        let mixedSamples = mix(mic: micTrack.samples, system: systemTrack.samples)
        let dataSize = mixedSamples.count * MemoryLayout<Int16>.size

        var data = Data()
        data.append(wavHeader(dataSize: dataSize, sampleRate: micTrack.sampleRate, channels: micTrack.channels, bitsPerSample: micTrack.bitsPerSample))
        for sample in mixedSamples {
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        try data.write(to: destinationURL, options: .atomic)

        try? FileManager.default.removeItem(at: micURL)
        try? FileManager.default.removeItem(at: systemURL)
        return destinationURL
    }

    private static func fileNamePrefix(for date: Date, title: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let timestamp = formatter.string(from: date)

        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let normalized = title.unicodeScalars.map { allowed.contains($0) ? String($0) : " " }.joined()
        let slug = normalized
            .split(whereSeparator: \.isWhitespace)
            .prefix(6)
            .joined(separator: "-")
            .lowercased()

        return slug.isEmpty ? timestamp : "\(timestamp)-\(slug)"
    }

    private static func mix(mic: [Int16], system: [Int16]) -> [Int16] {
        let maxCount = max(mic.count, system.count)
        var output = [Int16]()
        output.reserveCapacity(maxCount)

        for index in 0..<maxCount {
            let hasMic = index < mic.count
            let hasSystem = index < system.count
            let micValue = hasMic ? Int(mic[index]) : 0
            let systemValue = hasSystem ? Int(system[index]) : 0
            let contributors = (hasMic ? 1 : 0) + (hasSystem ? 1 : 0)
            // Average the active inputs to avoid clipping when both tracks peak.
            let averaged = contributors == 0 ? 0 : (micValue + systemValue) / contributors
            output.append(Int16(clamping: averaged))
        }

        return output
    }

    private static func loadPCMTrack(from url: URL) throws -> PCMTrack {
        let data = try Data(contentsOf: url)
        guard data.count >= 44 else {
            throw NSError(
                domain: "MeetingRecordingExporter",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Meeting audio file is too short to be a WAV file."]
            )
        }

        guard String(data: data.subdata(in: 0..<4), encoding: .ascii) == "RIFF",
              String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE" else {
            throw NSError(
                domain: "MeetingRecordingExporter",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Meeting audio file is not a valid WAV container."]
            )
        }

        var cursor = 12
        var sampleRate = 0
        var channels = 0
        var bitsPerSample = 0
        var pcmData = Data()

        while cursor + 8 <= data.count {
            let chunkID = String(data: data.subdata(in: cursor..<(cursor + 4)), encoding: .ascii) ?? ""
            let chunkSize = Int(readUInt32LE(data, at: cursor + 4))
            let chunkDataStart = cursor + 8
            let chunkDataEnd = min(chunkDataStart + chunkSize, data.count)

            if chunkID == "fmt ", chunkDataEnd - chunkDataStart >= 16 {
                channels = Int(readUInt16LE(data, at: chunkDataStart + 2))
                sampleRate = Int(readUInt32LE(data, at: chunkDataStart + 4))
                bitsPerSample = Int(readUInt16LE(data, at: chunkDataStart + 14))
            } else if chunkID == "data" {
                pcmData = data.subdata(in: chunkDataStart..<chunkDataEnd)
                break
            }

            cursor = chunkDataStart + chunkSize + (chunkSize % 2)
        }

        guard sampleRate > 0, channels == 1, bitsPerSample == 16, !pcmData.isEmpty else {
            throw NSError(
                domain: "MeetingRecordingExporter",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Meeting audio must be mono 16-bit PCM WAV."]
            )
        }

        let sampleCount = pcmData.count / MemoryLayout<Int16>.size
        let samples: [Int16] = pcmData.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            return Array(int16Buffer.prefix(sampleCount))
        }

        return PCMTrack(
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample,
            samples: samples
        )
    }

    private static func wavHeader(
        dataSize: Int,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int
    ) -> Data {
        var header = Data()
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8

        header.append(contentsOf: "RIFF".utf8)
        appendUInt32LE(UInt32(36 + dataSize), to: &header)
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        appendUInt32LE(16, to: &header)
        appendUInt16LE(1, to: &header)
        appendUInt16LE(UInt16(channels), to: &header)
        appendUInt32LE(UInt32(sampleRate), to: &header)
        appendUInt32LE(UInt32(byteRate), to: &header)
        appendUInt16LE(UInt16(blockAlign), to: &header)
        appendUInt16LE(UInt16(bitsPerSample), to: &header)
        header.append(contentsOf: "data".utf8)
        appendUInt32LE(UInt32(dataSize), to: &header)
        return header
    }

    private static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        data.subdata(in: offset..<(offset + 2)).withUnsafeBytes {
            UInt16(littleEndian: $0.load(as: UInt16.self))
        }
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            UInt32(littleEndian: $0.load(as: UInt32.self))
        }
    }
}
