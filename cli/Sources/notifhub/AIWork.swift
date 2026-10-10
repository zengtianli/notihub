import Foundation

enum AIWork {

    static let claudeBundle = "ai.claude"
    static let codexBundle = "ai.codex"
    static let canons: Set<String> = ["claude", "codex"]
    static let privateLabel = "私密事项"

    struct Roots {
        var claudeHistory: URL
        var codexHistory: URL
        var claudeProjects: URL
        var codexSessions: [URL]

        static var standard: Roots {
            let h = Paths.home
            return Roots(claudeHistory: h.appendingPathComponent(".claude/history.jsonl"),
                         codexHistory: h.appendingPathComponent(".codex/history.jsonl"),
                         claudeProjects: h.appendingPathComponent(".claude/projects"),
                         codexSessions: [h.appendingPathComponent(".codex/sessions"),
                                         h.appendingPathComponent(".codex/archived_sessions")])
        }
    }

    struct Collected { var prompts = 0; var minutes = 0; var files = 0; var bytes: Int64 = 0; var skipped = false }


    @discardableResult
    static func collect(store: Store, config: Config, roots: Roots = .standard,
                        now: Double = nowUnix()) -> Collected {
        var c = Collected()
        guard config.ai.enabled else { return c }
        Paths.ensureDataDir()
        let lockPath = Paths.dataDir.appendingPathComponent("ai-collect.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if fd >= 0 { close(fd) }
            c.skipped = true
            return c
        }
        defer { flock(fd, LOCK_UN); close(fd) }
        let cutoff = now - Double(max(1, config.ai.backfillDays)) * 86400
        var labels = Labeler(config: config)
        bytesRead = 0
        scanCodex(store: store, roots: roots, cutoff: cutoff, labels: &labels, into: &c)
        scanClaude(store: store, roots: roots, cutoff: cutoff, labels: &labels, into: &c)
        importClaudeHistory(store: store, url: roots.claudeHistory, cutoff: cutoff,
                            config: config, labels: &labels, into: &c)
        importCodexHistory(store: store, roots: roots, cutoff: cutoff,
                           config: config, labels: &labels, into: &c)
        store.setWatermark("ai.lastCollect", "\(now)")
        c.bytes = bytesRead
        return c
    }

    private static func newLines(store: Store, url: URL, _ body: (Data, inout String) -> Void,
                                 then finish: () -> Void = {}) -> Bool {
        let path = url.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return false }
        var offset: Int64 = 0
        var meta = ""
        store.db.query("SELECT offset, COALESCE(meta,'') FROM ai_files WHERE path=?", [path]) {
            offset = $0.int(0); meta = $0.str(1)
        }
        if size < offset { offset = 0; meta = "" }
        guard size > offset, let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        try? fh.seek(toOffset: UInt64(offset))
        var consumed: Int64 = 0
        var carry = Data()
        while let block = autoreleasepool(invoking: { try? fh.read(upToCount: 8 << 20) }), !block.isEmpty {
            carry.append(block)
            guard let lastNL = carry.lastIndex(of: 0x0A) else { continue }
            var start = carry.startIndex
            while start <= lastNL {
                let end = carry[start...lastNL].firstIndex(of: 0x0A)!
                if end > start { autoreleasepool { body(carry[start..<end], &meta) } }
                start = end + 1
            }
            consumed += Int64(start - carry.startIndex)
            carry = Data(carry[start...])
        }
        guard consumed > 0 else { return false }
        bytesRead += consumed
        store.db.exec("BEGIN")
        defer { store.db.exec("COMMIT") }
        finish()
        store.db.run("INSERT INTO ai_files(path,offset,meta) VALUES(?,?,?) "
                     + "ON CONFLICT(path) DO UPDATE SET offset=excluded.offset, meta=excluded.meta",
                     [path, offset + consumed, meta])
        return true
    }

    private static var bytesRead: Int64 = 0

    private static func json(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    struct LogLine: Decodable {
        var timestamp: String?
        var type: String?
        var cwd: String?
        var entrypoint: String?
        var sessionId: String?
        var payload: Payload?

        struct Payload: Decodable {
            var cwd: String?
            var originator: String?
            var id: String?
            var session_id: String?
            var source: String?
            enum K: String, CodingKey { case cwd, originator, id, session_id, source }
            init(from d: Decoder) throws {
                let c = try d.container(keyedBy: K.self)
                cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
                originator = try? c.decodeIfPresent(String.self, forKey: .originator)
                id = try? c.decodeIfPresent(String.self, forKey: .id)
                session_id = try? c.decodeIfPresent(String.self, forKey: .session_id)
                source = try? c.decodeIfPresent(String.self, forKey: .source)
            }
        }
    }
    private static let decoder = JSONDecoder()
    private static func logLine(_ line: Data) -> LogLine? { try? decoder.decode(LogLine.self, from: line) }

    private static func jsonlFiles(under root: URL, cutoff: Double) -> [URL] {
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let u as URL in en where u.pathExtension == "jsonl" {
            let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard v?.isRegularFile == true,
                  (v?.contentModificationDate?.timeIntervalSince1970 ?? 0) >= cutoff else { continue }
            out.append(u)
        }
        return out
    }

    private static func addMinutes(_ store: Store, tool: String, _ set: Set<String>, into c: inout Collected) {
        for key in set {
            let parts = key.split(separator: "\u{1F}", maxSplits: 1)
            guard parts.count == 2, let m = Int64(parts[0]) else { continue }
            store.db.run("INSERT OR IGNORE INTO ai_minutes(minute,tool,project) VALUES(?,?,?)",
                         [m, tool, String(parts[1])])
            c.minutes += store.db.changes
        }
    }

    static func scanClaude(store: Store, roots: Roots, cutoff: Double,
                           labels: inout Labeler, into c: inout Collected) {
        for f in jsonlFiles(under: roots.claudeProjects, cutoff: cutoff) {
            var mins = Set<String>()
            var moves: [(String, Int64, String)] = []
            let isMain = !f.path.contains("/subagents/")
            let read = newLines(store: store, url: f) { line, meta in
                guard let o = logLine(line), let ts = o.timestamp.flatMap(parseISO) else { return }
                if let ep = o.entrypoint, ep.hasPrefix("sdk") { return }
                if let cwd = o.cwd, !cwd.isEmpty, cwd != meta {
                    meta = cwd
                    if isMain, let sid = o.sessionId { moves.append((sid, Int64(ts / 60), cwd)) }
                }
                guard !meta.isEmpty, ts >= cutoff else { return }
                mins.insert("\(Int64(ts / 60))\u{1F}\(labels.label(meta))")
            } then: {
                addMinutes(store, tool: "claude", mins, into: &c)
                addMoves(store, moves)
            }
            if read { c.files += 1 }
        }
    }

    static func scanCodex(store: Store, roots: Roots, cutoff: Double,
                          labels: inout Labeler, into c: inout Collected) {
        for root in roots.codexSessions {
            for f in jsonlFiles(under: root, cutoff: cutoff) {
                var mins = Set<String>()
                var moves: [(String, Int64, String)] = []
                let read = newLines(store: store, url: f) { line, meta in
                    guard meta != "skip", let o = logLine(line) else { return }
                    let payload = o.payload
                    let ts = o.timestamp.flatMap(parseISO)
                    let parts = meta.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
                    var sid = parts.count == 2 ? String(parts[0]) : ""
                    var cwd = parts.count == 2 ? String(parts[1]) : ""
                    var newCwd: String? = nil
                    switch o.type {
                    case "session_meta":
                        if payload?.originator == "codex_exec" || payload?.source == "exec" { meta = "skip"; return }
                        sid = payload?.id ?? payload?.session_id ?? sid
                        newCwd = payload?.cwd
                    case "turn_context":
                        newCwd = payload?.cwd
                    default: break
                    }
                    if let w = newCwd, !w.isEmpty, w != cwd {
                        cwd = w
                        if !sid.isEmpty, let ts { moves.append((sid, Int64(ts / 60), cwd)) }
                    }
                    meta = sid + "\u{1F}" + cwd
                    guard !cwd.isEmpty, let ts, ts >= cutoff else { return }
                    mins.insert("\(Int64(ts / 60))\u{1F}\(labels.label(cwd))")
                } then: {
                    addMinutes(store, tool: "codex", mins, into: &c)
                    addMoves(store, moves)
                }
                if read { c.files += 1 }
            }
        }
    }

    private static func addMoves(_ store: Store, _ moves: [(String, Int64, String)]) {
        for (sid, m, cwd) in moves {
            store.db.run("INSERT OR REPLACE INTO ai_cwd(sid,minute,cwd) VALUES(?,?,?)", [sid, m, cwd])
        }
    }

    static func cwdAt(_ store: Store, sid: String, ts: Double) -> String? {
        guard !sid.isEmpty else { return nil }
        var v: String?
        store.db.query("SELECT cwd FROM ai_cwd WHERE sid=? AND minute<=? ORDER BY minute DESC LIMIT 1",
                       [sid, Int64(ts / 60)]) { v = $0.str(0) }
        return v
    }

    static func worthKeeping(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if t.hasPrefix("/") && !t.contains(where: { $0 == " " || $0 == "\n" }) { return false }
        return true
    }

    private static func insertPrompt(_ store: Store, bundle: String, app: String, ts: Double,
                                     cwd: String, sid: String, text: String, config: Config,
                                     labels: inout Labeler, into c: inout Collected) {
        guard worthKeeping(text) else { return }
        let priv = labels.isPrivate(cwd)
        let body = priv ? "（私密目录，输入内容未采集）"
                        : text.trimmingCharacters(in: .whitespacesAndNewlines).truncated(config.ai.maxPromptChars)
        let e = Event(ts: ts, source: app == "Codex" ? "codex" : "claude", bundle: bundle, app: app,
                      title: labels.label(cwd), subtitle: priv ? "" : labels.shortPath(cwd),
                      body: body, extID: sid, recID: nil)
        if store.insert(e) != nil { c.prompts += 1 }
    }

    static func importClaudeHistory(store: Store, url: URL, cutoff: Double, config: Config,
                                    labels: inout Labeler, into c: inout Collected) {
        var rows: [(Double, String, String, String)] = []
        _ = newLines(store: store, url: url) { line, _ in
            guard let o = json(line), let ms = (o["timestamp"] as? NSNumber)?.doubleValue,
                  ms / 1000 >= cutoff, let text = o["display"] as? String else { return }
            rows.append((ms / 1000, o["project"] as? String ?? "", o["sessionId"] as? String ?? "", text))
        } then: {
            for (ts, launch, sid, text) in rows {
                let cwd = cwdAt(store, sid: sid, ts: ts) ?? launch
                insertPrompt(store, bundle: claudeBundle, app: "Claude Code", ts: ts, cwd: cwd, sid: sid,
                             text: text, config: config, labels: &labels, into: &c)
            }
        }
    }

    static func importCodexHistory(store: Store, roots: Roots, cutoff: Double, config: Config,
                                   labels: inout Labeler, into c: inout Collected) {
        var rows: [(Double, String, String)] = []
        _ = newLines(store: store, url: roots.codexHistory) { line, _ in
            guard let o = json(line), let ts = (o["ts"] as? NSNumber)?.doubleValue, ts >= cutoff,
                  let text = o["text"] as? String else { return }
            rows.append((ts, o["session_id"] as? String ?? "", text))
        } then: {
            insertCodex(store, rows: rows, roots: roots, config: config, labels: &labels, into: &c)
        }
    }

    private static func insertCodex(_ store: Store, rows: [(Double, String, String)], roots: Roots,
                                    config: Config, labels: inout Labeler, into c: inout Collected) {
        var byFile: [String: URL]? = nil
        for (ts, sid, text) in rows {
            var cwd = cwdAt(store, sid: sid, ts: ts) ?? ""
            if cwd.isEmpty, !sid.isEmpty {
                if byFile == nil {
                    byFile = [:]
                    for root in roots.codexSessions {
                        let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
                        while let u = en?.nextObject() as? URL {
                            let n = u.deletingPathExtension().lastPathComponent
                            if n.hasPrefix("rollout-"), n.count > 36 { byFile![String(n.suffix(36))] = u }
                        }
                    }
                }
                if let u = byFile?[sid], let fh = try? FileHandle(forReadingFrom: u) {
                    let head = (try? fh.read(upToCount: 65536)) ?? Data()
                    try? fh.close()
                    if let nl = head.firstIndex(of: 0x0A) ?? (head.isEmpty ? nil : head.endIndex),
                       let o = json(head[..<nl]),
                       let p = o["payload"] as? [String: Any], let w = p["cwd"] as? String {
                        cwd = w
                        addMoves(store, [(sid, 0, cwd)])
                    }
                }
            }
            insertPrompt(store, bundle: codexBundle, app: "Codex", ts: ts, cwd: cwd, sid: sid,
                         text: text, config: config, labels: &labels, into: &c)
        }
    }


    struct Labeler {
        static let groups: Set<String> = ["projects", "shared", "bids", "services", "tools", "content",
                                          "assistance", "writing", "cli", "ios", "mac", "web", "mini",
                                          "vendor", "oss", "_archive", "topics", "lib", "apps"]
        let home: String
        let privates: [String]
        private var cache: [String: String] = [:]

        init(config: Config, home: String = Paths.home.path) {
            self.home = home
            privates = config.ai.privatePaths.map {
                let p = ($0 as NSString).expandingTildeInPath
                return p.hasSuffix("/") ? String(p.dropLast()) : p
            }
        }

        private func real(_ cwd: String) -> String {
            URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
        }

        func isPrivate(_ cwd: String) -> Bool {
            if cwd.isEmpty { return false }
            let paths = Set([cwd, real(cwd)])
            return privates.contains { p in paths.contains { $0 == p || $0.hasPrefix(p + "/") } }
        }

        func shortPath(_ cwd: String) -> String {
            cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
        }

        mutating func label(_ cwd: String) -> String {
            if let v = cache[cwd] { return v }
            let v = compute(cwd)
            cache[cwd] = v
            return v
        }

        private func compute(_ cwd: String) -> String {
            if cwd.isEmpty { return "未知目录" }
            if isPrivate(cwd) { return AIWork.privateLabel }
            let path = real(cwd)
            if path.hasPrefix("/private/tmp") || path.hasPrefix("/tmp") || path.hasPrefix("/private/var") {
                return "临时目录"
            }
            guard path == home || path.hasPrefix(home + "/") else {
                return URL(fileURLWithPath: path).lastPathComponent
            }
            let comps = path.dropFirst(home.count).split(separator: "/").map(String.init)
            guard let first = comps.first else { return "~" }
            var out = [first]
            for comp in comps.dropFirst() {
                out.append(comp)
                if !Self.groups.contains(comp.lowercased()) { break }
            }
            return out.joined(separator: "/")
        }
    }


    struct Row {
        var project: String
        var minutes: Int
        var byTool: [(String, Int)]   // [(Claude Code, 50), (Codex, 30)]
        var prompts: Int
        var first: Double
        var last: Double
    }

    struct Day {
        var wallMinutes: Int          // 全天去重（并行会话不重复计）
        var idleMinutes: Int
        var prompts: Int
        var rows: [Row]
    }

    static func toolName(_ t: String) -> String { t == "codex" ? "Codex" : "Claude Code" }

    static func activeMinutes(_ minutes: [Int64], idle: Int) -> Int {
        let s = Array(Set(minutes)).sorted()
        guard var prev = s.first else { return 0 }
        var total = 1
        for m in s.dropFirst() {
            let gap = Int(m - prev)
            total += gap <= idle ? gap : 1
            prev = m
        }
        return total
    }

    static func dayBounds(_ date: String) -> (Double, Double)? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = displayTZ
        guard let start = f.date(from: date) else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = displayTZ
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return (start.timeIntervalSince1970, end.timeIntervalSince1970)
    }

    static func day(store: Store, date: String, config: Config) -> Day? {
        guard let (start, end) = dayBounds(date) else { return nil }
        let idle = max(1, config.ai.idleMinutes)
        var perProject: [String: [String: [Int64]]] = [:]
        var all: [Int64] = []
        store.db.query("SELECT minute, tool, project FROM ai_minutes WHERE minute >= ? AND minute < ?",
                       [Int64(start / 60), Int64((end - 1) / 60) + 1]) { r in
            let m = r.int(0)
            perProject[r.str(2), default: [:]][r.str(1), default: []].append(m)
            all.append(m)
        }
        var prompts: [String: Int] = [:]
        store.db.query("""
            SELECT title, COUNT(*) FROM events
             WHERE canon IN ('claude','codex') AND \(Clock.sqlDay("ts")) = ? GROUP BY title
            """, [date]) { prompts[$0.str(0)] = Int($0.int(1)) }
        if perProject.isEmpty && prompts.isEmpty { return nil }

        var rows: [Row] = []
        for project in Set(perProject.keys).union(prompts.keys) {
            let tools = perProject[project] ?? [:]
            let merged = tools.values.flatMap { $0 }
            rows.append(Row(project: project,
                            minutes: activeMinutes(merged, idle: idle),
                            byTool: tools.map { (toolName($0.key), activeMinutes($0.value, idle: idle)) }
                                .sorted { ($0.1, $1.0) > ($1.1, $0.0) },
                            prompts: prompts[project] ?? 0,
                            first: Double(merged.min() ?? 0) * 60,
                            last: Double(merged.max() ?? 0) * 60))
        }
        rows.sort { ($0.minutes, $0.prompts, $1.project) > ($1.minutes, $1.prompts, $0.project) }
        return Day(wallMinutes: activeMinutes(all, idle: idle), idleMinutes: idle,
                   prompts: prompts.values.reduce(0, +), rows: rows)
    }

    static func fmtDuration(_ m: Int) -> String {
        m >= 60 ? "\(m / 60)h\(m % 60 == 0 ? "" : String(format: "%02dm", m % 60))" : "\(m)m"
    }

    static func summaryBlock(_ d: Day) -> String {
        var s = "AI 协作用时（会话日志算，间隔≤\(d.idleMinutes)分钟视为连续；全天去重合计 \(fmtDuration(d.wallMinutes))）：\n"
        for r in d.rows {
            let tools = r.byTool.map { "\($0.0) \(fmtDuration($0.1))" }.joined(separator: "，")
            s += "- \(r.project)：\(fmtDuration(r.minutes))\(tools.isEmpty ? "" : "（\(tools)）")，输入 \(r.prompts) 条\n"
        }
        return s
    }


    static func parseISO(_ s: String) -> Double? {
        let u = Array(s.utf8)
        func num(_ a: Int, _ n: Int) -> Int? {
            guard a + n <= u.count else { return nil }
            var v = 0
            for i in a..<(a + n) {
                let c = Int(u[i]) - 48
                guard c >= 0 && c <= 9 else { return nil }
                v = v * 10 + c
            }
            return v
        }
        if u.count >= 20, u.last == 90 /* Z */, u[4] == 45, u[10] == 84,
           let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
           let h = num(11, 2), let mi = num(14, 2), let se = num(17, 2) {
            let yy = mo <= 2 ? y - 1 : y
            let era = (yy >= 0 ? yy : yy - 399) / 400
            let yoe = yy - era * 400
            let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            let days = era * 146097 + doe - 719468
            return Double(days * 86400 + h * 3600 + mi * 60 + se)
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)?.timeIntervalSince1970
    }
}
