import Foundation


enum ExportFormat: String, CaseIterable, Identifiable {
    case csv = "CSV"
    case json = "JSON"
    var id: String { rawValue }
    var ext: String { self == .csv ? "csv" : "json" }
}

struct ExportOutcome {
    var directory: String
    var files: [(name: String, rows: Int)]
    var skipped: [(domain: String, reason: String)]
}

enum Exporter {

    static func export(domains: [DataDomain],
                       results: [String: DomainResult],
                       format: ExportFormat,
                       masked: Bool,
                       to directory: URL) throws -> ExportOutcome {
        let directory = directory.appendingPathComponent("export-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var outcome = ExportOutcome(directory: directory.path, files: [], skipped: [])

        for domain in domains {
            guard let r = results[domain.id] else {
                outcome.skipped.append((domain.name, "尚未扫描"))
                continue
            }
            guard r.isUsable else {
                outcome.skipped.append((domain.name, r.failure ?? r.verdict.label))
                continue
            }
            guard !r.rows.isEmpty else {
                outcome.skipped.append((domain.name, "读到 0 条(数据源为空,不是失败)"))
                continue
            }

            let rows = masked ? Masker.apply(r.rows, columns: domain.sensitiveColumns) : r.rows
            let body: String = format == .csv
                ? csv(columns: r.columns, rows: rows)
                : json(columns: r.columns, rows: rows)

            let url = directory.appendingPathComponent("\(domain.id).\(format.ext)")
            let data = (format == .csv ? "\u{FEFF}" + body : body).data(using: .utf8) ?? Data()
            try data.write(to: url, options: .atomic)
            outcome.files.append((url.lastPathComponent, rows.count))
        }

        let manifest = manifestText(domains: domains, results: results,
                                    format: format, masked: masked, outcome: outcome)
        try manifest.data(using: .utf8)?.write(
            to: directory.appendingPathComponent("导出说明.md"), options: .atomic)
        return outcome
    }


    static func csv(columns: [String], rows: [[String]]) -> String {
        var out = columns.map(escape).joined(separator: ",")
        out.append("\n")
        for row in rows {
            out.append(row.map(escape).joined(separator: ","))
            out.append("\n")
        }
        return out
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func json(columns: [String], rows: [[String]]) -> String {
        let objects: [[String: String]] = rows.map { row in
            var d: [String: String] = [:]
            for (i, c) in columns.enumerated() where i < row.count { d[c] = row[i] }
            return d
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: objects,
            options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }


    private static func manifestText(domains: [DataDomain],
                                     results: [String: DomainResult],
                                     format: ExportFormat,
                                     masked: Bool,
                                     outcome: ExportOutcome) -> String {
        var lines: [String] = []
        lines.append("# Notihub 本机数据导出说明")
        lines.append("")
        lines.append("- 导出时间:\(Extractor.formatTime(String(Int(Date().timeIntervalSince1970)))) (\(Clock.tz.identifier))")
        lines.append("- 格式:\(format.rawValue)")
        lines.append("- 脱敏:\(masked ? "开(电话/邮箱已打码)" : "关(原值)")")
        lines.append("- 读取方式:db + `-wal` 快照到临时目录后只读打开副本,**原库全程只被 read()**")
        lines.append("")
        lines.append("## 已导出")
        lines.append("")
        lines.append("| 域 | 文件 | 条数 | 是否触到上限 | 数据源 |")
        lines.append("|---|---|---|---|---|")
        for domain in domains {
            guard let r = results[domain.id],
                  let f = outcome.files.first(where: { $0.name.hasPrefix(domain.id + ".") }) else { continue }
            let src = domain.sources.map(\.display).joined(separator: "<br>")
            lines.append("| \(domain.name) | `\(f.name)` | \(f.rows) | \(r.truncated ? "**是,可能被截断**" : "否") | `\(src)`\(r.note.map { "<br>\($0)" } ?? "") |")
        }
        if !outcome.skipped.isEmpty {
            lines.append("")
            lines.append("## 未导出")
            lines.append("")
            lines.append("| 域 | 原因 |")
            lines.append("|---|---|")
            for s in outcome.skipped { lines.append("| \(s.domain) | \(s.reason) |") }
        }
        lines.append("")
        lines.append("> 时间列一律按**系统时区**(`/etc/localtime`)格式化,不受 `TZ` 环境变量影响。")
        lines.append("> 本目录只在本机;Notihub 的数据页内容永不上云、不进日报总结。")
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
