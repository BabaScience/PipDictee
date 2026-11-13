// The settings window (design/ui/Settings.dc.html and Privacy.dc.html).
import AppKit
import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General", dictionary = "Dictionary", history = "History", privacy = "Privacy", about = "About"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return L("General")
        case .dictionary: return L("Dictionary")
        case .history: return L("History")
        case .privacy: return L("Privacy")
        case .about: return L("About")
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .dictionary: return "character.book.closed"
        case .history: return "clock"
        case .privacy: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}

final class SettingsRouter: ObservableObject { @Published var tab = SettingsTab.general }

struct SettingsView: View {
    @ObservedObject var model: Model
    @ObservedObject var router: SettingsRouter
    @ObservedObject var store: DictionaryStore

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SettingsTab.allCases) { t in
                    Button { router.tab = t } label: {
                        HStack(spacing: 10) {
                            Image(systemName: t.icon).font(.system(size: 14, weight: .semibold)).frame(width: 18)
                                .foregroundStyle(router.tab == t ? Color.pipCoralText : Color.pipInkSoft)
                            Text(t.title).font(.pipText(14, router.tab == t ? .heavy : .bold))
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(router.tab == t ? Color.white : .clear)
                            .shadow(color: Color.pipInk.opacity(router.tab == t ? 0.08 : 0), radius: 2, y: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 40).padding(.bottom, 12)
            .frame(width: 200)
            .background(Color.pipMist)

            Rectangle().fill(Color.pipLine).frame(width: 1)

            MaybeScroll {
                Group {
                    switch router.tab {
                    case .general: GeneralTab(model: model)
                    case .dictionary: DictionaryTab(store: store)
                    case .history: HistoryTab(model: model)
                    case .privacy: PrivacyTab(model: model)
                    case .about: AboutTab(model: model)
                    }
                }
                .padding(.horizontal, 32).padding(.top, 36).padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.white)
        }
        .foregroundStyle(Color.pipInk)
        .frame(width: 820, height: 580)
    }
}

struct TabHeader: View {
    var title: String
    var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.pipTitle(28))
            Text(subtitle).font(.pipText(14.5)).foregroundStyle(Color.pipInkSoft)
        }
    }
}

struct SectionLabel: View {
    var text: String
    var detail: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            Text(text.uppercased()).font(.pipText(12.5, .heavy)).foregroundStyle(Color.pipInkSoft).tracking(0.4)
            if let d = detail { Text("· \(d)").font(.pipText(12.5, .bold)).foregroundStyle(Color.pipInkMuted) }
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.pipLine))
    }
}

struct SettingRow<Trailing: View>: View {
    var title: String
    var detail: String? = nil
    var first = false
    @ViewBuilder var trailing: Trailing
    var body: some View {
        VStack(spacing: 0) {
            if !first { Rectangle().fill(Color.pipLine).frame(height: 1) }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.pipText(14.5, .heavy))
                    if let d = detail { Text(d).font(.pipText(13)).foregroundStyle(Color.pipInkMuted).fixedSize(horizontal: false, vertical: true) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
        }
    }
}

struct Switch: View {
    @Binding var on: Bool
    var label: String
    var body: some View { Toggle(isOn: $on) { EmptyView() }.toggleStyle(PipToggleStyle()).fixedSize().accessibilityLabel(Text(label)) }
}

// MARK: - General

struct GeneralTab: View {
    @ObservedObject var model: Model
    @AppStorage("trigger") var trigger = Trigger.ctrlOption.rawValue
    @AppStorage("lang") var lang = "auto"
    @AppStorage("autoPaste") var autoPaste = true
    @AppStorage("restoreClipboard") var restoreClipboard = false
    @AppStorage("removeFillers") var removeFillers = true
    @AppStorage("sounds") var sounds = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TabHeader(title: L("General"), subtitle: L("How you start a dictation, and what happens to the text."))
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: L("Shortcut"), detail: L("hold it to talk, add Space for hands-free"))
                HStack(spacing: 8) {
                    ForEach(Trigger.allCases, id: \.rawValue) { t in
                        Button { trigger = t.rawValue } label: {
                            Text(t.title).font(.pipText(13.5, .bold))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(trigger == t.rawValue ? Color.pipCoral : Color.pipMist))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(trigger == t.rawValue ? .isSelected : [])
                    }
                }
            }
            Card {
                SettingRow(title: L("App language"), detail: L("The language of Pip Dictée's menus and windows."), first: true) {
                    AppLanguagePicker(model: model, compact: true)
                }
                SettingRow(title: L("Dictation language"), detail: L("Automatic recognises English, French, German, Italian, Spanish, Portuguese and many more.")) {
                    Picker(L("Dictation language"), selection: $lang) { ForEach(languages, id: \.code) { Text($0.name).tag($0.code) } }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                        .snapshotStandIn(languages.first { $0.code == lang }?.name ?? lang)
                }
                SettingRow(title: L("Paste automatically"), detail: L("Types the text where your cursor is. Off: it's only copied.")) { Switch(on: $autoPaste, label: L("Paste automatically")) }
                SettingRow(title: L("Restore the clipboard after pasting"), detail: L("Puts back what you had copied before the dictation.")) { Switch(on: $restoreClipboard, label: L("Restore the clipboard")) }
                SettingRow(title: L("Remove filler words"), detail: L("um, uh, euh, äh")) { Switch(on: $removeFillers, label: L("Remove filler words")) }
                SettingRow(title: L("Sounds"), detail: L("A soft tick when Pip starts and stops listening.")) { Switch(on: $sounds, label: L("Sounds")) }
                SettingRow(title: L("Open at login"), detail: loginError) {
                    Switch(on: Binding(get: { openAtLogin }, set: { v in
                        do { if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; openAtLogin = v; loginError = nil }
                        catch { loginError = L("Couldn't change it: %@", error.localizedDescription) }
                    }), label: L("Open at login"))
                }
            }
            PermissionsCard(model: model)
        }
    }
}

struct PermissionsCard: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: L("Permissions"))
            Card {
                SettingRow(title: L("Microphone"), detail: L("Only while you hold the shortcut."), first: true) {
                    if model.microphone == .authorized { Check(text: L("Allowed")) }
                    else { Button(L("Allow…")) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }.buttonStyle(PipButtonStyle(kind: .amber)) }
                }
                SettingRow(title: L("Accessibility"), detail: L("To notice the shortcut and type for you. Keys are never recorded.")) {
                    if model.accessibility { Check(text: L("Allowed")) }
                    else { Button(L("Allow…")) { model.askAccessibility() }.buttonStyle(PipButtonStyle(kind: .amber)) }
                }
            }
        }
    }
}

// MARK: - Dictionary

struct DictionaryTab: View {
    @ObservedObject var store: DictionaryStore
    @State private var newWord = ""
    @State private var newFrom = ""
    @State private var newTo = ""
    @State private var newSnippet = ""
    @State private var newSnippetText = ""
    @State private var importMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                TabHeader(title: L("Dictionary"), subtitle: L("Pip spells these your way. Words are also hints for Whisper."))
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Button(L("Import from Wispr Flow")) {
                        let n = importFromWispr()
                        store.reload()
                        importMessage = n == nil ? L("Wispr Flow wasn't found on this Mac.") : L("%@ new entries imported.", String(n!))
                    }
                    .buttonStyle(PipButtonStyle(kind: .secondary))
                    if let m = importMessage { Text(m).font(.pipText(12)).foregroundStyle(Color.pipInkMuted) }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: L("Words"), detail: "\(store.dict.words.count)")
                FlowLayout(spacing: 8) {
                    ForEach(store.dict.words, id: \.self) { w in
                        HStack(spacing: 6) {
                            Text(w).font(.pipText(13.5, .bold))
                            Button { store.dict.words.removeAll { $0 == w } } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .heavy)) }
                                .buttonStyle(.plain).foregroundStyle(Color.pipInkMuted).accessibilityLabel(Text(L("Remove %@", w)))
                        }
                        .padding(.leading, 12).padding(.trailing, 9).padding(.vertical, 6)
                        .background(Capsule().fill(Color.pipMist))
                    }
                    TextField(L("Add a word"), text: $newWord)
                        .snapshotStandIn(L("Add a word"), .field)
                        .textFieldStyle(.plain).font(.pipText(13.5, .bold)).frame(width: 120)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .overlay(Capsule().strokeBorder(Color.pipInk.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                        .onSubmit {
                            let w = newWord.trimmingCharacters(in: .whitespaces)
                            if !w.isEmpty, !store.dict.words.contains(w) { store.dict.words.append(w) }
                            newWord = ""
                        }
                }
            }

            pairs(title: L("Replacements"), detail: nil, left: L("When I say"), right: L("Pip writes"), items: store.dict.replacements,
                  from: $newFrom, to: $newTo, addLabel: L("Add a replacement"),
                  remove: { store.dict.replacements[$0] = nil }, add: { store.dict.replacements[$0] = $1 })
            pairs(title: L("Snippets"), detail: L("say a phrase, get a block of text"), left: L("When I say"), right: L("Pip types"), items: store.dict.snippets,
                  from: $newSnippet, to: $newSnippetText, addLabel: L("Add a snippet"),
                  remove: { store.dict.snippets[$0] = nil }, add: { store.dict.snippets[$0] = $1 })
        }
    }

    func pairs(title: String, detail: String?, left: String, right: String, items: [String: String],
               from: Binding<String>, to: Binding<String>, addLabel: String,
               remove: @escaping (String) -> Void, add: @escaping (String, String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: title, detail: detail)
            Card {
                HStack { Text(left).frame(maxWidth: .infinity, alignment: .leading); Text(right).frame(maxWidth: .infinity, alignment: .leading); Color.clear.frame(width: 20) }
                    .font(.pipText(12.5, .heavy)).foregroundStyle(Color.pipInkMuted)
                    .padding(.horizontal, 14).padding(.vertical, 9).background(Color(hex: 0xFAF8FD))
                ForEach(items.keys.sorted(), id: \.self) { k in
                    Rectangle().fill(Color.pipLine).frame(height: 1)
                    HStack {
                        Text(k).font(.pipText(14)).frame(maxWidth: .infinity, alignment: .leading)
                        Text(items[k] ?? "").font(.pipText(14, .heavy)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        Button { remove(k) } label: { Image(systemName: "minus.circle").font(.system(size: 14, weight: .semibold)) }
                            .buttonStyle(.plain).foregroundStyle(Color.pipInkMuted).frame(width: 20).accessibilityLabel(Text(L("Remove %@", k)))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                }
                Rectangle().fill(Color.pipLine).frame(height: 1)
                HStack {
                    TextField(left, text: from).textFieldStyle(.plain).font(.pipText(14)).frame(maxWidth: .infinity)
                        .snapshotStandIn(left, .field)
                    TextField(right, text: to).textFieldStyle(.plain).font(.pipText(14, .heavy)).frame(maxWidth: .infinity)
                        .snapshotStandIn(right, .field)
                        .onSubmit { commit(from, to, add) }
                    Button { commit(from, to, add) } label: { Image(systemName: "plus.circle.fill").font(.system(size: 15)) }
                        .buttonStyle(.plain).foregroundStyle(Color.pipCoralText).frame(width: 20).accessibilityLabel(Text(addLabel))
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }

    func commit(_ from: Binding<String>, _ to: Binding<String>, _ add: (String, String) -> Void) {
        let f = from.wrappedValue.trimmingCharacters(in: .whitespaces), t = to.wrappedValue.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty, !t.isEmpty else { return }
        add(f, t); from.wrappedValue = ""; to.wrappedValue = ""
    }
}

// MARK: - History

struct HistoryTab: View {
    @ObservedObject var model: Model
    @AppStorage("keepHistory") var keepHistory = true
    @State private var copied: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                TabHeader(title: L("History"), subtitle: L("Your last 200 dictations. Click one to copy it."))
                Spacer()
                Button(L("Clear history")) { model.clearHistory() }.buttonStyle(PipButtonStyle(kind: .secondary)).disabled(model.history.isEmpty)
            }
            Card {
                SettingRow(title: L("Keep history"), detail: L("Stored only on this Mac, in a folder only you can read."), first: true) {
                    Switch(on: Binding(get: { keepHistory }, set: { keepHistory = $0; if !$0 { model.clearHistory() } }), label: L("Keep history"))
                }
            }
            if model.history.isEmpty {
                VStack(spacing: 10) {
                    PipView(mood: .resting).frame(width: 70, height: 64)
                    Text(keepHistory ? L("No dictations yet.") : L("History is off.")).font(.pipText(14, .bold)).foregroundStyle(Color.pipInkMuted)
                }
                .frame(maxWidth: .infinity).padding(.top, 20)
            } else {
                Card {
                    ForEach(Array(model.history.prefix(200).enumerated()), id: \.offset) { i, e in
                        if i > 0 { Rectangle().fill(Color.pipLine).frame(height: 1) }
                        Button { model.copyText(e.text); copied = e.at } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(e.text).font(.pipText(14)).lineLimit(3).multilineTextAlignment(.leading)
                                    Text([e.app, e.at.ago, Lwords(wordCount(e.text))].compactMap { $0 }.joined(separator: " · "))
                                        .font(.pipText(12)).foregroundStyle(Color.pipInkMuted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if copied == e.at { Check(text: L("Copied")) }
                                else { Image(systemName: "doc.on.doc").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.pipInkSoft) }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Privacy

struct PrivacyTab: View {
    @ObservedObject var model: Model
    @AppStorage("keepHistory") var keepHistory = true
    @AppStorage("externalControl") var externalControl = false
    @AppStorage("aiPolish") var aiPolish = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 18) {
                PipView(mood: .ready).frame(width: 76, height: 69)
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("Everything stays on this Mac")).font(.pipTitle(22))
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 6) {
                        ForEach([L("Audio is deleted right after"), L("Whisper works offline"), L("The log never has your words"), L("Clipboard managers skip dictations")], id: \.self) { t in
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(Color.pipMint)
                                Text(t).font(.pipText(13.5, .semibold)).foregroundStyle(.white.opacity(0.9))
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.pipInk))
            .foregroundStyle(.white)

            Card {
                SettingRow(title: L("Keep history"), detail: L("Your last 200 dictations, only in a private folder on this Mac."), first: true) {
                    Button(L("Clear history")) { model.clearHistory() }.buttonStyle(PipButtonStyle(kind: .secondary)).disabled(model.history.isEmpty)
                    Switch(on: Binding(get: { keepHistory }, set: { keepHistory = $0; if !$0 { model.clearHistory() } }), label: L("Keep history"))
                }
                SettingRow(title: L("Allow control by other apps"), detail: L("Lets apps like Pip start a dictation for you. While it's off, no other app can use your microphone through Pip Dictée.")) {
                    Switch(on: $externalControl, label: L("Allow control by other apps"))
                }
                SettingRow(title: L("Local AI clean-up"), detail: L("Tidies self-corrections with Ollama, also on this Mac. A little slower.")) {
                    Switch(on: $aiPolish, label: L("Local AI clean-up"))
                }
            }
            HStack {
                Spacer()
                Button(L("Open the data folder")) { NSWorkspace.shared.open(URL(fileURLWithPath: supportDir)) }
                    .buttonStyle(.plain).font(.pipText(13.5, .bold)).foregroundStyle(Color.pipCoralText)
            }
        }
    }
}

// MARK: - About

struct AboutTab: View {
    @ObservedObject var model: Model
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                PipView(mood: .happy).frame(width: 96, height: 87)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pip Dictée").font(.pipTitle(30))
                    Text(L("Version %@ · free and open source (MIT)", version)).font(.pipText(14)).foregroundStyle(Color.pipInkSoft)
                }
            }
            Text(L("Hold a key, talk, let go: Pip types what you said, in any app. Transcription runs on this Mac with whisper.cpp and OpenAI's Whisper model."))
                .font(.pipText(14.5)).foregroundStyle(Color.pipInkSoft).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(L("Source code")) { NSWorkspace.shared.open(URL(string: "https://github.com/BabaScience/PipDictee")!) }.buttonStyle(PipButtonStyle(kind: .secondary))
                Button(L("Report a problem")) { NSWorkspace.shared.open(URL(string: "https://github.com/BabaScience/PipDictee/issues")!) }.buttonStyle(PipButtonStyle(kind: .secondary))
                Button(L("Run setup again")) { model.openOnboarding() }.buttonStyle(PipButtonStyle(kind: .secondary))
            }
        }
    }
}

/// The settings window, created once and reused.
final class SettingsWindow {
    let router = SettingsRouter()
    let store = DictionaryStore()
    private var window: NSWindow?

    func show(_ tab: SettingsTab, model: Model) {
        router.tab = tab
        store.reload()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 580), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
            w.title = L("Pip Dictée Settings")
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: model, router: router, store: store))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Chooses the interface language. On the welcome card it sits at the top, so you can switch before reading anything.
struct AppLanguagePicker: View {
    @ObservedObject var model: Model
    var compact = false
    var body: some View {
        HStack(spacing: 8) {
            if !compact {
                Image(systemName: "globe").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.pipInkSoft)
                Text(L("App language")).font(.pipText(13, .bold)).foregroundStyle(Color.pipInkSoft)
                Spacer()
            }
            Picker(L("App language"), selection: $model.uiLanguage) {
                ForEach(uiLanguages, id: \.code) { Text($0.name).tag($0.code) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            .snapshotStandIn(uiLanguages.first { $0.code == model.uiLanguage }?.name ?? model.uiLanguage)
        }
    }
}
