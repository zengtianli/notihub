import Foundation

struct DomainResult {
    let domainID: String
    var verdict: SourceVerdict = .ok
    var resolvedCount: Int = 0
    var columns: [String] = []
    var rows: [[String]] = []
    var truncated: Bool = false
    var failure: String?
    var scannedAt: Date = Date()
    var note: String? = nil
    var total: Int? = nil

    var rowCount: Int { rows.count }
    var isUsable: Bool { verdict.isOK && failure == nil }

    var exitCode: Int32 {
        if isUsable { return 0 }
        return (verdict == .denied && ROSqlite.fdaDenied()) ? 2 : 1
    }
    var statusLabel: String { failure.map { "读取失败:\($0)" } ?? verdict.label }
}

enum Extractor {

    static var richTextReader: ((URL) -> String?)?

    static let cliRichTextNote = "CLI 为纯文本近似(未用 AppKit 解析 RTF)"

    static func run(_ domain: DataDomain, limit: Int) -> DomainResult {
        var result = DomainResult(domainID: domain.id)
        guard let sources = open(domain, into: &result) else { return result }
        let first = sources[0]

        do {
            let table: ROSqlite.Table
            switch domain.extraction {
            case .sqlite(let sql):
                table = try ROSqlite.query(sources: sources, sql: sql.replacingOccurrences(of: "{LIMIT}", with: String(limit)))
            case .safariBookmarks:
                table = try safariBookmarks(path: first, limit: limit)
            case .stickies:
                table = try stickies(dir: first, limit: limit)
                if richTextReader == nil { result.note = cliRichTextNote }
            case .icloudDrive:
                table = try icloudDrive(root: first, limit: limit)
            }
            if let mismatch = auditColumnDeclarations(domain: domain, columns: table.columns) {
                result.failure = mismatch
                return result
            }
            result.columns = table.columns
            var raw = table.rows
            if sources.count > 1, let col = domain.mergeOrderColumn {
                raw = raw.enumerated().sorted { a, b in
                    let x = a.element.indices.contains(col) ? Int(a.element[col]) ?? Int.min : Int.min
                    let y = b.element.indices.contains(col) ? Int(b.element[col]) ?? Int.min : Int.min
                    return x != y ? x > y : a.offset < b.offset
                }.map(\.element)
            }
            result.rows = format(raw, domain: domain)
            if result.rows.count > limit {
                result.rows = Array(result.rows.prefix(limit))
            }
            result.truncated = result.rows.count >= limit
        } catch {
            result.failure = error.localizedDescription
        }
        return result
    }

    static func verdict(_ domain: DataDomain) -> SourceVerdict {
        var r = DomainResult(domainID: domain.id)
        _ = open(domain, into: &r)
        return r.verdict
    }

    static func count(_ domain: DataDomain) -> DomainResult {
        guard case .sqlite(let sql) = domain.extraction else {
            var r = run(domain, limit: 1_000_000)
            r.total = r.isUsable ? r.rows.count : nil
            r.rows = []
            return r
        }
        var result = DomainResult(domainID: domain.id)
        guard let sources = open(domain, into: &result) else { return result }
        do {
            let t = try ROSqlite.query(sources: sources, sqls: [
                sql.replacingOccurrences(of: "{LIMIT}", with: "0"),
                "SELECT COUNT(*) FROM (\(sql.replacingOccurrences(of: "{LIMIT}", with: "-1")))",
            ])
            if let mismatch = auditColumnDeclarations(domain: domain, columns: t[0].columns) {
                result.failure = mismatch
                return result
            }
            result.columns = t[0].columns
            result.total = t[1].rows.reduce(0) { $0 + (Int($1.first ?? "") ?? 0) }
        } catch {
            result.failure = error.localizedDescription
        }
        return result
    }

    private static func open(_ domain: DataDomain, into result: inout DomainResult) -> [String]? {
        let sources = domain.sources.flatMap { $0.resolve() }
        result.resolvedCount = sources.count
        guard let first = sources.first else {
            let parentDenied = domain.sources.contains { deniedAncestor(of: $0.pattern) }
            result.verdict = (parentDenied || ROSqlite.fdaDenied()) ? .denied : .notFound
            return nil
        }
        result.verdict = ROSqlite.triage(first)
        return result.verdict.isOK ? sources : nil
    }

    private static func deniedAncestor(of pattern: String) -> Bool {
        var dir = DataHome.expand(pattern)
        if let star = dir.firstIndex(of: "*") { dir = String(dir[..<star]) }
        dir = (dir as NSString).deletingLastPathComponent
        while dir.count > 1 {
            switch ROSqlite.triage(dir) {
            case .ok: return (try? FileManager.default.contentsOfDirectory(atPath: dir)) == nil
            case .denied: return true
            default: dir = (dir as NSString).deletingLastPathComponent
            }
        }
        return false
    }

    private static let timeWords = ["时间", "截止", "开始", "结束", "最后打开"]

    static func auditColumnDeclarations(domain: DataDomain, columns: [String]) -> String? {
        let declared = domain.timestampColumns
        for i in declared where i >= columns.count {
            return "列声明对账失败:timestampColumns 含下标 \(i),但本域只有 \(columns.count) 列"
        }
        for i in declared.sorted() where !timeWords.contains(where: { columns[i].contains($0) }) {
            return "列声明对账失败:第 \(i) 列「\(columns[i])」被声明成时间列,但列名不像时间"
        }
        for (i, name) in columns.enumerated()
        where timeWords.contains(where: { name.contains($0) }) && !declared.contains(i) {
            return "列声明对账失败:第 \(i) 列「\(name)」是时间列却没被声明,会原样输出 unix 秒"
        }
        for i in domain.sensitiveColumns where i >= columns.count {
            return "列声明对账失败:sensitiveColumns 含下标 \(i),但本域只有 \(columns.count) 列"
        }
        return nil
    }

    static func formatTime(_ unixSeconds: String, with f: DateFormatter = timeFormatter()) -> String {
        guard let t = Double(unixSeconds), t > 0 else { return "" }
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    static func timeFormatter(_ pattern: String = "yyyy-MM-dd HH:mm:ss") -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Clock.tz
        f.dateFormat = pattern
        return f
    }

    private static func format(_ rows: [[String]], domain: DataDomain) -> [[String]] {
        guard !domain.timestampColumns.isEmpty else { return rows }
        let f = timeFormatter()
        return rows.map { row in
            var r = row
            for i in domain.timestampColumns where i < r.count {
                r[i] = formatTime(r[i], with: f)
            }
            return r
        }
    }


    private static func safariBookmarks(path: String, limit: Int) throws -> ROSqlite.Table {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ROSqliteError.prepare("Bookmarks.plist 结构不是字典")
        }
        var rows: [[String]] = []
        walk(root, folder: [], into: &rows, limit: limit)
        return ROSqlite.Table(columns: ["所在文件夹", "标题", "网址"], rows: rows)
    }

    private static func walk(_ node: [String: Any], folder: [String], into rows: inout [[String]], limit: Int) {
        guard rows.count < limit else { return }
        let children = node["Children"] as? [[String: Any]] ?? []
        for child in children {
            guard rows.count < limit else { return }
            let type = child["WebBookmarkType"] as? String ?? ""
            if type == "WebBookmarkTypeLeaf" {
                let title = (child["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
                let url = child["URLString"] as? String ?? ""
                rows.append([folder.joined(separator: " / "), title, url])
            } else {
                let name = child["Title"] as? String ?? "(未命名)"
                walk(child, folder: folder + [displayFolder(name)], into: &rows, limit: limit)
            }
        }
    }

    private static func displayFolder(_ raw: String) -> String {
        switch raw {
        case "BookmarksBar": return "个人收藏"
        case "BookmarksMenu": return "书签菜单"
        case "com.apple.ReadingList": return "阅读列表"
        default: return raw
        }
    }


    private static func stickies(dir: String, limit: Int) throws -> ROSqlite.Table {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".rtfd") }.sorted()
        var rows: [[String]] = []
        for entry in entries.prefix(limit) {
            let pkg = (dir as NSString).appendingPathComponent(entry)
            let rtf = URL(fileURLWithPath: (pkg as NSString).appendingPathComponent("TXT.rtf"))
            let text: String
            if let reader = richTextReader {
                text = reader(rtf) ?? ""
            } else {
                text = (try? Data(contentsOf: rtf)).map(RTFText.plain) ?? ""
            }
            let mtime = (try? fm.attributesOfItem(atPath: pkg)[.modificationDate] as? Date) ?? nil
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            rows.append([
                (entry as NSString).deletingPathExtension,
                body,
                String(text.count),
                mtime.map { String(Int($0.timeIntervalSince1970)) } ?? "",
            ])
        }
        return ROSqlite.Table(columns: ["便签", "正文", "字数", "修改时间"], rows: rows)
    }


    private static func icloudDrive(root: String, limit: Int) throws -> ROSqlite.Table {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let e = fm.enumerator(at: rootURL, includingPropertiesForKeys: keys,
                                    options: [], errorHandler: nil) else {
            throw ROSqliteError.prepare("无法枚举 iCloud 云盘目录")
        }
        var rows: [[String]] = []
        let rootPath = rootURL.resolvingSymlinksInPath().path
        for case let url as URL in e {
            guard rows.count < limit else { break }
            let isPlaceholder = url.lastPathComponent.hasPrefix(".") && url.pathExtension == "icloud"
            if url.lastPathComponent.hasPrefix(".") && !isPlaceholder {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { e.skipDescendants() }
                continue
            }
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true { continue }
            var rel = url.resolvingSymlinksInPath().path
            if rel.hasPrefix(rootPath + "/") { rel.removeFirst(rootPath.count + 1) }
            let placeholder = url.lastPathComponent.hasPrefix(".") && url.pathExtension == "icloud"
            rows.append([
                rel,
                String(v?.fileSize ?? 0),
                v?.contentModificationDate.map { String(Int($0.timeIntervalSince1970)) } ?? "",
                placeholder ? "仅在云端" : "已下载",
            ])
        }
        return ROSqlite.Table(columns: ["相对路径", "字节数", "修改时间", "状态"], rows: rows)
    }
}


enum RTFText {
    static func plain(_ data: Data) -> String {
        let b = [UInt8](data)
        var out: [UInt16] = []           // UTF-16 码元,\uN 的代理对自然拼上
        var pending: [UInt8] = []        // 连续 \'xx 字节,遇到别的内容时按代码页解
        var codepage: UInt32 = 1252
        var uc = 1, skip = 0
        var depth = 0, skipDepth = Int.max
        var i = 0

        func flush() {
            guard !pending.isEmpty else { return }
            let enc = CFStringConvertEncodingToNSStringEncoding(CFStringConvertWindowsCodepageToEncoding(codepage))
            let s = String(data: Data(pending), encoding: String.Encoding(rawValue: enc))
                ?? String(decoding: pending, as: UTF8.self)
            out.append(contentsOf: s.utf16)
            pending.removeAll()
        }
        func emit(_ s: String) { flush(); if depth < skipDepth { out.append(contentsOf: s.utf16) } }

        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "{") { depth += 1; i += 1; continue }
            if c == UInt8(ascii: "}") { flush(); if depth == skipDepth { skipDepth = .max }; depth -= 1; i += 1; continue }
            if c == 0x0D || c == 0x0A { i += 1; continue }
            if c != UInt8(ascii: "\\") {
                if skip > 0 { skip -= 1 } else if depth < skipDepth { flush(); out.append(UInt16(c)) }
                i += 1; continue
            }
            i += 1
            guard i < b.count else { break }
            let n = b[i]
            if n == UInt8(ascii: "'"), i + 2 < b.count,
               let v = UInt8(String(bytes: b[(i + 1)...(i + 2)], encoding: .ascii) ?? "", radix: 16) {
                i += 3
                if skip > 0 { skip -= 1 } else if depth < skipDepth { pending.append(v) }
                continue
            }
            if n == UInt8(ascii: "*") { if depth < skipDepth { skipDepth = depth }; i += 1; continue }
            if !((n >= 0x41 && n <= 0x5A) || (n >= 0x61 && n <= 0x7A)) {
                switch n {
                case UInt8(ascii: "\\"), UInt8(ascii: "{"), UInt8(ascii: "}"): emit(String(UnicodeScalar(n)))
                case UInt8(ascii: "~"): emit("\u{00A0}")
                case 0x0A, 0x0D: emit("\n")
                default: break
                }
                i += 1; continue
            }
            var word = ""
            while i < b.count, (b[i] >= 0x41 && b[i] <= 0x5A) || (b[i] >= 0x61 && b[i] <= 0x7A) {
                word.append(Character(UnicodeScalar(b[i]))); i += 1
            }
            var num = "", hasNum = false
            if i < b.count, b[i] == UInt8(ascii: "-") { num = "-"; i += 1 }
            while i < b.count, b[i] >= 0x30 && b[i] <= 0x39 { num.append(Character(UnicodeScalar(b[i]))); i += 1; hasNum = true }
            if i < b.count, b[i] == 0x20 { i += 1 }   // 分隔空格属于控制字
            let arg = hasNum ? Int(num) ?? 0 : nil
            switch word {
            case "fonttbl", "colortbl", "expandedcolortbl", "stylesheet", "info", "pict", "listtable", "listoverridetable", "NeXTGraphic":
                if depth < skipDepth { skipDepth = depth }
            case "ansicpg": codepage = UInt32(arg ?? 1252)
            case "uc": uc = arg ?? 1
            case "u":
                if depth < skipDepth, var v = arg {
                    flush()
                    if v < 0 { v += 65536 }
                    out.append(UInt16(truncatingIfNeeded: v))
                }
                skip = uc
            case "par", "line", "sect", "page": emit("\n")
            case "tab": emit("\t")
            case "emdash": emit("\u{2014}")
            case "endash": emit("\u{2013}")
            case "bullet": emit("\u{2022}")
            case "lquote": emit("\u{2018}")
            case "rquote": emit("\u{2019}")
            case "ldblquote": emit("\u{201C}")
            case "rdblquote": emit("\u{201D}")
            default: break
            }
        }
        flush()
        return String(decoding: out, as: UTF16.self)
    }
}


enum Masker {

    static func apply(_ rows: [[String]], columns: Set<Int>) -> [[String]] {
        guard !columns.isEmpty else { return rows }
        return rows.map { row in
            var r = row
            for i in columns where i < r.count { r[i] = mask(r[i]) }
            return r
        }
    }

    static func mask(_ value: String) -> String {
        guard !value.isEmpty else { return value }
        if value.contains(" / ") {
            return value.components(separatedBy: " / ").map(maskOne).joined(separator: " / ")
        }
        return maskOne(value)
    }

    private static func maskOne(_ value: String) -> String {
        if let at = value.firstIndex(of: "@") {
            let local = String(value[value.startIndex..<at])
            let domain = String(value[at...])
            let head = local.prefix(2)
            return head + String(repeating: "*", count: max(1, local.count - 2)) + domain
        }
        let chars = Array(value)
        guard chars.count > 6 else {
            return String(chars.prefix(1)) + String(repeating: "*", count: max(0, chars.count - 1))
        }
        return String(chars.prefix(4)) + String(repeating: "*", count: chars.count - 6) + String(chars.suffix(2))
    }

    static func addr(_ value: String) -> String {
        let s = value.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return value }
        if s.contains(" / ") { return s.components(separatedBy: " / ").map(addr).joined(separator: " / ") }
        return s.count <= 6 ? "***" : "\(s.prefix(4))...\(s.suffix(2))"
    }

    static func applyAddr(_ rows: [[String]], columns: Set<Int>) -> [[String]] {
        guard !columns.isEmpty else { return rows }
        return rows.map { row in
            var r = row
            for i in columns where i < r.count { r[i] = addr(r[i]) }
            return r
        }
    }
}
