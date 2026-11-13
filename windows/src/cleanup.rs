//! Text clean-up after transcription. A line-by-line port of `clean()` in macos/Sources/main.swift:
//! both are checked against shared/cleanup-cases.json, so a change here must be made there too.

use crate::store::Dictionary;
use fancy_regex::{Captures, Regex};
use std::sync::OnceLock;

const HALLUCINATIONS: &[&str] = &[
    "sous-titres réalisés par la communauté d'amara.org", "sous-titrage st' 501", "merci d'avoir regardé",
    "merci d'avoir regardé cette vidéo", "thank you for watching", "thanks for watching", "thank you.", "you",
    "untertitel im auftrag des zdf", "sottotitoli creati dalla comunità amara.org", "untertitelung des zdf, 2020", "amara.org",
    "subtítulos realizados por la comunidad de amara.org", "gracias por ver el video", "gracias por ver", "¡gracias por ver",
    "legendas pela comunidade amara.org", "obrigado por assistir", "obrigada por assistir",
];

const LAYOUT: &[(&str, &str)] = &[
    ("nouveau paragraphe", "\n\n"), ("new paragraph", "\n\n"), ("à la ligne", "\n"), ("nouvelle ligne", "\n"),
    ("new line", "\n"), ("neue Zeile", "\n"), ("a capo", "\n"),
    ("nuevo párrafo", "\n\n"), ("nueva línea", "\n"), ("novo parágrafo", "\n\n"), ("nova linha", "\n"),
];

fn re(p: &str) -> Regex { Regex::new(p).expect("valid regex") }

macro_rules! cached {
    ($name:ident, $pat:expr) => {
        fn $name() -> &'static Regex { static R: OnceLock<Regex> = OnceLock::new(); R.get_or_init(|| re($pat)) }
    };
}
cached!(tags, r"(?i)\[[^\]]*\]|\([^)]*(musique|music|rires|laughs|applause|applaudissements|silence|inaudible)[^)]*\)|\*[^*]+\*");
cached!(fillers, r"(?i)(,\s*)?(?<![\p{L}'’-])(euh+|heu+|hum+|hmm+|uh+|uhm+|erm+|ehm+|ähm*|äh+|ãh+|hã+)(?![\p{L}'’-])(\s*,)?");
cached!(um, r"(?i)(^|[,.!?]\s*|\s,\s*)(umm*|eh+|em+),\s*");
cached!(multi_space, r"[ \t]{2,}");
cached!(space_before_punct, r"[ \t]+([,.!?…])");
cached!(double_comma, r",[ ]*(?=,)");
cached!(indent, r"\n[ ]+");
cached!(newline_lower, r"\n(\p{Ll})");
cached!(leading_punct, r"^[\s,.]+");
cached!(comma_before_end, r",\s*([.!?])");

fn replace_all(r: &Regex, t: &str, with: &str) -> String { r.replace_all(t, with).into_owned() }
fn literal(r: &Regex, t: &str, with: &str) -> String { r.replace_all(t, fancy_regex::NoExpand(with)).into_owned() }
fn trim_chars<'a>(t: &'a str, chars: &str) -> &'a str { t.trim_matches(|c| chars.contains(c)) }

fn capitalize_first(t: &str) -> String {
    let mut cs = t.chars();
    match cs.next() {
        Some(f) if f.is_lowercase() => f.to_uppercase().chain(cs).collect(),
        _ => t.to_string(),
    }
}

fn word(p: &str) -> Regex { re(&format!(r"(?i)(?<![\p{{L}}]){}(?![\p{{L}}])", regex::escape(p))) }

pub fn clean(raw: &str, dict: &Dictionary, remove_fillers: bool) -> String {
    let mut t = raw.replace('\n', " ");
    t = replace_all(tags(), &t, "");
    t = t.trim().to_string();
    let lower = t.to_lowercase();
    if HALLUCINATIONS.contains(&trim_chars(&lower, " .!")) || HALLUCINATIONS.contains(&lower.as_str()) {
        return String::new();
    }
    if remove_fillers {
        t = replace_all(fillers(), &t, " ");
        t = replace_all(um(), &t, "${1}");
    }
    for (said, put) in LAYOUT {
        let r = re(&format!(r"(?i)[ ,]*\b{}\b[,.]?[ ]*", regex::escape(said)));
        t = literal(&r, &t, put);
    }
    t = replace_all(multi_space(), &t, " ");
    t = replace_all(space_before_punct(), &t, "${1}");
    t = replace_all(double_comma(), &t, "");
    t = replace_all(indent(), &t, "\n");
    t = trim_chars(&t, " ,").to_string();
    t = capitalize_first(&t);
    t = newline_lower().replace_all(&t, |c: &Captures| format!("\n{}", c[1].to_uppercase())).into_owned();
    t = replace_all(leading_punct(), &t, "");
    t = replace_all(comma_before_end(), &t, "${1}");
    t = trim_chars(&t, " ,").to_string();
    // Dictionary words and snippets last, written exactly as they are.
    for (from, to) in &dict.replacements {
        t = literal(&word(from), &t, to);
    }
    for (trigger, text) in &dict.snippets {
        if trim_chars(&t.to_lowercase(), " .!?,") == trigger.to_lowercase() {
            t = text.clone();
            continue;
        }
        t = literal(&word(trigger), &t, text);
    }
    t
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;

    #[derive(Deserialize)]
    struct Case { input: String, expected: String, dictionary: Option<Dictionary> }

    /// The same cases the macOS app runs with `PipDictee --test-cleanup`.
    #[test]
    fn shared_cases() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../shared/cleanup-cases.json");
        let cases: Vec<Case> = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        let mut failed = Vec::new();
        for c in &cases {
            let got = clean(&c.input, &c.dictionary.clone().unwrap_or_default(), true);
            if got != c.expected { failed.push(format!("{:?}\n  expected {:?}\n  got      {:?}", c.input, c.expected, got)); }
        }
        assert!(failed.is_empty(), "{} of {} cases fail:\n{}", failed.len(), cases.len(), failed.join("\n"));
    }
}
