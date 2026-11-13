// Core: files, settings, dictionary, history, text clean-up and the local Whisper server. No UI here.
import AppKit
// MARK: - Paths and settings

let fm = FileManager.default
let supportDir = NSHomeDirectory() + "/Library/Application Support/Pip Dictée"
let modelPath = supportDir + "/models/ggml-large-v3-turbo.bin"
let dictionaryPath = supportDir + "/dictionary.json"
let historyPath = supportDir + "/history.json"
/// File names used before version 2.1; renamed at launch.
let legacyFiles = [(supportDir + "/dictionnaire.json", dictionaryPath), (supportDir + "/historique.json", historyPath)]
let logPath = supportDir + "/pip-dictee.log"
let serverPort = 18765
let defaults = UserDefaults.standard

func findTool(_ name: String) -> String? {
    ["/opt/homebrew/bin/", "/usr/local/bin/"].map { $0 + name }.first { fm.isExecutableFile(atPath: $0) }
}

/// Dictations are private: the data folder is readable by this user only (0700), its files too (0600).
func ensurePrivateSupportDir() {
    try? fm.createDirectory(atPath: supportDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDir)
    for p in [dictionaryPath, historyPath, logPath] where fm.fileExists(atPath: p) {
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p)
    }
}
func writePrivate(_ data: Data, to path: String) {
    let url = URL(fileURLWithPath: path)
    do {
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    } catch { log("could not write \(url.lastPathComponent): \(error.localizedDescription)") }
}

/// Never logs what was said: only events, timings and lengths.
func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    if let h = FileHandle(forWritingAtPath: logPath) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { fm.createFile(atPath: logPath, contents: line.data(using: .utf8), attributes: [.posixPermissions: 0o600]) }
}

var languages: [(code: String, name: String)] { [
    ("auto", L("Automatic (detect language)")), ("fr", "Français"), ("en", "English"), ("it", "Italiano"), ("de", "Deutsch"), ("es", "Español"), ("pt", "Português"),
] }

enum Trigger: String, CaseIterable {
    case ctrlOption = "ctrlOption", fn = "fn", rightOption = "rightOption", rightCommand = "rightCommand"
    var title: String {
        switch self {
        case .ctrlOption: return L("Ctrl + Option")
        case .fn: return "fn (🌐)"
        case .rightOption: return L("Right Option")
        case .rightCommand: return L("Right Command")
        }
    }
    var short: String {
        switch self {
        case .ctrlOption: return "⌃⌥"
        case .fn: return "fn"
        case .rightOption: return L("right ⌥")
        case .rightCommand: return L("right ⌘")
        }
    }
}

struct Settings {
    static var lang: String { get { defaults.string(forKey: "lang") ?? "auto" } set { defaults.set(newValue, forKey: "lang") } }
    static var trigger: Trigger {
        get { Trigger(rawValue: defaults.string(forKey: "trigger") ?? "") ?? .ctrlOption }
        set { defaults.set(newValue.rawValue, forKey: "trigger") }
    }
    static func flag(_ k: String, _ d: Bool) -> Bool { defaults.object(forKey: k) == nil ? d : defaults.bool(forKey: k) }
    static var autoPaste: Bool { get { flag("autoPaste", true) } set { defaults.set(newValue, forKey: "autoPaste") } }
    static var sounds: Bool { get { flag("sounds", true) } set { defaults.set(newValue, forKey: "sounds") } }
    static var removeFillers: Bool { get { flag("removeFillers", true) } set { defaults.set(newValue, forKey: "removeFillers") } }
    static var aiPolish: Bool { get { flag("aiPolish", false) } set { defaults.set(newValue, forKey: "aiPolish") } }
    static var restoreClipboard: Bool { get { flag("restoreClipboard", false) } set { defaults.set(newValue, forKey: "restoreClipboard") } }
    static var keepHistory: Bool { get { flag("keepHistory", true) } set { defaults.set(newValue, forKey: "keepHistory") } }
    /// Lets other local programs (e.g. Pip) start/stop a dictation or feed a file. Off by default: otherwise any
    /// process could use the microphone permission granted to Pip Dictée.
    static var externalControl: Bool { get { flag("externalControl", false) } set { defaults.set(newValue, forKey: "externalControl") } }
}

// MARK: - Dictionary (words, replacements, snippets) and history

struct Dictionary: Codable {
    var words: [String] = []
    var replacements: [String: String] = [:]
    var snippets: [String: String] = [:]

    enum CodingKeys: String, CodingKey { case words, replacements, snippets, mots, remplacements }
    init(words: [String] = [], replacements: [String: String] = [:], snippets: [String: String] = [:]) {
        self.words = words; self.replacements = replacements; self.snippets = snippets
    }
    /// Also reads the French keys of files written before version 2.1 ("mots", "remplacements").
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        words = try c.decodeIfPresent([String].self, forKey: .words) ?? c.decodeIfPresent([String].self, forKey: .mots) ?? []
        replacements = try c.decodeIfPresent([String: String].self, forKey: .replacements)
            ?? c.decodeIfPresent([String: String].self, forKey: .remplacements) ?? [:]
        snippets = try c.decodeIfPresent([String: String].self, forKey: .snippets) ?? [:]
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(words, forKey: .words); try c.encode(replacements, forKey: .replacements); try c.encode(snippets, forKey: .snippets)
    }
}

/// Renames the pre-2.1 files and rewrites the dictionary with English keys. Nothing is lost.
func migrateLegacyFiles() {
    for (old, new) in legacyFiles where fm.fileExists(atPath: old) && !fm.fileExists(atPath: new) {
        do { try fm.moveItem(atPath: old, toPath: new); log("renamed \((old as NSString).lastPathComponent) → \((new as NSString).lastPathComponent)") }
        catch { log("could not rename \((old as NSString).lastPathComponent): \(error.localizedDescription)") }
    }
    if let d = fm.contents(atPath: dictionaryPath), String(decoding: d, as: UTF8.self).contains("\"mots\"") {
        saveDictionary(loadDictionary())
    }
}

func loadDictionary() -> Dictionary {
    guard let d = fm.contents(atPath: dictionaryPath), let v = try? JSONDecoder().decode(Dictionary.self, from: d) else { return Dictionary() }
    return v
}
func saveDictionary(_ d: Dictionary) {
    let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? e.encode(d) { writePrivate(data, to: dictionaryPath) }
}

struct Entry: Codable { var text: String; var at: Date; var app: String? }
func loadHistory() -> [Entry] {
    guard let d = fm.contents(atPath: historyPath) else { return [] }
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    return (try? dec.decode([Entry].self, from: d)) ?? []
}
func saveHistory(_ h: [Entry]) {
    guard Settings.keepHistory else { try? fm.removeItem(atPath: historyPath); return }
    let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .prettyPrinted
    if let data = try? e.encode(Array(h.prefix(200))) { writePrivate(data, to: historyPath) }
}

/// Imports the words, replacements and snippets of Wispr Flow's local dictionary (read only).
func importFromWispr() -> Int? {
    let db = NSHomeDirectory() + "/Library/Application Support/Wispr Flow/flow.sqlite"
    guard fm.fileExists(atPath: db) else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    p.arguments = ["-readonly", "-json", db, "select phrase, replacement, isSnippet from Dictionary where isDeleted=0 order by frequencyUsed desc"]
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
    var d = loadDictionary(); var n = 0
    for r in rows {
        guard let phrase = r["phrase"] as? String, !phrase.isEmpty else { continue }
        let repl = (r["replacement"] as? String) ?? ""
        let snippet = (r["isSnippet"] as? Int ?? 0) == 1
        if snippet, !repl.isEmpty { if d.snippets[phrase] == nil { d.snippets[phrase] = repl; n += 1 } }
        else if !repl.isEmpty { if d.replacements[phrase] == nil { d.replacements[phrase] = repl; n += 1 } }
        else if !d.words.contains(phrase) { d.words.append(phrase); n += 1 }
    }
    saveDictionary(d)
    return n
}

// MARK: - Text clean-up

let hallucinations = [
    "sous-titres réalisés par la communauté d'amara.org", "sous-titrage st' 501", "merci d'avoir regardé", "merci d'avoir regardé cette vidéo",
    "thank you for watching", "thanks for watching", "thank you.", "you", "untertitel im auftrag des zdf", "sottotitoli creati dalla comunità amara.org",
    "untertitelung des zdf, 2020", "amara.org",
    "subtítulos realizados por la comunidad de amara.org", "gracias por ver el video", "gracias por ver", "¡gracias por ver",
    "legendas pela comunidade amara.org", "obrigado por assistir", "obrigada por assistir",
]

func clean(_ raw: String, dict: Dictionary) -> String {
    var t = raw.replacingOccurrences(of: "\n", with: " ")
    // Tags such as [BLANK_AUDIO], (musique), *rires*.
    t = t.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*(musique|music|rires|laughs|applause|applaudissements|silence|inaudible)[^)]*\)|\*[^*]+\*"#, with: "", options: [.regularExpression, .caseInsensitive])
    t = t.trimmingCharacters(in: .whitespacesAndNewlines)
    if hallucinations.contains(t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!"))) || hallucinations.contains(t.lowercased()) { return "" }
    if Settings.removeFillers {
        // A hesitation goes with the commas around it: « je pense, euh, que » → « je pense que ».
        t = t.replacingOccurrences(of: #"(?i)(,\s*)?(?<![\p{L}'’-])(euh+|heu+|hum+|hmm+|uh+|uhm+|erm+|ehm+|ähm*|äh+|ãh+|hã+)(?![\p{L}'’-])(\s*,)?"#, with: " ", options: .regularExpression)
        // « um » is also a German word: only when it stands alone between commas or at the start.
        // « um » (German), « eh », « em » (Spanish, Portuguese) are also words: only alone between commas or at the start.
        t = t.replacingOccurrences(of: #"(?i)(^|[,.!?]\s*|\s,\s*)(umm*|eh+|em+),\s*"#, with: "$1", options: .regularExpression)
    }
    // Spoken layout commands.
    for (said, put) in [("nouveau paragraphe", "\n\n"), ("new paragraph", "\n\n"), ("à la ligne", "\n"), ("nouvelle ligne", "\n"), ("new line", "\n"), ("neue Zeile", "\n"), ("a capo", "\n"),
                       ("nuevo párrafo", "\n\n"), ("nueva línea", "\n"), ("novo parágrafo", "\n\n"), ("nova linha", "\n")] {
        t = t.replacingOccurrences(of: #"[ ,]*\b"# + NSRegularExpression.escapedPattern(for: said) + #"\b[,.]?[ ]*"#, with: put, options: [.regularExpression, .caseInsensitive])
    }
    t = t.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
    t = t.replacingOccurrences(of: #"[ \t]+([,.!?…])"#, with: "$1", options: .regularExpression)
    t = t.replacingOccurrences(of: #",[ ]*(?=,)"#, with: "", options: .regularExpression)
    t = t.replacingOccurrences(of: #"\n[ ]+"#, with: "\n", options: .regularExpression)
    t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
    if let f = t.first, f.isLowercase { t = f.uppercased() + t.dropFirst() }
    // Each new line starts with a capital, like the first.
    if let re = try? NSRegularExpression(pattern: #"\n(\p{Ll})"#) {
        let ns = t as NSString; var out = t
        for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed() {
            out = (out as NSString).replacingCharacters(in: m.range(at: 1), with: ns.substring(with: m.range(at: 1)).uppercased())
        }
        t = out
    }
    t = t.replacingOccurrences(of: #"^[\s,.]+"#, with: "", options: .regularExpression)
    t = t.replacingOccurrences(of: #",\s*([.!?])"#, with: "$1", options: .regularExpression)
    t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
    // The words of the dictionary and the snippets last, written exactly as they are (no capital added).
    for (from, to) in dict.replacements {
        t = t.replacingOccurrences(of: #"(?<![\p{L}])"# + NSRegularExpression.escapedPattern(for: from) + #"(?![\p{L}])"#, with: to, options: [.regularExpression, .caseInsensitive])
    }
    for (trigger, text) in dict.snippets {
        let bare = t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!?,"))
        if bare == trigger.lowercased() { t = text; continue }
        t = t.replacingOccurrences(of: #"(?<![\p{L}])"# + NSRegularExpression.escapedPattern(for: trigger) + #"(?![\p{L}])"#, with: text, options: [.regularExpression, .caseInsensitive])
    }
    return t
}

/// Optional: a local model (Ollama) removes self-corrections and tidies the sentence, nothing else.
func polish(_ text: String) -> String {
    guard text.split(separator: " ").count >= 6 else { return text }
    let model = defaults.string(forKey: "ollamaModel") ?? "llama3.2"
    let prompt = """
    You clean up a voice dictation. Keep EXACTLY the same language, meaning and tone. Only remove hesitations, repetitions \
    and false starts; when the speaker corrects themselves ("no, rather…", "I mean…", « non, plutôt… »), keep the corrected version. \
    Fix the punctuation. Add nothing, don't answer the text, don't translate it. Reply with the cleaned-up text only.

    Text: \(text)
    """
    var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/generate")!, timeoutInterval: 8)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "prompt": prompt, "stream": false, "options": ["temperature": 0]])
    guard let (data, _) = syncRequest(req), let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          var out = j["response"] as? String else { return text }
    out = out.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"«» "))
    // A reply far longer or shorter than the dictation is the model talking, not tidying: keep the dictation.
    let ratio = Double(out.count) / Double(max(text.count, 1))
    return (out.isEmpty || ratio < 0.5 || ratio > 1.3) ? text : out
}

func syncRequest(_ req: URLRequest) -> (Data, HTTPURLResponse)? {
    let sem = DispatchSemaphore(value: 0)
    var result: (Data, HTTPURLResponse)?
    URLSession.shared.dataTask(with: req) { d, r, _ in
        if let d = d, let r = r as? HTTPURLResponse { result = (d, r) }
        sem.signal()
    }.resume()
    sem.wait()
    return result
}

// MARK: - Whisper (kept loaded in a local server, the command line as a fallback)

final class Whisper {
    var server: Process?
    var ready = false { didSet { if ready != oldValue { onReady(ready) } } }
    /// Called on the main thread when the server becomes ready or stops.
    var onReady: (Bool) -> Void = { _ in }

    func start() {
        guard server == nil, let bin = findTool("whisper-server"), fm.fileExists(atPath: modelPath) else { return }
        // A server left by a previous run (killed rather than quit) would hold the port: it goes first.
        let k = Process(); k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k.arguments = ["-f", "whisper-server.*--port \(serverPort)"]; try? k.run(); k.waitUntilExit()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        var args = ["-m", modelPath, "--host", "127.0.0.1", "--port", String(serverPort), "-l", "auto", "-t", "8", "-fa"]
        // Voice detection (Silero, the one Pip already uses): silences are skipped instead of "heard".
        let vad = [supportDir + "/models/ggml-silero-v5.1.2.bin", NSHomeDirectory() + "/.cache/pip/models/ggml-silero-v5.1.2.bin"]
        if let v = vad.first(where: { fm.fileExists(atPath: $0) }) { args += ["--vad", "-vm", v] }
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let s = self else { return }
                s.server = nil; s.ready = false
                log("whisper-server stopped; restarting in 3 s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { s.start() }
            }
        }
        do { try p.run(); server = p; log("whisper-server started (pid \(p.processIdentifier))") } catch { log("whisper-server: \(error)"); return }
        waitReady(tries: 120)
    }
    func waitReady(tries: Int) {
        DispatchQueue.global().async {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(serverPort)/")!, timeoutInterval: 1)
            req.httpMethod = "GET"
            let ok = syncRequest(req)?.1.statusCode == 200
            DispatchQueue.main.async {
                if ok { self.ready = true; log("whisper-server ready") }
                else if tries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.waitReady(tries: tries - 1) } }
            }
        }
    }
    func stop() { server?.terminationHandler = nil; server?.terminate(); server = nil }

    /// Off the main thread.
    func transcribe(_ wav: URL, lang: String, prompt: String) -> String? {
        if ready, let t = viaServer(wav, lang: lang, prompt: prompt) { return t }
        return viaCLI(wav, lang: lang, prompt: prompt)
    }
    private func viaServer(_ wav: URL, lang: String, prompt: String) -> String? {
        guard let audio = try? Data(contentsOf: wav) else { return nil }
        let boundary = "pip-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictee.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio); body.append("\r\n".data(using: .utf8)!)
        field("response_format", "json"); field("temperature", "0.0"); field("language", lang)
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(serverPort)/inference")!, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        guard let (data, r) = syncRequest(req), r.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let t = j["text"] as? String else { return nil }
        return t
    }
    private func viaCLI(_ wav: URL, lang: String, prompt: String) -> String? {
        guard let bin = findTool("whisper-cli") else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-m", modelPath, "-f", wav.path, "-l", lang, "-nt", "-np", "-t", "8"] + (prompt.isEmpty ? [] : ["--prompt", prompt])
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
