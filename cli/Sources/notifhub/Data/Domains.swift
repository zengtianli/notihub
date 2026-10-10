import Foundation



enum DataHome {
    static var path: String {
        if let s = ProcessInfo.processInfo.environment["NOTIHUB_DATA_HOME"], !s.isEmpty {
            return (s as NSString).expandingTildeInPath
        }
        return NSHomeDirectory()
    }

    static func expand(_ p: String) -> String {
        if p == "~" { return path }
        if p.hasPrefix("~/") { return path + p.dropFirst() }
        return p
    }
}


struct SourceSpec {
    let pattern: String
    let multi: Bool

    init(_ pattern: String, multi: Bool = false) {
        self.pattern = pattern
        self.multi = multi
    }

    func resolve() -> [String] {
        let expanded = DataHome.expand(pattern)
        var candidates = ["/"]
        for segment in expanded.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            guard segment.contains("*") else {
                candidates = candidates.map { ($0 as NSString).appendingPathComponent(segment) }
                continue
            }
            var next: [String] = []
            for base in candidates {
                let entries = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
                for e in entries.sorted() where SourceSpec.matches(e, glob: segment) {
                    next.append((base as NSString).appendingPathComponent(e))
                }
            }
            candidates = next
        }
        let found = candidates.filter { FileManager.default.fileExists(atPath: $0) }
        return multi ? found : Array(found.prefix(1))
    }

    static func matches(_ name: String, glob: String) -> Bool {
        let parts = glob.components(separatedBy: "*")
        guard parts.count > 1 else { return name == glob }
        if let first = parts.first, !first.isEmpty, !name.hasPrefix(first) { return false }
        if let last = parts.last, !last.isEmpty, !name.hasSuffix(last) { return false }
        var cursor = name.startIndex
        for part in parts where !part.isEmpty {
            guard let r = name.range(of: part, range: cursor..<name.endIndex) else { return false }
            cursor = r.upperBound
        }
        return true
    }

    var display: String { pattern }
}


enum Extraction {
    case sqlite(String)
    case safariBookmarks
    case stickies
    case icloudDrive
}


struct DataDomain: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let summary: String
    let sources: [SourceSpec]
    let extraction: Extraction
    let timestampColumns: Set<Int>
    let sensitiveColumns: Set<Int>
    let mergeOrderColumn: Int?

    init(id: String, name: String, symbol: String, summary: String,
         sources: [SourceSpec], extraction: Extraction,
         timestampColumns: Set<Int> = [], sensitiveColumns: Set<Int> = [], mergeOrderColumn: Int? = nil) {
        self.id = id; self.name = name; self.symbol = symbol; self.summary = summary
        self.sources = sources; self.extraction = extraction
        self.timestampColumns = timestampColumns; self.sensitiveColumns = sensitiveColumns
        self.mergeOrderColumn = mergeOrderColumn
    }

    static func == (a: DataDomain, b: DataDomain) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}


enum DomainRegistry {

    static let all: [DataDomain] = [
        messages, mail, safariHistory, safariBookmarks, safariTabs, callHistory, podcasts,
        screenTime, notes, contacts, reminders, books, voiceMemos, stickies, icloudDrive,
    ]

    static func domain(_ id: String) -> DataDomain? { all.first { $0.id == id } }

    static let messageBodySQL =
        "COALESCE(NULLIF(REPLACE(COALESCE(m.text,''),char(65532),''),''),imsg_body(m.attributedBody),'')"
    static let messageTimeSQL =
        "CAST((CASE WHEN m.date>1000000000000000 THEN m.date/1000000000 ELSE m.date END)+978307200 AS INT)"

    static let messages = DataDomain(
        id: "messages", name: "信息", symbol: "message.fill",
        summary: "iMessage 与短信正文(含只存在 attributedBody 里的)、对方号码、收发方向、所属会话",
        sources: [SourceSpec("~/Library/Messages/chat.db")],
        extraction: .sqlite("""
        SELECT * FROM (
          SELECT \(messageTimeSQL) AS 时间,
                 COALESCE(h.id,'') AS 对方,
                 CASE m.is_from_me WHEN 1 THEN '发出' ELSE '收到' END AS 方向,
                 COALESCE(NULLIF(c.display_name,''), NULLIF(c.chat_identifier,''), '') AS 会话,
                 COALESCE(m.service,'') AS 服务,
                 \(messageBodySQL) AS 正文
          FROM message m
          LEFT JOIN handle h ON m.handle_id = h.ROWID
          LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
          LEFT JOIN chat c ON c.ROWID = cmj.chat_id
          WHERE (m.text IS NOT NULL AND m.text <> '') OR m.attributedBody IS NOT NULL
        ) WHERE 正文 <> ''
        ORDER BY 时间 DESC LIMIT {LIMIT}
        """),
        timestampColumns: [0], sensitiveColumns: [1, 3])

    static let mail = DataDomain(
        id: "mail", name: "邮件", symbol: "envelope.fill",
        summary: "Mail.app 本地信封索引:发件人、主题、收件时间、已读与大小(不读正文)",
        sources: [SourceSpec("~/Library/Mail/V*/MailData/Envelope Index")],
        extraction: .sqlite("""
        SELECT CAST(m.date_received AS INT) AS 收件时间,
               COALESCE(a.address,'') AS 发件人,
               COALESCE(s.subject,'') AS 主题,
               CASE m.read WHEN 1 THEN '已读' ELSE '未读' END AS 状态,
               COALESCE(m.size,0) AS 字节数
        FROM messages m
        LEFT JOIN addresses a ON m.sender = a.ROWID
        LEFT JOIN subjects s ON m.subject = s.ROWID
        WHERE m.deleted = 0
        ORDER BY m.date_received DESC LIMIT {LIMIT}
        """),
        timestampColumns: [0], sensitiveColumns: [1])

    static let safariHistory = DataDomain(
        id: "safari-history", name: "Safari 历史", symbol: "clock.arrow.circlepath",
        summary: "浏览历史:访问时间、网址、页面标题、累计访问次数",
        sources: [SourceSpec("~/Library/Safari/History.db")],
        extraction: .sqlite("""
        SELECT CAST(v.visit_time+978307200 AS INT) AS 访问时间,
               COALESCE(NULLIF(v.title,''),'(无标题)') AS 标题,
               i.url AS 网址,
               COALESCE(i.domain_expansion,'') AS 域名,
               i.visit_count AS 累计次数
        FROM history_visits v
        JOIN history_items i ON v.history_item = i.id
        ORDER BY v.visit_time DESC LIMIT {LIMIT}
        """),
        timestampColumns: [0])

    static let safariBookmarks = DataDomain(
        id: "safari-bookmarks", name: "Safari 书签", symbol: "bookmark.fill",
        summary: "书签树(含收藏夹与阅读列表)展平:所在文件夹、标题、网址",
        sources: [SourceSpec("~/Library/Safari/Bookmarks.plist")],
        extraction: .safariBookmarks)

    static let safariTabs = DataDomain(
        id: "safari-tabs", name: "Safari 标签页", symbol: "square.on.square",
        summary: "当前开着的标签页:标题、网址(SafariTabs.db,不含标签组文件夹)",
        sources: [SourceSpec("~/Library/Containers/com.apple.Safari/Data/Library/Safari/SafariTabs.db")],
        extraction: .sqlite("""
        SELECT COALESCE(title,'') AS 标题, url AS 网址
        FROM bookmarks
        WHERE type = 0 AND url IS NOT NULL AND url <> ''
        ORDER BY id DESC LIMIT {LIMIT}
        """))

    static let callHistory = DataDomain(
        id: "callhistory", name: "通话记录", symbol: "phone.fill",
        summary: "电话与 FaceTime:时间、号码、时长、呼入呼出、是否接通(按时长判)、运营商",
        sources: [SourceSpec("~/Library/Application Support/CallHistoryDB/CallHistory.storedata")],
        extraction: .sqlite("""
        SELECT CAST(ZDATE+978307200 AS INT) AS 时间,
               COALESCE(ZADDRESS,'') AS 号码,
               COALESCE(ZNAME,'') AS 名称,
               CAST(COALESCE(ZDURATION,0) AS INT) AS 时长秒,
               CASE ZORIGINATED WHEN 1 THEN '呼出' ELSE '呼入' END AS 方向,
               CASE WHEN COALESCE(ZDURATION,0) > 0 THEN '已接通' ELSE '未接通' END AS 接通,
               COALESCE(ZISO_COUNTRY_CODE,'') AS 国家,
               COALESCE(ZSERVICE_PROVIDER,'') AS 服务
        FROM ZCALLRECORD
        ORDER BY ZDATE DESC LIMIT {LIMIT}
        """),
        timestampColumns: [0], sensitiveColumns: [1])

    static let podcasts = DataDomain(
        id: "podcasts", name: "播客", symbol: "antenna.radiowaves.left.and.right",
        summary: "订阅节目与单集:节目名、作者、单集标题、发布时间、播放进度",
        sources: [SourceSpec("~/Library/Group Containers/243LU875E5.groups.com.apple.podcasts/Documents/MTLibrary.sqlite")],
        extraction: .sqlite("""
        SELECT COALESCE(p.ZTITLE,'') AS 节目,
               COALESCE(p.ZAUTHOR,'') AS 作者,
               COALESCE(e.ZTITLE,'') AS 单集,
               CAST(e.ZPUBDATE+978307200 AS INT) AS 发布时间,
               CAST(COALESCE(e.ZPLAYHEAD,0) AS INT) AS 播放位置秒,
               CASE e.ZHASBEENPLAYED WHEN 1 THEN '已播' ELSE '未播' END AS 状态
        FROM ZMTEPISODE e
        LEFT JOIN ZMTPODCAST p ON e.ZPODCAST = p.Z_PK
        ORDER BY e.ZPUBDATE DESC LIMIT {LIMIT}
        """),
        timestampColumns: [3])

    static let screenTime = DataDomain(
        id: "screentime", name: "屏幕使用时间", symbol: "hourglass",
        summary: "knowledgeC 里的 App 使用分段:Bundle ID、开始结束时间、持续秒数",
        sources: [SourceSpec("~/Library/Application Support/Knowledge/knowledgeC.db")],
        extraction: .sqlite("""
        SELECT COALESCE(ZVALUESTRING,'') AS 应用,
               CAST(ZSTARTDATE+978307200 AS INT) AS 开始,
               CAST(ZENDDATE+978307200 AS INT) AS 结束,
               CAST(ZENDDATE-ZSTARTDATE AS INT) AS 时长秒
        FROM ZOBJECT
        WHERE ZSTREAMNAME = '/app/usage'
        ORDER BY ZSTARTDATE DESC LIMIT {LIMIT}
        """),
        timestampColumns: [1, 2])

    static let notes = DataDomain(
        id: "notes", name: "备忘录", symbol: "note.text",
        summary: "备忘录条目:标题、摘要片段、所属文件夹、创建与修改时间(不解正文富文本)",
        sources: [SourceSpec("~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")],
        extraction: .sqlite("""
        SELECT COALESCE(n.ZTITLE1,'') AS 标题,
               COALESCE(n.ZSNIPPET,'') AS 摘要,
               COALESCE(f.ZTITLE2,'') AS 文件夹,
               CAST(n.ZCREATIONDATE3+978307200 AS INT) AS 创建时间,
               CAST(n.ZMODIFICATIONDATE1+978307200 AS INT) AS 修改时间
        FROM ZICCLOUDSYNCINGOBJECT n
        LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON n.ZFOLDER = f.Z_PK
        WHERE n.ZTITLE1 IS NOT NULL
        ORDER BY n.ZMODIFICATIONDATE1 DESC LIMIT {LIMIT}
        """),
        timestampColumns: [3, 4])

    static let contacts = DataDomain(
        id: "contacts", name: "通讯录", symbol: "person.crop.circle",
        summary: "联系人:姓名、公司、职位、电话、邮箱、创建时间(多个账户来源合并)",
        sources: [SourceSpec("~/Library/Application Support/AddressBook/Sources/*/AddressBook-v22.abcddb", multi: true),
                  SourceSpec("~/Library/Application Support/AddressBook/AddressBook-v22.abcddb")],
        extraction: .sqlite("""
        SELECT TRIM(COALESCE(r.ZLASTNAME,'')||COALESCE(r.ZFIRSTNAME,'')) AS 姓名,
               COALESCE(r.ZORGANIZATION,'') AS 公司,
               COALESCE(r.ZJOBTITLE,'') AS 职位,
               COALESCE((SELECT GROUP_CONCAT(p.ZFULLNUMBER,' / ') FROM ZABCDPHONENUMBER p WHERE p.ZOWNER = r.Z_PK),'') AS 电话,
               COALESCE((SELECT GROUP_CONCAT(e.ZADDRESS,' / ') FROM ZABCDEMAILADDRESS e WHERE e.ZOWNER = r.Z_PK),'') AS 邮箱,
               CAST(r.ZCREATIONDATE+978307200 AS INT) AS 创建时间
        FROM ZABCDRECORD r
        WHERE r.ZFIRSTNAME IS NOT NULL OR r.ZLASTNAME IS NOT NULL OR r.ZORGANIZATION IS NOT NULL
        ORDER BY r.ZCREATIONDATE DESC LIMIT {LIMIT}
        """),
        timestampColumns: [5], sensitiveColumns: [3, 4], mergeOrderColumn: 5)

    static let reminders = DataDomain(
        id: "reminders", name: "提醒事项", symbol: "checklist",
        summary: "提醒:标题、所属清单、完成状态、截止时间、备注、完成时间",
        sources: [SourceSpec("~/Library/Group Containers/group.com.apple.reminders/Container_v1/Stores/Data-*.sqlite", multi: true)],
        extraction: .sqlite("""
        SELECT COALESCE(r.ZTITLE,'') AS 标题,
               COALESCE(l.ZNAME,'') AS 清单,
               CASE r.ZCOMPLETED WHEN 1 THEN '已完成' ELSE '未完成' END AS 状态,
               CAST(r.ZDUEDATE+978307200 AS INT) AS 截止,
               CAST(r.ZCREATIONDATE+978307200 AS INT) AS 创建时间,
               COALESCE(r.ZNOTES,'') AS 备注,
               CAST(r.ZCOMPLETIONDATE+978307200 AS INT) AS 完成时间
        FROM ZREMCDREMINDER r
        LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK
        WHERE r.ZMARKEDFORDELETION = 0
        ORDER BY r.ZCREATIONDATE DESC LIMIT {LIMIT}
        """),
        timestampColumns: [3, 4, 6], mergeOrderColumn: 4)

    static let books = DataDomain(
        id: "books", name: "图书", symbol: "books.vertical.fill",
        summary: "Apple Books 书库:书名、作者、类型、页数、最后打开时间",
        sources: [SourceSpec("~/Library/Containers/com.apple.iBooksX/Data/Documents/BKLibrary/BKLibrary*.sqlite")],
        extraction: .sqlite("""
        SELECT COALESCE(ZTITLE,'') AS 书名,
               COALESCE(ZAUTHOR,'') AS 作者,
               COALESCE(ZGENRE,'') AS 类型,
               COALESCE(ZPAGECOUNT,0) AS 页数,
               CAST(ZLASTOPENDATE+978307200 AS INT) AS 最后打开,
               CAST(ZCREATIONDATE+978307200 AS INT) AS 加入时间
        FROM ZBKLIBRARYASSET
        ORDER BY ZLASTOPENDATE DESC LIMIT {LIMIT}
        """),
        timestampColumns: [4, 5])

    static let voiceMemos = DataDomain(
        id: "voicememos", name: "语音备忘录", symbol: "waveform",
        summary: "录音条目:名称、录制时间、时长、文件名(只列 metadata,不读音频)",
        sources: [SourceSpec("~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db")],
        extraction: .sqlite("""
        SELECT COALESCE(ZCUSTOMLABEL,'') AS 名称,
               CAST(ZDATE+978307200 AS INT) AS 录制时间,
               CAST(COALESCE(ZDURATION,0) AS INT) AS 时长秒,
               COALESCE(ZPATH,'') AS 文件名
        FROM ZCLOUDRECORDING
        ORDER BY ZDATE DESC LIMIT {LIMIT}
        """),
        timestampColumns: [1])

    static let stickies = DataDomain(
        id: "stickies", name: "便签", symbol: "note",
        summary: "Stickies.app 便签:正文纯文本、字数、修改时间",
        sources: [SourceSpec("~/Library/Containers/com.apple.Stickies/Data/Library/Stickies")],
        extraction: .stickies,
        timestampColumns: [3])   // 列序 便签/正文/字数/修改时间 —— 时间在 3,不是 2

    static let icloudDrive = DataDomain(
        id: "icloud-drive", name: "iCloud 云盘", symbol: "icloud.fill",
        summary: "云盘文件清单:相对路径、大小、修改时间、是否仅在云端(**不读文件内容**)",
        sources: [SourceSpec("~/Library/Mobile Documents/com~apple~CloudDocs")],
        extraction: .icloudDrive,
        timestampColumns: [2])
}
