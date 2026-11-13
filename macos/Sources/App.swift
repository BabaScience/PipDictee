// The app: shortcut, recording, transcription, typing the text, menu-bar item and windows.
import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

final class App: NSObject, NSApplicationDelegate {
    let model = Model.shared
    var item: NSStatusItem!
    let popover = NSPopover()
    let whisper = Whisper()
    let pill = Pill()
    let settings = SettingsWindow()
    let onboarding = OnboardingWindow()
    var recorder: AVAudioRecorder?
    var wavURL = URL(fileURLWithPath: NSTemporaryDirectory() + "pip-dictee.wav")
    var mode: DictationMode = .idle { didSet { model.mode = mode; updateIcon() } }
    var startedAt = Date()
    var peak: Float = -160
    var history: [Entry] { get { model.history } set { model.history = newValue } }
    var tap: CFMachPort?
    var comboDown = false
    var carbonHotKey: EventHotKeyRef?
    var axTimer: Timer?
    var targetApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ n: Notification) {
        // One copy only. A second one (an old build opened from a project folder, a double-click…) would add a second
        // menu-bar icon and a second shortcut listener, type every dictation twice, and fight over the Whisper server.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "fr.pip.dictee")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let running = others.first {
            log("already running (pid \(running.processIdentifier)): this copy quits and shows the running one's panel")
            DistributedNotificationCenter.default().postNotificationName(.init("fr.pip.dictee.showPanel"), object: nil, userInfo: nil, deliverImmediately: true)
            exit(0)
        }
        NSApp.setActivationPolicy(.accessory)
        applyUILanguage(model.uiLanguage)
        try? fm.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        migrateLegacyFiles()
        ensurePrivateSupportDir()
        removeLeftoverRecordings()
        if !fm.fileExists(atPath: dictionaryPath) {
            let n = importFromWispr() ?? 0
            if n == 0 { saveDictionary(Dictionary(words: ["Pip", "Claude", "TypeScript", "JavaScript", "Node.js", "YouTube"])) }
            log("dictionary created (\(n) imported from Wispr Flow)")
        }
        history = loadHistory()
        wireModel()

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PanelView(model: model))
        updateIcon()

        pill.level = { [weak self] in self?.currentLevel() ?? 0 }
        pill.model.action = { [weak self] need in self?.resolve(need) }
        stopOnSignal()
        whisper.onReady = { [weak self] ready in self?.model.whisperReady = ready; self?.updateIcon() }
        whisper.start()
        installHotKeys()
        // For Pip and for tests: other programs can start, stop or feed a file — only if the user turned it on.
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("fr.pip.dictee.toggle"), object: nil, queue: .main) { [weak self] _ in
            guard Settings.externalControl else { log("external toggle ignored (off in settings)"); return }
            self?.toggleHandsFree()
        }
        dnc.addObserver(forName: .init("fr.pip.dictee.file"), object: nil, queue: .main) { [weak self] n in
            guard Settings.externalControl else { log("external file ignored (off in settings)"); return }
            guard let p = n.object as? String, p.lowercased().hasSuffix(".wav") else { return }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue else { return }
            self?.transcribeFile(URL(fileURLWithPath: p))
        }
        // A second copy that was just opened asks this one to show itself (harmless: it only opens the panel).
        dnc.addObserver(forName: .init("fr.pip.dictee.showPanel"), object: nil, queue: .main) { [weak self] _ in
            guard let s = self, !s.popover.isShown else { return }
            s.togglePanel()
        }
        // Permissions can change in System Settings at any time: keep the panel and icon honest.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.model.refreshPermissions(); self?.updateIcon()
        }
        log("started; accessibility=\(AXIsProcessTrusted())")

        if !defaults.bool(forKey: "onboardingDone") || model.need == .whisper || model.need == .model {
            onboarding.show(model: model)
        }
    }

    func wireModel() {
        model.toggleDictation = { [weak self] in self?.popover.performClose(nil); self?.toggleHandsFree() }
        model.copyText = { [weak self] t in self?.setPrivateClipboard(t) }
        model.openSettings = { [weak self] tab in guard let s = self else { return }; s.popover.performClose(nil); s.settings.show(tab, model: s.model) }
        model.openOnboarding = { [weak self] in guard let s = self else { return }; s.popover.performClose(nil); s.onboarding.show(model: s.model) }
        model.askAccessibility = { [weak self] in self?.askAccessibility() }
        model.clearHistory = { [weak self] in self?.clearHistory() }
        model.startWhisper = { [weak self] in self?.whisper.start() }
        model.quit = { NSApp.terminate(nil) }
    }

    /// Recordings left in the temporary folder by a crash.
    func removeLeftoverRecordings() {
        let tmp = NSTemporaryDirectory()
        for f in (try? fm.contentsOfDirectory(atPath: tmp)) ?? [] where f.hasPrefix("pip-dictee") && f.hasSuffix(".wav") {
            try? fm.removeItem(atPath: tmp + f)
        }
    }
    func applicationWillTerminate(_ n: Notification) { whisper.stop() }
    var sigterm: DispatchSourceSignal?
    func stopOnSignal() {
        signal(SIGTERM, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        s.setEventHandler { [weak self] in self?.whisper.stop(); exit(0) }
        s.resume(); sigterm = s
    }

    // MARK: shortcuts

    func installHotKeys() {
        if AXIsProcessTrusted() { installTap(); return }
        // Without Accessibility: Ctrl+Option+Space still works (hands-free), through Carbon, until it's granted.
        installCarbonFallback()
        axTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard AXIsProcessTrusted(), let s = self else { return }
            t.invalidate(); s.axTimer = nil
            if let h = s.carbonHotKey { UnregisterEventHotKey(h); s.carbonHotKey = nil }
            s.installTap()
            s.model.refreshPermissions(); s.updateIcon()
            s.pill.show(.info(L("Ready: hold %@ and talk", Settings.trigger.short)), hideAfter: 2.5)
        }
    }

    func installCarbonFallback() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ud in
            let me = Unmanaged<App>.fromOpaque(ud!).takeUnretainedValue()
            DispatchQueue.main.async { me.toggleHandsFree() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x50495044), id: 1)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &carbonHotKey)
    }

    func installTap() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let cb: CGEventTapCallBack = { _, type, event, ud in
            let me = Unmanaged<App>.fromOpaque(ud!).takeUnretainedValue()
            return me.handle(type, event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: cb, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log("event tap refused"); installCarbonFallback(); return
        }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        log("event tap installed")
    }

    func isCombo(_ e: CGEvent) -> Bool {
        let f = e.flags
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        switch Settings.trigger {
        case .ctrlOption:
            return f.contains(.maskControl) && f.contains(.maskAlternate) && !f.contains(.maskCommand) && !f.contains(.maskShift)
        case .fn:
            return f.contains(.maskSecondaryFn) && !f.contains(.maskCommand) && !f.contains(.maskControl) && !f.contains(.maskAlternate) && (code == 63 || code == 179 || comboDown)
        case .rightOption:
            return f.contains(.maskAlternate) && (code == 61 || comboDown) && f.rawValue & 0x40 != 0 // NX_DEVICERALTKEYMASK
        case .rightCommand:
            return f.contains(.maskCommand) && (code == 54 || comboDown) && f.rawValue & 0x10 != 0 // NX_DEVICERCMDKEYMASK
        }
    }

    func handle(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(e)
        }
        if type == .flagsChanged {
            let now = isCombo(e)
            if now && !comboDown { comboDown = true; comboPressed() }
            else if !now && comboDown { comboDown = false; comboReleased() }
            return Unmanaged.passUnretained(e)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(e) }
        let code = Int(e.getIntegerValueField(.keyboardEventKeycode))
        let f = e.flags
        // Esc cancels a dictation in progress.
        if code == kVK_Escape, mode == .holding || mode == .handsFree { DispatchQueue.main.async { self.cancel(showing: true) }; return nil }
        // Shortcut + Space: hands-free.
        if code == kVK_Space, comboDown {
            DispatchQueue.main.async {
                if self.mode == .holding { self.mode = .handsFree; self.pill.show(.handsFree) }
                else if self.mode == .idle { self.start(handsFree: true) }
            }
            return nil
        }
        // Cmd+Ctrl+V / Cmd+Ctrl+C: the last dictation, pasted again or copied.
        if f.contains(.maskCommand), f.contains(.maskControl), !f.contains(.maskAlternate) {
            if code == kVK_ANSI_V { DispatchQueue.main.async { self.pasteLast() }; return nil }
            if code == kVK_ANSI_C { DispatchQueue.main.async { self.copyLast() }; return nil }
        }
        // Any other key while the shortcut is held: it was another shortcut (Rectangle…), not a dictation.
        if comboDown, mode == .holding { DispatchQueue.main.async { self.cancel(showing: false) } }
        return Unmanaged.passUnretained(e)
    }

    func comboPressed() {
        DispatchQueue.main.async {
            switch self.mode {
            case .idle: self.start(handsFree: false)
            case .handsFree: self.finish()
            default: break
            }
        }
    }
    func comboReleased() {
        DispatchQueue.main.async {
            guard self.mode == .holding else { return }
            if Date().timeIntervalSince(self.startedAt) < 0.35 { self.cancel(showing: false) } else { self.finish() }
        }
    }

    // MARK: recording

    func start(handsFree: Bool) {
        guard mode == .idle else { return }
        model.refreshPermissions()
        if !model.hasWhisper || !model.hasModel { pill.show(.needsYou(model.hasWhisper ? .model : .whisper), hideAfter: 5); return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.model.refreshPermissions() } }
            }
            pill.show(.needsYou(.microphone), hideAfter: 5); return
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        wavURL = URL(fileURLWithPath: NSTemporaryDirectory() + "pip-dictee-\(Int(Date().timeIntervalSince1970 * 1000)).wav")
        guard let r = try? AVAudioRecorder(url: wavURL, settings: settings) else { pill.show(.oops(L("The microphone isn't available")), hideAfter: 2); return }
        r.isMeteringEnabled = true
        guard r.record() else { pill.show(.oops(L("The microphone isn't available")), hideAfter: 2); return }
        recorder = r
        peak = -160
        startedAt = Date()
        targetApp = NSWorkspace.shared.frontmostApplication
        mode = handsFree ? .handsFree : .holding
        if Settings.sounds { NSSound(named: "Tink")?.play() }
        pill.show(handsFree ? .handsFree : .listening)
    }

    func currentLevel() -> CGFloat {
        guard let r = recorder, r.isRecording else { return 0 }
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)
        peak = max(peak, r.peakPower(forChannel: 0))
        return CGFloat(max(0, min(1, (db + 50) / 45)))
    }

    func cancel(showing: Bool) {
        guard mode == .holding || mode == .handsFree else { return }
        recorder?.stop(); recorder = nil
        try? fm.removeItem(at: wavURL)
        mode = .idle
        if showing { pill.show(.cancelled, hideAfter: 1) } else { pill.hide() }
    }

    func finish() {
        guard mode == .holding || mode == .handsFree, let r = recorder else { return }
        _ = currentLevel()
        let duration = r.currentTime
        r.stop(); recorder = nil
        if Settings.sounds { NSSound(named: "Pop")?.play() }
        if peak < -42 || duration < 0.3 {
            mode = .idle; try? fm.removeItem(at: wavURL)
            pill.show(.oops(L("I didn't hear anything")), hideAfter: 1.6); return
        }
        process(wavURL, remove: true)
    }

    func transcribeFile(_ url: URL) {
        guard mode == .idle else { return }
        targetApp = NSWorkspace.shared.frontmostApplication
        process(url, remove: false)
    }

    func process(_ url: URL, remove: Bool) {
        mode = .working
        pill.show(.thinking)
        let lang = Settings.lang
        let dict = loadDictionary()
        let prompt = dict.words.prefix(60).joined(separator: ", ")
        let t0 = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let raw = self.whisper.transcribe(url, lang: lang, prompt: prompt) ?? ""
            var text = clean(raw, dict: dict)
            if Settings.aiPolish, !text.isEmpty { text = polish(text) }
            if remove { try? fm.removeItem(at: url) }
            log("transcribed in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s: \(text.count) chars")
            DispatchQueue.main.async { self.deliver(text) }
        }
    }

    func deliver(_ text: String) {
        mode = .idle
        guard !text.isEmpty else { pill.show(.oops(L("I didn't catch that")), hideAfter: 1.6); return }
        history.insert(Entry(text: text, at: Date(), app: targetApp?.localizedName), at: 0)
        saveHistory(history)
        insert(text)
    }

    // MARK: inserting the text

    func insert(_ text: String) {
        let pb = NSPasteboard.general
        let saved = Settings.restoreClipboard ? pb.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        } : nil
        setPrivateClipboard(text)
        guard Settings.autoPaste, AXIsProcessTrusted() else { pill.show(.copied, hideAfter: 1.8); return }
        // Back to the app that was in front when the dictation started, then ⌘V.
        if let a = targetApp, a != NSWorkspace.shared.frontmostApplication { a.activate() }
        let appName = targetApp?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : targetApp?.localizedName
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.sendCommandV()
            self.pill.show(.typed(app: appName, words: wordCount(text)), hideAfter: 1.1)
            if let s = saved, !s.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { pb.clearContents(); pb.writeObjects(s) }
            }
        }
    }

    func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        // So that keys still held (Ctrl, Option) don't turn ⌘V into another shortcut.
        src?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap); up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Puts the text on the clipboard, marked so that clipboard managers don't keep it (nspasteboard.org convention).
    func setPrivateClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        pb.writeObjects([item])
    }

    func pasteLast() {
        guard let t = history.first?.text else { return }
        targetApp = NSWorkspace.shared.frontmostApplication
        insert(t)
    }
    func copyLast() {
        guard let t = history.first?.text else { return }
        setPrivateClipboard(t)
        pill.show(.copied, hideAfter: 1)
    }

    func toggleHandsFree() {
        switch mode {
        case .idle: start(handsFree: true)
        case .holding, .handsFree: finish()
        case .working: break
        }
    }

    func clearHistory() {
        history.removeAll()
        try? fm.removeItem(atPath: historyPath)
        log("history cleared")
    }

    func askAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    /// What the amber "needs you" button does.
    func resolve(_ need: Need) {
        pill.hide()
        switch need {
        case .microphone: NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        case .accessibility: askAccessibility()
        case .whisper, .model: onboarding.show(model: model)
        }
    }

    // MARK: menu bar

    func updateIcon() {
        guard let b = item?.button else { return }
        let state: GlyphState
        switch mode {
        case .holding, .handsFree: state = .listening
        case .working: state = .thinking
        case .idle: state = model.need == nil ? .ready : .needsYou
        }
        b.image = menuBarGlyph(state)
        b.toolTip = model.need?.message ?? L("Pip Dictée — hold %@ and talk", Settings.trigger.short)
    }

    @objc func togglePanel() {
        guard let b = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        model.refreshPermissions()
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
