import Foundation


struct FileStamp: Equatable {
    let inode: UInt64
    let size: Int64
    let mtimeNS: Int64

    init?(_ url: URL) {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        inode = UInt64(st.st_ino)
        size = Int64(st.st_size)
        mtimeNS = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
    }
}

struct DayFingerprint: Equatable {
    var day: String
    var hasDatabase: Bool
    var events: [Int64]
    var notes: [Int64]
    var rules: FileStamp?
}

final class TodayProbe {
    private var db: DB?
    private var inode: UInt64?
    private var tz: TimeZone?
    private var tzKey = ""
    private var sqlDay = ""
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func resetTimeZone() { tz = nil; tzKey = "" }

    static func utcMidnight(_ day: String) -> Double? { Today.utcMidnight(day) }
    static func dayRange(_ day: String, offsetMinutes: Int? = nil) -> (lo: Double, hi: Double) {
        Today.dayRange(day, offsetMinutes: offsetMinutes)
    }

    func fingerprint(dbPath: String, rulesURL: URL) -> DayFingerprint? {
        let now = Date()
        let zone: TimeZone
        if let tz { zone = tz } else { zone = Clock.tz; tz = zone }
        let minutes = zone.secondsFromGMT(for: now) / 60
        let key = "\(zone.identifier)|\(minutes)"
        if key != tzKey {
            dayFormatter.timeZone = zone
            sqlDay = Clock.sqlDay("ts")
            tzKey = key
        }
        let day = dayFormatter.string(from: now)
        var fp = DayFingerprint(day: day, hasDatabase: false, events: [], notes: [], rules: FileStamp(rulesURL))
        guard let file = FileStamp(URL(fileURLWithPath: dbPath)) else {
            db = nil; inode = nil
            return fp
        }
        fp.hasDatabase = true
        if db == nil || inode != file.inode {
            db = DB(path: dbPath, readOnly: true)
            inode = file.inode
        }
        guard let db else { return nil }
        let range = Self.dayRange(day, offsetMinutes: minutes)
        db.query("""
            SELECT count(*), COALESCE(max(id),0),
                   COALESCE(sum(rec_id IS NOT NULL AND dismissed_at IS NULL),0),
                   COALESCE(sum(dismissed_at IS NOT NULL),0), COALESCE(sum(redacted),0)
              FROM events
             WHERE ts >= ? AND ts < ? AND \(sqlDay) = ?
            """, [range.lo, range.hi, day]) { r in fp.events = (0..<5).map { r.int(Int32($0)) } }
        db.query("SELECT count(*), COALESCE(max(id),0) FROM notes WHERE date = ?", [day]) { r in
            fp.notes = [r.int(0), r.int(1)]
        }
        guard fp.events.count == 5, fp.notes.count == 2 else {
            self.db = nil; inode = nil   // 下次重开
            return nil
        }
        return fp
    }
}

final class DataWatcher {
    private let queue = DispatchQueue(label: "cyou.tianli.notifhubbar.watch", qos: .utility)
    private let dirs: [URL]
    private let files: [URL]
    private let debounce: TimeInterval
    private let onChange: () -> Void
    private let onLost: () -> Void
    private var dirSources: [DispatchSourceFileSystemObject] = []
    private var fileSources: [DispatchSourceFileSystemObject] = []
    private var pending = false
    private var rearmFiles = false
    private var lost = false

    init?(dirs: [URL], files: [URL], debounce: TimeInterval = 1.0,
          onChange: @escaping () -> Void, onLost: @escaping () -> Void = {}) {
        var seen = Set<String>()
        self.dirs = dirs.filter { seen.insert($0.standardizedFileURL.path).inserted }
        self.files = files
        self.debounce = debounce
        self.onChange = onChange
        self.onLost = onLost
        guard let primary = self.dirs.first else { return nil }
        var ok = false
        queue.sync {
            for dir in self.dirs {
                guard let s = watch(dir, mask: [.write, .delete, .rename, .revoke], isDir: true) else { continue }
                if dir == primary { ok = true }
                dirSources.append(s)
            }
            if ok { armFiles() }
        }
        guard ok else {
            queue.sync { (dirSources + fileSources).forEach { $0.cancel() } }
            return nil
        }
    }

    deinit { (dirSources + fileSources).forEach { $0.cancel() } }

    private func watch(_ url: URL, mask: DispatchSource.FileSystemEvent, isDir: Bool) -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: queue)
        s.setEventHandler { [weak self, weak s] in
            guard let self, let s else { return }
            let flags = s.data
            if isDir, !flags.intersection([.delete, .rename, .revoke]).isEmpty, url == self.dirs.first {
                self.lost = true
            }
            if isDir || !flags.intersection([.delete, .rename, .revoke]).isEmpty { self.rearmFiles = true }
            self.schedule()
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        return s
    }

    private func armFiles() {
        fileSources.forEach { $0.cancel() }
        fileSources = files.compactMap { watch($0, mask: [.write, .extend, .delete, .rename, .revoke], isDir: false) }
    }

    private func schedule() {
        guard !pending else { return }
        pending = true
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in
            guard let self else { return }
            self.pending = false
            if self.lost {
                (self.dirSources + self.fileSources).forEach { $0.cancel() }
                self.dirSources = []
                self.fileSources = []
                self.onLost()
                return
            }
            if self.rearmFiles {
                self.rearmFiles = false
                self.armFiles()
            }
            self.onChange()
        }
    }
}
