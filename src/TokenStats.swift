import Foundation

// MARK: - Modell

struct TokenCounts {
    var input = 0, output = 0, cacheRead = 0, cacheWrite = 0
    var total: Int { input + output + cacheRead + cacheWrite }
    /// Input + Output ohne Cache – aussagekräftiger als total, das fast nur aus Cache-Lesen besteht
    var io: Int { input + output }

    static func += (l: inout TokenCounts, r: TokenCounts) {
        l.input += r.input; l.output += r.output
        l.cacheRead += r.cacheRead; l.cacheWrite += r.cacheWrite
    }
}

struct TokenSummary {
    var totals = TokenCounts()
    var byModel: [(name: String, counts: TokenCounts)] = []
    var byProject: [(name: String, counts: TokenCounts)] = []
    var requests = 0
}

struct TokenStats {
    var fiveHour = TokenSummary()
    var week = TokenSummary()
}

// MARK: - Scanner

/// Liest die Token-Zahlen, die Claude Code zu jeder Antwort in ~/.claude/projects/**/*.jsonl schreibt.
/// Pro Datei wird gemerkt, bis zu welchem Byte schon gelesen wurde – Folge-Scans lesen nur neue Zeilen.
/// Dateien, die seit über 8 Tagen nicht geändert wurden, werden übersprungen.
actor TokenScanner {
    static let shared = TokenScanner()

    private struct Entry {
        let date: Date
        let model: String
        let project: String
        let counts: TokenCounts
    }

    private var offsets: [String: UInt64] = [:]
    private var entries: [Entry] = []
    private var seen = Set<String>()   // message.id + requestId (Claude Code loggt Antworten teils mehrfach)

    private static let keep: TimeInterval = 8 * 86400
    private static let chunkSize = 4 << 20

    private static let roots: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs = [home.appendingPathComponent(".claude/projects"),
                    home.appendingPathComponent(".config/claude/projects")]
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            dirs.insert(URL(fileURLWithPath: custom).appendingPathComponent("projects"), at: 0)
        }
        return dirs
    }()

    /// fiveHourStart / weekStart: Beginn der Fenster laut API (Reset − 5 h bzw. − 7 T)
    func stats(fiveHourStart: Date, weekStart: Date) -> TokenStats {
        scan()
        return TokenStats(fiveHour: summarize(since: fiveHourStart),
                          week: summarize(since: weekStart))
    }

    private func scan() {
        let cutoff = Date().addingTimeInterval(-Self.keep)
        let fm = FileManager.default
        for root in Self.roots {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                         options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let mod = v.contentModificationDate, mod >= cutoff,
                      let size = v.fileSize.map(UInt64.init) else { continue }
                let path = url.path
                var offset = offsets[path] ?? 0
                if size < offset { offset = 0 }          // Datei wurde neu geschrieben
                guard size > offset else { continue }
                offsets[path] = read(url, from: offset, cutoff: cutoff)
            }
        }
        entries.removeAll { $0.date < cutoff }
    }

    /// Liest ab `offset` nur vollständige Zeilen und gibt den neuen Offset zurück.
    private func read(_ url: URL, from offset: UInt64, cutoff: Date) -> UInt64 {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return offset }
        defer { try? fh.close() }
        try? fh.seek(toOffset: offset)
        var pos = offset
        var buffer = Data()
        while true {
            // autoreleasepool: JSONSerialization erzeugt viele Objekte – pro Block wieder freigeben
            let more: Bool = autoreleasepool {
                guard let chunk = try? fh.read(upToCount: Self.chunkSize), !chunk.isEmpty else { return false }
                buffer.append(chunk)
                var lineStart = buffer.startIndex
                while let nl = buffer[lineStart...].firstIndex(of: 0x0A) {
                    parse(buffer[lineStart..<nl], cutoff: cutoff)
                    pos += UInt64(nl - lineStart + 1)
                    lineStart = buffer.index(after: nl)
                }
                buffer = Data(buffer[lineStart...])   // angefangene letzte Zeile behalten
                return true
            }
            if !more { break }
        }
        return pos
    }

    private static let usageMarker = Data("\"usage\"".utf8)
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func parse(_ line: Data, cutoff: Date) {
        // Schneller Vorfilter: die meisten Zeilen (Tool-Ausgaben, User-Nachrichten) haben keine usage
        guard line.range(of: Self.usageMarker) != nil,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "assistant",
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any],
              let ts = obj["timestamp"] as? String,
              let date = Self.iso.date(from: ts), date >= cutoff
        else { return }

        let model = msg["model"] as? String ?? "?"
        if model == "<synthetic>" { return }
        if let id = msg["id"] as? String {
            let key = id + ":" + (obj["requestId"] as? String ?? "")
            guard seen.insert(key).inserted else { return }
        }

        func int(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
        let counts = TokenCounts(input: int("input_tokens"), output: int("output_tokens"),
                                 cacheRead: int("cache_read_input_tokens"),
                                 cacheWrite: int("cache_creation_input_tokens"))
        let project = (obj["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? "?"
        entries.append(Entry(date: date, model: Self.prettyModel(model), project: project, counts: counts))
    }

    private func summarize(since start: Date) -> TokenSummary {
        var s = TokenSummary()
        var models: [String: TokenCounts] = [:]
        var projects: [String: TokenCounts] = [:]
        for e in entries where e.date >= start {
            s.totals += e.counts
            s.requests += 1
            models[e.model, default: TokenCounts()] += e.counts
            projects[e.project, default: TokenCounts()] += e.counts
        }
        s.byModel = models.map { ($0.key, $0.value) }.sorted { $0.counts.io > $1.counts.io }
        s.byProject = projects.map { ($0.key, $0.value) }.sorted { $0.counts.io > $1.counts.io }
        return s
    }

    /// "claude-opus-5-5" → "Opus 5.5", "claude-sonnet-4-5-20250929" → "Sonnet 4.5"
    static func prettyModel(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init).filter { $0 != "claude" && $0.count < 8 }
        guard let family = parts.first(where: { Int($0) == nil }) else { return id }
        let version = parts.filter { Int($0) != nil }.joined(separator: ".")
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
    }
}
