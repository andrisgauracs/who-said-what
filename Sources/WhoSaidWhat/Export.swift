import Foundation
import UniformTypeIdentifiers

/// The transcript formats the app can save. Speaker names are whatever the user renamed them to.
enum ExportFormat: String, CaseIterable, Identifiable {
    case text, srt, vtt, json

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: "Text with timecodes (.txt)"
        case .srt: "Subtitles (.srt)"
        case .vtt: "Web subtitles (.vtt)"
        case .json: "JSON (.json)"
        }
    }

    var fileExtension: String { self == .text ? "txt" : rawValue }

    var contentType: UTType {
        switch self {
        case .text: .plainText
        case .json: .json
        default: UTType(filenameExtension: fileExtension) ?? .plainText
        }
    }
}

struct Transcript {
    let fileName: String
    let duration: Double
    let segments: [Segment]
    let names: [Int: String]

    func name(_ speaker: Int) -> String { names[speaker] ?? "Speaker \(speaker + 1)" }

    func render(_ format: ExportFormat) -> String {
        switch format {
        case .text: text
        case .srt: subtitles(vtt: false)
        case .vtt: subtitles(vtt: true)
        case .json: json
        }
    }

    /// `[00:01:23] Name: what they said`, one paragraph per speaker turn.
    private var text: String {
        let speakers = Set(segments.map(\.speaker)).sorted().map(name).joined(separator: ", ")
        let header = "\(fileName)\nDuration: \(Transcript.clock(duration))\nSpeakers: \(speakers)"
        let body = segments.map { "[\(Transcript.clock($0.start))] \(name($0.speaker)): \($0.text)" }
        return ([header] + body).joined(separator: "\n\n") + "\n"
    }

    /// Cues of at most ~7 s / 84 characters, each prefixed with its speaker.
    private func subtitles(vtt: Bool) -> String {
        var cues: [String] = []
        for segment in segments {
            for words in Transcript.cueChunks(segment.words) {
                let start = Transcript.clock(words.first!.start, millis: vtt ? "." : ",")
                let end = Transcript.clock(words.last!.end, millis: vtt ? "." : ",")
                let line = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
                let text = vtt ? "<v \(name(segment.speaker))>\(line)" : "\(name(segment.speaker)): \(line)"
                cues.append(vtt ? "\(start) --> \(end)\n\(text)"
                                : "\(cues.count + 1)\n\(start) --> \(end)\n\(text)")
            }
        }
        return (vtt ? "WEBVTT\n\n" : "") + cues.joined(separator: "\n\n") + "\n"
    }

    private var json: String {
        struct Speaker: Encodable { let id: Int; let name: String }
        struct Line: Encodable { let speaker: Int; let name: String; let start: Double; let end: Double; let text: String }
        struct File: Encodable { let file: String; let duration: Double; let speakers: [Speaker]; let segments: [Line] }

        let round = { (t: Double) in (t * 100).rounded() / 100 }
        let file = File(
            file: fileName,
            duration: round(duration),
            speakers: Set(segments.map(\.speaker)).sorted().map { Speaker(id: $0, name: name($0)) },
            segments: segments.map {
                Line(speaker: $0.speaker, name: name($0.speaker), start: round($0.start), end: round($0.end), text: $0.text)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(file)) ?? Data(), as: UTF8.self) + "\n"
    }

    /// `HH:MM:SS`, or `HH:MM:SS,mmm` for subtitles.
    static func clock(_ t: Double, millis separator: String? = nil) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        let base = String(format: "%02d:%02d:%02d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60)
        return separator.map { base + $0 + String(format: "%03d", ms % 1000) } ?? base
    }

    /// Splits a speaker turn into subtitle cues: whole sentences packed together while they fit,
    /// and sentences too long for one cue cut into evenly sized pieces (no one-word leftovers).
    private static func cueChunks(_ words: [Word]) -> [[Word]] {
        let maxChars = 84, maxSeconds = 7.0
        func chars(_ w: [Word]) -> Int { w.map(\.text).joined().trimmingCharacters(in: .whitespaces).count }
        func fits(_ w: [Word]) -> Bool { chars(w) <= maxChars && (w.last!.end - w.first!.start) <= maxSeconds }

        var sentences: [[Word]] = [[]]
        for word in words {
            sentences[sentences.count - 1].append(word)
            if let last = word.text.trimmingCharacters(in: .whitespaces).last, ".?!".contains(last) {
                sentences.append([])
            }
        }

        var pieces: [[Word]] = []
        for sentence in sentences where !sentence.isEmpty {
            if fits(sentence) { pieces.append(sentence); continue }
            let parts = max(Int((Double(chars(sentence)) / Double(maxChars)).rounded(.up)),
                            Int(((sentence.last!.end - sentence.first!.start) / maxSeconds).rounded(.up)))
            let target = Double(chars(sentence)) / Double(parts)
            var current: [Word] = []
            for word in sentence {
                if !current.isEmpty, Double(chars(current + [word])) > target * 1.1 {
                    pieces.append(current)
                    current = []
                }
                current.append(word)
            }
            if !current.isEmpty { pieces.append(current) }
        }

        var cues: [[Word]] = []
        for piece in pieces {
            if let last = cues.last, fits(last + piece) {
                cues[cues.count - 1] += piece
            } else {
                cues.append(piece)
            }
        }
        return cues
    }
}
