import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class DB {
    private var handle: OpaquePointer?
    let path: String

    init?(path: String, readOnly: Bool = false) {
        self.path = path
        let flags = readOnly ? SQLITE_OPEN_READONLY
                             : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            Log.err("打不开数据库 \(path): \(lastError)")
            return nil
        }
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit { if handle != nil { sqlite3_close(handle) } }

    var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    static func readFailed(path: String, rc: Int32, message: String) {
        let corrupt = rc == SQLITE_CORRUPT || rc == SQLITE_NOTADB
        Log.err("读取数据库失败 \(path): \(message)" + (corrupt ? "\n  库文件已损坏：停掉 daemon，把备份放回或移走该文件后重跑（会重建空库）" : ""))
        if corrupt && CommandLine.arguments.dropFirst().first != "daemon" { exit(3) }
    }

    @discardableResult
    func exec(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            Log.err("SQL 失败: \(msg)\n  \(sql.truncated(200))")
            return false
        }
        return true
    }

    func query(_ sql: String, _ binds: [Any?] = [], _ row: (Row) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            Log.err("prepare 失败: \(lastError)\n  \(sql.truncated(200))")
            return
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, binds)
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW { row(Row(stmt!)); rc = sqlite3_step(stmt) }
        if rc != SQLITE_DONE { DB.readFailed(path: path, rc: rc, message: lastError) }
    }

    @discardableResult
    func run(_ sql: String, _ binds: [Any?] = []) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            Log.err("prepare 失败: \(lastError)\n  \(sql.truncated(200))")
            return false
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, binds)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            Log.err("step 失败: \(lastError)")
            return false
        }
        return true
    }

    var changes: Int { Int(sqlite3_changes(handle)) }
    var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }

    private func bind(_ stmt: OpaquePointer?, _ binds: [Any?]) {
        for (i, v) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case nil:               sqlite3_bind_null(stmt, idx)
            case let s as String:   sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case let d as Double:   sqlite3_bind_double(stmt, idx, d)
            case let n as Int:      sqlite3_bind_int64(stmt, idx, Int64(n))
            case let n as Int64:    sqlite3_bind_int64(stmt, idx, n)
            case let b as Bool:     sqlite3_bind_int(stmt, idx, b ? 1 : 0)
            case let d as Data:     _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(d.count), SQLITE_TRANSIENT) }
            default:                sqlite3_bind_text(stmt, idx, "\(v!)", -1, SQLITE_TRANSIENT)
            }
        }
    }

    struct Row {
        let stmt: OpaquePointer
        init(_ s: OpaquePointer) { stmt = s }
        func str(_ i: Int32) -> String {
            guard let c = sqlite3_column_text(stmt, i) else { return "" }
            return String(cString: c)
        }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func dbl(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
        func data(_ i: Int32) -> Data {
            guard let p = sqlite3_column_blob(stmt, i) else { return Data() }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
        }
    }
}


final class Store {
    let db: DB
    private(set) var ftsEnabled = false

    init?() {
        Paths.ensureDataDir()
        Store.tightenFiles()
        guard let d = DB(path: Paths.db.path) else { return nil }
        db = d
        guard db.exec("SELECT count(*) FROM sqlite_master;") else {
            Log.err("数据库损坏或不是 SQLite 文件：\(Paths.db.path)\n  停掉 daemon，把备份放回或移走该文件后重跑（会重建空库）")
            return nil
        }
        db.exec("PRAGMA journal_mode=WAL;")
        db.exec("PRAGMA synchronous=NORMAL;")
        migrate()
        Store.tightenFiles()
    }

    init?(readOnlyAt path: String) {
        guard FileManager.default.fileExists(atPath: path), let d = DB(path: path, readOnly: true) else { return nil }
        db = d
        guard db.exec("SELECT count(*) FROM sqlite_master;") else {
            Log.err("数据库损坏或不是 SQLite 文件：\(path)")
            return nil
        }
        var fts = false
        db.query("SELECT 1 FROM sqlite_master WHERE type='table' AND name='events_fts'") { _ in fts = true }
        ftsEnabled = fts
    }

    private static func tightenFiles() {
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: Paths.db.path + suffix) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.db.path + suffix)
        }
    }

    private func migrate() {
        db.exec("""
        CREATE TABLE IF NOT EXISTS events (
          id         INTEGER PRIMARY KEY,
          ts         REAL NOT NULL,
          source     TEXT NOT NULL,
          bundle     TEXT NOT NULL,
          canon      TEXT NOT NULL,
          app        TEXT NOT NULL,
          title      TEXT,
          subtitle   TEXT,
          body       TEXT,
          ext_id     TEXT,
          rec_id     INTEGER,
          dedup_key  TEXT NOT NULL UNIQUE,
          redacted   INTEGER NOT NULL DEFAULT 0,
          dismissed_at REAL,
          renotified INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts DESC);
        CREATE INDEX IF NOT EXISTS idx_events_canon ON events(canon, ts DESC);
        CREATE INDEX IF NOT EXISTS idx_events_open ON events(renotified, dismissed_at) WHERE rec_id IS NOT NULL;

        CREATE TABLE IF NOT EXISTS state (k TEXT PRIMARY KEY, v TEXT NOT NULL);

        CREATE TABLE IF NOT EXISTS actions (
          id       INTEGER PRIMARY KEY,
          event_id INTEGER NOT NULL,
          ts       REAL NOT NULL,
          rule     TEXT NOT NULL,
          action   TEXT NOT NULL,
          detail   TEXT,
          ok       INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_actions_event ON actions(event_id);

        -- 自反馈环闸门：我们自己弹出去的通知的 (标题|正文) 哈希。
        -- 采集时命中就跳过。落库不放内存 —— daemon 重启后那条还没被消费的
        -- 自弹通知仍会被采集，内存表这时已经空了。
        CREATE TABLE IF NOT EXISTS self_emitted (h TEXT PRIMARY KEY, ts REAL NOT NULL);

        -- 一天的 LLM 总结。一天一行，重算就覆盖。
        CREATE TABLE IF NOT EXISTS summaries (
          date         TEXT PRIMARY KEY,
          generated_at REAL NOT NULL,
          event_count  INTEGER NOT NULL,   -- 生成时这天有多少条事件（判「要不要重算」）
          headline     TEXT,
          text         TEXT NOT NULL,      -- markdown 正文
          raw          TEXT                -- LLM 原始回复，解析出问题时能回溯
        );

        -- 待办 / 日程。两个来源：LLM 从通知里抽的，和你自己敲的。
        -- **不删行**：done/dropped 只改 status，历史留着才能复盘「当时抽出来的对不对」。
        CREATE TABLE IF NOT EXISTS agenda (
          id          INTEGER PRIMARY KEY,
          created_at  REAL NOT NULL,
          source      TEXT NOT NULL,        -- llm | manual
          src_date    TEXT,                 -- 从哪天的复盘抽出来的
          kind        TEXT NOT NULL,        -- todo | event
          title       TEXT NOT NULL,
          note        TEXT,
          due_ts      REAL,                 -- 截止/开始时刻，可空（没时间的纯待办）
          end_ts      REAL,                 -- 仅 event
          all_day     INTEGER NOT NULL DEFAULT 0,
          who         TEXT,
          evidence    TEXT,                 -- 原始通知片段（LLM 抽的必须给，方便核）
          confidence  REAL,
          status      TEXT NOT NULL DEFAULT 'open',   -- open | done | dropped
          dedup_key   TEXT UNIQUE,
          reminder_id TEXT,                 -- 推进「提醒事项」后拿到的 id（幂等靠它）
          calendar_id TEXT,                 -- 推进「日历」后拿到的 uid
          pushed_at   REAL
        );
        CREATE INDEX IF NOT EXISTS idx_agenda_status ON agenda(status, due_ts);
        CREATE INDEX IF NOT EXISTS idx_agenda_date ON agenda(src_date);

        -- 随手记：自己往某一天里加的内容，和通知并排进时间线，也参与总结。
        CREATE TABLE IF NOT EXISTS notes (
          id   INTEGER PRIMARY KEY,
          ts   REAL NOT NULL,
          date TEXT NOT NULL,
          text TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_notes_date ON notes(date, ts);

        -- Claude Code / Codex 会话的活跃分钟（AIWork）。只存「哪一分钟、哪个工具、哪个项目」，
        -- 不存会话内容；一天的用时由它现算。本表不上云，云端拿的是 feed 里算好的用时。
        CREATE TABLE IF NOT EXISTS ai_minutes (
          minute  INTEGER NOT NULL,         -- unix 秒 / 60
          tool    TEXT NOT NULL,            -- claude | codex
          project TEXT NOT NULL,
          PRIMARY KEY (minute, tool, project)
        ) WITHOUT ROWID;
        -- 每个日志文件读到了哪个字节（增量读）；meta 存 Codex 会话当前 cwd 或 skip
        CREATE TABLE IF NOT EXISTS ai_files (path TEXT PRIMARY KEY, offset INTEGER NOT NULL, meta TEXT);
        -- 会话里 cwd 的变化轨迹（只记变化点）。输入历史只有启动目录（Claude）或连目录都没有（Codex），
        -- 按「敲下那一刻会话在哪个目录」归属，才和用时按目录算的口径一致。
        CREATE TABLE IF NOT EXISTS ai_cwd (sid TEXT NOT NULL, minute INTEGER NOT NULL, cwd TEXT NOT NULL,
                                           PRIMARY KEY (sid, minute));
        """)

        ftsEnabled = db.exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
          title, subtitle, body, app,
          content='events', content_rowid='id',
          tokenize='trigram'
        );
        """)
        if ftsEnabled {
            db.exec("""
            CREATE TRIGGER IF NOT EXISTS events_ai AFTER INSERT ON events BEGIN
              INSERT INTO events_fts(rowid,title,subtitle,body,app)
              VALUES (new.id,new.title,new.subtitle,new.body,new.app);
            END;
            CREATE TRIGGER IF NOT EXISTS events_ad AFTER DELETE ON events BEGIN
              INSERT INTO events_fts(events_fts,rowid,title,subtitle,body,app)
              VALUES('delete',old.id,old.title,old.subtitle,old.body,old.app);
            END;
            CREATE TRIGGER IF NOT EXISTS events_au AFTER UPDATE ON events BEGIN
              INSERT INTO events_fts(events_fts,rowid,title,subtitle,body,app)
              VALUES('delete',old.id,old.title,old.subtitle,old.body,old.app);
              INSERT INTO events_fts(rowid,title,subtitle,body,app)
              VALUES (new.id,new.title,new.subtitle,new.body,new.app);
            END;
            """)
        } else {
            Log.write("警告: FTS5/trigram 建不起来，search 降级为 LIKE 扫描")
        }
    }


    func watermark(_ key: String) -> String? {
        var v: String?
        db.query("SELECT v FROM state WHERE k=?", [key]) { v = $0.str(0) }
        return v
    }

    func setWatermark(_ key: String, _ value: String) {
        db.run("INSERT INTO state(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v",
               [key, value])
    }


    @discardableResult
    func insert(_ e: Event) -> Int64? {
        let ok = db.run("""
            INSERT OR IGNORE INTO events(ts,source,bundle,canon,app,title,subtitle,body,ext_id,rec_id,dedup_key)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """, [e.ts, e.source, e.bundle, BundleMap.canonical(e.bundle), e.app,
                  e.title, e.subtitle, e.body, e.extID, e.recID, e.dedupKey])
        guard ok, db.changes > 0 else { return nil }
        return db.lastInsertID
    }


    func markSelfEmitted(_ hash: String) {
        db.run("INSERT OR REPLACE INTO self_emitted(h,ts) VALUES(?,?)", [hash, nowUnix()])
        db.run("DELETE FROM self_emitted WHERE ts < ?", [nowUnix() - 600])
    }

    func isSelfEmitted(_ e: Event) -> Bool {
        let h = Actions.selfHash(title: e.title, body: e.body)
        var hit = false
        db.query("SELECT 1 FROM self_emitted WHERE h=? AND ts > ?", [h, nowUnix() - 600]) { _ in hit = true }
        return hit
    }

    func logAction(eventID: Int64, rule: String, action: String, detail: String, ok: Bool) {
        db.run("INSERT INTO actions(event_id,ts,rule,action,detail,ok) VALUES(?,?,?,?,?,?)",
               [eventID, nowUnix(), rule, action, detail, ok])
    }


    @discardableResult
    func applyRetention(days: Int) -> Int {
        guard days > 0 else { return 0 }
        let cut = nowUnix() - Double(days) * 86400
        db.run("""
            UPDATE events SET body=NULL, subtitle=NULL, title=NULL, redacted=1
             WHERE ts < ? AND redacted=0
            """, [cut])
        let n = db.changes
        if n > 0 { Log.write("保留期清理: \(n) 条超过 \(days) 天的正文已抹除") }
        return n
    }
}
