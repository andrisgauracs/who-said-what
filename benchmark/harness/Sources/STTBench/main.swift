import AVFoundation
import Foundation
import Speech
import Voz

// Usage: STTBench <apple|voz> <manifest.tsv> <out.jsonl>
// manifest.tsv: id \t set \t path   (16 kHz mono WAV)

struct Item { let id, set, path: String }

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// Same configuration as Pipeline.transcribeWithApple in the app.
func appleTranscribe(_ url: URL) async throws -> String {
    let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        ?? Locale(identifier: "en-US")
    let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                        reportingOptions: [], attributeOptions: [.audioTimeRange])
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try await request.downloadAndInstall()
    }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let file = try AVAudioFile(forReading: url)
    let collector = Task { () throws -> String in
        var text = ""
        for try await result in transcriber.results { text += String(result.text.characters) }
        return text
    }
    if let last = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: last)
    } else {
        await analyzer.cancelAndFinishNow()
    }
    return try await collector.value
}

let args = CommandLine.arguments
guard args.count == 4, ["apple", "voz"].contains(args[1]) else {
    FileHandle.standardError.write("usage: STTBench <apple|voz> <manifest.tsv> <out.jsonl>\n".data(using: .utf8)!)
    exit(2)
}
let engine = args[1]
let items = try String(contentsOfFile: args[2], encoding: .utf8)
    .split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
    .filter { $0.count == 3 }.map { Item(id: $0[0], set: $0[1], path: $0[2]) }
FileManager.default.createFile(atPath: args[3], contents: nil)
let out = try FileHandle(forWritingTo: URL(fileURLWithPath: args[3]))

let loadClock = ContinuousClock.now
let voz: Voz? = engine == "voz" ? try await Voz() : nil
let loadSeconds = (ContinuousClock.now - loadClock).seconds
FileHandle.standardError.write("[\(engine)] load \(String(format: "%.2f", loadSeconds))s, \(items.count) items\n".data(using: .utf8)!)

func run(_ item: Item) async throws -> String {
    if let voz { return try await voz.transcribe(path: item.path).text }
    return try await appleTranscribe(URL(fileURLWithPath: item.path))
}

// Warm-up so first-call compilation/asset checks don't land on a scored item.
if let first = items.first { _ = try? await run(first) }

var total = 0.0, audio = 0.0
for (i, item) in items.enumerated() {
    let duration = (try? AVAudioFile(forReading: URL(fileURLWithPath: item.path))).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
    let clock = ContinuousClock.now
    var text = "", error: String?
    do { text = try await run(item) } catch let e { error = "\(e)" }
    let seconds = (ContinuousClock.now - clock).seconds
    total += seconds; audio += duration
    var row: [String: Any] = ["id": item.id, "set": item.set, "engine": engine,
                              "duration": duration, "seconds": seconds, "hyp": text]
    if let error { row["error"] = error }
    out.write(try JSONSerialization.data(withJSONObject: row) + "\n".data(using: .utf8)!)
    if i % 25 == 0 || duration > 120 {
        FileHandle.standardError.write("[\(engine)] \(i + 1)/\(items.count) \(item.set) \(String(format: "%.1fs audio in %.2fs", duration, seconds))\n".data(using: .utf8)!)
    }
}
FileHandle.standardError.write("[\(engine)] done: \(String(format: "%.0fs audio in %.1fs (%.0fx realtime)", audio, total, audio / max(total, 1e-9)))\n".data(using: .utf8)!)
