import Foundation
import SQLite3

enum SourceVerdict: Equatable {
    case ok
    case notFound
    case denied
    case failed(String)

    var isOK: Bool { self == .ok }

    var label: String {
        switch self {
        case .ok: return "可读"
        case .notFound: return "文件不存在"
        case .denied: return "需要完全磁盘访问权限"
        case .failed(let m): return "读取失败:\(m)"
        }
    }
}

enum ROSqliteError: LocalizedError {
    case open(String)
    case prepare(String)
    case noSource

    var errorDescription: String? {
        switch self {
        case .open(let m): return "打开数据库副本失败:\(m)"
        case .prepare(let m): return "SQL 执行失败:\(m)"
        case .noSource: return "没有可读的数据源文件"
        }
    }
}

enum ROSqlite {


    static var fdaProbe: String { DataHome.path + "/Library/Safari/History.db" }

    static func fdaDenied() -> Bool { triage(fdaProbe) == .denied }

    static func fdaGranted() -> Bool {
        guard let fh = FileHandle(forReadingAtPath: fdaProbe) else { return false }
        defer { try? fh.close() }
        return (try? fh.read(upToCount: 16)) != nil
    }

    static func triage(_ path: String) -> SourceVerdict {
        var st = stat()
        if stat(path, &st) != 0 {
            return (errno == EPERM || errno == EACCES) ? .denied : .notFound
        }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            return FileManager.default.isReadableFile(atPath: path) ? .ok : .denied
        }
        guard let fh = FileHandle(forReadingAtPath: path) else { return .denied }
        defer { try? fh.close() }
        do {
            _ = try fh.read(upToCount: 1)
            return .ok
        } catch {
            return .denied
        }
    }


    private static func signature(of path: String) -> [String] {
        ["", "-wal"].map { suffix in
            guard let a = try? FileManager.default.attributesOfItem(atPath: path + suffix),
                  let size = a[.size] as? NSNumber,
                  let mtime = a[.modificationDate] as? Date else { return "-" }
            return "\(size.int64Value):\(mtime.timeIntervalSince1970)"
        }
    }

    private static func snapshot(_ src: String, into dstDir: String, attempts: Int = 3) throws -> String {
        let fm = FileManager.default
        let dst = (dstDir as NSString).appendingPathComponent("snapshot.db")
        for _ in 0..<attempts {
            let before = signature(of: src)
            try? fm.removeItem(atPath: dst)
            try fm.copyItem(atPath: src, toPath: dst)

            let wal = src + "-wal"
            try? fm.removeItem(atPath: dst + "-wal")
            if fm.fileExists(atPath: wal) {
                try? fm.copyItem(atPath: wal, toPath: dst + "-wal")
            }
            try? fm.removeItem(atPath: dst + "-shm")

            if signature(of: src) == before { break }
        }
        return dst
    }


    struct Table {
        var columns: [String]
        var rows: [[String]]
    }

    static func query(sources: [String], sql: String) throws -> Table {
        try query(sources: sources, sqls: [sql])[0]
    }

    static func query(sources: [String], sqls: [String]) throws -> [Table] {
        guard !sources.isEmpty else { throw ROSqliteError.noSource }
        var merged = sqls.map { _ in Table(columns: [], rows: []) }
        var failures: [String] = []

        for src in sources {
            do {
                let ts = try queryOne(source: src, sqls: sqls)
                for (i, t) in ts.enumerated() {
                    if merged[i].columns.isEmpty { merged[i].columns = t.columns }
                    merged[i].rows.append(contentsOf: t.rows)
                }
            } catch {
                failures.append("第 \(failures.count + 1) 个失败的来源 \((src as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            throw ROSqliteError.prepare("\(sources.count) 个来源中 \(failures.count) 个读取失败 —— " + failures.joined(separator: "; "))
        }
        return merged
    }

    private static func queryOne(source: String, sqls: [String]) throws -> [Table] {
        let fm = FileManager.default
        let tmp = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("notihub-data-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(atPath: tmp) }

        let copy = try snapshot(source, into: tmp)

        var db: OpaquePointer?
        let rc = sqlite3_open_v2(copy, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let handle = db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            sqlite3_close(db)
            throw ROSqliteError.open(msg)
        }
        defer { sqlite3_close(handle) }
        sqlite3_create_function_v2(handle, "imsg_body", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC,
                                   nil, imsgBodyFunction, nil, nil, nil)
        return try sqls.map { try run(handle, $0) }
    }

    private static let imsgBodyFunction: @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Void = { ctx, argc, argv in
        guard argc == 1, let v = argv?[0], sqlite3_value_type(v) == SQLITE_BLOB,
              let p = sqlite3_value_blob(v) else {
            sqlite3_result_text(ctx, "", 0, nil)   // 空串(静态),不是 NULL:COALESCE 链与自检都按 '' 判「解不出」
            return
        }
        let body = IMessageBody.decode(Data(bytes: p, count: Int(sqlite3_value_bytes(v))))
        sqlite3_result_text(ctx, body, -1, SQLITE_TRANSIENT)
    }

    private static func run(_ handle: OpaquePointer, _ sql: String) throws -> Table {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt else {
            let msg = String(cString: sqlite3_errmsg(handle))
            sqlite3_finalize(stmt)
            throw ROSqliteError.prepare(msg)
        }
        defer { sqlite3_finalize(st) }

        let ncol = Int(sqlite3_column_count(st))
        var columns: [String] = []
        for i in 0..<ncol {
            columns.append(sqlite3_column_name(st, Int32(i)).map { String(cString: $0) } ?? "col\(i)")
        }

        var rows: [[String]] = []
        var step = sqlite3_step(st)
        while step == SQLITE_ROW {
            var row: [String] = []
            row.reserveCapacity(ncol)
            for i in 0..<ncol {
                row.append(cell(st, Int32(i)))
            }
            rows.append(row)
            step = sqlite3_step(st)
        }
        guard step == SQLITE_DONE else {
            throw ROSqliteError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        return Table(columns: columns, rows: rows)
    }

    private static func cell(_ st: OpaquePointer, _ i: Int32) -> String {
        switch sqlite3_column_type(st, i) {
        case SQLITE_NULL:
            return ""
        case SQLITE_INTEGER:
            return String(sqlite3_column_int64(st, i))
        case SQLITE_FLOAT:
            let d = sqlite3_column_double(st, i)
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(format: "%.3f", d)
        case SQLITE_BLOB:
            return "<二进制 \(sqlite3_column_bytes(st, i)) 字节>"
        default:
            guard let c = sqlite3_column_text(st, i) else { return "" }
            return String(cString: c)
        }
    }
}
