// Translations. Every visible string goes through L("English text"); the English text is the key, and the
// translations live in shared/i18n/<lang>.json (shared with the Windows app). build.sh turns each JSON file into
// <lang>.lproj/Localizable.strings, so macOS picks the user's language — or the one set for this app in
// System Settings › General › Language & Region › Applications.
import Foundation

/// Where strings come from. Snapshots point it at one language's .lproj folder.
var stringsBundle = Bundle.main

/// The translation of `key`, with each `%@` replaced by the next argument, in order.
func L(_ key: String, _ args: String...) -> String {
    var s = stringsBundle.localizedString(forKey: key, value: key, table: nil)
    for a in args {
        guard let r = s.range(of: "%@") else { break }
        s.replaceSubrange(r, with: a)
    }
    return s
}

/// "1 word" / "12 words", in the interface language.
func Lwords(_ n: Int) -> String { n == 1 ? L("1 word") : L("%@ words", String(n)) }

/// The locale of the interface language, for dates and sizes.
var uiLocale: Locale { Locale(identifier: uiLanguageOverride ?? Bundle.main.preferredLocalizations.first ?? "en") }

/// Set by the app-language setting or by `--snapshot <folder> <lang>`, so dates follow the language shown.
var uiLanguageOverride: String?

/// The interface languages, each in its own language so anyone can find theirs.
var uiLanguages: [(code: String, name: String)] {
    [("system", L("Same as the system")), ("en", "English"), ("fr", "Français"), ("de", "Deutsch"),
     ("it", "Italiano"), ("es", "Español"), ("pt", "Português")]
}

/// Switches the interface language now (views re-render through Model.uiLanguage) and remembers it.
/// "system" follows macOS, including the per-app choice in System Settings › Language & Region.
func applyUILanguage(_ code: String) {
    UserDefaults.standard.set(code, forKey: "uiLanguage")
    if code != "system", let path = Bundle.main.path(forResource: code, ofType: "lproj"), let b = Bundle(path: path) {
        stringsBundle = b
        uiLanguageOverride = code
        UserDefaults.standard.set([code], forKey: "AppleLanguages")   // so system texts follow at next launch
    } else {
        stringsBundle = Bundle.main
        uiLanguageOverride = nil
        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    }
}
