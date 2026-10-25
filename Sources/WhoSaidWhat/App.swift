import AVFoundation
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct WhoSaidWhatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Start loading Voz now, so its first-run Neural Engine preparation runs while the drop zone waits.
        if Transcriber.current == .voz { _ = Pipeline.voz }
        // `WhoSaidWhat --print file.wav [--format txt|srt|vtt|json] [--names "A,B"]` runs without the window and prints the transcript.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--print"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            Task {
                do {
                    let audio = try await Pipeline.playableAudio(for: url)
                    let duration = try await AVURLAsset(url: audio).load(.duration).seconds
                    async let d = Pipeline.diarize(audio) { _ in }
                    async let w = Pipeline.transcribe(audio, duration: duration) { _ in }
                    let ((diarization, whoTime), (words, speechTime)) = try await (d, w)
                    // Stats go to stderr so `--print file > transcript.srt` writes a clean file.
                    let stats = String(format: "%d speakers, %d words · Who: %.2fs (%.0fx realtime) · speech to text: %.2fs (%.0fx realtime)\n",
                                       diarization.speakerCount, words.count,
                                       whoTime, duration / whoTime, speechTime, duration / speechTime)
                    FileHandle.standardError.write(Data(stats.utf8))
                    // `--format txt|srt|vtt|json` picks the output; the default is text with timecodes.
                    let format = args.firstIndex(of: "--format").flatMap { j in
                        j + 1 < args.count ? ExportFormat.allCases.first { [$0.rawValue, $0.fileExtension].contains(args[j + 1]) } : nil
                    } ?? .text
                    let segments = Pipeline.align(words: words, turns: diarization.turns)
                    // `--names "Lex,Guest"` names the speakers in order of first appearance.
                    var names: [Int: String] = [:]
                    if let j = args.firstIndex(of: "--names"), j + 1 < args.count {
                        for (n, name) in args[j + 1].split(separator: ",").enumerated() {
                            names[n] = name.trimmingCharacters(in: .whitespaces)
                        }
                    }
                    print(Transcript(fileName: url.lastPathComponent, duration: duration, segments: segments, names: names)
                        .render(format), terminator: "")
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
                    exit(1)
                }
            }
            return
        }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        WindowGroup("Who Said What") {
            ContentView()
                .frame(minWidth: 820, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 720)
        // Always open a fresh window, never a restored "closed" state.
        .restorationBehavior(.disabled)
    }
}
