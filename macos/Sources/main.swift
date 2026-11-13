// Pip Dictée — free, 100 % local voice dictation for macOS, in the spirit of Wispr Flow.
// Hold the shortcut (Ctrl+Option by default) and talk, release and the text is typed where the cursor is.
// Shortcut + Space = hands-free (press the shortcut again to finish). Esc cancels.
// Cmd+Ctrl+V pastes the last dictation again, Cmd+Ctrl+C copies it.
// Speech is transcribed on this Mac by whisper.cpp (large-v3-turbo, Metal), kept loaded in a local server.
import AppKit

// `PipDictee --test-cleanup shared/cleanup-cases.json`: checks clean() against the cases shared with the Windows app.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--test-cleanup" {
    struct Case: Decodable { var input: String; var expected: String; var dictionary: Dictionary? }
    guard let data = fm.contents(atPath: CommandLine.arguments[2]), let cases = try? JSONDecoder().decode([Case].self, from: data) else {
        print("cannot read \(CommandLine.arguments[2])"); exit(2)
    }
    var failed = 0
    for c in cases {
        let got = clean(c.input, dict: c.dictionary ?? Dictionary())
        if got != c.expected { failed += 1; print("FAIL \(c.input.debugDescription)\n  expected \(c.expected.debugDescription)\n  got      \(got.debugDescription)") }
    }
    print("\(cases.count - failed)/\(cases.count) cleanup cases pass")
    exit(failed == 0 ? 0 : 1)
}

// `PipDictee --render-icon <folder.iconset>`: the app icon at every size (build.sh makes AppIcon.icns from it).
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-icon" {
    _ = NSApplication.shared
    MainActor.assumeIsolated { renderAppIcon(to: CommandLine.arguments[2]) }
    exit(0)
}

// `PipDictee --render-windows-assets <folder>`: tray and app icons for the Windows app.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-windows-assets" {
    _ = NSApplication.shared
    MainActor.assumeIsolated { renderWindowsAssets(to: CommandLine.arguments[2]) }
    exit(0)
}

// `PipDictee --snapshot <folder>`: every screen as PNG, with sample data (see Snapshots.swift).
// `PipDictee --snapshot <folder> fr` renders them in one language.
if (3...4).contains(CommandLine.arguments.count), CommandLine.arguments[1] == "--snapshot" {
    _ = NSApplication.shared
    if CommandLine.arguments.count == 4 {
        guard let path = Bundle.main.path(forResource: CommandLine.arguments[3], ofType: "lproj"), let b = Bundle(path: path) else {
            print("no translation for \(CommandLine.arguments[3])"); exit(2)
        }
        stringsBundle = b
        uiLanguageOverride = CommandLine.arguments[3]
    }
    MainActor.assumeIsolated { renderSnapshots(to: CommandLine.arguments[2]) }
    exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()
