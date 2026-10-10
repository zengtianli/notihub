import Foundation

enum People {

    struct Event {
        let key: String
        let when: Double?     // unix 秒
        let chan: String
        let detail: String
        let text: String
    }

    struct Book {
        var order: [String] = []
        var names: [String: [String]] = [:]
        var orgOf: [String: String] = [:]
    }

    static func norm(_ raw: String) -> String {
        var d = raw.filter(\.isASCII).filter(\.isNumber)
        if d.count > 11 && d.hasPrefix("86") { d.removeFirst(2) }
        if d.count > 11 && d.hasPrefix("0086") { d.removeFirst(4) }
        return d.count >= 11 ? String(d.suffix(11)) : d
    }

    static func appleTime(_ s: String) -> Double? {
        guard let v = Double(s), v != 0 else { return nil }
        return (v > 1e15 ? v / 1e9 : v) + appleEpoch
    }


    enum LoadError: Error { case rc(Int32, String) }

    static func loadBook() throws -> Book {
        let srcs = DomainRegistry.contacts.sources.flatMap { $0.resolve() }
        guard !srcs.isEmpty else {
            throw LoadError.rc(1, "通讯录源一个都没找到: \(DomainRegistry.contacts.sources.map(\.display).joined(separator: " , "))")
        }
        let t = try ROSqlite.query(sources: srcs, sql: """
            SELECT COALESCE(r.ZFIRSTNAME,''), COALESCE(r.ZLASTNAME,''), COALESCE(r.ZORGANIZATION,''),
                   COALESCE(r.ZNICKNAME,''), COALESCE(p.ZFULLNUMBER,'')
            FROM ZABCDRECORD r JOIN ZABCDPHONENUMBER p ON p.ZOWNER = r.Z_PK
            """)
        var b = Book()
        for r in t.rows {
            let (first, last, org, nick, num) = (r[0], r[1], r[2], r[3], r[4])
            var name = last + first
            if name.isEmpty { name = nick.isEmpty ? org : nick }
            name = name.trimmingCharacters(in: .whitespaces)
            let k = norm(num)
            guard !k.isEmpty, !name.isEmpty else { continue }
            if b.names[k] == nil { b.order.append(k); b.names[k] = [] }
            if !name.isEmpty && !(b.names[k]!.contains(name)) { b.names[k]!.append(name) }
            if !name.isEmpty && !org.isEmpty && b.orgOf[name] == nil { b.orgOf[name] = org }
        }
        return b
    }

    private static func sources(of domain: DataDomain) throws -> [String] {
        let srcs = domain.sources.flatMap { $0.resolve() }
        if let first = srcs.first {
            let v = ROSqlite.triage(first)
            if v == .denied && ROSqlite.fdaDenied() {
                throw LoadError.rc(2, "\(domain.name)库读不到且探针证实缺完全磁盘访问权限\n"
                                   + "  系统设置 → 隐私与安全性 → 完全磁盘访问权限 → 加入运行本命令的终端(Notihub.app 要单独授权)")
            }
            if v != .ok { throw LoadError.rc(1, "\(domain.name)库读不到(\(v.label)): \(first)") }
            return srcs
        }
        if ROSqlite.fdaDenied() {
            throw LoadError.rc(2, "\(domain.name)库列不出且探针证实缺完全磁盘访问权限")
        }
        return []
    }

    static func loadCalls() throws -> [Event] {
        let srcs = try sources(of: DomainRegistry.callHistory)
        guard !srcs.isEmpty else { return [] }
        let t = try ROSqlite.query(sources: srcs, sql: """
            SELECT COALESCE(CAST(ZADDRESS AS TEXT),''), ZDATE, CAST(COALESCE(ZDURATION,0) AS INT), COALESCE(ZORIGINATED,0)
            FROM ZCALLRECORD
            """)
        return t.rows.map { r in
            let secs = Int(r[2]) ?? 0, out = r[3] == "1"
            return Event(key: norm(r[0]), when: appleTime(r[1]), chan: out ? "去电" : "来电",
                         detail: secs > 0 ? "\(secs)s" : (out ? "未接通" : "未接"), text: "")
        }
    }

    static func loadMessages() throws -> [Event] {
        let srcs = try sources(of: DomainRegistry.messages)
        guard !srcs.isEmpty else { return [] }
        let t = try ROSqlite.query(sources: srcs, sql: """
            SELECT * FROM (
              SELECT COALESCE(h.id,''), m.date, COALESCE(m.is_from_me,0), COALESCE(m.service,''),
                     \(DomainRegistry.messageBodySQL) AS body
              FROM message m JOIN handle h ON h.ROWID = m.handle_id
            ) WHERE body <> ''
            """)
        return t.rows.map { r in
            let text = r[4].split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return Event(key: norm(r[0]), when: appleTime(r[1]),
                         chan: (r[2] == "1" ? "发出" : "收到") + "·" + (r[3].isEmpty ? "?" : r[3]),
                         detail: "\(r[4].unicodeScalars.count)字", text: text)
        }
    }


    struct Options {
        var query = "", since: String?, until: String?, limit = 60, full = false
    }

    static func command(_ args: [String]) -> Int32 {
        guard let sub = args.first, ["who", "timeline", "stats"].contains(sub) else {
            Log.err("用法: notihub data people who <词> | timeline <词> [--since YYYY-MM-DD --until YYYY-MM-DD --limit 60 --full] | stats")
            return 64
        }
        var o = Options()
        var i = 1
        while i < args.count {
            let a = args[i]
            switch a {
            case "--since": o.since = i + 1 < args.count ? args[i + 1] : nil; i += 1
            case "--until": o.until = i + 1 < args.count ? args[i + 1] : nil; i += 1
            case "--limit": o.limit = max(1, Int(i + 1 < args.count ? args[i + 1] : "") ?? 60); i += 1
            case "--full": o.full = true
            default: if o.query.isEmpty { o.query = a }
            }
            i += 1
        }
        if sub != "stats" && o.query.isEmpty { Log.err("缺关键词:notihub data people \(sub) <姓名/组织/号码>"); return 64 }
        do {
            let book = try loadBook()
            let events = try loadCalls() + loadMessages()
            switch sub {
            case "who": who(o, book, events)
            case "timeline": timeline(o, book, events)
            default: stats(book, events)
            }
            return 0
        } catch LoadError.rc(let rc, let msg) {
            Log.err("[fail] \(msg)"); return rc
        } catch {
            Log.err("[fail] \(error.localizedDescription)"); return 1
        }
    }

    static func resolve(_ kw: String, _ b: Book) -> (Set<String>, [String]) {
        var keys = Set<String>(), names: [String] = []
        let nk = norm(kw)
        for k in b.order {
            let ns = b.names[k] ?? []
            let hit = (!nk.isEmpty && k.contains(nk)) || ns.contains { $0.contains(kw) }
                || ns.contains { (b.orgOf[$0] ?? "").contains(kw) }
            guard hit else { continue }
            keys.insert(k)
            for n in ns where !names.contains(n) { names.append(n) }
        }
        return (keys, names)
    }

    private static func iso(_ t: Double?, _ f: DateFormatter) -> String {
        t.map { f.string(from: Date(timeIntervalSince1970: $0)) } ?? "?"
    }

    private static func who(_ o: Options, _ b: Book, _ events: [Event]) {
        let (keys, names) = resolve(o.query, b)
        guard !keys.isEmpty else { Log.err("(通讯录里没有匹配 '\(o.query)' 的人/组织/号码)"); return }
        var cnt: [String: Int] = [:], last: [String: Double] = [:]
        for e in events where keys.contains(e.key) {
            cnt[e.key, default: 0] += 1
            if let w = e.when, w > (last[e.key] ?? -.infinity) { last[e.key] = w }
        }
        let f = Extractor.timeFormatter("yyyy-MM-dd HH:mm")
        print("匹配 \(keys.count) 个号码 / \(names.count) 个人名")
        for k in b.order.filter(keys.contains).sorted(by: { (cnt[$0] ?? 0) > (cnt[$1] ?? 0) }) {
            let ns = b.names[k] ?? []
            let nameStr = ns.isEmpty ? "(通讯录无名)" : ns.joined(separator: "、")
            let org = ns.compactMap { b.orgOf[$0] }.first ?? ""
            print("  " + CLI.pad(k, 14) + CLI.pad(String(nameStr.prefix(24)), 26) + CLI.pad(String(org.prefix(20)), 22)
                  + "触点 \(String(cnt[k] ?? 0).leftPad(4))  最近 \(iso(last[k], f))")
        }
    }

    private static func timeline(_ o: Options, _ b: Book, _ events: [Event]) {
        var (keys, names) = resolve(o.query, b)
        if keys.isEmpty {
            let nk = norm(o.query)
            guard nk.count >= 7 else { Log.err("(没有匹配 '\(o.query)' 的人/组织/号码)"); return }
            keys = [nk]
            Log.err("[note] '\(o.query)' 不在通讯录, 按号码 \(nk) 直查")
        }
        let f = Extractor.timeFormatter("yyyy-MM-dd HH:mm")
        var sel = events.filter { keys.contains($0.key) && $0.when != nil }
        if let s = o.since { sel = sel.filter { iso($0.when, f).prefix(10) >= s } }
        if let u = o.until { sel = sel.filter { iso($0.when, f).prefix(10) <= u } }
        guard !sel.isEmpty else { Log.err("(该时间窗内 0 条触点)"); return }
        sel.sort { $0.when! < $1.when! }
        let label = names.isEmpty ? o.query : names.prefix(3).joined(separator: "、")
        print("# \(label) —— \(sel.count) 条触点  \(iso(sel.first!.when, f).prefix(10)) → \(iso(sel.last!.when, f).prefix(10))\n")
        for e in sel.suffix(o.limit) {
            let nm = (b.names[e.key] ?? []).joined(separator: "、")
            let body = o.full ? e.text : String(e.text.prefix(40))
            print("\(iso(e.when, f))  " + CLI.pad(e.chan, 10) + CLI.pad(String((nm.isEmpty ? e.key : nm).prefix(12)), 14)
                  + e.detail.leftPad(7) + "  " + body)
        }
        if sel.count > o.limit {
            fflush(stdout)   // 不 flush 的话 stderr 会抢在结果前面打出来
            Log.err("\n(只显示最近 \(o.limit) 条, 共 \(sel.count) 条; --limit 调整)")
        }
    }

    private static func stats(_ b: Book, _ events: [Event]) {
        let known = events.filter { b.names[$0.key] != nil }.count
        print("通讯录号码=\(b.order.count)\t触点总数=\(events.count)\t其中能对上通讯录=\(known) (\(known * 100 / max(events.count, 1))%)")
        let dated = events.compactMap(\.when)
        let f = Extractor.timeFormatter("yyyy-MM-dd")
        if let lo = dated.min(), let hi = dated.max() { print("时间跨度\t\(iso(lo, f)) → \(iso(hi, f))") }
        var ch: [String: Int] = [:]
        for e in events { ch[e.chan, default: 0] += 1 }
        print("\n-- 按渠道 --")
        for (k, v) in ch.sorted(by: { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }) {
            print("  " + CLI.pad(k, 14) + "\(v)")
        }
        var top: [String: Int] = [:]
        for e in events where b.names[e.key] != nil { top[e.key, default: 0] += 1 }
        print("\n-- 触点最多的 10 个联系人(名字脱敏为首字+**) --")
        for (k, v) in top.sorted(by: { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }).prefix(10) {
            let n = b.names[k]?.first ?? "?"
            print("  \(n.prefix(1))**           \(k.prefix(3))****\(k.suffix(4))  \(v)")
        }
    }
}

private extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
