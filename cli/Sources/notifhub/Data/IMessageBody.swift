import Foundation

enum IMessageBody {

    static let objectReplacement = "\u{FFFC}"

    static func decode(_ blob: Data) -> String {
        let b = [UInt8](blob)
        guard let i = find(b, Array("NSString".utf8), from: 0),
              let j = b[i...].firstIndex(of: 0x2B) else { return "" }
        var p = j + 1
        guard p < b.count else { return "" }
        var n = Int(b[p]); p += 1
        let extra = [0x81: 2, 0x82: 3, 0x83: 4][n] ?? 0
        if extra > 0 {
            guard p + extra <= b.count else { return "" }
            n = 0
            for k in 0..<extra { n |= Int(b[p + k]) << (8 * k) }
            p += extra
        }
        let end = min(b.count, p + n)
        guard p <= end, let s = String(bytes: b[p..<end], encoding: .utf8) else { return "" }
        return s.replacingOccurrences(of: objectReplacement, with: "")
    }

    static func body(text: String?, blob: Data?) -> String {
        let t = (text ?? "").replacingOccurrences(of: objectReplacement, with: "")
        if !t.isEmpty { return t }
        return blob.map(decode) ?? ""
    }

    private static func find(_ hay: [UInt8], _ needle: [UInt8], from: Int) -> Int? {
        guard needle.count <= hay.count else { return nil }
        var i = from
        while i <= hay.count - needle.count {
            if hay[i] == needle[0] && Array(hay[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }


    struct SelfCheck {
        var compared = 0
        var matched = 0
        var invisibleOnly = 0
        var recovered = 0
        var withBody = 0
        var mismatched: Int { compared - matched - invisibleOnly }
        var passed: Bool { compared > 0 && mismatched == 0 }
    }

    static func selfCheck(sources: [String]) throws -> SelfCheck {
        let strip = "REPLACE(text,char(65532),'')"
        func invisible(_ e: String) -> String { "REPLACE(REPLACE(REPLACE(\(e),char(65533),''),char(8206),''),char(8207),'')" }
        let t = try ROSqlite.query(sources: sources, sqls: ["""
            SELECT COUNT(*), COALESCE(SUM(\(strip) = imsg_body(attributedBody)),0),
                   COALESCE(SUM(\(strip) <> imsg_body(attributedBody)
                                AND \(invisible(strip)) = \(invisible("imsg_body(attributedBody)"))),0)
            FROM message WHERE text IS NOT NULL AND length(text) > 0 AND attributedBody IS NOT NULL
            """, """
            SELECT COALESCE(SUM(COALESCE(\(strip),'') = '' AND imsg_body(attributedBody) <> ''),0),
                   COALESCE(SUM(COALESCE(\(strip),'') <> '' OR imsg_body(attributedBody) <> ''),0)
            FROM message
            """])
        var r = SelfCheck()
        let a = t[0].rows.reduce(into: [0, 0, 0]) { acc, row in for k in 0..<3 { acc[k] += Int(row[k]) ?? 0 } }
        let b = t[1].rows.reduce(into: [0, 0]) { acc, row in acc[0] += Int(row[0]) ?? 0; acc[1] += Int(row[1]) ?? 0 }
        r.compared = a[0]; r.matched = a[1]; r.invisibleOnly = a[2]; r.recovered = b[0]; r.withBody = b[1]
        return r
    }
}
