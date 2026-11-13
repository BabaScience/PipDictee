// The panel that opens from the menu-bar icon (design/ui/Menu.dc.html).
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: Model
    @AppStorage("lang") var lang = "auto"
    @AppStorage("autoPaste") var autoPaste = true
    @AppStorage("removeFillers") var removeFillers = true
    @AppStorage("trigger") var trigger = Trigger.ctrlOption.rawValue
    @State private var copied: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let need = model.need { needCard(need) }
            shortcutCard
            recent
            Divider().overlay(Color.pipLine)
            VStack(spacing: 4) {
                HStack {
                    Text(L("Dictation language")).font(.pipText(13.5, .bold))
                    Spacer()
                    Picker(L("Dictation language"), selection: $lang) {
                        ForEach(languages, id: \.code) { Text($0.code == "auto" ? L("Automatic") : $0.name).tag($0.code) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    .snapshotStandIn(lang == "auto" ? L("Automatic") : (languages.first { $0.code == lang }?.name ?? lang))
                }
                .padding(.vertical, 4)
                Toggle(isOn: $autoPaste) { Text(L("Paste automatically")).font(.pipText(13.5, .bold)) }.toggleStyle(PipToggleStyle()).padding(.vertical, 5)
                Toggle(isOn: $removeFillers) { Text(L("Remove filler words")).font(.pipText(13.5, .bold)) }.toggleStyle(PipToggleStyle()).padding(.vertical, 5)
            }
            Divider().overlay(Color.pipLine)
            HStack(spacing: 8) {
                Button(L("Dictionary…")) { model.openSettings(.dictionary) }.buttonStyle(PipButtonStyle(kind: .secondary, fill: true))
                Button(L("Settings…")) { model.openSettings(.general) }.buttonStyle(PipButtonStyle(kind: .secondary, fill: true))
            }
        }
        .padding(16)
        .frame(width: 340)
        .foregroundStyle(Color.pipInk)
        .background(Color.pipMist.opacity(0.55))
    }

    var shortcutKeys: [String] {
        switch Trigger(rawValue: trigger) ?? .ctrlOption {
        case .ctrlOption: return ["⌃", "⌥"]
        case .fn: return ["fn"]
        case .rightOption: return [L("right ⌥")]
        case .rightCommand: return [L("right ⌘")]
        }
    }

    var header: some View {
        HStack(spacing: 12) {
            PipView(mood: model.mode == .idle ? (model.need == nil ? .ready : .needsYou) : (model.mode == .working ? .thinking : .listening))
                .frame(width: 44, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pip Dictée").font(.pipTitle(18))
                HStack(spacing: 6) {
                    StatusDot(color: model.whisperReady ? Color(hex: 0x2FBF8C) : (model.need == nil ? .pipSun : Color(hex: 0xE0A100)))
                    Text(status).font(.pipText(12.5, .bold)).foregroundStyle(Color.pipInkSoft)
                }
            }
            Spacer(minLength: 8)
            Button { model.quit() } label: {
                Image(systemName: "power").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.pipInkSoft)
                    .frame(width: 30, height: 30).background(Circle().fill(.white.opacity(0.8)))
            }
            .buttonStyle(.plain).keyboardShortcut("q")
            .help(L("Quit Pip Dictée")).accessibilityLabel(Text(L("Quit Pip Dictée")))
        }
    }

    var status: String {
        if !model.hasWhisper { return L("whisper.cpp isn't installed") }
        if !model.hasModel { return L("The voice model is missing") }
        switch model.mode {
        case .holding, .handsFree: return L("Listening…")
        case .working: return L("Writing it down…")
        case .idle: return model.whisperReady ? L("Ready · Whisper runs on this Mac") : L("Whisper is loading…")
        }
    }

    func needCard(_ need: Need) -> some View {
        HStack(spacing: 10) {
            Text(need.message).font(.pipText(13.5, .bold)).foregroundStyle(Color.pipSunText)
            Spacer()
            Button(need == .accessibility ? L("Allow…") : L("Set up…")) {
                if need == .accessibility { model.askAccessibility() } else { model.openOnboarding() }
            }
            .buttonStyle(PipButtonStyle(kind: .amber))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: 0xFFF8E1)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.pipSun.opacity(0.6)))
    }

    var shortcutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(L("Hold")).font(.pipText(14, .bold))
                ForEach(shortcutKeys, id: \.self) { Keycap(label: $0) }
                Text(L("and talk")).font(.pipText(14, .bold))
            }
            Text(L("Add Space for hands-free · Esc cancels · ⌃⌘V types the last one again"))
                .font(.pipText(12.5)).foregroundStyle(Color.pipInkSoft).fixedSize(horizontal: false, vertical: true)
            Button(model.mode == .idle ? L("Start hands-free") : (model.mode == .working ? L("Writing it down…") : L("Finish dictation"))) { model.toggleDictation() }
                .buttonStyle(PipButtonStyle(kind: .primary, fill: true))
                .disabled(model.mode == .working)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.85)))
    }

    var recent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("RECENT")).font(.pipText(12, .heavy)).foregroundStyle(Color.pipInkSoft).tracking(0.4)
                Spacer()
                Button(L("All history")) { model.openSettings(.history) }.buttonStyle(.plain).font(.pipText(12.5, .bold)).foregroundStyle(Color.pipCoralText)
            }
            if model.history.isEmpty {
                Text(L("Your dictations will show up here.")).font(.pipText(13)).foregroundStyle(Color.pipInkMuted).padding(.vertical, 8)
            }
            ForEach(Array(model.history.prefix(3).enumerated()), id: \.offset) { i, e in
                Button { model.copyText(e.text); copied = e.at } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.text.replacingOccurrences(of: "\n", with: " ")).font(.pipText(13.5, .bold)).lineLimit(1)
                            Text([e.app, e.at.ago].compactMap { $0 }.joined(separator: " · ")).font(.pipText(12)).foregroundStyle(Color.pipInkMuted)
                        }
                        Spacer(minLength: 4)
                        if copied == e.at { Check(text: L("Copied")) }
                        else { Image(systemName: "doc.on.doc").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.pipInkSoft) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(i == 0 ? Color.white.opacity(0.75) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(e.text)
                .accessibilityLabel(Text(L("Copy: %@", e.text)))
            }
        }
    }
}
