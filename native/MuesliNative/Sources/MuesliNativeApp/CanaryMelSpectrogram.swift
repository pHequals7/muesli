import Accelerate
import Foundation

/// Canary-compatible mel spectrogram extraction based on the saved NeMo frontend assets.
///
/// This matches the current Python baseline:
/// - sample_rate: 16000
/// - n_fft: 512
/// - win_length: 400
/// - hop_length: 160
/// - n_mels: 128
/// - center padding enabled
/// - natural log with `2^-24` epsilon
/// - per-feature normalization
///
/// The implementation uses precomputed DFT tables to keep the code simple and deterministic.
/// This class is not thread-safe; each transcriber instance should own its own frontend.
final class CanaryMelSpectrogram {
    private let sampleRate = 16_000
    private let nFFT = 512
    private let winLength = 400
    private let hopLength = 160
    private let numMelBins = 128
    private let epsilon: Float = powf(2.0, -24.0)

    private var numFreqBins: Int { (nFFT / 2) + 1 }
    private var frameOffset: Int { (nFFT - winLength) / 2 }
    private var centerPad: Int { nFFT / 2 }

    private let melFilterbankFlat: [Float]
    private let window: [Float]
    private let dftCos: [Float]
    private let dftSin: [Float]

    private var fftInput: [Float]
    private var realPart: [Float]
    private var imagPart: [Float]
    private var powerSpec: [Float]
    private var imagSq: [Float]
    private var melFrame: [Float]

    init(filterBankURL: URL, windowURL: URL) throws {
        let numFreqBins = (nFFT / 2) + 1
        let filterData = try Data(contentsOf: filterBankURL)
        let windowData = try Data(contentsOf: windowURL)

        let expectedFilterFloats = numMelBins * numFreqBins
        let expectedWindowFloats = winLength
        guard filterData.count == expectedFilterFloats * MemoryLayout<Float>.size else {
            throw NSError(domain: "CanaryMelSpectrogram", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid mel filter bank size at \(filterBankURL.path)",
            ])
        }
        guard windowData.count == expectedWindowFloats * MemoryLayout<Float>.size else {
            throw NSError(domain: "CanaryMelSpectrogram", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Invalid mel window size at \(windowURL.path)",
            ])
        }

        self.melFilterbankFlat = filterData.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Float.self)
            return Array(ptr)
        }
        self.window = windowData.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Float.self)
            return Array(ptr)
        }

        var cosTable = [Float](repeating: 0, count: numFreqBins * nFFT)
        var sinTable = [Float](repeating: 0, count: numFreqBins * nFFT)
        let twoPiOverN = Float(2.0 * .pi) / Float(nFFT)
        for k in 0..<numFreqBins {
            let rowOffset = k * nFFT
            for n in 0..<nFFT {
                let angle = -twoPiOverN * Float(k) * Float(n)
                cosTable[rowOffset + n] = cosf(angle)
                sinTable[rowOffset + n] = sinf(angle)
            }
        }
        self.dftCos = cosTable
        self.dftSin = sinTable

        self.fftInput = [Float](repeating: 0, count: nFFT)
        self.realPart = [Float](repeating: 0, count: numFreqBins)
        self.imagPart = [Float](repeating: 0, count: numFreqBins)
        self.powerSpec = [Float](repeating: 0, count: numFreqBins)
        self.imagSq = [Float](repeating: 0, count: numFreqBins)
        self.melFrame = [Float](repeating: 0, count: numMelBins)
    }

    func compute(audio: [Float]) -> [[Float]] {
        guard !audio.isEmpty else { return [] }

        let paddedLength = audio.count + (2 * centerPad)
        var padded = [Float](repeating: 0, count: paddedLength)
        padded.withUnsafeMutableBufferPointer { dst in
            audio.withUnsafeBufferPointer { src in
                _ = memcpy(
                    dst.baseAddress!.advanced(by: centerPad),
                    src.baseAddress!,
                    audio.count * MemoryLayout<Float>.stride
                )
            }
        }

        let numFrames = (audio.count / hopLength) + 1
        var mel = [[Float]](
            repeating: [Float](repeating: 0, count: numFrames),
            count: numMelBins
        )

        for frameIdx in 0..<numFrames {
            fftInput.withUnsafeMutableBufferPointer { ptr in
                ptr.initialize(repeating: 0)
            }

            let start = frameIdx * hopLength
            for i in 0..<winLength {
                let srcIdx = start + i
                if srcIdx < padded.count {
                    fftInput[frameOffset + i] = padded[srcIdx] * window[i]
                }
            }

            dftCos.withUnsafeBufferPointer { cosPtr in
                fftInput.withUnsafeBufferPointer { inputPtr in
                    realPart.withUnsafeMutableBufferPointer { outPtr in
                        vDSP_mmul(
                            cosPtr.baseAddress!, 1,
                            inputPtr.baseAddress!, 1,
                            outPtr.baseAddress!, 1,
                            vDSP_Length(numFreqBins),
                            1,
                            vDSP_Length(nFFT)
                        )
                    }
                }
            }

            dftSin.withUnsafeBufferPointer { sinPtr in
                fftInput.withUnsafeBufferPointer { inputPtr in
                    imagPart.withUnsafeMutableBufferPointer { outPtr in
                        vDSP_mmul(
                            sinPtr.baseAddress!, 1,
                            inputPtr.baseAddress!, 1,
                            outPtr.baseAddress!, 1,
                            vDSP_Length(numFreqBins),
                            1,
                            vDSP_Length(nFFT)
                        )
                    }
                }
            }

            vDSP_vsq(realPart, 1, &powerSpec, 1, vDSP_Length(numFreqBins))
            vDSP_vsq(imagPart, 1, &imagSq, 1, vDSP_Length(numFreqBins))
            vDSP_vadd(powerSpec, 1, imagSq, 1, &powerSpec, 1, vDSP_Length(numFreqBins))

            melFilterbankFlat.withUnsafeBufferPointer { filterPtr in
                powerSpec.withUnsafeBufferPointer { specPtr in
                    melFrame.withUnsafeMutableBufferPointer { outPtr in
                        vDSP_mmul(
                            filterPtr.baseAddress!, 1,
                            specPtr.baseAddress!, 1,
                            outPtr.baseAddress!, 1,
                            vDSP_Length(numMelBins),
                            1,
                            vDSP_Length(numFreqBins)
                        )
                    }
                }
            }

            for melIdx in 0..<numMelBins {
                mel[melIdx][frameIdx] = logf(melFrame[melIdx] + epsilon)
            }
        }

        for melIdx in 0..<numMelBins {
            let row = mel[melIdx]
            let count = Float(row.count)
            if count == 0 { continue }
            let mean = row.reduce(0, +) / count
            let variance = row.reduce(0) { partial, value in
                let delta = value - mean
                return partial + (delta * delta)
            } / count
            let denom = sqrtf(variance) + 1e-5
            for t in 0..<numFrames {
                mel[melIdx][t] = (mel[melIdx][t] - mean) / denom
            }
        }

        return mel
    }
}
