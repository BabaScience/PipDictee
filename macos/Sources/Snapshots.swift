// `PipDictee --snapshot <folder>`: renders every screen to PNG with made-up sample data, for design reviews and
// pull requests. Touches no user file and starts nothing (no microphone, no shortcut, no server).
import AppKit
import SwiftUI

@MainActor
func renderSnapshots(to dir: String) {
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    func save<V: View>(_ name: String, _ view: V) {
        let r = ImageRenderer(content: view.environment(\.snapshot, true))
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("could not render \(name)"); return }
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        print("wrote \(name).png")
    }

    let now = Date()
    let sample: [Entry] = [
        Entry(text: "Thanks for the notes on the intro. I agree the first ten seconds drag, so I've cut the logo animation.", at: now.addingTimeInterval(-120), app: "Mail"),
        Entry(text: "Can we move the call to 4 pm? I'm stuck in a review.", at: now.addingTimeInterval(-1080), app: "Slack"),
        Entry(text: "Add a retry when the whisper server isn't ready yet.", at: now.addingTimeInterval(-3700), app: "Xcode"),
    ]
    func model(ready: Bool = true, ax: Bool = true, mic: Bool = true, hasModel: Bool = true) -> Model {
        let m = Model()
        m.history = sample; m.whisperReady = ready; m.accessibility = ax; m.hasModel = hasModel; m.hasWhisper = true
        m.microphone = mic ? .authorized : .notDetermined
        return m
    }
    let dict = Dictionary(words: ["Kubernetes", "TypeScript", "Node.js", "Claude", "Pip", "YouTube Shorts", "whisper.cpp"],
                          replacements: ["type script": "TypeScript", "java script": "JavaScript", "pip dictée": "Pip Dictée"],
                          snippets: ["my email": "[YOUR EMAIL]", "my calendar link": "[YOUR BOOKING LINK]"])

    // Pill states, on a light desktop-like background.
    let states: [(String, PillState)] = [
        ("listening", .listening), ("hands-free", .handsFree), ("thinking", .thinking), ("typed", .typed(app: "Mail", words: 21)),
        ("copied", .copied), ("oops", .oops("I didn't hear anything")), ("needs-you", .needsYou(.microphone)), ("cancelled", .cancelled),
    ]
    for (name, s) in states {
        let pm = PillModel(); pm.state = s; pm.levels = [0.2, 0.6, 0.4, 0.9, 0.5, 0.75, 0.3, 0.8, 0.45, 0.25, 0.6, 0.35]
        save("pill-\(name)", PillView(model: pm).frame(width: 460, height: 90).background(Color(hex: 0xEFEAF7)))
    }

    // Menu-bar glyphs, light and dark.
    let glyphs = HStack(spacing: 18) {
        ForEach([GlyphState.ready, .listening, .thinking, .needsYou], id: \.self) { g in
            Image(nsImage: menuBarGlyph(g)).renderingMode(g == .ready || g == .thinking ? .template : .original).foregroundStyle(Color.pipInk)
        }
    }.padding(16).background(Color(hex: 0xECE8F3))
    save("glyphs", glyphs)

    save("panel", PanelView(model: model()).background(Color.white))
    save("panel-needs-you", PanelView(model: model(ax: false)).background(Color.white))

    let router = SettingsRouter()
    for t in SettingsTab.allCases {
        router.tab = t
        save("settings-\(t.rawValue.lowercased())", SettingsView(model: model(), router: router, store: DictionaryStore(dict)))
    }

    let steps: [(String, Int, Model, (OnboardingModel) -> Void)] = [
        ("1-welcome", 0, model(), { _ in }),
        ("2-microphone", 1, model(), { $0.heard = true; $0.levels = [0.3, 0.7, 0.5, 0.9, 0.4, 0.6, 0.8, 0.5] }),
        ("2-microphone-quiet", 1, model(), { $0.quietForAWhile = true; $0.micName = "MacBook Pro Microphone" }),
        ("3-accessibility", 2, model(ax: false), { _ in }),
        ("4-model", 3, model(hasModel: false), { $0.download = .downloading(0.62, 1_007_000_000, 1_624_555_275) }),
        ("5-try-it", 4, model(), { $0.practice = "Hello Pip, this is my first dictation."; $0.practiced = true }),
    ]
    for (name, step, m, setup) in steps {
        let ob = OnboardingModel(live: false); ob.step = step; setup(ob)
        save("onboarding-\(name)", OnboardingView(model: m, ob: ob))
    }
    save("pip-moods", HStack(spacing: 14) {
        ForEach([PipMood.ready, .listening, .thinking, .happy, .oops, .needsYou, .resting], id: \.self) { PipView(mood: $0).frame(width: 90, height: 82) }
    }.padding(20).background(Color.pipMist))
}

extension GlyphState: Hashable {}
extension PipMood: Hashable {}
