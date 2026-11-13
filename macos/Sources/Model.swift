// What the windows show: one observable object, updated by App on the main thread.
import AppKit
import AVFoundation
import SwiftUI

enum DictationMode { case idle, holding, handsFree, working }

/// Something the user has to do before dictation fully works. The pill and the panel turn amber for it.
enum Need: Equatable { case microphone, accessibility, whisper, model
    var message: String {
        switch self {
        case .microphone: return L("Allow the microphone")
        case .accessibility: return L("Allow Accessibility to type for you")
        case .whisper: return L("Install whisper.cpp")
        case .model: return L("Download the voice model")
        }
    }
}

final class Model: ObservableObject {
    static let shared = Model()

    @Published var mode = DictationMode.idle
    /// The interface language ("system" or a code). Changing it re-renders every window right away.
    @Published var uiLanguage = UserDefaults.standard.string(forKey: "uiLanguage") ?? "system" {
        didSet { applyUILanguage(uiLanguage) }
    }
    @Published var history: [Entry] = []
    @Published var whisperReady = false
    @Published var accessibility = AXIsProcessTrusted()
    @Published var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var hasModel = fm.fileExists(atPath: modelPath)
    @Published var hasWhisper = findTool("whisper-server") != nil || findTool("whisper-cli") != nil

    /// The most urgent missing piece, if any.
    var need: Need? {
        if !hasWhisper { return .whisper }
        if !hasModel { return .model }
        if microphone == .denied || microphone == .restricted { return .microphone }
        if !accessibility { return .accessibility }
        return nil
    }

    func refreshPermissions() {
        accessibility = AXIsProcessTrusted()
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        hasModel = fm.fileExists(atPath: modelPath)
        hasWhisper = findTool("whisper-server") != nil || findTool("whisper-cli") != nil
    }

    /// Callbacks into App, so views never touch the recorder or the shortcut directly.
    var toggleDictation: () -> Void = {}
    var copyText: (String) -> Void = { _ in }
    var openSettings: (SettingsTab) -> Void = { _ in }
    var openOnboarding: () -> Void = {}
    var askAccessibility: () -> Void = {}
    var clearHistory: () -> Void = {}
    var startWhisper: () -> Void = {}
    var quit: () -> Void = {}
}

/// The dictionary as the settings window edits it; saved on every change. Snapshots use an in-memory copy.
final class DictionaryStore: ObservableObject {
    @Published var dict: Dictionary { didSet { if persist { saveDictionary(dict) } } }
    private let persist: Bool
    init(_ d: Dictionary? = nil) { persist = d == nil; dict = d ?? loadDictionary() }
    func reload() { if persist { dict = loadDictionary() } }
}

extension Date {
    var ago: String {
        let s = -timeIntervalSinceNow
        if s < 60 { return L("just now") }
        if s < 86400 * 7 {
            let f = RelativeDateTimeFormatter(); f.locale = uiLocale; f.unitsStyle = .short
            return f.localizedString(for: self, relativeTo: Date())
        }
        let f = DateFormatter(); f.locale = uiLocale; f.dateStyle = .medium; f.timeStyle = .none
        return f.string(from: self)
    }
}

func wordCount(_ s: String) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }
