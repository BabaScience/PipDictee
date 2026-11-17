//! Update check (same rules as macos/Sources/Updates.swift). Once a day Pip asks GitHub for the version number of
//! the latest release, and tells you when a newer one is out. It never downloads or installs anything by itself:
//! you get the release page, where the files have SHA-256 sums and a signed build provenance.
//!
//! What is sent: one HTTPS request to api.github.com with the user agent "PipDictee", nothing about you or your
//! dictations. Only the version number is read from the answer; the page it opens is fixed here, never taken from
//! the answer. Off in Settings › Privacy › Check for updates.

pub const LATEST_RELEASE_API: &str = "https://api.github.com/repos/BabaScience/PipDictee/releases/latest";
pub const LATEST_RELEASE_PAGE: &str = "https://github.com/BabaScience/PipDictee/releases/latest";
/// Checked at most this often (the app looks every hour whether it's time).
pub const CHECK_EVERY_SECS: i64 = 23 * 3600;

/// "v2.3.0" or "2.3" → [2, 3, 0]. None for anything else, pre-releases ("2.3.0-beta.1") included.
pub fn parse_version(s: &str) -> Option<[u32; 3]> {
    let t = s.strip_prefix('v').unwrap_or(s);
    let parts: Vec<&str> = t.split('.').collect();
    if !(2..=3).contains(&parts.len()) { return None; }
    let mut out = [0u32; 3];
    for (i, p) in parts.iter().enumerate() {
        if p.is_empty() || p.len() > 5 || !p.bytes().all(|b| b.is_ascii_digit()) { return None; }
        out[i] = p.parse().ok()?;
    }
    Some(out)
}

pub fn is_newer(latest: &str, current: &str) -> bool {
    matches!((parse_version(latest), parse_version(current)), (Some(a), Some(b)) if a > b)
}

/// The latest published release's version ("2.3.0"), read from GitHub's answer. None if the answer isn't exactly
/// what's expected: drafts and pre-releases never count.
pub fn latest_version_from_json(body: &[u8]) -> Option<String> {
    if body.len() >= 1_000_000 { return None; }
    let j: serde_json::Value = serde_json::from_slice(body).ok()?;
    if j["draft"].as_bool() == Some(true) || j["prerelease"].as_bool() == Some(true) { return None; }
    let v = parse_version(j["tag_name"].as_str()?)?;
    Some(format!("{}.{}.{}", v[0], v[1], v[2]))
}

/// Asks GitHub (blocking; call it off the UI thread). None if the check failed.
#[cfg(windows)]
pub fn fetch_latest() -> Option<String> {
    use std::io::Read;
    use std::sync::Arc;
    use std::time::Duration;
    let tls = native_tls::TlsConnector::new().ok()?;
    let agent = ureq::AgentBuilder::new()
        .tls_connector(Arc::new(tls))
        .https_only(true)
        .redirects(0)
        .user_agent("PipDictee")
        .timeout(Duration::from_secs(15))
        .build();
    let resp = agent.get(LATEST_RELEASE_API)
        .set("Accept", "application/vnd.github+json")
        .set("X-GitHub-Api-Version", "2022-11-28")
        .call();
    let resp = match resp {
        Ok(r) => r,
        Err(e) => {
            crate::store::log(&format!("update check failed: {}", match &e {
                ureq::Error::Status(code, _) => format!("HTTP {code}"),
                ureq::Error::Transport(t) => t.kind().to_string(),
            }));
            return None;
        }
    };
    let mut body = Vec::new();
    resp.into_reader().take(1_000_000).read_to_end(&mut body).ok()?;
    let v = latest_version_from_json(&body);
    crate::store::log(&match &v { Some(v) => format!("update check: latest is {v}"), None => "update check: unexpected answer".into() });
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_compare_as_numbers() {
        assert!(is_newer("2.3.0", "2.2.0"));
        assert!(is_newer("v2.10.0", "2.9.9"));
        assert!(!is_newer("2.2.0", "2.2"));
        assert!(!is_newer("2.1.9", "2.2.0"));
        assert_eq!(parse_version("v2.3.0-beta.1"), None);
        for bad in ["", "v", "2", "2.3.0.1", "2.3.x", "２.3", "2.3.0; rm -rf /", "+2.3"] { assert_eq!(parse_version(bad), None, "{bad}"); }
    }

    #[test]
    fn only_published_releases_and_only_the_version() {
        assert_eq!(latest_version_from_json(br#"{"tag_name":"v2.4.1","html_url":"https://evil.example"}"#), Some("2.4.1".into()));
        assert_eq!(latest_version_from_json(br#"{"tag_name":"v9.0.0","draft":true}"#), None);
        assert_eq!(latest_version_from_json(br#"{"tag_name":"v9.0.0","prerelease":true}"#), None);
        assert_eq!(latest_version_from_json(br#"{"message":"Not Found"}"#), None);
        assert_eq!(latest_version_from_json(b"not json"), None);
    }
}
