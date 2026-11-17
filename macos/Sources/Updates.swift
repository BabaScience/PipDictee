// Update check (same rules as windows/src/updates.rs). Once a day Pip asks GitHub for the version number of the
// latest release, and tells you when a newer one is out. It never downloads or installs anything by itself: you get
// the release page, where the files have SHA-256 sums and a signed build provenance.
//
// What is sent: one HTTPS request to api.github.com with the user agent "PipDictee", no cookies, nothing about you or
// your dictations. Only the version number is read from the answer; the link it opens is fixed here, never taken from
// the answer. Off in Settings › Privacy › Check for updates.
import Foundation

let latestReleaseAPI = URL(string: "https://api.github.com/repos/BabaScience/PipDictee/releases/latest")!
let latestReleasePage = URL(string: "https://github.com/BabaScience/PipDictee/releases/latest")!
var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

/// "v2.3.0" or "2.3" → [2, 3, 0]. Nil for anything else, pre-releases ("2.3.0-beta.1") included.
func parseVersion(_ s: String) -> [Int]? {
    let t = s.hasPrefix("v") ? s.dropFirst() : Substring(s)
    let parts = t.split(separator: ".", omittingEmptySubsequences: false)
    guard (2...3).contains(parts.count) else { return nil }
    var out: [Int] = []
    for p in parts {
        guard (1...5).contains(p.count), p.allSatisfy({ ("0"..."9").contains($0) }), let n = Int(p) else { return nil }
        out.append(n)
    }
    return out + Array(repeating: 0, count: 3 - out.count)
}

func isNewer(_ latest: String, than current: String) -> Bool {
    guard let a = parseVersion(latest), let b = parseVersion(current) else { return false }
    for (x, y) in zip(a, b) where x != y { return x > y }
    return false
}

/// The latest published release's version ("2.3.0"), read from GitHub's answer. Nil if the answer isn't exactly
/// what's expected: drafts and pre-releases never count.
func latestVersion(fromJSON data: Data) -> String? {
    guard data.count < 1_000_000, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tag = j["tag_name"] as? String, j["draft"] as? Bool != true, j["prerelease"] as? Bool != true,
          let v = parseVersion(tag) else { return nil }
    return v.map(String.init).joined(separator: ".")
}

/// Asks GitHub. The answer comes on the main thread: the version, or nil if the check failed.
func fetchLatestVersion(_ done: @escaping (String?) -> Void) {
    let config = URLSessionConfiguration.ephemeral   // no cookies, no cache, nothing kept
    config.timeoutIntervalForRequest = 15
    config.httpAdditionalHeaders = ["User-Agent": "PipDictee", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
    let session = URLSession(configuration: config)
    session.dataTask(with: latestReleaseAPI) { data, response, error in
        var version: String?
        if let r = response as? HTTPURLResponse, r.statusCode == 200, r.url?.host == "api.github.com", let data {
            version = latestVersion(fromJSON: data)
        }
        log(version.map { "update check: latest is \($0)" } ?? "update check failed (\((response as? HTTPURLResponse)?.statusCode ?? 0)\(error.map { ", \($0.localizedDescription)" } ?? ""))")
        session.finishTasksAndInvalidate()
        DispatchQueue.main.async { done(version) }
    }.resume()
}

/// Checks at launch (after a short wait), then once a day; remembers the last answer between launches.
final class Updater {
    /// A newer version than this one, or nil.
    var onChange: (String?) -> Void = { _ in }
    private var timer: Timer?
    private var checking = false

    func start() {
        report(defaults.string(forKey: "latestVersion"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.check(force: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.check(force: false) }
    }

    /// `force`: the "Check now" button (even if the daily check is off). `done` gets whether it worked.
    func check(force: Bool, done: ((Bool) -> Void)? = nil) {
        guard force || Settings.checkUpdates, !checking else { done?(false); return }
        if !force, let last = defaults.object(forKey: "lastUpdateCheck") as? Date, Date().timeIntervalSince(last) < 23 * 3600 { return }
        checking = true
        fetchLatestVersion { [weak self] v in
            guard let self else { return }
            self.checking = false
            if let v {
                defaults.set(Date(), forKey: "lastUpdateCheck")
                defaults.set(v, forKey: "latestVersion")
            }
            self.report(v ?? defaults.string(forKey: "latestVersion"))
            done?(v != nil)
        }
    }

    private func report(_ latest: String?) {
        guard Settings.checkUpdates, let latest, isNewer(latest, than: appVersion) else { onChange(nil); return }
        onChange(latest)
    }
}
