// First launch (design/ui/Onboarding.dc.html): one thing per card, and Pip checks it works before moving on.
import AppKit
import AVFoundation
import CryptoKit
import SwiftUI

/// The files the app downloads, pinned by SHA-256 (same values as scripts/setup-macos.sh).
struct ModelFile {
    let name: String, url: URL, sha256: String, bytes: Int64
    static let whisper = ModelFile(name: "ggml-large-v3-turbo.bin",
                                   url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
                                   sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69", bytes: 1_624_555_275)
    static let vad = ModelFile(name: "ggml-silero-v5.1.2.bin",
                               url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!,
                               sha256: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf", bytes: 885_098)
    var destination: String { supportDir + "/models/" + name }
}

func sha256(ofFile path: String) -> String? {
    guard let h = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? h.close() }
    var hasher = SHA256()
    while true {
        let chunk = h.readData(ofLength: 8 << 20)
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Downloads a model over HTTPS to a temporary file, checks its SHA-256, and only then moves it into place.
final class Downloader: NSObject, URLSessionDownloadDelegate {
    var progress: (Int64, Int64) -> Void = { _, _ in }
    var finished: (Result<Void, Error>) -> Void = { _ in }
    private var file: ModelFile?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    struct Mismatch: LocalizedError { var errorDescription: String? { L("The download didn't match its checksum, so it was deleted.") } }

    func start(_ f: ModelFile) {
        file = f
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        session = s
        task = s.downloadTask(with: f.url)
        task?.resume()
    }
    func cancel() { task?.cancel(); session?.invalidateAndCancel() }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite t: Int64) {
        progress(w, t > 0 ? t : file?.bytes ?? 0)
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let f = file else { return }
        // The temporary file disappears when this method returns: move it first, check it off the main thread.
        let staged = URL(fileURLWithPath: f.destination + ".part")
        try? fm.createDirectory(atPath: supportDir + "/models", withIntermediateDirectories: true)
        try? fm.removeItem(at: staged)
        do { try fm.moveItem(at: location, to: staged) } catch { finished(.failure(error)); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = sha256(ofFile: staged.path) == f.sha256
            DispatchQueue.main.async {
                if ok {
                    try? fm.removeItem(atPath: f.destination)
                    do { try fm.moveItem(atPath: staged.path, toPath: f.destination); log("model verified: \(f.name)"); self.finished(.success(())) }
                    catch { self.finished(.failure(error)) }
                } else {
                    try? fm.removeItem(at: staged)
                    log("model checksum mismatch: \(f.name)")
                    self.finished(.failure(Mismatch()))
                }
            }
        }
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error, (e as NSError).code != NSURLErrorCancelled { finished(.failure(e)) }
    }
}

final class OnboardingModel: ObservableObject {
    enum Download: Equatable { case idle, downloading(Double, Int64, Int64), verifying, done, failed(String) }

    @Published var step = 0
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 8)
    @Published var heard = false
    /// The microphone in use, shown so a wrong input (a disconnected headset…) is easy to spot.
    @Published var micName: String?
    /// True after a few seconds without hearing anything: the card offers help instead of waiting forever.
    @Published var quietForAWhile = false
    private var loudTicks = 0
    private var micStartedAt = Date()
    private weak var app: Model?
    @Published var download = Download.idle
    @Published var practice = ""
    @Published var practiced = false

    private var recorder: AVAudioRecorder?
    private var meter: Timer?
    private var poll: Timer?
    private let downloader = Downloader()
    private var lastAtStart: Date?
    let live: Bool

    init(live: Bool = true) { self.live = live }

    func enter(_ s: Int, app: Model) {
        stopMic(); poll?.invalidate(); poll = nil
        self.app = app
        step = s
        guard live else { return }
        switch s {
        case 1: if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { startMic() }
        case 2:
            // Moves on by itself a moment after Accessibility is turned on.
            poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                app.refreshPermissions()
                guard app.accessibility, let me = self else { return }
                t.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if me.step == 2 { me.enter(3, app: app) } }
            }
        case 3: app.refreshPermissions(); if app.hasModel { download = .done }
        case 4: lastAtStart = app.history.first?.at; practiced = false; practice = ""
                // Each new dictation lands at the top of the history: show exactly what Pip heard in the box.
                // (Don't rely on the ⌘V paste for this: it only reaches the box if it has the keyboard focus.)
                poll = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                    guard let me = self, let first = app.history.first, first.at != me.lastAtStart else { return }
                    me.lastAtStart = first.at
                    me.practice = first.text
                    me.practiced = true
                }
        default: break
        }
    }

    func allowMicrophone(app: Model) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async { app.refreshPermissions(); if ok { self.startMic() } }
        }
    }

    /// A short meter so you can see Pip hears you. Recorded to a temp file that's deleted right away.
    func startMic() {
        guard recorder == nil else { return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "pip-dictee-miccheck.wav")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16]
        micName = AVCaptureDevice.default(for: .audio)?.localizedName
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else { log("mic check: recorder unavailable"); quietForAWhile = true; return }
        r.isMeteringEnabled = true
        guard r.record() else { log("mic check: could not start recording"); quietForAWhile = true; return }
        recorder = r; heard = false; quietForAWhile = false; loudTicks = 0; micStartedAt = Date()
        let m = Timer(timeInterval: 1 / 15, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(m, forMode: .common)   // keeps running while a menu or a drag is in progress
        meter = m
    }

    /// Voice, not noise: the peak has to stay above -32 dBFS for about 0.2 s (a click or a cough is shorter).
    /// The old check needed the *average* above -30 dBFS, which a normal voice a little away from a MacBook rarely reaches.
    private func tick() {
        guard let r = recorder else { return }
        r.updateMeters()
        let avg = r.averagePower(forChannel: 0), peak = r.peakPower(forChannel: 0)
        var ls = levels; ls.removeFirst(); ls.append(CGFloat(max(0, min(1, (avg + 55) / 40)))); levels = ls
        guard !heard else { return }
        loudTicks = peak > -32 ? loudTicks + 1 : 0
        if loudTicks >= 3 {
            heard = true
            log("mic check: voice heard")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                if let me = self, me.step == 1, let app = me.app { me.enter(2, app: app) }
            }
        } else if Date().timeIntervalSince(micStartedAt) > 6 {
            quietForAWhile = true
        }
    }
    func stopMic() {
        meter?.invalidate(); meter = nil
        if let r = recorder { r.stop(); r.deleteRecording() }
        recorder = nil
    }

    func startDownload(app: Model) {
        download = .downloading(0, 0, ModelFile.whisper.bytes)
        downloader.progress = { [weak self] w, t in self?.download = w >= t && t > 0 ? .verifying : .downloading(Double(w) / Double(max(t, 1)), w, t) }
        downloader.finished = { [weak self] r in
            guard let me = self else { return }
            switch r {
            case .success:
                me.download = .done
                app.refreshPermissions(); app.startWhisper()
                // The voice-detection model is small and optional: fetched quietly after.
                if !fm.fileExists(atPath: ModelFile.vad.destination) {
                    let d = Downloader(); d.finished = { _ in _ = d }; d.start(ModelFile.vad)
                }
            case .failure(let e): me.download = .failed(e.localizedDescription)
            }
        }
        downloader.start(ModelFile.whisper)
    }
    func cancelDownload() { downloader.cancel(); download = .idle }
    func finish() { stopMic(); poll?.invalidate() }
}

struct OnboardingView: View {
    @ObservedObject var model: Model
    @ObservedObject var ob: OnboardingModel
    var close: () -> Void = {}
    @FocusState private var practiceFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(stepLabel).font(.pipText(12.5, .heavy)).foregroundStyle(ob.step == 2 && !model.accessibility ? Color.pipSunText : Color.pipInkMuted)
                Spacer()
                HStack(spacing: 6) { ForEach(0..<5) { i in Capsule().fill(i <= ob.step ? Color.pipCoral : Color.pipInk.opacity(0.12)).frame(width: i == ob.step ? 18 : 7, height: 7) } }
            }
            Group {
                switch ob.step {
                case 0: welcome
                case 1: microphone
                case 2: accessibility
                case 3: voiceModel
                default: tryIt
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(28)
        .frame(width: 400, height: 600)
        .foregroundStyle(Color.pipInk)
        .background(ob.step == 2 && !model.accessibility ? Color(hex: 0xFFF8E1) : Color.white)
    }

    var stepLabel: String { [L("1 of 5"), L("2 of 5 · Microphone"), L("3 of 5 · Accessibility"), L("4 of 5 · Voice model"), L("5 of 5 · Try it")][min(ob.step, 4)] }

    func hero(_ mood: PipMood, glow: Color? = nil) -> some View {
        ZStack {
            if let g = glow { Circle().fill(g.opacity(0.22)).frame(width: 170, height: 170) }
            PipView(mood: mood).frame(width: 150, height: 136)
        }
        .frame(height: 176)
    }
    func title(_ t: String, _ body: String) -> some View {
        VStack(spacing: 10) {
            Text(t).font(.pipTitle(30))
            Text(body).font(.pipText(15.5)).foregroundStyle(Color.pipInkSoft).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
    }
    func next(_ label: String = L("Next"), kind: PipButtonStyle.Kind = .primary, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(label, action: action).buttonStyle(PipButtonStyle(kind: kind, fill: true)).disabled(!enabled).opacity(enabled ? 1 : 0.45)
    }
    func go(_ s: Int) { ob.enter(s, app: model) }

    var welcome: some View {
        VStack(spacing: 16) {
            AppLanguagePicker(model: model)
            hero(.happy)
            title(L("Hi! I'm Pip."), L("Hold a key, talk, and I'll type for you, in any app. Everything stays on this Mac."))
            Text(L("Three quick things and we're ready.")).font(.pipText(13.5)).foregroundStyle(Color.pipInkMuted)
            Spacer()
            next(L("Let's set it up")) { go(1) }
        }
    }

    var microphone: some View {
        VStack(spacing: 16) {
            hero(.listening, glow: .pipCoral)
            title(L("Can I hear you?"), L("Allow the microphone, then say anything. I only listen while you hold the key."))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Waveform(levels: ob.levels).colorMultiply(.pipCoral)
                    Spacer()
                    if ob.heard { Check(text: L("I can hear you")) }
                    else if model.microphone == .authorized { Text(L("Say something…")).font(.pipText(13.5, .bold)).foregroundStyle(Color.pipInkMuted) }
                }
                if let mic = ob.micName, model.microphone == .authorized {
                    Text(L("Using: %@", mic)).font(.pipText(12)).foregroundStyle(Color.pipInkMuted).lineLimit(1)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.pipMist))
            if ob.quietForAWhile, !ob.heard, model.microphone == .authorized {
                VStack(spacing: 8) {
                    Text(L("I can't hear you yet. Check that the right microphone is selected and not muted."))
                        .font(.pipText(13)).foregroundStyle(Color.pipSunText).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Button(L("Open Sound Settings")) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input")!) }
                        .buttonStyle(.plain).font(.pipText(13, .bold)).foregroundStyle(Color.pipCoralText)
                }
            }
            if model.microphone == .denied {
                Text(L("The microphone is turned off for Pip Dictée. Turn it on in System Settings › Privacy & Security › Microphone."))
                    .font(.pipText(13)).foregroundStyle(Color.pipSunText).multilineTextAlignment(.center)
            }
            Spacer()
            if model.microphone == .authorized { next(ob.heard ? L("Next") : L("Skip for now"), kind: ob.heard ? .primary : .secondary) { go(2) } }
            else if model.microphone == .denied {
                next(L("Open System Settings"), kind: .amber) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
            } else { next(L("Allow the microphone")) { ob.allowMicrophone(app: model) } }
        }
    }

    var accessibility: some View {
        VStack(spacing: 16) {
            hero(model.accessibility ? .happy : .needsYou, glow: model.accessibility ? nil : .pipSun)
            title(model.accessibility ? L("Thank you!") : L("One more permission"),
                  L("Accessibility lets me notice ⌃⌥ and type for you. I only react to the shortcut, Space and Esc; I never record your keys."))
            if model.accessibility { Check(text: L("Accessibility is on")) }
            else {
                HStack(spacing: 8) { StatusDot(color: Color(hex: 0xE0A100)); Text(L("Waiting… I'll notice when it's on.")).font(.pipText(13.5, .bold)).foregroundStyle(Color.pipSunText) }
            }
            Spacer()
            if model.accessibility { next { go(3) } }
            else {
                next(L("Open System Settings"), kind: .amber) { model.askAccessibility() }
                Button(L("Skip: I'll paste with ⌘V myself")) { go(3) }.buttonStyle(.plain).font(.pipText(13, .bold)).foregroundStyle(Color.pipInkMuted)
            }
        }
    }

    var voiceModel: some View {
        VStack(spacing: 16) {
            hero(ob.download == .done ? .happy : .thinking)
            if !model.hasWhisper {
                title(L("I need whisper.cpp"), L("It's the engine that turns your voice into text. Install it once with Homebrew, in Terminal:"))
                HStack {
                    Text("brew install whisper-cpp").font(.system(size: 13.5, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button(L("Copy")) { model.copyText("brew install whisper-cpp") }.buttonStyle(PipButtonStyle(kind: .secondary))
                }
                .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color.pipMist))
                Spacer()
                next(L("Check again")) { model.refreshPermissions() }
            } else {
                title(ob.download == .done ? L("Got my ears") : L("Getting my ears"), L("I download Whisper once (1.6 GB). After that I work offline, forever."))
                downloadStatus
                Spacer()
                switch ob.download {
                case .idle, .failed: next(ob.download == .idle ? L("Download (1.6 GB)") : L("Try again")) { ob.startDownload(app: model) }
                case .downloading: next("Cancel", kind: .secondary) { ob.cancelDownload() }
                case .verifying: next("Checking…", kind: .secondary, enabled: false) {}
                case .done: next { go(4) }
                }
            }
        }
    }

    @ViewBuilder var downloadStatus: some View {
        switch ob.download {
        case .idle: Text(L("Checked with SHA-256 before I use it.")).font(.pipText(13)).foregroundStyle(Color.pipInkMuted)
        case .downloading(let p, let w, let t):
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(hex: 0xECE8F3))
                        Capsule().fill(Color.pipCoral).frame(width: max(10, g.size.width * p))
                    }
                }
                .frame(height: 10)
                HStack {
                    Text(L("%@ of %@", ByteCountFormatter.string(fromByteCount: w, countStyle: .file), ByteCountFormatter.string(fromByteCount: t, countStyle: .file)))
                    Spacer(); Text("\(Int(p * 100)) %")
                }
                .font(.pipText(13, .bold)).foregroundStyle(Color.pipInkSoft)
                Text(L("Checked with SHA-256 before I use it.")).font(.pipText(12.5)).foregroundStyle(Color.pipInkMuted)
            }
        case .verifying: HStack(spacing: 8) { ThinkingDots().colorMultiply(.pipInk); Text(L("Checking the file…")).font(.pipText(13.5, .bold)) }
        case .done: Check(text: L("Downloaded and verified"))
        case .failed(let m): Text(m).font(.pipText(13.5, .bold)).foregroundStyle(Color.pipSunText).multilineTextAlignment(.center)
        }
    }

    var tryIt: some View {
        VStack(spacing: 14) {
            hero(.happy)
            title(L("Your turn"), L("Hold ⌃⌥, say “Hello Pip, this is my first dictation.”, then let go."))
            VStack(alignment: .leading, spacing: 6) {
                Text(ob.practiced ? L("Here's what I heard") : L("Practice box")).font(.pipText(12.5, .heavy)).foregroundStyle(Color.pipInkMuted)
                TextEditor(text: $ob.practice)
                    .focused($practiceFocused)
                    .onAppear { practiceFocused = true }
                    .font(.pipText(15, .semibold)).scrollContentBackground(.hidden)
                    .snapshotStandIn(ob.practice, .editor)
                    .padding(8).frame(height: 70)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.white))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ob.practiced ? Color.pipMint : Color.pipLine, lineWidth: 2))
            }
            if ob.practiced { Check(text: L("It works. You're all set.")) }
            else { Text(L("Your words will appear in the box.")).font(.pipText(13)).foregroundStyle(Color.pipInkMuted) }
            Spacer()
            next(ob.practiced ? L("Done") : L("Skip for now"), kind: ob.practiced ? .primary : .secondary) {
                UserDefaults.standard.set(true, forKey: "onboardingDone")
                ob.finish(); close()
            }
        }
    }
}

final class OnboardingWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var ob: OnboardingModel?

    func show(model: Model) {
        if window == nil {
            let o = OnboardingModel()
            ob = o
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
            w.title = L("Welcome to Pip Dictée")
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: OnboardingView(model: model, ob: o, close: { [weak self] in self?.window?.close() }))
            w.center()
            window = w
            o.enter(0, app: model)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ n: Notification) { ob?.finish(); window = nil; ob = nil }
}
