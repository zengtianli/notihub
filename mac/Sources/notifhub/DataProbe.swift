import Foundation

enum DataProbe {
    struct Entry: Encodable {
        let id: String
        let status: String
        let rows: Int
        let sources: Int
    }

    static func status(of result: DomainResult) -> String {
        if result.failure != nil { return "corrupt" }
        switch result.verdict {
        case .ok: return "ok"
        case .notFound: return "missing"
        case .denied: return "eperm"
        case .failed: return "corrupt"
        }
    }

    static func entries(_ domains: [DataDomain] = DomainRegistry.all,
                        count: (DataDomain) -> DomainResult = { Extractor.count($0) }) -> [Entry] {
        domains.map { domain in
            let r = count(domain)
            let s = status(of: r)
            return Entry(id: domain.id, status: s, rows: s == "ok" ? (r.total ?? r.rowCount) : 0, sources: r.resolvedCount)
        }
    }

    static func run(output: URL) throws {
        let list = entries()
        var counts: [String: Int] = ["ok": 0, "missing": 0, "eperm": 0, "corrupt": 0]
        for e in list { counts[e.status, default: 0] += 1 }
        let env = ProcessInfo.processInfo.environment
        let terminal = env["TERM_PROGRAM"] != nil || env["TERM"] != nil
        let stamp = ISO8601DateFormatter()
        stamp.timeZone = Clock.tz
        let report: [String: Any] = [
            "schema": "notihub-data-probe/1",
            "generated_at": stamp.string(from: Date()),
            "bundle_id": Bundle.main.bundleIdentifier ?? "",
            "bundle_path": Bundle.main.bundlePath,
            "launched_by_terminal": terminal,
            "tcc_note": terminal
                ? "从终端启动：结果反映终端的完全磁盘访问授权，不代表 Notihub.app"
                : "非终端启动：结果反映启动本进程的 App（open /Applications/Notihub.app 时即 Notihub.app）的授权",
            "summary": counts,
            "domains": try list.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) },
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        print("data-probe: \(list.count) 个域 · ok \(counts["ok"]!) · missing \(counts["missing"]!) · eperm \(counts["eperm"]!) · corrupt \(counts["corrupt"]!) → \(output.path)")
    }
}
