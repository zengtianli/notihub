import Foundation

let VERSION = "1.5.1"

enum Help {

    static func requested(_ args: [String]) -> Bool { args.contains("--help") || args.contains("-h") }

    static let usages: [String: String] = {
        var u: [String: String] = [
            "day": """
            notihub day|recap [YYYY-MM-DD] [--all] [--json] [--html [路径]] [--no-open]
              一天的复盘时间线（主用途）。默认今天；--all 连折叠的噪音一起看。
              --json   只读：输出与云同步同形的 FeedDay（外加 ok），不收取 AI 输入、不建库、不写任何东西；
                       只认一个日期和 --all，别的参数或非法日期 → ok:false、退出 64
              --html   写 HTML 复盘页（默认 <数据目录>/day-<日期>.html）；不加 --no-open 会用浏览器打开
              文本模式会先收取 Claude Code / Codex 的新输入（与 publish 相同），这是它唯一的写入。
            """,
            "summarize": """
            notihub summarize|sum [YYYY-MM-DD…|--days N] [--force] [--no-agenda]
              调总部 LLM 通路（个人总结作业可配 codex）总结这一天，并抽出时间节点进待办（status=open，不推送）。
              会把当天通知正文发给 LLM；summary.enabled=false 时不做。
            """,
            "publish": """
            notihub publish [--days 30] [--all] [--no-llm] [--json-only] [--out 目录] [--upload [--shrink]]
              在本机生成复盘 JSON（和 HTML），默认不上传。云同步（notihub sync，采集器每 5 分钟调度一轮）
              只用 `publish --no-upload --no-llm --json-only`，再 HTTPS 上传到云端（--no-upload 仍认，等于默认）。
              --upload 才 rsync --delete 到静态目录（个人实例是 VPS 的 /var/www/notihub，nginx 已不再服务它；
              独立实例是它自己的 rrsync 根）—— 这是对外写入，agent 不要加。
              不加 --no-llm 会调 LLM 补总结（同 summarize，把当天正文发给 LLM）。
            """,
            "sync": """
            notihub sync [--no-refresh] [--dry-run] [--json]
              云同步一轮（采集器每 5 分钟调度的就是它，见 notihub jobs）：先 `publish --no-upload --no-llm --json-only`
              刷新本机 JSON，再把采集库的一致快照（events / notes / agenda / summaries + 各天 JSON）经 HTTPS
              送到本实例云端的 /api/sync。这是对外写入（整库替换云端的采集镜像；云端随手记与待办状态不受影响）。
              内容自上次上传没变就不传，但每 30 分钟保底传一次；另一轮在跑则本轮跳过（退出 0）。
              --no-refresh  不重新生成 JSON，直接用 <数据目录>/site 里现有的
              --dry-run     不刷新、不上传、不写状态、不需要凭据：只报这一轮会传什么（行数 / 天数 / 字节 / 指纹）
              --json        输出 {"ok":true,"action":"uploaded|unchanged|busy|dry-run","counts":{…},…}
              凭据读 ~/.config/notifhub/cloud-<实例>.json，经 curl 配置从 stdin 传入，不进 argv、不打印。
              NOTIFHUB_DATA_DIR 把数据目录改到隔离位置时拒绝上传（--dry-run 仍可用）。
              退出码 0 成功或跳过 / 1 生成、读库、网络或回执失败 / 2 未连接云端、配置不符或数据目录被隔离 / 64 用法错误。
            """,
            "today": """
            notihub today [--all] [--json]
              今天的通知流水（与菜单栏同一份：按来源分组、事件 id、未读标记、未读/总数/折叠/随手记计数）。
              只读：只读连接打开已有的库，库不存在就报错（不建空库）。退出码 0 正常 / 1 读不到。
            """,
            "mark-read": """
            notihub mark-read <事件id…> | --all [--include-muted] | --source <来源> [--dry-run] [--json]
              标已读 = 写本机 notif.db 的 dismissed_at（菜单栏「标已读」同一路径，不碰系统通知中心）。
              只接受今天流水里的事件（today --json 里的 id / canon）；--all 默认不含折叠的噪音。
              退出码 0 成功 / 1 有 id 不在今天的流水里、--source 对不上今天任何来源或写入失败 / 64 用法错误。
            """,
            "cloud": """
            notihub cloud status [--json]            连接、最后同步时间与距今秒数、天数、云端未完成数（不打印凭据）
            notihub cloud days [--limit N] [--json]  主窗口的日期侧栏：每天条数、总结标题、未完成数
            notihub cloud day <YYYY-MM-DD> [--json]  这一天在主窗口 / 网页 / iPhone 上的样子：时间线、总结、
                                                     套用了云端状态的待办、云端随手记
            notihub cloud open [--json]              全部未完成待办（已套用云端的完成/丢弃，= 主窗口「待办事项」）
                                                     --json 每项加 reminderKey / inReminders，命令自己按手机的键
                                                     比对 Mac 可读提醒的备注末行；reminderScope 说明范围。
                                                     不代表未同步或只在手机本机的列表；需要完全磁盘访问，不弹授权框。
            notihub cloud mark <id> open|done|dropped [--dry-run] [--json]
                                                     只改云端状态（与主窗口 / 网页 / iPhone 的按钮同一个写入）
            notihub cloud note "<正文>" [--date YYYY-MM-DD] [--key 幂等键] [--dry-run] [--json]
                                                     写一条云端随手记（各端立即可见，没有删除接口）；
                                                     不给 --key 就新生成并打印，失败重试请带同一个 --key
              凭据读 ~/.config/notifhub/cloud-<实例>.json（NOTIHUB_CLOUD_CONFIG 可指定）；
              NOTIFHUB_DATA_DIR 被改到隔离目录时不连云端。--json 原样转出服务端字段并加 ok。
              退出码 0 成功 / 1 网络、HTTP 或提醒读取失败 / 2 未连接云端、配置不符或探针确认缺完全磁盘访问 / 64 用法错误。
            """,
            "note": """
            notihub note "<正文>" [--date YYYY-MM-DD] [--at 14:30]
              本机随手记：写进 notif.db，下一次云同步（≤5 分钟）出现在这天的时间线里。
              要立刻在各端出现、且和主窗口的随手记同一类，用 notihub cloud note。
            """,
            "add": """
            notihub add "<标题>" [--due "周三下午3点"] [--kind todo|event] [--dur 60] [--note ..] [--who ..] [--push]
              加一条本机待办/日程；--push 立刻推进提醒事项/日历（写苹果 App，会响铃）。
            """,
            "agenda": """
            notihub agenda|todo [--all] [--date YYYY-MM-DD] [--overdue] [--json]
              本机采集库里的待办。--json 成功时输出数组（每项 id/kind/title/status/source…）；只读连接，
              库不存在输出 {"ok":false,…} 并退出 1，参数错误（含非法 --date）ok:false、退出 64。
              注意：主窗口 / 网页 / iPhone 改过的状态只在云端，要看人实际看到的未完成清单用 notihub cloud open。
            """,
            "done": """
            notihub done|drop|reopen <id…> [--local-only] [--dry-run] [--json]
              改待办状态：先改本机 notif.db（done 且已推进提醒事项时顺手勾掉那条提醒），
              再写云端状态覆盖（与主窗口按钮同一个写入），这样各端看到的就是新状态。
              云端还没有这条（尚未同步）不算失败：本机状态会随下次同步上去。
              --local-only 只改本机（云端已有覆盖时各端仍显示旧状态）。
              库不存在就报错（不建空库）；--dry-run 用只读连接。
              退出码 0 成功 / 1 有 id 不存在、库不存在、本机改不动或云端写入失败 / 2 用法错误（--json 时 64）。
            """,
            "push": """
            notihub push <id…>|--all [--to reminders|calendar|both] [--list 列表] [--cal 日历] [--no-alarm] [--force] [--dry-run]
              把待办写进苹果「提醒事项 / 日历」（会按时间响铃）。这是外部写入：agent 先用 --dry-run 看路由。
              网页 / iPhone 的「存进提醒事项」按钮最终也是 Mac 上的队列执行这条命令。
            """,
            "targets": """
            notihub targets
              列出可写的日历和提醒事项列表。经 AppleScript 询问 Calendar / Reminders，会唤起这两个 App。
            """,
            "queue": """
            notihub queue [run] [--dry-run]   领网页「存进提醒事项」下的单并执行 push（采集器每分钟调度一轮）；
                                              --dry-run 只报会领哪些，不领、不执行
            notihub queue list [--json]       只读查看队列（待领 / 执行中 / 失败 / 完成与失败原因），不领任何单
              经 ssh 走 VPS 本机回环；其它参数一律拒绝（退出码 64），不会误跑接单器。
            """,
            "status": """
            notihub status [--json]
              读回当前状态（只读，不 ssh、不问「提醒事项」、不建库）：命令版本、所在 Notihub.app 的版本与构建号、
              数据库与配置位置、采集源读不读得到（= 完全磁盘访问是否到位）、库 / 配置 / 时区 / launchd 等本机检查。
              检查项与 notihub doctor --json 的本机那一份相同。
              --json  {"ok":true,"version":"…","app":{"path","version","build","cliCommit"}|null,"data":"…","config":"…",
                       "fullDiskAccess":true,"fatal":0,"checks":[{"name","level","ok","fatal","detail","group"}…]}
                      有致命项时 ok:false，另带 "error":"N 项致命检查未通过：…"（字符串）与 "errorCode":"fatal_checks"，其余字段照给。
                      装机后核对新旧看 app.cliCommit（命令版本号与 App 版本号换包时不一定变）。
              退出码 0 无致命项 / 1 有致命项 / 64 用法错误。后台任务看 notihub jobs，云端连接看 notihub cloud status。
            """,
            "jobs": """
            notihub jobs [--json]
              采集器自己调度的后台任务（queue 每 60 秒 / sync 每 300 秒 / summarize 每 3600 秒）的状态。只读：
              读采集器写的回执 <数据目录>/jobs.json，不启动、不停止任何任务。
              每条任务：status、interval、last_started_at、last_finished_at、last_exit、last_error（一行）、
              consecutive_failures、next_due_at、日志路径。status 取值：
                ok / running / pending（还没跑过、未到期）/ deferred（同名旧 launchd 作业还加载着，由它跑）/
                disabled / failing（上一轮失败）/ overdue（到期后迟迟没跑：调度器停了）
              退出码 0 全部正常 / 1 有任务 failing 或 overdue、或读不到回执 / 64 用法错误。
              间隔与开关在 rules.json 的 jobs（enabled、disabled、queueSeconds、syncSeconds、summarizeSeconds），改完不用重启。
            """,
            "tail": """
            notihub tail [-n 20] [-f]
              最近的通知（-f 跟随，Ctrl-C 退出）。
            """,
            "search": """
            notihub search <关键词> [--app wechat] [--days 30] [--json]
              全文检索本机通知（最多 100 条）；不足 3 字自动改用 LIKE（--json 时提示走 stderr）。
              --json 成功时输出数组（每项 id/ts/app/title/body/source）；只读连接，库不存在输出 {"ok":false,…}
              并退出 1；缺关键词、不认识的参数、--days 不在 1–36500 → ok:false、退出 64。
            """,
            "stats": """
            notihub stats [--days 7] [--json] [--html [路径]] [--no-open]
              打扰统计：总数、未点开、按 app / 小时 / 天、规则动作。--json 只读（库不存在报错不建库），
              只认 --days（1–36500），别的参数 → ok:false、退出 64。
            """,
            "doctor": """
            notihub doctor [--offline] [--json]
              权限 / 在岗 / 依赖自检。完整版（默认文本）会 ssh 到 VPS 查队列与 nginx、
              用 AppleScript 问「提醒事项」是否应答（可能唤起 Reminders.app）。
              --offline 或 --json：只做本机检查（采集源、库、配置、时区、launchd、本机数据），不 ssh、不碰苹果 App；
              --json --online 才把联网检查也做进 JSON。退出码 0 全过 / 1 有致命项。
            notihub doctor --sources [--json]   只查采集源读不读得到（授权探针用）
            """,
            "install": """
            notihub install [--dry-run [--json]]
              写 daemon 的 launchd plist 并重新加载（指向 Notihub.app 里的采集器），建 ~/.local/bin 软链。
              launchd 里只有这一个作业：接单 / 云同步 / 总结由采集器自己调度（notihub jobs）。
              会重启常驻采集；agent 只用 --dry-run 看计划。
            """,
            "uninstall": """
            notihub uninstall --yes
              卸载 daemon 的 launchd 作业（采集与它调度的接单 / 云同步 / 总结一起停；库和配置保留）。必须带 --yes。
            """,
            "rules": """
            notihub rules                     看当前规则与复盘折叠设置
            notihub rules test "<文本>"       试一段文本会命中哪条规则（不执行动作）
            notihub rules init [--force]      写默认 rules.json；已有配置时拒绝，--force 先备份成 rules.json.bak-<时间> 再覆盖
            """,
            "data": DataCLI.usage + "\n  退出码 0 正常 / 1 缺源·库损坏·列对不上 / 2 探针确认缺完全磁盘访问（终端授权 ≠ App 授权）/ 64 用法错误",
            "instance": """
            notihub instance show             当前实例（id、数据库、站点、上传主机）JSON
            notihub instance check <profile.json>
            notihub instance activate <profile.json>   写 ~/.config/notifhub/instance.json（已有则拒绝）
            """,
            "daemon": """
            notihub daemon
              常驻采集（launchd com.notifhub.daemon 调它），并按时拉起 queue / sync / summarize 子进程。不要手动再起一个。
            """,
            "once": """
            notihub once
              手动跑一轮采集就退出（会读系统通知库并按规则执行动作）。
            """,
            "selftest": """
            notihub selftest [--live]
              回归测试（临时库，不碰真实数据）；--live 会发一条真通知端到端验。
            """,
            "version": "notihub version | --version | -v",
            "help": "notihub help [命令]    打印总帮助或某个命令的用法",
        ]
        for (alias, main) in aliases { u[alias] = u[main] }
        return u
    }()

    static let aliases: [String: String] = [
        "recap": "day", "sum": "summarize", "todo": "agenda", "drop": "done", "reopen": "done",
    ]

    static func usage(_ cmd: String) -> String? { usages[cmd] }


    static let lifecycleWindowEntry = "配置与同步…"
    static let lifecycleReads = [
        "  config status              「使用 iCloud 记住配置」开关、开关下面那句同步状态、当前可迁移的配置项、App 是否在运行（只读）",
        "  update check               检查更新：当前版本、此渠道最新版本、有没有新版、怎么升级（只读；私有渠道读 iCloud Drive 里的发行记录，公开渠道联网读发行记录）",
    ]
    static let lifecycleWrites = [
        "  config export -o <file>        导出配置：与窗口「导出配置…」同一份文件；不改设置，只写你指定的那个文件（--force 覆盖；-o - 输出到标准输出，不写文件）",
        "  config import <file> --yes     导入配置：先备份原配置再覆盖，与窗口「导入配置…」相同",
        "  config sync on|off --yes       拨动「使用 iCloud 记住配置」（--dry-run 只看会不会变；用 notihub config status 回读）",
        "  update install --yes           升级到新版：与窗口「升级到新版…」同一条路——验证发行包与签名、替换当前 App，运行中的先退出、换好再重开；配置保留，替换失败回滚（--dry-run 只看会做什么；用 notihub update check 回读）",
    ]
    static let lifecycleWindowOnly = "打开「\(lifecycleWindowEntry)」窗口"
    static let lifecycleHandOff = """
          Notihub 的升级由发行包自带的安装事务完成（换包、重启采集器并核对监视点，没恢复就放回旧包）：update install --yes 验证完发行包即返回
          state: handed_off、installed: false，替换在它返回之后的一两分钟内进行（最长约两分钟，其间采集器重启一次）；
          用 notihub update check 回读 current，仍是旧构建号就是没换成、原 App 保留。App 没在运行时换好后不打开它。
        """

    static var main: String {
        """
        notihub \(VERSION) —— macOS 通知即日志（事件驱动，空闲 0% CPU，不打扰）
        界面给本人，命令给程序和 agent：与 Notihub.app（菜单栏、主窗口、本机数据页）共用同一套引擎、同一份数据和配置。
        每个子命令都认 --help：只打印用法、退出 0，不做任何事。未知命令退出 64。
        --json：输出一个带 ok 的对象，失败时 ok:false 且退出码非 0；--json 下参数错误一律 ok:false、退出 64。
        例外：agenda / search / data <域> 的 --json 成功时是数组（失败看退出码；agenda/search 另输出 ok:false 对象）。
        config / update 由 Notihub.app 里的共用命令层执行，约定不同：error 是 {"code","message"} 对象，用法错误退出 2（见 notihub config --help）。

        读命令（不写任何文件或状态；库不存在就报错，不建空库）：
          status · today · day --json · stats --json · agenda · search · jobs · queue list · rules · rules test ·
          cloud status · cloud days · cloud day · cloud open · data list · data <域> · data people · data selfcheck ·
          doctor --offline · doctor --json · doctor --sources · instance show · instance check · tail · version ·
          install --dry-run · sync --dry-run · config status · update check
          会联网或唤起别的 App 的读命令：cloud …（HTTPS 到本实例云端）· queue list（ssh）· doctor 完整版（ssh、问「提醒事项」）·
          targets（唤起日历与提醒事项）
        写命令（带 --dry-run 的加上它只报计划、不落改动）：
          本机库      mark-read · note · add · done · drop · reopen · once · summarize · day（文本模式收取 AI 输入）
          云端        cloud mark · cloud note · sync · done / drop / reopen（本机之后写云端覆盖）· publish --upload
          苹果 App    push（写提醒事项 / 日历，会按时间响铃）· queue run（领网页下的单并执行 push）· add --push
          本机文件    data export（只写 --out 目录）· publish（<数据目录>/site）· day --html · stats --html
          配置与常驻  rules init · instance activate · install · uninstall --yes · daemon
          配置与更新  config export（只写 -o 指定的那个文件）· config import --yes · config sync on|off --yes ·
                      update install --yes（替换并重开 App、重启采集器；--dry-run 只看会做什么）
        --json 输出形状：成功 {"ok": true, …各命令自己的字段，见 notihub <命令> --help}；
          失败 {"ok": false, "error": "给人看的原因"}，参数错误另带 "usageError": true。error 是字符串（沿用至今的形状）。
          config / update：成功 {"ok": true, "command": "config status", …}；失败 {"ok": false, "command": …, "error": {"code", "message"}}。
        退出码：0 成功（查无结果也算）
                1 操作失败：读不到库、网络或 HTTP 失败、有 id 不存在、jobs 有任务失败或逾期、status / doctor 有致命项
                2 缺前置：cloud / sync 未连接云端或配置不符；data 经探针确认缺完全磁盘访问；
                  config / update 的用法错误或缺确认参数（error.code：usage · confirmation_required · file_exists；update install 缺 --yes 也在这里）
                64 用法错误：未知命令、不认识的参数、缺值、非法日期（--json 时同时输出 ok:false；config / update 除外，见上一行）
        仅在窗口中（没有对应命令）：
          Mac      打开主窗口、\(lifecycleWindowOnly)（应用菜单里的「配置与更新…」是同一个窗口）、退出 App；进入「本机数据」页；折叠或展开来源分组；
                   阅读总结 / 收起总结、展开全文 / 收起（命令输出里总是全文）；时间线 / 当日待办 / 云端笔记 分段切换；
                   「在线复盘」「打开网页版」打开浏览器（地址：notihub instance show 的 siteURL）及打不开时的提示；
                   随手记未保存的草稿；导出后在访达中显示；数据页提示条的「知道了」；打开系统设置授予完全磁盘访问（授权只能本人点）。
          手机端   今天 / 通知 / 随手记 / 连接 的标签或侧栏分区切换；展开正文 / 收起正文；随手记草稿（存在该设备）与收起键盘；
                   「连接」页的云端站点链接（打开浏览器）、访问密码登录或更新凭据（本人在手机上输入，只进该设备钥匙串）、
                   提醒事项授权（系统弹窗只能本人点）；手表主页上下翻页（未读 / 从哪来 / 要点 三页，内容见 cloud day）。
          暂无命令：手机端已装版本、更新渠道与检查更新（手机经 TestFlight 更新，Mac 上的命令够不到手机）、
                   手机上「加入到哪个提醒事项列表」的选择；只在手机本机的列表与未同步的提醒 Mac 读不到。
          提醒只读：cloud open --json 自算键比对 inReminders（范围为 Mac 可读列表）；
                   data reminders --date YYYY-MM-DD --json 取当天到期未完成 + 当天完成，含「完成时间」（系统时区）。
          窗口里的搜索框是对当前内容的过滤：用 cloud day / cloud open 的 --json 取全量后自行筛。
          窗口里操作失败或成功的提示行：命令自己以退出码和输出说明（--json 下 ok 与 error）。

        复盘
          notihub day [2026-08-13] [--all] [--json] [--html] [--no-open]   ← 主用途：一天的复盘时间线
          notihub summarize [日期|--days N] [--force] [--no-agenda]
                                      调总部 LLM 通路总结这一天（个人作业可配 codex），并挑出时间节点
          notihub publish [--days 30] [--no-llm] [--json-only] [--upload]
                                      在本机生成复盘 JSON（默认不上传）；云同步作业只用 --json-only；--upload 才 rsync 到旧静态目录
          notihub sync [--no-refresh] [--dry-run] [--json]
                                      云同步一轮：刷新 JSON 并经 HTTPS 上传到云端（采集器每 5 分钟调度；对外写入）

        今天（与菜单栏同一份数据）
          notihub today [--all] [--json]              今日未读、按来源分组的流水（带事件 id）
          notihub mark-read <事件id…>|--all|--source <来源> [--dry-run] [--json]   标已读（写本机）

        云端（与主窗口 / 网页 / iPhone 同一份：已套用云端状态与云端随手记）
          notihub cloud status|days|open [--json]
          notihub cloud day <YYYY-MM-DD> [--json]
          notihub cloud mark <id> open|done|dropped [--dry-run]      只改云端状态（同主窗口按钮）
          notihub cloud note "<正文>" [--date D] [--key K] [--dry-run] 写云端随手记（无删除接口）

        自己往里加
          notihub note "下午和老王聊了方案，他倾向 B"  [--date 2026-08-13] [--at 14:30]
          notihub add "跟老王对方案" --due "周三下午3点" [--kind todo|event] [--dur 60] [--push]

        时间节点 → 苹果提醒事项 / 日历
          notihub agenda|todo [--all] [--date d] [--overdue] [--json]
          notihub done|drop|reopen <id…> [--local-only] [--dry-run] [--json]   本机 + 云端状态一起改
          notihub push <id>|--all [--to reminders|calendar|both] [--cal 日历名] [--dry-run]
          notihub targets            列出可写的日历和提醒事项列表（会唤起这两个 App）
          notihub queue [run] [--dry-run] | queue list [--json]   网页「存进提醒事项」的队列

        本机数据（只读，DataDesk 并入；内容永不上云、不进总结）
          notihub data list [--json]                 15 个域的状态与条数（含通讯录统计）
          notihub data <域> [--limit N] [--json|--csv] [--raw]   号码/邮箱默认打码
          notihub data export <域…|--all> --out <目录> [--csv|--json] [--mask]
          notihub data people who <词> | timeline <词> [--since --until --limit --full] | stats
          notihub data selfcheck                     信息正文解码对照（只报计数）
          退出码 0 正常 / 1 缺源·库损坏·列对不上 / 2 探针确认缺完全磁盘访问（终端授权 ≠ App 授权）/ 64 用法错误

        配置与更新（Notihub.app「\(lifecycleWindowEntry)」窗口里的几项，与窗口读写同一份设置；由 App 主程序执行，不开窗口；notihub config --help 看用法与字段）
        \(lifecycleReads.joined(separator: "\n"))
        \(lifecycleWrites.joined(separator: "\n"))
        \(lifecycleHandOff)
          随配置迁移的只有 rules.json 里的保留期、动作时效、展示折叠、Bark 开关 / 服务器 / 分组、总结、提醒事项与日历名、后台任务、AI 协作这几组偏好；
          规则、Bark 密钥与密钥文件、Python 路径、云端凭据、通知正文不迁移。

        其它
          notihub daemon             常驻采集（launchd 调它，一般不用手跑）；接单 / 云同步 / 总结由它调度
          notihub status [--json]    读回当前状态：版本、所在 App、权限是否到位、本机检查（只读）
          notihub jobs [--json]      后台任务状态（上次结果、连续失败、下次到期）；有任务在失败或逾期时退出 1
          notihub once               手动跑一轮采集
          notihub tail [-n 20] [-f]  最近的通知
          notihub search <词> [--app wechat] [--days 30] [--json]
          notihub stats [--days 7] [--json] [--html [路径]] [--no-open]
          notihub rules [init [--force]|test <文本>]
          notihub doctor [--offline] [--json]   自检（完整版会 ssh、会问「提醒事项」；--offline/--json 只查本机）
          notihub doctor --sources [--json]  只查采集源读不读得到（授权探针用）
          notihub instance show|check <profile>|activate <profile>
          notihub selftest [--live]  回归测试（--live 会发一条真通知端到端验）
          notihub install|uninstall --yes  装/卸 launchd 常驻（采集器在 Notihub.app 里，不复制）
          notihub install --dry-run [--json]  只打印安装计划，零改动
          别名：recap=day  sum=summarize  todo=agenda

        数据: \(Paths.db.path)（0600，含通知正文，不进任何 git repo）
        配置: \(Paths.configFile.path)
        旧名 notifhub 仍可用（~/.local/bin/notifhub 软链到同一程序），如 notifhub day ≡ notihub day。
        采集器在 Notihub.app 里：删除或移动 App 就等于停止采集。
        ⛔ 它自己从不弹提醒。苹果那边的闹钟只在你敲 `push` 时才会有。
        """
    }
}
