//! Translations, shared with the macOS app: shared/i18n/<lang>.json maps each English string to its translation.
//! The files are built into the executable; the language follows Windows' display language.

use std::collections::HashMap;
use std::sync::RwLock;

pub const FILES: &[(&str, &str)] = &[
    ("fr", include_str!("../../shared/i18n/fr.json")),
    ("de", include_str!("../../shared/i18n/de.json")),
    ("it", include_str!("../../shared/i18n/it.json")),
    ("es", include_str!("../../shared/i18n/es.json")),
    ("pt", include_str!("../../shared/i18n/pt.json")),
];

static TABLE: RwLock<Option<(String, HashMap<String, String>)>> = RwLock::new(None);

fn load(code: &str) -> HashMap<String, String> {
    FILES.iter().find(|(c, _)| *c == code).and_then(|(_, j)| serde_json::from_str(j).ok()).unwrap_or_default()
}

/// "fr" for fr-FR, fr-CA… English (no table) when the language isn't translated.
pub fn system_language() -> String {
    sys_locale::get_locale().unwrap_or_default().split(['-', '_']).next().unwrap_or("en").to_lowercase()
}

/// Chooses the interface language: "system" (Windows' display language) or a code. Takes effect immediately.
pub fn set_language(choice: &str) {
    let code = if choice == "system" { system_language() } else { choice.to_string() };
    let table = load(&code);
    *TABLE.write().unwrap() = Some((code, table));
}

fn ensure() { if TABLE.read().unwrap().is_none() { set_language("system"); } }

/// The language code in use ("fr"…), for dates and number formats in the windows.
pub fn current() -> String { ensure(); TABLE.read().unwrap().as_ref().map(|(c, _)| c.clone()).unwrap_or_else(|| "en".into()) }

/// Every translation of the current language, sent to the windows' UI.
pub fn table() -> HashMap<String, String> { ensure(); TABLE.read().unwrap().as_ref().map(|(_, t)| t.clone()).unwrap_or_default() }

/// The translation of `key` (English text), or the key itself.
pub fn t(key: &str) -> String {
    ensure();
    TABLE.read().unwrap().as_ref().and_then(|(_, t)| t.get(key).cloned()).unwrap_or_else(|| key.to_string())
}

/// Like `t`, with each `%@` replaced by the next argument, in order.
pub fn tf(key: &str, args: &[&str]) -> String {
    let mut s = t(key);
    for a in args {
        match s.find("%@") { Some(i) => s.replace_range(i..i + 2, a), None => break }
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every language file parses and has exactly the same keys, with the same number of %@ placeholders.
    #[test]
    fn translation_files_agree() {
        let tables: Vec<(&str, HashMap<String, String>)> =
            FILES.iter().map(|(c, j)| (*c, serde_json::from_str(j).unwrap_or_else(|e| panic!("{c}.json: {e}")))).collect();
        let (first, reference) = &tables[0];
        for (code, table) in &tables {
            for k in reference.keys() { assert!(table.contains_key(k), "{code}.json is missing {k:?} (present in {first}.json)"); }
            for (k, v) in table {
                assert!(reference.contains_key(k), "{code}.json has an extra key {k:?}");
                assert_eq!(k.matches("%@").count(), v.matches("%@").count(), "{code}.json: placeholders differ in {k:?}");
            }
        }
    }
}
