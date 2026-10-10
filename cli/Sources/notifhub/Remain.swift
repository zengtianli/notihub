import Foundation

enum Remain {

    static let scanner = ProcessInfo.processInfo.environment["NOTIHUB_REMAIN_SCANNER"] ?? ""

    @discardableResult
    static func emit(outDir: URL, config: Config) -> Bool {
        guard FileManager.default.fileExists(atPath: scanner) else {
            fallback(outDir, "未配置可选扫描器：\(scanner)")
            return false
        }
        guard let py = LLM.findPython(config.summary.python) else {
            fallback(outDir, "找不到 3.10+ 的 python3（remain_deck 复用总部 dashboard_gen，要 3.10+）")
            return false
        }
        let (rc, out) = notifhub.run(py, [scanner, "--out", outDir.path],
                                     stderrToo: true, timeout: 60)
        let htmlPath = outDir.appendingPathComponent("remain.html").path
        if rc == 0, FileManager.default.fileExists(atPath: htmlPath) { return true }
        fallback(outDir, "remain_deck rc=\(rc)\n\(String(out.suffix(800)))")
        return false
    }

    static func fallbackHTML(_ msg: String) -> String {
        """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="robots" content="noindex,nofollow">
        <title>未完成 · remain（生成失败）</title></head>
        <body style="font:15px/1.6 -apple-system,'PingFang SC',sans-serif;background:#fdfcfa;color:#1f2328;padding:32px 18px">
        <h1>⚠ remain 面本轮没生成出来</h1>
        <p>缺席的页面长得像「全清了」，所以放这张占位页。修好后下一轮 publish 自动覆盖。</p>
        <pre style="background:#f2ece4;padding:12px;border-radius:6px;white-space:pre-wrap">\(CLI.esc(msg))</pre>
        <p><a href="index.html">← 通知复盘</a></p></body></html>
        """
    }

    private static func fallback(_ outDir: URL, _ msg: String) {
        Log.err("remain 面生成失败：\(msg)")
        Log.write("publish: remain 面失败 \(msg.prefix(200))")
        try? fallbackHTML(msg).write(to: outDir.appendingPathComponent("remain.html"),
                                     atomically: true, encoding: .utf8)
    }
}
