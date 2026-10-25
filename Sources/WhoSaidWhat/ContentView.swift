import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import Who

let speakerColors: [Color] = [
    Color(red: 0.36, green: 0.63, blue: 1.00),
    Color(red: 1.00, green: 0.55, blue: 0.35),
    Color(red: 0.40, green: 0.85, blue: 0.55),
    Color(red: 0.80, green: 0.50, blue: 1.00),
    Color(red: 1.00, green: 0.80, blue: 0.30),
]

func color(for speaker: Int) -> Color { speakerColors[speaker % speakerColors.count] }

func timestamp(_ t: Double) -> String {
    let s = Int(t.rounded(.down))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

func seconds(_ t: Double) -> String {
    t < 10 ? String(format: "%.2f s", t) : t < 60 ? String(format: "%.1f s", t) : timestamp(t)
}

func speed(_ audio: Double, _ took: Double) -> String {
    guard took > 0 else { return "–" }
    let x = audio / took
    return x >= 100 ? String(format: "%.0f×", x) : String(format: "%.1f×", x)
}

@MainActor
final class Session: ObservableObject {
    @Published var stage: Stage = .idle
    @Published var fileName = ""
    @Published var duration: Double = 0
    @Published var turns: [Turn] = []
    @Published var segments: [Segment] = []
    @Published var names: [Int: String] = [:]
    @Published var speakerCount = 0
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var hasVideo = false
    @Published private(set) var player: AVPlayer?

    // Timings for the speed numbers.
    @Published var startedAt = Date()
    @Published var whoSeconds: Double?
    @Published var speechSeconds: Double?
    @Published var speechStatus: String?
    @Published var totalSeconds: Double = 0

    private var timeObserver: Any?

    func name(_ speaker: Int) -> String { names[speaker] ?? "Speaker \(speaker + 1)" }

    /// The speaker talking at `currentTime`, preferring the most recent turn when two overlap.
    var currentSpeaker: Int? {
        turns.last { $0.start <= currentTime && currentTime < $0.end }?.speaker
    }

    func load(_ url: URL) {
        reset()
        fileName = url.lastPathComponent
        stage = .preparing
        Task {
            do {
                let audio = try await Pipeline.playableAudio(for: url)
                let dur = try await AVURLAsset(url: audio).load(.duration).seconds
                duration = dur
                hasVideo = !(try await AVURLAsset(url: url).loadTracks(withMediaType: .video)).isEmpty
                setUpPlayer(hasVideo ? url : audio)
                startedAt = Date()
                stage = .working(diarize: 0, transcribe: 0)

                async let diarization = runWho(audio)
                async let transcription = runSpeech(audio, duration: dur)
                let (d, w) = try await (diarization, transcription)
                totalSeconds = Date().timeIntervalSince(startedAt)

                // Hide speakers no words were assigned to (noises Who gave a label) and renumber the rest.
                let aligned = Pipeline.align(words: w, turns: d.turns)
                var renumber: [Int: Int] = [:]
                for s in aligned where renumber[s.speaker] == nil { renumber[s.speaker] = renumber.count }
                segments = aligned.map { var s = $0; s.speaker = renumber[s.speaker]!; return s }
                turns = d.turns.compactMap { t in renumber[t.speaker].map { Turn(start: t.start, end: t.end, speaker: $0) } }
                speakerCount = renumber.count
                stage = .done
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }

    private func runWho(_ audio: URL) async throws -> Diarization {
        let (result, took) = try await Pipeline.diarize(audio) { p in
            Task { @MainActor in self.update(diarize: p) }
        }
        whoSeconds = took
        return result
    }

    private func runSpeech(_ audio: URL, duration: Double) async throws -> [Word] {
        let (words, took) = try await Pipeline.transcribe(audio, duration: duration, status: { note in
            Task { @MainActor in self.speechStatus = note }
        }) { p in
            Task { @MainActor in self.update(transcribe: p) }
        }
        speechSeconds = took
        return words
    }

    private func update(diarize p: Double) {
        if case let .working(_, t) = stage { stage = .working(diarize: p, transcribe: t) }
    }

    private func update(transcribe p: Double) {
        if case let .working(d, _) = stage { stage = .working(diarize: d, transcribe: p) }
    }

    private func setUpPlayer(_ url: URL) {
        let player = AVPlayer(url: url)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.currentTime = time.seconds
                self?.isPlaying = player.rate > 0
            }
        }
        self.player = player
    }

    func togglePlay() {
        guard let player else { return }
        player.rate > 0 ? player.pause() : player.play()
        isPlaying = player.rate > 0
    }

    func seek(_ t: Double) {
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = t
        if !isPlaying { player?.play(); isPlaying = true }
    }

    func reset() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        player = nil
        timeObserver = nil
        turns = []
        segments = []
        names = [:]
        speakerCount = 0
        currentTime = 0
        isPlaying = false
        hasVideo = false
        whoSeconds = nil
        speechSeconds = nil
        speechStatus = nil
        stage = .idle
    }

    var transcript: Transcript {
        Transcript(fileName: fileName, duration: duration, segments: segments, names: names)
    }

    func rename(_ speaker: Int, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        names[speaker] = name.isEmpty ? nil : name
    }

    /// Asks where to save, then writes the transcript with the current speaker names.
    func export(_ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = (fileName as NSString).deletingPathExtension + " transcript." + format.fileExtension
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try transcript.render(format).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

struct ContentView: View {
    @StateObject private var session = Session()
    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.09).ignoresSafeArea()
            switch session.stage {
            case .idle:
                dropZone
            case .preparing, .working:
                progressView
            case .done:
                ResultView(session: session)
            case let .failed(message):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(.orange)
                    Text(message).foregroundStyle(.white).multilineTextAlignment(.center)
                    Button("Try another file") { session.reset() }
                }
                .padding(40)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // `open WhoSaidWhat.app --args -open path/to/file` opens straight into that file. (A bare path
            // argument would make AppKit treat it as a document to open, and SwiftUI then shows no window.)
            if let path = UserDefaults.standard.string(forKey: "open") {
                session.load(URL(fileURLWithPath: path))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in session.load(url) } }
            }
            return true
        }
    }

    private var dropZone: some View {
        VStack(spacing: 22) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(dropTargeted ? .white : .white.opacity(0.6))
                .symbolEffect(.bounce, value: dropTargeted)
            VStack(spacing: 8) {
                Text("Drop a podcast recording")
                    .font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                Text("Audio or video. Who figures out who spoke when, all on this Mac.")
                    .font(.system(size: 14)).foregroundStyle(.white.opacity(0.5))
            }
            Button("Choose File…") { chooseFile() }
                .buttonStyle(.bordered).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                .foregroundStyle(dropTargeted ? speakerColors[0] : .white.opacity(0.15))
                .background(RoundedRectangle(cornerRadius: 24)
                    .fill(dropTargeted ? speakerColors[0].opacity(0.08) : .clear))
                .padding(28)
        )
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
    }

    private var progressView: some View {
        VStack(spacing: 28) {
            Text(session.fileName).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
            if case let .working(d, t) = session.stage {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    let elapsed = context.date.timeIntervalSince(session.startedAt)
                    VStack(spacing: 18) {
                        Text(String(format: "%.1f s", elapsed))
                            .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                        Text("\(timestamp(session.duration)) of audio")
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.45))
                            .padding(.top, -12)
                        progressRow("Who: labelling speakers",
                                    whoNote(d), d, speakerColors[0])
                        progressRow("Transcribing speech",
                                    speechNote(t, elapsed), t, speakerColors[1])
                    }
                }
                .frame(width: 440)
            } else {
                ProgressView().controlSize(.large)
                Text("Reading audio…").foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func whoNote(_ progress: Double) -> String? {
        if let took = session.whoSeconds { return "\(seconds(took)) · \(speed(session.duration, took)) realtime" }
        return progress < 0.5 && !Pipeline.who.isDownloaded() ? "downloading model" : nil
    }

    private func speechNote(_ progress: Double, _ elapsed: Double) -> String? {
        if let took = session.speechSeconds { return "\(seconds(took)) · \(speed(session.duration, took)) realtime" }
        guard progress > 0 else { return session.speechStatus }
        let done = progress * session.duration
        return "\(timestamp(done)) in · \(speed(done, elapsed)) realtime"
    }

    private func progressRow(_ title: String, _ note: String?, _ value: Double, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).foregroundStyle(.white.opacity(0.85))
                Spacer()
                if let note { Text(note).monospacedDigit().foregroundStyle(.white.opacity(0.5)) }
                Image(systemName: "checkmark.circle.fill").foregroundStyle(tint).opacity(value >= 1 ? 1 : 0)
            }
            .font(.system(size: 13))
            ProgressView(value: value).tint(tint)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        if panel.runModal() == .OK, let url = panel.url { session.load(url) }
    }
}

struct ResultView: View {
    @ObservedObject var session: Session
    @State private var renaming: Int?

    private var activeID: UUID? {
        session.segments.last { $0.start <= session.currentTime + 0.05 }?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            stats.padding(.horizontal, 24).padding(.bottom, 16)
            Timeline(session: session).frame(height: 54).padding(.horizontal, 24).padding(.bottom, 16)
            Divider().overlay(.white.opacity(0.08))
            HStack(alignment: .top, spacing: 0) {
                transcript
                if session.hasVideo, let player = session.player {
                    VideoPanel(session: session, player: player)
                        .frame(width: 460)
                        .padding(.trailing, 24).padding(.top, 16)
                }
            }
        }
        .background {
            // Off while renaming, so typing a space doesn't toggle playback.
            Button("") { session.togglePlay() }.keyboardShortcut(.space, modifiers: []).disabled(renaming != nil).hidden()
            Button("") { session.export(.text) }.keyboardShortcut("e").hidden()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Button { session.togglePlay() } label: {
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16)).frame(width: 36, height: 36)
                    .background(Circle().fill(.white.opacity(0.1)))
            }
            .buttonStyle(.plain).foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.fileName).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text("\(session.speakerCount) speakers · \(timestamp(session.duration)) of audio")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            HStack(spacing: 8) {
                ForEach(0..<session.speakerCount, id: \.self) { speaker in
                    speakerChip(speaker)
                }
            }
            Menu {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.title) { session.export(format) }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            } primaryAction: {
                session.export(.text)
            }
            .fixedSize()
            .help("Save the transcript with timecodes (⌘E). Use the arrow for subtitles or JSON.")
            Menu {
                Button("Copy transcript") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.transcript.render(.text), forType: .string)
                }
                Button("Open another file") { session.reset() }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 24).padding(.top, 36).padding(.bottom, 18)
    }

    private var stats: some View {
        HStack(spacing: 12) {
            statTile("Who · speaker labels", session.whoSeconds, speakerColors[0])
            statTile("Speech to text", session.speechSeconds, speakerColors[1])
            statTile("Whole pipeline", session.totalSeconds, .white)
        }
    }

    private func statTile(_ title: String, _ took: Double?, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6)
                .foregroundStyle(.white.opacity(0.45))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(took.map { speed(session.duration, $0) } ?? "–")
                    .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint)
                Text("realtime").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
            }
            Text(took.map { "\(seconds($0)) for \(timestamp(session.duration)) of audio" } ?? "")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.04)))
    }

    private func speakerChip(_ speaker: Int) -> some View {
        Button { renaming = speaker } label: {
            HStack(spacing: 6) {
                Circle().fill(color(for: speaker)).frame(width: 8, height: 8)
                Text(session.name(speaker))
                Image(systemName: "pencil").font(.system(size: 10, weight: .semibold)).opacity(0.5)
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(color(for: speaker).opacity(0.15)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Rename this speaker")
        .popover(isPresented: Binding(get: { renaming == speaker }, set: { if !$0 { renaming = nil } }),
                 arrowEdge: .bottom) {
            RenameField(speaker: speaker, current: session.names[speaker] ?? "") { name in
                if let name { session.rename(speaker, to: name) }
                renaming = nil
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(session.segments) { segment in
                        row(segment).id(segment.id)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 16)
            }
            .onChange(of: activeID) { _, id in
                guard session.isPlaying, let id else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func row(_ segment: Segment) -> some View {
        let active = segment.id == activeID
        let tint = color(for: segment.speaker)
        return HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(session.name(segment.speaker)).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                        .onTapGesture { renaming = segment.speaker }
                        .help("Click to rename")
                    Text(timestamp(segment.start)).font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.35))
                }
                Text(segment.text).font(.system(size: 15)).foregroundStyle(.white.opacity(active ? 1 : 0.78))
                    .textSelection(.enabled).lineSpacing(3)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(active ? tint.opacity(0.10) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { session.seek(segment.start) }
        .animation(.easeOut(duration: 0.2), value: active)
    }
}

/// Popover for naming a speaker. Calls `done` with the new name, or nil on cancel.
struct RenameField: View {
    let speaker: Int
    let done: (String?) -> Void
    @State private var draft: String
    @FocusState private var focused: Bool

    init(speaker: Int, current: String, done: @escaping (String?) -> Void) {
        self.speaker = speaker
        self.done = done
        _draft = State(initialValue: current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(color(for: speaker)).frame(width: 8, height: 8)
                Text("Rename Speaker \(speaker + 1)").font(.system(size: 12, weight: .semibold))
            }
            TextField("Name, e.g. Lex", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused($focused)
                .onSubmit { done(draft) }
            HStack {
                Text("Leave empty to reset").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Save") { done(draft) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .onAppear { focused = true }
    }
}

/// The video, framed in the colour of whoever is talking, with their name in the corner.
struct VideoPanel: View {
    @ObservedObject var session: Session
    let player: AVPlayer

    var body: some View {
        let speaker = session.currentSpeaker
        let tint = speaker.map(color(for:)) ?? .white.opacity(0.15)
        VStack(alignment: .leading, spacing: 10) {
            VideoSurface(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint, lineWidth: 2))
                .overlay(alignment: .bottomLeading) {
                    if let speaker {
                        HStack(spacing: 6) {
                            Circle().fill(color(for: speaker)).frame(width: 8, height: 8)
                            Text(session.name(speaker)).font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.65)))
                        .padding(12)
                        .transition(.opacity)
                    }
                }
                .onTapGesture { session.togglePlay() }
            Text(timestamp(session.currentTime) + " / " + timestamp(session.duration))
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.45))
        }
        .animation(.easeOut(duration: 0.2), value: speaker)
    }
}

/// A bare AVPlayerLayer, without the system playback controls.
struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}

/// One lane per speaker; each turn from Who is a bar. Click anywhere to jump there.
struct Timeline: View {
    @ObservedObject var session: Session

    var body: some View {
        GeometryReader { geo in
            let lanes = max(session.speakerCount, 1)
            let laneHeight = (geo.size.height - CGFloat(lanes - 1) * 3) / CGFloat(lanes)
            let scale = session.duration > 0 ? geo.size.width / session.duration : 0
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.04))
                ForEach(Array(session.turns.enumerated()), id: \.offset) { _, turn in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: turn.speaker))
                        .frame(width: max(1.5, (turn.end - turn.start) * scale), height: laneHeight)
                        .offset(x: turn.start * scale, y: CGFloat(turn.speaker) * (laneHeight + 3))
                }
                Rectangle().fill(.white).frame(width: 2, height: geo.size.height)
                    .offset(x: session.currentTime * scale - 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                guard scale > 0 else { return }
                session.seek(max(0, min(session.duration, value.location.x / scale)))
            })
        }
    }
}
