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
cached!(trailing, r"[ ]+\n");
cached!(blank_lines, r"\n{2,}");
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
    // A single line break is only where Whisper cut its text, sometimes inside a word ("trans⏎cribing"): each piece
    // already carries its own spaces, so they're joined as they are. A blank line is a paragraph (join_segments).
    let mut t = replace_all(blank_lines(), &raw.replace('\r', ""), "\u{2029}").replace('\n', "").replace('\u{2029}', "\n\n");
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
    t = replace_all(trailing(), &t, "\n");
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

/// The dictionary words Whisper gets as a hint (same rules as `whisperHint` on macOS). Tested on real audio:
/// - Whisper copies the hint's style: a comma list made it join sentences with commas, so each word is a sentence.
/// - A short hint works better than a long one, and Whisper keeps only the end of a long one: the newest words
///   (added at the end of the list) are kept, within ~300 characters, and come last.
/// - Only real words: a letter and no digits (not "@" or "logohost5173"), no duplicates.
pub fn whisper_hint(words: &[String]) -> String {
    let mut seen = std::collections::HashSet::new();
    let (mut kept, mut length) = (Vec::new(), 0);
    for w in words.iter().rev() {
        let t = w.trim();
        let n = t.chars().count();
        if !t.chars().any(char::is_alphabetic) || t.chars().any(|c| c.is_numeric()) || n > 40 || !seen.insert(t.to_lowercase()) {
            continue;
        }
        if length + n + 2 > 300 { break; }
        kept.push(t);
        length += n + 2;
    }
    if kept.is_empty() { return String::new(); }
    kept.reverse();
    kept.join(". ") + "."
}

/// Silences of at least `min_pause` seconds inside the recording, as (start, end) in seconds. The level that counts
/// as silence is measured on the recording itself, so it works with a quiet mic or a noisy room. A silence that runs
/// to the end is the end of the dictation, not a pause.
pub fn find_pauses(x: &[f32], rate: f32, min_pause: f32) -> Vec<(f32, f32)> {
    let hop = (rate * 0.02) as usize;
    if hop == 0 || x.len() < hop * 10 { return Vec::new(); }
    let rms: Vec<f32> = x.chunks_exact(hop).map(|c| (c.iter().map(|s| s * s).sum::<f32>() / hop as f32).sqrt()).collect();
    let mut sorted = rms.clone();
    sorted.sort_by(f32::total_cmp);
    let threshold = (sorted[sorted.len() / 10] * 2.5).max(sorted[sorted.len() * 9 / 10] * 0.1);
    let (mut out, mut start) = (Vec::new(), None);
    for (k, &v) in rms.iter().enumerate() {
        if v < threshold {
            start.get_or_insert(k);
        } else if let Some(s) = start.take() {
            if (k - s) as f32 * 0.02 >= min_pause { out.push((s as f32 * 0.02, k as f32 * 0.02)); }
        }
    }
    out
}

/// Whisper's segments (start, text) joined as written (each carries its own spaces), with a new paragraph where a
/// sentence ends at a pause. Whisper's timestamps hide pauses inside the segments around them, so the pauses come
/// from the audio.
pub fn join_segments(segments: &[(f32, String)], pauses: &[(f32, f32)]) -> String {
    let mut out = String::new();
    for (i, (start, text)) in segments.iter().enumerate() {
        let ends_sentence = out.trim_end().ends_with(['.', '!', '?', '…']);
        if i > 0 && ends_sentence && pauses.iter().any(|&(a, b)| a - 0.5 <= *start && *start <= b + 0.5) {
            out = format!("{}\n\n{}", out.trim_end(), text.trim_start());
        } else {
            out.push_str(text);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;

    #[test]
    fn hint_keeps_newest_real_words_last() {
        let words: Vec<String> = ["Claude", "@", "logohost5173", "claude", "Pip"].iter().map(|s| s.to_string()).collect();
        assert_eq!(whisper_hint(&words), "claude. Pip."); // the newest spelling wins
        let many: Vec<String> = (0..200).map(|i| format!("Word{}", "x".repeat(i % 7 + 1))).collect();
        assert!(whisper_hint(&many).len() <= 302);
    }

    #[test]
    fn paragraph_only_at_a_sentence_end_with_a_pause() {
        // 1 s of speech, 2 s of silence, 1 s of speech, 0.5 s of silence, 1 s of speech (16 kHz).
        let tone = |secs: f32| (0..(16_000.0 * secs) as usize).map(|i| (i as f32 * 0.05).sin() * 0.3).collect::<Vec<f32>>();
        let quiet = |secs: f32| vec![0.0005f32; (16_000.0 * secs) as usize];
        let audio = [tone(1.0), quiet(2.0), tone(1.0), quiet(0.5), tone(1.0)].concat();
        let pauses = find_pauses(&audio, 16_000.0, 1.2);
        assert_eq!(pauses.len(), 1, "{pauses:?}");
        let segs = vec![(0.0, " First idea.".to_string()), (1.0, " Second".to_string()), (3.5, " point.".to_string()), (4.5, " Third.".to_string())];
        assert_eq!(join_segments(&segs, &pauses), " First idea.\n\nSecond point. Third.");
    }

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
