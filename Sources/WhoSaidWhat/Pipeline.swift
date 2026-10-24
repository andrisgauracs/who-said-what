import AVFoundation
import Foundation
import Speech
import Who

struct Word {
    let text: String
    let start: Double
    let end: Double
}

/// One speaker's uninterrupted stretch of speech. Keeps its words so exports can split it by time.
struct Segment: Identifiable {
    let id = UUID()
    var speaker: Int
    var words: [Word]

    var start: Double { words.first?.start ?? 0 }
    var end: Double { words.last?.end ?? 0 }
    var text: String { words.map(\.text).joined().trimmingCharacters(in: .whitespaces) }
}

enum Stage: Equatable {
    case idle
    case preparing
    case working(diarize: Double, transcribe: Double)
    case done
    case failed(String)
}

/// Runs Who (who spoke when) and SpeechTranscriber (what was said) side by side, then
/// assigns every transcribed word to the speaker turn it falls in.
enum Pipeline {
    static let who = Who()

    /// AVAudioFile reads wav/aiff/mp3/m4a/caf directly; anything else (video, odd containers)
    /// gets its audio track decoded to a temporary PCM file first (no lossy re-encode).
    static func playableAudio(for url: URL) async throws -> URL {
        if (try? AVAudioFile(forReading: url)) != nil { return url }
        let failure = NSError(domain: "WhoSaidWhat", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Can't read audio from \(url.lastPathComponent)"])
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw failure }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? failure }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        var file: AVAudioFile?
        while let sample = output.copyNextSampleBuffer() {
            guard let description = sample.formatDescription,
                  let asbd = description.audioStreamBasicDescription else { continue }
            var streamDescription = asbd
            guard let format = AVAudioFormat(streamDescription: &streamDescription) else { throw failure }
            if file == nil {
                file = try AVAudioFile(forWriting: out, settings: format.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: true)
            }
            let frames = AVAudioFrameCount(sample.numSamples)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { throw failure }
            buffer.frameLength = frames
            try sample.copyPCMData(fromRange: 0..<sample.numSamples, into: buffer.mutableAudioBufferList)
            try file?.write(from: buffer)
        }
        if reader.status == .failed { throw reader.error ?? failure }
        guard file != nil else { throw failure }
        return out
    }

    /// Returns the result and the seconds the model itself took (download and decoding excluded).
    static func diarize(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> (Diarization, Double) {
        if !who.isDownloaded() {
            try await who.download { progress($0 * 0.5) }
        }
        progress(0.5)
        // Decode up front so the timing below covers only the model.
        let samples = try decodeMono(url, sampleRate: 16_000)
        let clock = ContinuousClock.now
        // Drop "speakers" with under 2% of the audio: laughs, coughs, short blips.
        let result = try await who.diarize(samples: samples, sampleRate: 16_000)
            .keepingSpeakers(minimumShare: 0.02)
        let seconds = (ContinuousClock.now - clock).seconds
        progress(1)
        return (result, seconds)
    }

    static func decodeMono(_ url: URL, sampleRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw NSError(domain: "WhoSaidWhat", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Can't convert \(url.lastPathComponent) to mono"])
        }
        let chunk: AVAudioFrameCount = 65_536
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk)!
        let output = AVAudioPCMBuffer(pcmFormat: target,
                                      frameCapacity: AVAudioFrameCount(Double(chunk) * sampleRate / file.processingFormat.sampleRate) + 1024)!
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * sampleRate / file.processingFormat.sampleRate))
        var finished = false
        while true {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                if finished { outStatus.pointee = .endOfStream; return nil }
                do { try file.read(into: input, frameCount: chunk) } catch { finished = true }
                if input.frameLength == 0 { finished = true; outStatus.pointee = .endOfStream; return nil }
                outStatus.pointee = .haveData
                return input
            }
            if let error { throw error }
            samples.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            if status == .endOfStream || (status == .inputRanDry && finished) { break }
        }
        return samples
    }

    /// Returns the words and the seconds spent transcribing (speech model install excluded).
    static func transcribe(_ url: URL, duration: Double,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> ([Word], Double) {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
            ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let clock = ContinuousClock.now
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)

        let collector = Task { () throws -> [Word] in
            var words: [Word] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters)
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    words.append(Word(text: text, start: range.start.seconds, end: range.end.seconds))
                }
                if duration > 0 { progress(min(1, result.range.end.seconds / duration)) }
            }
            return words
        }

        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let words = try await collector.value
        progress(1)
        return (words, (ContinuousClock.now - clock).seconds)
    }

    /// Each word goes to the turn that overlaps it most, or the nearest turn when it
    /// falls in a gap; consecutive words by the same speaker become one segment.
    static func align(words: [Word], turns: [Turn]) -> [Segment] {
        guard !turns.isEmpty else { return words.isEmpty ? [] : [Segment(speaker: 0, words: words)] }
        var segments: [Segment] = []
        for word in words {
            let speaker = bestSpeaker(for: word, in: turns)
            if let last = segments.last, last.speaker == speaker, word.start - last.end < 1.5 {
                segments[segments.count - 1].words.append(word)
            } else {
                segments.append(Segment(speaker: speaker, words: [word]))
            }
        }
        return segments
    }

    private static func bestSpeaker(for word: Word, in turns: [Turn]) -> Int {
        var best: (speaker: Int, overlap: Double)?
        for turn in turns {
            let overlap = min(word.end, turn.end) - max(word.start, turn.start)
            if overlap > 0, overlap > (best?.overlap ?? 0) { best = (turn.speaker, overlap) }
        }
        if let best { return best.speaker }
        let mid = (word.start + word.end) / 2
        return turns.min { distance(mid, $0) < distance(mid, $1) }!.speaker
    }

    private static func distance(_ t: Double, _ turn: Turn) -> Double {
        t < turn.start ? turn.start - t : (t > turn.end ? t - turn.end : 0)
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
