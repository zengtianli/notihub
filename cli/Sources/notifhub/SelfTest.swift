import Foundation

enum SelfTest {

    static func run(live: Bool) -> Bool {
        var pass = 0, fail = 0
        Log.silent = true   // 纯逻辑部分不许污染真实日志；--live 段前会放开

        func check(_ want: String, _ body: String, _ note: String = "") {
            let got = OTP.find(in: body) ?? ""
            if got == want { pass += 1 }
            else {
                fail += 1
                print("FAIL  期望[\(want)] 实得[\(got)]\n      正文: \(body)")
            }
        }

        print("== 应当命中 ==")
        check("123456", "【某某科技】您的验证码是 123456，5 分钟内有效。")
        check("8842",   "验证码：8842，请勿告知他人。")
        check("917305", "您的动态码为917305，若非本人操作请忽略。")
        check("4821",   "Your verification code is 4821. It expires in 10 minutes.")
        check("660214", "[GitHub] Your one-time code: 660214")
        check("302914", "OTP 302914 for your login request")
        check("5566",   "您的校验码 5566 ，请在 5 分钟内输入。")

        print("== 多候选：必须挑关键词旁边那个，不是第一个数字 ==")
        check("738291", "【银行】尊敬的客户，您本次操作的验证码为738291，5 分钟内有效，客服热线 4000000000。")
        check("246810", "您有 3 条未读消息。验证码 246810 请勿转发。")
        check("135790", "订单 20260728 已发货。取件验证码 135790。")

        print("== 不该命中（无关键词，纯数字不能乱抓）==")
        check("", "您的快递 SF1234567890 已签收，感谢使用。")
        check("", "本月账单 1280.00 元，请于 20260805 前缴纳。")
        check("", "会议改到 14:30，房间 2058。")
        check("", "Your order 8829301 has shipped.")

        print("== 虚构短信回归 ==")
        check("654321", "【虚构银行】序号01的验证码654321，向示例账户尾号9999转账10.0元。")
        check("24680", "【虚构网络】WiFi安全验证码：24680")
        check("112233", "【虚构商店】验证码：112233，5分钟内有效，请勿分享。")

        print("== 邮件 .emlx 首行是报文字节数，绝不能被当成验证码 ==")
        for (want, prefix, body) in [
            ("903471", "1234",   "Your verification code is 903471. It expires in 10 minutes."),
            ("558102", "104857", "【示例银行】您的验证码为 558102，5 分钟内有效，请勿转发。")
        ] {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("notifhub-test-\(UUID().uuidString).emlx")
            let content = "\(prefix)\nFrom: t@example.com\nSubject: code\nContent-Type: text/plain\n\n\(body)\n"
            try? content.write(to: tmp, atomically: true, encoding: .utf8)
            let parsed = MailCollector.parse(tmp)
            let got = OTP.find(in: (parsed?.0 ?? "") + " " + (parsed?.1 ?? "")) ?? ""
            if got == want { pass += 1 }
            else { fail += 1; print("FAIL  期望[\(want)] 实得[\(got)]  长度头=\(prefix)") }
            try? FileManager.default.removeItem(at: tmp)
        }

        print("== 邮件 MIME 正文：HTML / 编码 / 附件 / emlx 尾部 ==")
        let mailCases: [(String, String, String)] = [
            ("Subject: fragment\nContent-Type: text/plain; charset=utf-8\n\n正文<br><br>下一段", "fragment", "正文\n\n下一段"),
            ("Subject: mislabeled\nContent-Type: text/plain; charset=utf-8\n\n<html><div>交易所假日</div></html>", "mislabeled", "交易所假日"),
            ("Subject: empty plain\nContent-Type: multipart/alternative; boundary=x\n\n--x\nContent-Type: text/plain\n\n \n--x\nContent-Type: text/html\n\n<p>Real body</p>\n--x--", "empty plain", "Real body"),
            ("Subject: =?UTF-8?B?5rWL6K+V?=\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<html><head><style>.x{color:red}</style></head><body><p>你好 &amp; 欢迎</p><script>bad()</script><p>下一行</p></body></html>", "测试", "你好 & 欢迎\n\n下一行"),
            ("Subject: code\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: base64\n\nSGVsbG8gOTAzNDcx", "code", "Hello 903471"),
            ("Subject: qp\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: quoted-printable\n\n=E4=BD=A0=E5=A5=BD=\r\n world", "qp", "你好 world"),
            ("Subject: multi\nMIME-Version: 1.0\nContent-Type: multipart/mixed; boundary=x\n\n--x\nContent-Type: text/plain\nContent-Disposition: attachment\n\nattachment junk\n--x\nContent-Type: multipart/alternative; boundary=y\n\n--y\nContent-Type: text/plain\n\nplain body\n--y\nContent-Type: text/html\n\n<b>HTML duplicate</b>\n--y--\n--x--", "multi", "HTML duplicate")
        ]
        for (raw, subject, body) in mailCases {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notifhub-mime-\(UUID().uuidString).emlx")
            let content = "\(raw.utf8.count)\n\(raw)<?xml version=\"1.0\"?><plist>private metadata</plist>"
            try? content.write(to: tmp, atomically: true, encoding: .utf8)
            let parsed = MailCollector.parse(tmp)
            if parsed?.0 == subject && parsed?.1 == body { pass += 1 }
            else { fail += 1; print("FAIL MIME \(subject): \(String(describing: parsed))") }
            try? FileManager.default.removeItem(at: tmp)
        }

        print("== 跨源去重 ==")
        let t = (nowUnix() / 60).rounded(.down) * 60 + 10
        let fromUsernoted = Event(ts: t, source: "usernoted", bundle: "com.alibaba.dingtalkmac",
                                  app: "钉钉", title: "工作通知", subtitle: "", body: "验证码998877",
                                  extID: "1", recID: 1)
        let fromRemote = Event(ts: t + 3, source: "remote", bundle: "com.laiwang.DingTalk",
                               app: "钉钉", title: "工作通知", subtitle: "", body: "验证码998877",
                               extID: "IM_1", recID: nil)
        if fromUsernoted.dedupKey == fromRemote.dedupKey { pass += 1 }
        else { fail += 1; print("FAIL  钉钉 iOS/macOS 两个 bundle 没归一到同一个去重键") }

        let other = Event(ts: t, source: "usernoted", bundle: "com.tencent.xinwechat",
                          app: "微信", title: "工作通知", subtitle: "", body: "验证码998877",
                          extID: "2", recID: 2)
        if other.dedupKey != fromUsernoted.dedupKey { pass += 1 }
        else { fail += 1; print("FAIL  不同 app 的同文本被误判成重复") }

        print("== 规则引擎 ==")
        let cfg = Config()
        let otpEvent = Event(ts: t, source: "test", bundle: "com.apple.MobileSMS", app: "信息",
                             title: "", subtitle: "", body: "【虚构商店】验证码：112233，5分钟内有效",
                             extID: "", recID: nil)
        let hits = Engine.match(otpEvent, config: cfg)
        if hits.first?.code == "112233" { pass += 1 }
        else { fail += 1; print("FAIL  内置 otp 规则没命中或没抽到码: \(hits.map(\.rule.name))") }

        let chat = Event(ts: t, source: "test", bundle: "com.tencent.xinwechat", app: "微信",
                         title: "示例联系人", subtitle: "", body: "晚上一起吃饭吗", extID: "", recID: nil)
        if Engine.match(chat, config: cfg).isEmpty { pass += 1 }
        else { fail += 1; print("FAIL  普通聊天消息不该命中默认规则") }

        print("== 自反馈环闸门 ==")
        if let s = testStore() {
            s.markSelfEmitted(Actions.selfHash(title: "验证码已复制 246810", body: "京东"))
            let echoed = Event(ts: t, source: "usernoted", bundle: "com.apple.ScriptEditor2",
                               app: "scripteditor2", title: "验证码已复制 246810",
                               subtitle: "", body: "京东", extID: "", recID: nil)
            if s.isSelfEmitted(echoed) { pass += 1 }
            else { fail += 1; print("FAIL  自己弹的通知没被认出来 —— 自反馈环会复发") }

            let realOTP = Event(ts: t, source: "usernoted", bundle: "com.apple.MobileSMS", app: "信息",
                                title: "验证码", subtitle: "", body: "您的验证码是 246810", extID: "", recID: nil)
            if !s.isSelfEmitted(realOTP) { pass += 1 }
            else { fail += 1; print("FAIL  真验证码被误判成自己弹的 —— 会漏掉真码") }
        } else { fail += 2; print("FAIL  测试库建不起来") }

        print("== 保留期 ==")
        if let store = testStore() {
            var old = Event(ts: nowUnix() - 400 * 86400, source: "test", bundle: "t.old", app: "旧",
                            title: "很久以前", subtitle: "", body: "老正文", extID: "o", recID: nil)
            old.ts = nowUnix() - 400 * 86400
            let fresh = Event(ts: nowUnix(), source: "test", bundle: "t.new", app: "新",
                              title: "刚刚", subtitle: "", body: "新正文", extID: "n", recID: nil)
            store.insert(old); store.insert(fresh)
            let n = store.applyRetention(days: 30)
            var oldBody = "x", newBody = ""
            store.db.query("SELECT COALESCE(body,'<null>') FROM events WHERE ext_id='o'") { oldBody = $0.str(0) }
            store.db.query("SELECT COALESCE(body,'<null>') FROM events WHERE ext_id='n'") { newBody = $0.str(0) }
            if n >= 1 && oldBody == "<null>" && newBody == "新正文" { pass += 1 }
            else { fail += 1; print("FAIL  保留期: 清理 \(n) 条, 旧正文=[\(oldBody)] 新正文=[\(newBody)]") }
        } else {
            fail += 1; print("FAIL  测试库建不起来")
        }

        func ok(_ cond: Bool, _ msg: String) {
            if cond { pass += 1 } else { fail += 1; print("FAIL  \(msg)") }
        }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = displayTZ
        func comps(_ ts: Double) -> DateComponents {
            cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday],
                               from: Date(timeIntervalSince1970: ts))
        }

        let t0 = Date()
        let (trc, tout) = notifhub.run("/bin/sleep", ["30"], timeout: 2)
        let elapsed = Date().timeIntervalSince(t0)
        ok(trc == -9, "超时没返回 -9（实得 \(trc)）—— 挂住的子进程不会被识别为超时")
        ok(elapsed < 8, "超时没真杀掉，等了 \(String(format: "%.1f", elapsed))s —— 接单器会被堵死")
        ok(tout.contains("超时"), "超时没在输出里说明原因，排查时看不出发生了什么")
        let queueTransport = AgendaQueue.transportArguments(["-X", "PATCH", "-d", "{\"detail\":\"it's $(literal)\"}"], host: "fixture.invalid")
        ok(AgendaQueue.transportTimeout > 20 && AgendaQueue.transportTimeout < 60,
           "队列SSH必须有覆盖远端curl且短于轮询间隔的本机总时限")
        ok(queueTransport.contains("ServerAliveInterval=5") && queueTransport.contains("ServerAliveCountMax=3")
            && queueTransport.contains("ControlPath=none"), "已建立SSH连接也应限时，并禁用共享连接复用")
        ok(queueTransport.last?.contains("'--fail'") == true, "HTTP错误不能冒充领取确认")
        let quoteFixture = "it's $(printf not-executed) `printf also-not-executed`"
        let (quoteRC, quoteOut) = notifhub.run("/bin/sh", ["-c", "printf '%s' " + AgendaQueue.shellQuote(quoteFixture)], timeout: 2)
        ok(quoteRC == 0 && quoteOut == quoteFixture, "远端JSON参数里的引号和shell语法必须原样传递")

        print("== 全天事件跨天闸 ==")
        do {
            var c = Calendar(identifier: .gregorian); c.timeZone = displayTZ
            let due = 1786838400.0   // 某天的 09:00 左右，具体值不重要
            let d0 = c.startOfDay(for: Date(timeIntervalSince1970: due))
            let computed = AppleExport.allDayEnd(due)
            ok(computed == d0.timeIntervalSince1970,
               "全天事件的讫没落在当天零点 —— 会变成跨两天的全天事件")
            let sd = c.component(.day, from: d0)
            let ed = c.component(.day, from: Date(timeIntervalSince1970: computed))
            ok(sd == ed, "全天事件起讫不在同一天（起 \(sd) 讫 \(ed)）")
        }

        print("== 队列接单器 ==")
        do {
            let minimal = #"{"items":[{"id":"a31-1","agendaId":31}]}"#
            let r = try JSONDecoder().decode(AgendaQueue.QueueResponse.self,
                                             from: Data(minimal.utf8))
            ok(r.items.count == 1, "缺字段的队列条目整条读不出来（整队列会静默变空）")
            if let j = r.items.first {
                ok(j.status == "pending", "status 缺失没回落 pending，实得 \(j.status)")
                ok(j.target == "auto", "target 缺失没回落 auto，实得 \(j.target)")
                ok(j.attempts == 0, "attempts 缺失没回落 0，实得 \(j.attempts)")
                ok(j.title.contains("31"), "title 缺失没回落成可辨认的默认")
            }
        } catch {
            ok(false, "队列 JSON 缺字段直接解码失败：\(error)")
        }
        do {
            let fresh = ISO8601DateFormatter().string(from: Date())
            let stale = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
            let js = #"""
            {"items":[
              {"id":"p","agendaId":1,"status":"pending","attempts":0,"updatedAt":"\#(fresh)"},
              {"id":"d","agendaId":2,"status":"done","attempts":1,"updatedAt":"\#(fresh)"},
              {"id":"f","agendaId":3,"status":"failed","attempts":3,"updatedAt":"\#(fresh)"},
              {"id":"rFresh","agendaId":4,"status":"running","attempts":1,"updatedAt":"\#(fresh)"},
              {"id":"rStale","agendaId":5,"status":"running","attempts":1,"updatedAt":"\#(stale)"},
              {"id":"maxed","agendaId":6,"status":"pending","attempts":3,"updatedAt":"\#(fresh)"}
            ]}
            """#
            let r = try JSONDecoder().decode(AgendaQueue.QueueResponse.self, from: Data(js.utf8))
            let ids = Set(AgendaQueue.claimable(r.items).map(\.id))
            ok(ids.contains("p"), "pending 单没被领")
            ok(!ids.contains("d") && !ids.contains("f"), "done/failed 被重复领 → 会推两次")
            ok(!ids.contains("rFresh"), "刚开跑的 running 被抢 → 同一单两个进程在推")
            ok(ids.contains("rStale"), "超时 running 没被接管 → 崩一次就永久卡住")
            ok(!ids.contains("maxed"), "attempts 到顶还在领 → 无限重试")
        } catch {
            ok(false, "领单判据用例自身解码失败：\(error)")
        }
        do {
            let js = #"{"items":[{"id":"a1","agendaId":1,"force":true},{"id":"a2","agendaId":2}]}"#
            let r = try JSONDecoder().decode(AgendaQueue.QueueResponse.self, from: Data(js.utf8))
            ok(r.items.first?.force == true, "force:true 没读出来 —— 重推会退化成静默跳过")
            ok(r.items.last?.force == false, "force 缺省没回落 false（保守值）")
        } catch {
            ok(false, "force 字段用例自身解码失败：\(error)")
        }
        ok(AgendaQueue.reallyAdded("#31 和示例同学碰面  → 提醒事项 ✓"),
           "真写成功被判成没写 —— 成功的单会被标 failed")
        ok(!AgendaQueue.reallyAdded("#31 和示例同学碰面\n     提醒事项：已推过（abc），要重推加 --force"),
           "「已推过，跳过」被当成成功 —— 站上会显示「✓ 已加进」而苹果那边一条没多")

        ok(AgendaQueue.succeeded(kind: "note", output: "#7 已记到 2026-08-31 21:40：今天把示例练习改完了"),
           "note 真写进去了却被判失败")
        ok(!AgendaQueue.succeeded(kind: "note", output: "用法: notifhub note \"…\""),
           "note 没写成却被判成功 —— 日记会静默丢掉")
        ok(AgendaQueue.succeeded(kind: "status", output: "#31 → 完成：和示例同学碰面 · 提醒事项已勾掉"),
           "status 真标掉了却被判失败")
        ok(!AgendaQueue.succeeded(kind: "status", output: "#999 不存在"),
           "标一个不存在的 id 被判成功 —— app 上那条会显示已完成而库里还开着")
        ok(!AgendaQueue.succeeded(kind: "status", output: "#31 改不动"),
           "改不动被判成功")

        do {
            func job(_ fields: String) -> AgendaQueue.Job? {
                let raw = "{\"items\":[{\"id\":\"x\",\"agendaId\":31,\"title\":\"t\",\"target\":\"auto\"," +
                          "\"force\":false,\"noAlarm\":false,\"status\":\"pending\"," +
                          "\"requestedAt\":\"2026-08-31T00:00:00Z\",\"updatedAt\":\"2026-08-31T00:00:00Z\"," +
                          "\"attempts\":0" + (fields.isEmpty ? "" : "," + fields) + "}]}"
                return try? JSONDecoder().decode(AgendaQueue.QueueResponse.self,
                                                 from: Data(raw.utf8)).items.first
            }
            ok(job("\"kind\":\"note\",\"text\":\"今天把示例练习改完了\"").flatMap(AgendaQueue.argv(for:))
                 == ["note", "今天把示例练习改完了"], "note 的 argv 拼错")
            ok(job("\"kind\":\"note\",\"text\":\"   \"").flatMap(AgendaQueue.argv(for:)) == nil,
               "空白正文没被拦下 —— 会往库里写一条空随手记")
            ok(job("\"kind\":\"status\",\"to\":\"done\"").flatMap(AgendaQueue.argv(for:)) == ["done", "31"],
               "status→done 的 argv 拼错")
            ok(job("\"kind\":\"status\",\"to\":\"dropped\"").flatMap(AgendaQueue.argv(for:)) == ["drop", "31"],
               "status→dropped 的 argv 拼错")
            ok(job("\"kind\":\"push\"").flatMap(AgendaQueue.argv(for:)) == ["push", "31"], "push 的 argv 拼错")
            ok(job("")?.kind == "push", "没有 kind 的老单没被当成 push —— 存量队列会整批读不出来")
        }

        print("== 时间节点按钮 ==")
        do {
            let cfg = Config()
            let base = 1786838400.0
            var todo = AgendaItem(kind: "todo", title: "联系示例老师")
            todo.id = 101
            var pushedTodo = AgendaItem(kind: "todo", title: "已经推过的那条")
            pushedTodo.id = 102; pushedTodo.reminderID = "x-apple-reminder://ABC"
            var evt = AgendaItem(kind: "event", title: "参加示例活动")
            evt.id = 103; evt.dueTS = base; evt.endTS = base + 7200
            var doneItem = AgendaItem(kind: "todo", title: "已完成的")
            doneItem.id = 104; doneItem.status = "done"
            let day = Recap.Day(date: "2026-08-16", items: [], total: 0, muted: 0,
                                apps: [], whos: [], byHour: [Int](repeating: 0, count: 24),
                                first: nil, last: nil,
                                agenda: [todo, pushedTodo, evt, doneItem])
            let h = Recap.renderHTML(day, config: cfg)
            func btn(_ id: Int, _ to: String) -> Bool {
                h.contains("data-id=\"\(id)\" data-to=\"\(to)\"")
            }
            ok(btn(101, "reminders"), "待办没有「存进提醒事项」按钮")
            ok(!btn(101, "calendar"), "没时间的待办给了日历按钮 —— 日历事件必须有时刻，点了必失败")
            ok(btn(103, "reminders") && btn(103, "calendar"),
               "有时刻的日程没有「提醒事项 + 日历」两个按钮 —— 只按 kind 自动分流会把人送去错的 app")
            ok(btn(102, "reminders"), "已推过的条目没有按钮 —— 「重新添加」这条路被堵死了")
            ok(h.contains("已进提醒事项"), "已推过的没显示去处（用户看不出加没加、加到哪）")
            ok(!btn(104, "reminders"), "已完成的条目还能推 —— 复盘视图不该再往苹果里塞旧事")
            ok(h.contains("force: true"), "下单没带 force —— 重新添加会静默变成什么都不做")
            ok(h.contains("class=\"pstat") && h.contains("已加进"),
               "页面没有状态回显 —— 刷新后一律回到初始态，看不出上次点的成没成")
        }

        print("== remain 面 ==")
        do {
            let idx = Publish.renderIndex([])
            ok(idx.contains("href=\"remain.html\""), "索引页没有 remain 入口 —— 未完成清单在站上但没人找得到")
            let fb = Remain.fallbackHTML("boom-marker-123")
            ok(fb.contains("没生成出来") && fb.contains("boom-marker-123"),
               "失败占位页没把错误可见地写出来 —— 缺席会长得像「全清了」")
        }

        print("== Bark 完整正文、UTF-8 字节预算与静音归档分段 ==")
        do {
            let body = String(repeating: "中文😀👩‍💻 <>&\u{2028}\u{2029} \"quoted\" \\\n", count: 900)
            let origin: [String: Any] = ["host": "fixture-host", "component": "notifhub.collector", "entrypoint": "Actions.perform.bark",
                "job": "fixture-rule", "run_id": "event:42", "pid": 7,
                "owner_session": ["provider": "codex", "sid": "owner-fixture-full-sid"],
                "model_session": ["provider": "claude", "sid": "model-fixture-full-sid"]]
            let header = try BarkOrigin.header(origin)
            let parts = try BarkPayload.parts(["title": "规则报告", "body": body, "group": "fixture", "device_key": "fake-device"], origin: origin)
            ok(parts.count > 2 && parts.compactMap { $0["body"] as? String }.map { String($0.dropFirst(header.count)) }.joined() == body, "Bark 长正文被截断或丢失换行")
            ok(try parts.allSatisfy { try BarkPayload.byteCount($0) <= BarkPayload.byteBudget }, "Bark 分段超过 UTF-8/APNs 字节预算")
            ok(parts.allSatisfy { $0["isArchive"] as? String == "1" }, "Bark 分段没有归档")
            ok(parts.dropFirst().allSatisfy { $0["level"] as? String == "passive" && $0["sound"] as? String == "" }, "Bark 后续段仍有提醒声")
            ok(parts.allSatisfy { ($0["body"] as? String)?.hasPrefix(header) == true
                && ($0["origin"] as? [String: Any])?["run_id"] as? String == "event:42" }, "Bark 分段漏了可见来源或来源元数据")
            ok(header.contains("主机=fixture-host") && header.contains("组件=notifhub.collector")
                && header.contains("发送入口：Actions.perform.bark") && header.contains("执行=event:42")
                && header.contains("发起会话：Codex SID=owner-fixture-full-sid")
                && header.contains("业务模型会话：Claude SID=model-fixture-full-sid"), "Bark 发起会话与实际模型会话串错或SID截断")
            let unknown = try BarkOrigin.normalize(["component": "fixture", "pid": 7], environment: [:])
            let unknownHeader = try BarkOrigin.header(unknown)
            ok(unknownHeader.contains("名称未取得") && unknownHeader.contains("SID未取得")
                && unknownHeader.contains("执行=pid:7"), "Bark 来源缺失没有如实标明")
            let rule = try BarkOrigin.normalize(BarkOrigin.rule("fixture", eventID: 42, source: "usernoted"),
                                               environment: ["CODEX_THREAD_ID": "unrelated-fixture-owner"])
            let ruleHeader = try BarkOrigin.header(rule)
            ok(!ruleHeader.contains("unrelated-fixture-owner") && ruleHeader.contains("不适用模型会话")
                && rule["run_id"] as? String == "event:42:usernoted", "系统规则通知借用了发起AI会话或丢了真实事件ID")
            let ownerOnly = try BarkOrigin.normalize(["component": "fixture", "pid": 7], environment: ["CODEX_THREAD_ID": "owner-only-fixture"])
            ok((ownerOnly["owner_session"] as? [String: Any])?["sid"] as? String == "owner-only-fixture"
                && (ownerOnly["model_session"] as? [String: Any])?["status"] as? String == "unavailable", "Bark 发起SID被误当作业务模型SID")
            do {
                _ = try BarkOrigin.normalize(["component": "fixture\ninjected", "pid": 7], environment: [:])
                ok(false, "Bark 来源控制字符没有拒绝")
            } catch { ok(true, "Bark 来源控制字符拒绝") }
            let safeOrigin = try BarkPayload.parts(["title": "来源脱敏", "body": "正文", "device_key": "raw-device-key"],
                origin: ["host": "fixture", "component": "fixture", "entrypoint": "sender", "pid": 7,
                         "job": "password=origin-secret", "run_id": "raw-device-key"])
            let originMetadata = safeOrigin[0]["origin"] as? [String: Any] ?? [:]
            let encodedOrigin = String(decoding: try BarkPayload.encoded(originMetadata), as: UTF8.self)
            ok(!originMetadata.isEmpty && !encodedOrigin.contains("origin-secret") && !encodedOrigin.contains("raw-device-key")
               && !(safeOrigin[0]["body"] as! String).contains("origin-secret"), "Bark 来源元数据或可见header泄露凭证")
            let hidden = BarkPayload.safe("password=private-value\nBearer bearer-value\nraw-device-key", key: "raw-device-key")
            ok(!hidden.contains("private-value") && !hidden.contains("bearer-value") && !hidden.contains("raw-device-key"), "Bark 正文或回执泄露凭证")
            let cookies = BarkPayload.safe("Cookie: session=cookie-secret; track=cookie-track\nJD_COOKIE=pt_key=jd-key;pt_pin=jd-user;\nwskey=ws-secret\npt_key=pt-secret;pt_pin=pin-secret;\n错误原因：限额，明细保留")
            ok(["cookie-secret", "cookie-track", "jd-key", "jd-user", "ws-secret", "pt-secret", "pin-secret"].allSatisfy { !cookies.contains($0) }
               && cookies.contains("错误原因：限额，明细保留"), "Bark Cookie/JD 登录字段未安全隐藏或删掉后续诊断")
            do {
                _ = try BarkPayload.parts(["title": String(repeating: "x", count: 5000), "body": "正文"])
                ok(false, "Bark 过大元信息没有明确失败")
            } catch { ok(true, "Bark 过大元信息拒绝") }
        } catch { ok(false, "Bark 分段纯函数失败：\(type(of: error))") }

        print("== 配置容错解码 ==")
        let partial = #"{"rules":[{"name":"只写了名字"}]}"#
        do {
            let c = try JSONDecoder().decode(Config.self, from: Data(partial.utf8))
            ok(c.retentionDays == 365, "顶层缺键没回落默认: retentionDays=\(c.retentionDays)")
            ok(c.bark.server == "https://api.day.app", "Bark 子结构缺键没回落默认")
            ok(c.summary.minIntervalSeconds == 10800 && c.summary.enabled,
               "SummaryCfg 子结构缺键没回落默认")
            ok(c.apple.defaultDueHour == 9 && c.apple.defaultEventMinutes == 60,
               "AppleCfg 子结构缺键没回落默认")
            ok(c.rules.count == 1 && c.rules[0].name == "只写了名字"
               && c.rules[0].actions == ["clipboard"] && c.rules[0].enabled,
               "Rule 只写 name 时其余字段没回落默认: \(c.rules)")
        } catch {
            ok(false, "残缺配置整个解析失败了（\(error)）—— 用户手上的旧 rules.json 会被静默丢弃")
        }

        ok(Sources.all().map(\.name) == ["usernoted", "remote", "messages", "mail"],
           "采集源清单变了：\(Sources.all().map(\.name))。加源要同步改这条用例 —— "
           + "它是「doctor 会不会漏查」的唯一机器守卫")

        print("== 时间解析 ==")
        let base = cal.date(from: DateComponents(year: 2026, month: 8, day: 14, hour: 10, minute: 0))!
        func when(_ s: String) -> (ts: Double, allDay: Bool)? {
            WhenParser.parse(s, now: base, defaultHour: 9)
        }
        if let r = when("2026-08-20T15:00") {
            let c = comps(r.ts)
            ok(c.year == 2026 && c.month == 8 && c.day == 20 && c.hour == 15 && c.minute == 0 && !r.allDay,
               "ISO 带时刻解析错: \(c)")
        } else { ok(false, "2026-08-20T15:00 解析不出来") }

        if let r = when("2026-08-20") {
            let c = comps(r.ts)
            ok(c.day == 20 && c.hour == 9 && r.allDay, "只有日期该落 defaultHour 且算整天: \(c) allDay=\(r.allDay)")
        } else { ok(false, "2026-08-20 解析不出来") }

        if let r = when("明天 15:00") {
            let c = comps(r.ts)
            ok(c.month == 8 && c.day == 15 && c.hour == 15, "「明天 15:00」错: \(c)")
        } else { ok(false, "「明天 15:00」解析不出来") }

        if let r = when("周三下午3点") {
            let c = comps(r.ts)
            ok(c.weekday == 4 && c.hour == 15 && r.ts > base.timeIntervalSince1970
               && r.ts - base.timeIntervalSince1970 <= 7 * 86400,
               "「周三下午3点」错: \(c)")
        } else { ok(false, "「周三下午3点」解析不出来") }

        if let r = when("下周四") {
            ok(comps(r.ts).month == 8 && comps(r.ts).day == 20, "周五说「下周四」该是 08-20: \(comps(r.ts))")
        } else { ok(false, "「下周四」解析不出来") }
        let mon = cal.date(from: DateComponents(year: 2026, month: 8, day: 17, hour: 10))!  // 周一
        if let r = WhenParser.parse("下周三 14:00", now: mon, defaultHour: 9) {
            let c = comps(r.ts)
            ok(c.day == 26 && c.hour == 14, "周一说「下周三」该是 08-26（不是后天 08-19）: \(c)")
        } else { ok(false, "「下周三 14:00」解析不出来") }
        if let r = WhenParser.parse("本周三", now: mon, defaultHour: 9) {
            ok(comps(r.ts).day == 19, "周一说「本周三」该是 08-19: \(comps(r.ts))")
        } else { ok(false, "「本周三」解析不出来") }

        if let r = when("8月20日 9:30") {
            let c = comps(r.ts)
            ok(c.month == 8 && c.day == 20 && c.hour == 9 && c.minute == 30, "「8月20日 9:30」错: \(c)")
        } else { ok(false, "「8月20日 9:30」解析不出来") }

        if let r = when("15:30") {
            let c = comps(r.ts)
            ok(c.day == 14 && c.hour == 15 && c.minute == 30, "光给时刻该落当天: \(c)")
        } else { ok(false, "「15:30」解析不出来") }
        if let r = when("08:00") {
            ok(comps(r.ts).day == 15, "已过的时刻没顺延到明天: \(comps(r.ts))")
        } else { ok(false, "「08:00」解析不出来") }

        if let r = WhenParser.parse("+2h", now: base) {
            ok(abs(r.ts - base.timeIntervalSince1970 - 7200) < 2, "「+2h」偏移不对")
        } else { ok(false, "「+2h」解析不出来") }

        ok(when("下次再说") == nil, "看不懂的时间必须返回 nil，不能瞎猜一个")

        print("== LLM 回复解析 ==")
        ok(Summarizer.parseJSON("```json\n{\"headline\":\"忙\"}\n```")?["headline"] as? String == "忙",
           "带 ``` 围栏的 JSON 没剥干净")
        ok(Summarizer.parseJSON("好的，结果如下：{\"headline\":\"忙\"} 以上。")?["headline"] as? String == "忙",
           "前后带废话的 JSON 没抠出来")
        ok(Summarizer.parseJSON("我不知道") == nil, "不是 JSON 时必须返回 nil")

        let broken = #"{"headline":"落户材料跑派出所办成","points":["落户线跑通：下午在派出所补齐材料","points_note":null,"threads":null,"agenda":null}"#
        let repaired = Summarizer.parseJSON(broken)
        ok(repaired?["headline"] as? String == "落户材料跑派出所办成"
           && (repaired?["points"] as? [Any])?.count == 1
           && repaired?.keys.contains("threads") == true,
           "少一个 ] 的 JSON 没修回来 —— 那天就永远没有总结: \(String(describing: repaired))")
        ok(Summarizer.repairBrackets(#"{"a":["x","y"],"b":1}"#) == nil, "合法 JSON 被误修了")
        ok(Summarizer.parseJSON(#"{"headline":"落户材料跑派出所办成，同时}"#) == nil,
           "被截断（字符串没收尾）的输出不许硬猜成功")

        let noTime = Summarizer.makeItem(["title": "跟示例联系人对方案", "kind": "event"],
                                         srcDate: "2026-08-14", config: cfg)
        ok(noTime?.kind == "todo" && noTime?.dueTS == nil, "没时刻的 event 没降级成 todo")
        let timed = Summarizer.makeItem(["title": "评审会", "kind": "event",
                                         "when": "2026-08-20T14:00", "durationMinutes": 90],
                                        srcDate: "2026-08-14", config: cfg)
        ok(timed?.kind == "event" && timed?.endTS != nil
           && abs((timed!.endTS! - timed!.dueTS!) - 5400) < 1, "event 的时长没按 durationMinutes 算")
        ok(Summarizer.makeItem(["kind": "todo"], srcDate: "d", config: cfg) == nil, "没标题的条目必须丢掉")

        print("== agenda 幂等与重算保护 ==")
        if let s = testStore() {
            let a = AgendaItem(source: "llm", srcDate: "2026-08-14", title: "交周报",
                               dueTS: base.timeIntervalSince1970)
            ok(s.insertAgenda(a) != nil, "第一次插入该成功")
            ok(s.insertAgenda(a) == nil, "同一条重复插入必须被 dedup_key 挡住")

            var pushed = AgendaItem(source: "llm", srcDate: "2026-08-14", title: "已经推过的")
            _ = s.insertAgenda(pushed)
            pushed.id = s.agenda(where: "title='已经推过的'").first?.id ?? 0
            s.setAgendaPushed(pushed.id, reminderID: "x-apple-reminder://TEST", calendarID: nil)
            _ = s.insertAgenda(AgendaItem(source: "manual", srcDate: "2026-08-14", title: "我自己加的"))

            let cleared = s.clearLLMAgenda(date: "2026-08-14")
            let left = Set(s.agenda(where: "1=1").map(\.title))
            ok(cleared == 1 && left == ["已经推过的", "我自己加的"],
               "重算只该清掉「LLM 抽的+没推+还 open」的，实际清了 \(cleared) 条，剩 \(left)")

            s.setAgendaPushed(pushed.id, reminderID: nil, calendarID: "CAL-1")
            let after = s.agendaItem(id: pushed.id)
            ok(after?.reminderID == "x-apple-reminder://TEST" && after?.calendarID == "CAL-1",
               "推日历把已有的提醒事项 id 抹掉了")
        } else { ok(false, "测试库建不起来") }

        print("== 随手记入时间线 ==")
        if let s = testStore() {
            let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!.timeIntervalSince1970
            let today = dayString(noon)
            var e = Event(ts: noon + 3600, source: "test", bundle: "com.tencent.xinwechat", app: "微信",
                          title: "示例联系人", subtitle: "", body: "晚上吃饭", extID: "e1", recID: nil)
            e.ts = noon + 3600
            s.insert(e)
            s.insertNote(text: "上午完成示例练习", ts: noon, date: today)
            let d = Recap.load(store: s, date: today, includeAll: true, config: cfg)
            ok(d.items.first?.canon == Recap.noteCanon && d.items.count == 2,
               "随手记没按时刻排到通知前面: \(d.items.map(\.app))")
            ok(d.total == 1 && d.notes == 1, "随手记被算进了「通知总数」: total=\(d.total) notes=\(d.notes)")
            var busy = d
            for i in 0..<60 {
                busy.items.append(Recap.Item(ts: noon + Double(i * 60), endTs: noon + Double(i * 60),
                    canon: "test", app: "测试", who: "全天事件\(i)",
                    lines: ["事件正文\(i)" + String(repeating: "长正文", count: 300)], redacted: false, missed: false))
            }
            busy.items.append(Recap.Item(ts: noon + 7200, endTs: noon + 7200,
                canon: Recap.noteCanon, app: "随手记", who: "尾部随手记",
                lines: ["最后补充的笔记"], redacted: false, missed: false))
            do {
                let balanced = try Summarizer.timeline(busy, maxChars: 3200)
                ok(balanced.count <= 3200 && balanced.contains("尾部随手记") &&
                   balanced.contains("上午完成示例练习") &&
                   (0..<60).allSatisfy { balanced.contains("全天事件\($0):") },
                   "总结预算未覆盖全天事件及尾部笔记，或突破预算")
                do {
                    _ = try Summarizer.timeline(busy, maxChars: 100)
                    ok(false, "预算不足仍静默遗漏全天记录")
                } catch { ok(true, "预算不足明确失败") }
            } catch { ok(false, "均衡总结测试失败: \(error)") }
        } else { ok(false, "测试库建不起来") }

        print("== 总结 markdown 渲染 ==")
        let md = Recap.mdLite("- 上午改方案\n- 下午见示例联系人\n\n**几条线：**\n- 示例联系人：等我回")
        ok(md.contains("<li>上午改方案</li>") && md.contains("<strong>几条线：</strong>")
           && !md.contains("**"), "mdLite 没渲染干净: \(md)")
        ok(Recap.mdLite("<script>x</script>").contains("&lt;script&gt;"),
           "总结正文没转义，HTML 会被注进页面")

        print("== 划天走系统时区 ==")
        let (rlRC, rlOut) = notifhub.run("/bin/sh", ["-c", "readlink -f /etc/localtime"])
        let sysName = rlOut.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "zoneinfo/").last ?? ""
        ok(rlRC == 0 && !sysName.isEmpty && Clock.systemTZName == sysName,
           "Clock 解出来的系统时区和 readlink 对不上: Clock=[\(Clock.systemTZName ?? "nil")] readlink=[\(sysName)]")
        ok(Clock.tz.identifier == sysName && Clock.resolvedFromSystem,
           "划天用的不是系统时区: \(Clock.tz.identifier) ≠ \(sysName)")

        let probeTS = 1_786_811_400.0   // 固定一个时刻，具体是哪天由系统时区决定
        if let s = testStore() {
            let want = dayString(probeTS)
            let prevTZ = ProcessInfo.processInfo.environment["TZ"]
            var got: [String] = []
            for fake in ["America/Los_Angeles", "Asia/Tokyo"] {
                setenv("TZ", fake, 1); tzset()
                s.db.query("SELECT \(Clock.sqlDay("?"))", [probeTS]) { got.append($0.str(0)) }
            }
            if let prevTZ { setenv("TZ", prevTZ, 1) } else { unsetenv("TZ") }
            tzset()
            ok(got == [want, want],
               "掰进程 TZ 之后 SQLite 侧划天跟着变了: \(got)（应两次都是 \(want)）")
        } else { ok(false, "测试库建不起来") }

        if let s = testStore() {
            for offset in [-86400.0, 0, 86400.0] {
                let ts = probeTS + offset
                let e = Event(ts: ts, source: "test", bundle: "summary-date-test", app: "测试",
                              title: "日期", subtitle: "", body: "fixture \(offset)",
                              extID: "summary-date-\(offset)", recID: nil)
                s.insert(e)
            }
            let dates = Summarizer.recentDates(store: s, count: 2, through: dayString(probeTS))
            ok(dates == [dayString(probeTS), dayString(probeTS - 86400)],
               "未来记录挤掉总结窗口的昨天: \(dates)")
        } else { ok(false, "总结日期测试库建不起来") }

        let selfBin: String = {
            let p = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
            return FileManager.default.isExecutableFile(atPath: p) ? p : Paths.installedBinary.path
        }()
        var probes: [String] = []
        for fake in ["America/Los_Angeles", "Asia/Tokyo"] {
            let (rc, out) = notifhub.run(selfBin, ["__tzprobe", String(Int(probeTS))], env: ["TZ": fake])
            probes.append(rc == 0 ? out.trimmingCharacters(in: .whitespacesAndNewlines) : "rc=\(rc)")
        }
        ok(probes == [dayString(probeTS), dayString(probeTS)],
           "换 TZ 起子进程后划天变了: \(probes)（应两次都是 \(dayString(probeTS))，bin=\(selfBin)）")

        print("== AI 协作：输入与用时 ==")
        aiWorkTests(ok)

        print("== AppleScript 传参安全 ==")
        let nasty = #"示例联系人说 "行" \ 然后 & 走了"#
        let echoed = AppleExport.echoArgv(nasty)
        ok(echoed == nasty, "argv 传参把特殊字符搞坏了: 期望[\(nasty)] 实得[\(echoed)]")

        print("== 安装计划：App 内采集器 ==")
        installPlanTests(ok, selfBin: selfBin)

        print("== 本机数据：15 域 / 正文解码 / 接通判据 / 打码 / 导出 / 往来 / 退出码 ==")
        dataTests(ok, selfBin: selfBin)

        AgentSelfTest.run(ok, selfBin: selfBin)

        SyncSelfTest.run(ok, selfBin: selfBin)

        JobsSelfTest.run(ok, selfBin: selfBin)

        print("\n通过 \(pass) / 失败 \(fail)")

        guard live else {
            print("（未跑 --live：以上只验规则与库逻辑，**没验**「真通知会不会被抓到」）")
            return fail == 0
        }
        Log.silent = false   // 端到端那段跑的是真库真通知，日志要留痕
        return liveTest(&pass, &fail) && fail == 0
    }

    private static func liveTest(_ pass: inout Int, _ fail: inout Int) -> Bool {
        print("\n== 端到端（--live）==")
        guard let store = Store() else { print("FAIL 库打不开"); return false }
        let marker = "notifhub-live-\(Int(nowUnix()))"
        Actions.localNotify(title: "notifhub 自检", body: marker)
        print("已发出测试通知，等采集…")

        var found = false
        for i in 1...20 {
            Thread.sleep(forTimeInterval: 1)
            if i == 3, let d = Daemon() { d.ingest() }
            store.db.query("SELECT COUNT(*) FROM events WHERE body LIKE ?", ["%\(marker)%"]) {
                if $0.int(0) > 0 { found = true }
            }
            if found { print("✅ 第 \(i) 秒在库里查到了这条通知"); break }
        }
        if found { pass += 1 } else { fail += 1; print("FAIL  20 秒内没在库里查到测试通知") }
        return found
    }

    private static func aiWorkTests(_ ok: (Bool, String) -> Void) {
        ok(AIWork.activeMinutes([100, 105, 140], idle: 15) == 7,
           "用时算法：间隔 5 分钟应补上、35 分钟应断开，[100,105,140] 应为 7，实得 \(AIWork.activeMinutes([100, 105, 140], idle: 15))")
        let isoSample = "2026-09-24T06:35:06.546Z"
        let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        ok(AIWork.parseISO(isoSample) == floor(fmt.date(from: isoSample)!.timeIntervalSince1970),
           "手写 ISO 时间解析和系统解析对不上：\(String(describing: AIWork.parseISO(isoSample)))")
        ok(!AIWork.worthKeeping("/clear") && AIWork.worthKeeping("/review 看看这个改动") && AIWork.worthKeeping("继续"),
           "纯命令应跳过、带内容的命令和普通输入应保留")

        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notifhub-ai-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let roots = AIWork.Roots(claudeHistory: root.appendingPathComponent("claude/history.jsonl"),
                                 codexHistory: root.appendingPathComponent("codex/history.jsonl"),
                                 claudeProjects: root.appendingPathComponent("claude/projects"),
                                 codexSessions: [root.appendingPathComponent("codex/sessions")])
        for d in [roots.claudeProjects.appendingPathComponent("p"), roots.codexSessions[0].appendingPathComponent("2026/09/23")] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let home = Paths.home.path
        let foo = home + "/Apps/zz-ai-test-foo", bar = home + "/Apps/zz-ai-test-bar"
        let secret = home + "/Personal/legal/zz-ai-test-case"
        let day = dayString(nowUnix() - 86400)
        let t0 = AIWork.dayBounds(day)!.0 + 10 * 3600          // 昨天 10:00
        func iso(_ t: Double) -> String {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.string(from: Date(timeIntervalSince1970: t))
        }
        func line(_ o: [String: Any]) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! + "\n"
        }
        func write(_ url: URL, _ s: String, append: Bool = false) {
            if append, let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(s.data(using: .utf8)!); try? h.close()
            } else { try? s.write(to: url, atomically: true, encoding: .utf8) }
        }
        var claude = ""
        for m in [0, 5, 10] { claude += line(["type": "assistant", "timestamp": iso(t0 + Double(m) * 60), "cwd": foo, "sessionId": "s1", "entrypoint": "cli"]) }
        claude += line(["type": "user", "timestamp": iso(t0 + 20 * 60), "cwd": bar, "sessionId": "s1", "entrypoint": "cli"])
        claude += line(["type": "assistant", "timestamp": iso(t0 + 60 * 60), "cwd": foo, "sessionId": "s9", "entrypoint": "sdk-cli"])
        write(roots.claudeProjects.appendingPathComponent("p/s1.jsonl"), claude)
        write(roots.claudeHistory,
              line(["display": "修一下 foo 的登录", "timestamp": (t0 + 60) * 1000, "project": foo, "sessionId": "s1"])
            + line(["display": "/clear", "timestamp": (t0 + 120) * 1000, "project": foo, "sessionId": "s1"])
            + line(["display": "顺手把 bar 的测试也补上", "timestamp": (t0 + 21 * 60) * 1000, "project": foo, "sessionId": "s1"])
            + line(["display": "起诉状第三段改一下", "timestamp": (t0 + 30 * 60) * 1000, "project": secret, "sessionId": "s2"])
            + line(["display": "太早的一条", "timestamp": (t0 - 90 * 86400) * 1000, "project": foo, "sessionId": "s1"])
            + #"{"display":"还没写完的一行","timestamp":"#)   // 没有换行 = 还在写
        let sid = "01a0aaaa-0000-7000-8000-000000000001"
        write(roots.codexSessions[0].appendingPathComponent("2026/09/23/rollout-2026-09-23T10-00-00-\(sid).jsonl"),
              line(["type": "session_meta", "timestamp": iso(t0 + 40 * 60), "payload": ["id": sid, "cwd": bar, "originator": "codex-tui", "source": "cli"]])
            + line(["type": "response_item", "timestamp": iso(t0 + 44 * 60), "payload": ["type": "message"]]))
        write(roots.codexSessions[0].appendingPathComponent("2026/09/23/rollout-2026-09-23T11-00-00-01a0aaaa-0000-7000-8000-000000000002.jsonl"),
              line(["type": "session_meta", "timestamp": iso(t0 + 90 * 60), "payload": ["id": "x", "cwd": foo, "originator": "codex_exec", "source": "exec"]])
            + line(["type": "response_item", "timestamp": iso(t0 + 95 * 60), "payload": [:] as [String: Any]]))
        write(roots.codexHistory, line(["session_id": sid, "ts": t0 + 41 * 60, "text": "看看 bar 的构建为什么挂了"]))

        guard let s = testStore() else { ok(false, "AI 测试库建不起来"); return }
        var cfg = Config()
        cfg.ai.privatePaths = ["~/Personal/legal"]
        let first = AIWork.collect(store: s, config: cfg, roots: roots)
        var bodies: [String: String] = [:]
        s.db.query("SELECT body, title FROM events WHERE canon IN ('claude','codex')") { bodies[$0.str(0)] = $0.str(1) }
        ok(first.prompts == 4 && bodies["/clear"] == nil && bodies["太早的一条"] == nil,
           "输入收取条数不对：应收 4 条（跳过 /clear、回填窗口外、半行），实得 \(first.prompts)：\(bodies)")
        ok(bodies["修一下 foo 的登录"] == "Apps/zz-ai-test-foo",
           "项目归属不对：foo 的输入应归 Apps/zz-ai-test-foo，实得 \(bodies["修一下 foo 的登录"] ?? "无")")
        ok(bodies["顺手把 bar 的测试也补上"] == "Apps/zz-ai-test-bar",
           "会话 cd 之后的输入应按当时目录归 bar，不按启动目录：实得 \(bodies["顺手把 bar 的测试也补上"] ?? "无")")
        ok(bodies["看看 bar 的构建为什么挂了"] == "Apps/zz-ai-test-bar",
           "Codex 输入应从会话头拿到目录：实得 \(bodies["看看 bar 的构建为什么挂了"] ?? "无")")
        ok(!bodies.keys.contains("起诉状第三段改一下") && bodies.values.contains(AIWork.privateLabel),
           "私密目录的输入正文泄进库了：\(bodies.keys.sorted())")

        let w = AIWork.day(store: s, date: day, config: cfg)
        let rows = Dictionary((w?.rows ?? []).map { ($0.project, $0) }, uniquingKeysWith: { a, _ in a })
        ok(rows["Apps/zz-ai-test-foo"]?.minutes == 11,
           "foo 用时应为 11 分钟（0–10 连续，sdk 调用与 exec 会话不算），实得 \(rows["Apps/zz-ai-test-foo"].map { String($0.minutes) } ?? "无")")
        ok(rows["Apps/zz-ai-test-bar"]?.byTool.map(\.0).sorted() == ["Claude Code", "Codex"],
           "bar 应同时有 Claude Code 与 Codex 用时：\(rows["Apps/zz-ai-test-bar"].map { "\($0.byTool)" } ?? "无")")

        write(roots.claudeHistory, "\"x\"}\n", append: true)
        write(roots.claudeHistory, line(["display": "接着改 foo", "timestamp": (t0 + 50 * 60) * 1000, "project": foo, "sessionId": "s1"]), append: true)
        let second = AIWork.collect(store: s, config: cfg, roots: roots)
        ok(second.prompts == 1 && second.minutes == 0,
           "增量收取应只多 1 条输入、0 分钟，实得 \(second.prompts) 条 / \(second.minutes) 分钟")

        let d = Recap.load(store: s, date: day, includeAll: false, config: cfg)
        ok(d.total == 0 && d.aiInputs == 5 && d.whos.isEmpty,
           "AI 输入不该算进通知数和联系人：total=\(d.total) aiInputs=\(d.aiInputs) whos=\(d.whos)")
        let text = (try? Summarizer.timeline(d, maxChars: 4000)) ?? ""
        ok(text.contains("[Claude Code] Apps/zz-ai-test-foo") && text.contains("[Codex] Apps/zz-ai-test-bar"),
           "总结输入里缺 AI 条目：\(text.prefix(300))")
        let md = Summarizer.workMarkdown([["project": "Apps/zz-ai-test-foo", "did": "修好登录", "pending": "补测试", "state": "进行中"]], day: d.work)
        ok(md.contains("（11m）") && md.contains("还没做：**补测试"),
           "AI 协作段应带会话日志算的用时与未完成项：\(md)")
        let feed = String(data: (try? JSONEncoder().encode(JSONFeed.day(d))) ?? Data(), encoding: .utf8) ?? ""
        ok(feed.contains("\"wallMinutes\"") && feed.contains("zz-ai-test-bar"), "feed 里缺 work 用时")
    }

    private static func installPlanTests(_ ok: (Bool, String) -> Void, selfBin: String) {
        let bin = URL(fileURLWithPath: "/Applications/Notihub.app/Contents/Resources/bin/notihub")
        let app = Paths.bundle(ofAppBinary: bin)
        ok(app.path == "/Applications/Notihub.app", "appBundle 应为 /Applications/Notihub.app，实得 \(app.path)")
        let home = URL(fileURLWithPath: "/tmp/notihub-plan-home")
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        let binDir = home.appendingPathComponent(".local/bin")
        let data = home.appendingPathComponent(".local/share/notifhub")

        let p = Installer.plan(binary: bin, app: app, instanceID: nil, labelPrefix: "com.notifhub",
                               instanceConfig: nil, dataDir: data, launchAgentsDir: agents, binDir: binDir) { url in
            url.lastPathComponent == "notifhub" ? .regularFile : .missing
        }
        let labels = p.jobs.map(\.label)
        ok(labels == ["com.notifhub.daemon"], "launchd 里应只有 daemon 一个作业（接单/同步/总结由它调度），实得 \(labels)")
        ok(!p.jobs.contains { $0.content["StartInterval"] != nil }, "安装计划不该再有定时作业: \(labels)")
        ok(p.untouchedJobs == ["com.notifhub.queue", "com.notifhub.publish", "com.notifhub.summarize"],
           "untouched_jobs 应列出三个已退役的旧作业（不写也不卸）: \(p.untouchedJobs)")
        ok(p.json["daemon_tasks"] as? [String] == ["queue", "sync", "summarize"], "dry-run JSON 应写明采集器调度哪些任务")
        ok(p.jobs.allSatisfy { ($0.content["ProgramArguments"] as? [String])?.first == bin.path },
           "ProgramArguments[0] 应全是 App 内路径 \(bin.path)")
        func hasTZ(_ c: [String: Any]) -> Bool {
            c["TZ"] != nil || ((c["EnvironmentVariables"] as? [String: String])?["TZ"] != nil)
        }
        ok(!p.jobs.contains { hasTZ($0.content) }, "plist 里出现了 TZ（会把划天口径冻住）")
        ok(!p.jobs.contains { $0.content["EnvironmentVariables"] != nil }, "个人实例 plist 不该带任何环境变量")
        let daemon = p.jobs.first?.content ?? [:]
        ok(daemon["KeepAlive"] as? Bool == true && daemon["RunAtLoad"] as? Bool == true
           && daemon["ProcessType"] as? String == "Background" && daemon["LowPriorityIO"] as? Bool == true
           && daemon["StandardErrorPath"] as? String == data.appendingPathComponent("daemon.err").path,
           "daemon plist 键和旧版不一致: \(daemon)")
        let linkActs = p.links.map { "\($0.path.lastPathComponent):\($0.action)" }
        ok(linkActs == ["notihub:create", "notifhub:skip-regular-file"], "软链动作不对（普通文件必须 skip）: \(linkActs)")
        ok(p.links.allSatisfy { $0.target.path == bin.path && $0.path.deletingLastPathComponent().path == binDir.path }, "软链目标应全指向 App 内二进制")
        let j = p.json
        ok(j["mode"] as? String == "app" && j["copies_binary"] as? Bool == false && j["resigns"] as? Bool == false
           && j["instance"] is NSNull && JSONSerialization.isValidJSONObject(j),
           "dry-run JSON 契约字段不对: mode/copies_binary/resigns/instance")
        ok(p.jobs.allSatisfy { (try? PropertyListSerialization.data(fromPropertyList: $0.content, format: .xml, options: 0)) != nil },
           "plist 内容序列化不了")

        let cfg = "/tmp/notihub-plan-home/.config/notifhub/instance.json"
        let q = Installer.plan(binary: bin, app: app, instanceID: "acme", labelPrefix: "com.notifhub.acme",
                               instanceConfig: cfg, dataDir: data, launchAgentsDir: agents, binDir: binDir) { url in
            switch url.lastPathComponent {
            case "notihub": return .symlink(resolvedTo: bin.path)
            case "notifhub": return .symlink(resolvedTo: "/Users/x/.local/bin/old-notifhub")
            default: return .missing
            }
        }
        ok(q.jobs.map(\.label) == ["com.notifhub.acme.daemon"], "实例模式应只装 daemon: \(q.jobs.map(\.label))")
        ok(q.jobs.first?.content["EnvironmentVariables"] as? [String: String] == ["NOTIFHUB_INSTANCE_CONFIG": cfg],
           "实例 plist 环境变量应只有 NOTIFHUB_INSTANCE_CONFIG")
        ok(!q.jobs.contains { hasTZ($0.content) }, "实例 plist 出现了 TZ")
        ok(q.untouchedJobs == ["com.notifhub.acme.publish", "com.notifhub.acme.summarize"], "实例 untouched_jobs 不对: \(q.untouchedJobs)")
        ok(q.json["daemon_tasks"] as? [String] == ["sync"], "独立实例的采集器只调度 sync")
        let qActs = q.links.map { "\($0.path.lastPathComponent):\($0.action)" }
        ok(qActs == ["notihub:keep", "notifhub:update", "notifhub-acme:create"], "实例软链动作不对: \(qActs)")
        ok((q.jobs.first?.content["ProgramArguments"] as? [String]) == [bin.path, "daemon"], "实例 daemon 应直接跑 App 内二进制")

        let inApp = URL(fileURLWithPath: "/Volumes/X/Build/Notihub.app/Contents/Resources/bin/notihub")
        ok(Paths.locateAppBinary(selfPath: inApp) { _ in false } == inApp, "App 内运行时应认自己")
        let dev = URL(fileURLWithPath: "/Users/x/Apps/notifhub/cli/.build/release/notifhub")
        ok(Paths.locateAppBinary(selfPath: dev) { $0 == Paths.defaultAppBinary.path } == Paths.defaultAppBinary,
           ".build 里运行应回落 /Applications/Notihub.app 里那份")
        ok(Paths.locateAppBinary(selfPath: dev) { _ in false } == nil, "哪儿都没有 App 时应返回 nil")

        let (rc, out) = notifhub.run(selfBin, ["install", "--dry-run", "--json"], timeout: 20)
        let obj = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]
        let mode = obj?["mode"] as? String
        let jobsOut = (obj?["jobs"] as? [[String: Any]])?.compactMap { $0["label"] as? String } ?? []
        ok((rc == 0 && mode == "app" && !jobsOut.contains { $0.contains("publish") || $0.contains("summarize") })
           || (rc == 2 && mode == "unavailable" && obj?["error"] is String),
           "install --dry-run --json 退出码与 mode 不一致: rc=\(rc) mode=\(mode ?? "nil") jobs=\(jobsOut) out=\(out.prefix(160))")
    }

    private static func testStore() -> Store? {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notifhub-test-\(UUID().uuidString)")
        let prev = ProcessInfo.processInfo.environment["NOTIFHUB_DATA_DIR"]
        setenv("NOTIFHUB_DATA_DIR", dir.path, 1)
        let s = Store()
        if let prev { setenv("NOTIFHUB_DATA_DIR", prev, 1) } else { unsetenv("NOTIFHUB_DATA_DIR") }
        return s
    }
}


enum DataFixture {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static let personA = "林小溪", phoneA = "13800138000", emailA = "lin.xiaoxi@example.org"
    static let personB = "周远山", phoneB = "13900001111"
    static let onlyInAttributedBody = "只存在 attributedBody 里的正文：会议改到周三下午"
    static let stickyText = "周末买菜\nCafé list"

    static let t0 = 809_884_800.0

    static func typedstream(_ s: String) -> Data {
        var b = [UInt8]([0x04, 0x0B]) + Array("streamtyped".utf8) + [0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84, 0x12]
        b += Array("NSAttributedString".utf8) + [0x00, 0x84, 0x84, 0x08] + Array("NSObject".utf8) + [0x00, 0x85, 0x92, 0x84, 0x84, 0x84, 0x08]
        b += Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B]
        let u = Array(s.utf8)
        if u.count < 0x81 { b.append(UInt8(u.count)) }
        else { b += [0x81, UInt8(u.count & 0xFF), UInt8((u.count >> 8) & 0xFF)] }
        b += u + [0x86, 0x84, 0x02, 0x69, 0x49, 0x01, 0x05, 0x92, 0x84, 0x84, 0x84, 0x0C]
        b += Array("NSDictionary".utf8) + [0x00, 0x94, 0x84, 0x01, 0x69, 0x01, 0x92, 0x86, 0x86]
        return Data(b)
    }

    @discardableResult
    static func build(at root: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func dir(_ rel: String) throws -> URL {
            let u = root.appendingPathComponent(rel, isDirectory: true)
            try fm.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }
        func sqlite(_ rel: String, _ schema: String, _ inserts: [(String, [Any?])]) throws {
            let u = root.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: u)
            guard let db = DB(path: u.path) else { throw Failure(description: "建库失败 \(rel)") }
            guard db.exec(schema) else { throw Failure(description: "建表失败 \(rel)") }
            for (sql, binds) in inserts where !db.run(sql, binds) { throw Failure(description: "写入失败 \(rel): \(sql)") }
        }
        let ns = { (t: Double) in Int64(t * 1_000_000_000) }

        let longBody = String(repeating: "长消息测试，", count: 12) + "结束"   // >127 字节 → 0x81 长度前缀
        try sqlite("Library/Messages/chat.db", """
            CREATE TABLE handle(ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT);
            CREATE TABLE message(ROWID INTEGER PRIMARY KEY, date INTEGER, handle_id INTEGER, is_from_me INTEGER,
                                 service TEXT, text TEXT, attributedBody BLOB);
            CREATE TABLE chat(ROWID INTEGER PRIMARY KEY, display_name TEXT, chat_identifier TEXT);
            CREATE TABLE chat_message_join(chat_id INTEGER, message_id INTEGER);
            """, [
            ("INSERT INTO handle VALUES(1,?, 'SMS')", [phoneA]),
            ("INSERT INTO handle VALUES(2,?, 'iMessage')", [emailA]),
            ("INSERT INTO chat VALUES(1,'',?)", [phoneA]),
            ("INSERT INTO message VALUES(1,?,1,0,'SMS','明天上午十点见',?)", [ns(t0 + 3600), typedstream("明天上午十点见")]),
            ("INSERT INTO message VALUES(2,?,1,1,'SMS',NULL,?)", [ns(t0 + 7200), typedstream(onlyInAttributedBody)]),
            ("INSERT INTO message VALUES(3,?,1,0,'SMS','看这张图',?)", [ns(t0 + 7300), typedstream("看这张图\u{FFFC}")]),
            ("INSERT INTO message VALUES(4,?,2,0,'iMessage',NULL,?)", [ns(t0 + 7400), typedstream(longBody)]),
            ("INSERT INTO message VALUES(5,?,2,0,'iMessage',NULL,?)", [ns(t0 + 7500), typedstream("\u{FFFC}")]),
            ("INSERT INTO message VALUES(6,?,2,1,'iMessage','好的',?)", [ns(t0 + 7600), typedstream("好的\u{FFFD}")]),
            ("INSERT INTO chat_message_join VALUES(1,1),(1,2),(1,3)", []),
        ])
        try sqlite("Library/Mail/V10/MailData/Envelope Index", """
            CREATE TABLE addresses(ROWID INTEGER PRIMARY KEY, address TEXT);
            CREATE TABLE subjects(ROWID INTEGER PRIMARY KEY, subject TEXT);
            CREATE TABLE messages(ROWID INTEGER PRIMARY KEY, date_received INTEGER, sender INTEGER, subject INTEGER,
                                  read INTEGER, size INTEGER, deleted INTEGER);
            """, [
            ("INSERT INTO addresses VALUES(1,?)", [emailA]),
            ("INSERT INTO subjects VALUES(1,'周报（虚构）')", []),
            ("INSERT INTO messages VALUES(1,?,1,1,1,2048,0)", [Int(t0 + 978_307_200)]),
            ("INSERT INTO messages VALUES(2,?,1,1,0,1024,1)", [Int(t0 + 978_307_300)]),
        ])
        try sqlite("Library/Safari/History.db", """
            CREATE TABLE history_items(id INTEGER PRIMARY KEY, url TEXT, domain_expansion TEXT, visit_count INTEGER);
            CREATE TABLE history_visits(id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT);
            """, [
            ("INSERT INTO history_items VALUES(1,'https://example.org/a','example',3)", []),
            ("INSERT INTO history_visits VALUES(1,1,?,'示例页面')", [t0 + 100]),
        ])
        let leaf = { (t: String, u: String) -> [String: Any] in
            ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": u, "URIDictionary": ["title": t]] }
        let plist: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeList", "Children": [
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar", "Children": [leaf("示例书签", "https://example.org/b")]],
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "com.apple.ReadingList", "Children": [leaf("稍后读", "https://example.org/r")]],
        ]]
        let pdata = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try pdata.write(to: try dir("Library/Safari").appendingPathComponent("Bookmarks.plist"))
        try sqlite("Library/Containers/com.apple.Safari/Data/Library/Safari/SafariTabs.db", """
            CREATE TABLE bookmarks(id INTEGER PRIMARY KEY, type INTEGER, title TEXT, url TEXT);
            """, [
            ("INSERT INTO bookmarks VALUES(1,1,'标签组',NULL)", []),
            ("INSERT INTO bookmarks VALUES(2,0,'开着的标签','https://example.org/t')", []),
        ])
        try sqlite("Library/Application Support/CallHistoryDB/CallHistory.storedata", """
            CREATE TABLE ZCALLRECORD(Z_PK INTEGER PRIMARY KEY, ZDATE REAL, ZADDRESS TEXT, ZNAME TEXT, ZDURATION REAL,
                                     ZORIGINATED INTEGER, ZANSWERED INTEGER, ZISO_COUNTRY_CODE TEXT, ZSERVICE_PROVIDER TEXT);
            """, [
            ("INSERT INTO ZCALLRECORD VALUES(1,?,'+8613800138000','',125.4,1,0,'cn','com.apple.Telephony')", [t0 + 600]),
            ("INSERT INTO ZCALLRECORD VALUES(2,?,'+86 138 0013 8000','',0,0,0,'cn','com.apple.Telephony')", [t0 + 900]),
            ("INSERT INTO ZCALLRECORD VALUES(3,?,?,'',30,0,1,'cn','com.apple.Telephony')", [t0 + 1200, phoneB]),
        ])
        try sqlite("Library/Group Containers/243LU875E5.groups.com.apple.podcasts/Documents/MTLibrary.sqlite", """
            CREATE TABLE ZMTPODCAST(Z_PK INTEGER PRIMARY KEY, ZTITLE TEXT, ZAUTHOR TEXT);
            CREATE TABLE ZMTEPISODE(Z_PK INTEGER PRIMARY KEY, ZPODCAST INTEGER, ZTITLE TEXT, ZPUBDATE REAL, ZPLAYHEAD REAL, ZHASBEENPLAYED INTEGER);
            """, [("INSERT INTO ZMTPODCAST VALUES(1,'示例节目','示例作者')", []),
                  ("INSERT INTO ZMTEPISODE VALUES(1,1,'第一集',?,60,1)", [t0])])
        try sqlite("Library/Application Support/Knowledge/knowledgeC.db", """
            CREATE TABLE ZOBJECT(Z_PK INTEGER PRIMARY KEY, ZVALUESTRING TEXT, ZSTARTDATE REAL, ZENDDATE REAL, ZSTREAMNAME TEXT);
            """, [("INSERT INTO ZOBJECT VALUES(1,'com.example.app',?,?,'/app/usage')", [t0, t0 + 300]),
                  ("INSERT INTO ZOBJECT VALUES(2,'com.example.other',?,?,'/display/isBacklit')", [t0, t0 + 300])])
        try sqlite("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite", """
            CREATE TABLE ZICCLOUDSYNCINGOBJECT(Z_PK INTEGER PRIMARY KEY, ZTITLE1 TEXT, ZSNIPPET TEXT, ZFOLDER INTEGER,
                                               ZTITLE2 TEXT, ZCREATIONDATE3 REAL, ZMODIFICATIONDATE1 REAL);
            """, [("INSERT INTO ZICCLOUDSYNCINGOBJECT VALUES(1,NULL,NULL,NULL,'备忘录',NULL,NULL)", []),
                  ("INSERT INTO ZICCLOUDSYNCINGOBJECT VALUES(2,'示例备忘','摘要片段',1,NULL,?,?)", [t0, t0 + 60])])
        let ab = """
            CREATE TABLE ZABCDRECORD(Z_PK INTEGER PRIMARY KEY, ZFIRSTNAME TEXT, ZLASTNAME TEXT, ZORGANIZATION TEXT,
                                     ZJOBTITLE TEXT, ZNICKNAME TEXT, ZCREATIONDATE REAL);
            CREATE TABLE ZABCDPHONENUMBER(Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER, ZFULLNUMBER TEXT);
            CREATE TABLE ZABCDEMAILADDRESS(Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER, ZADDRESS TEXT);
            """
        try sqlite("Library/Application Support/AddressBook/Sources/AAAA-FIXTURE/AddressBook-v22.abcddb", ab, [
            ("INSERT INTO ZABCDRECORD VALUES(1,'小溪','林','示例水务公司','工程师',NULL,?)", [t0]),
            ("INSERT INTO ZABCDPHONENUMBER VALUES(1,1,'+86 138-0013-8000')", []),
            ("INSERT INTO ZABCDEMAILADDRESS VALUES(1,1,?)", [emailA]),
        ])
        try sqlite("Library/Application Support/AddressBook/Sources/BBBB-FIXTURE/AddressBook-v22.abcddb", ab, [
            ("INSERT INTO ZABCDRECORD VALUES(1,'远山','周',NULL,NULL,NULL,?)", [t0]),
            ("INSERT INTO ZABCDPHONENUMBER VALUES(1,1,'+86 139 0000 1111')", []),
            ("INSERT INTO ZABCDRECORD VALUES(2,'小溪','林','示例水务公司',NULL,NULL,?)", [t0]),   // 同一人在第二个账户里
        ])
        try sqlite("Library/Application Support/AddressBook/AddressBook-v22.abcddb", ab, [])
        let rem = """
            CREATE TABLE ZREMCDBASELIST(Z_PK INTEGER PRIMARY KEY, ZNAME TEXT);
            CREATE TABLE ZREMCDREMINDER(Z_PK INTEGER PRIMARY KEY, ZTITLE TEXT, ZLIST INTEGER, ZCOMPLETED INTEGER,
                                        ZDUEDATE REAL, ZCREATIONDATE REAL, ZNOTES TEXT, ZMARKEDFORDELETION INTEGER,
                                        ZCOMPLETIONDATE REAL);
            """
        for (i, store) in ["Data-AAAA.sqlite", "Data-BBBB.sqlite"].enumerated() {
            try sqlite("Library/Group Containers/group.com.apple.reminders/Container_v1/Stores/\(store)", rem, [
                ("INSERT INTO ZREMCDBASELIST VALUES(1,'提醒')", []),
                ("INSERT INTO ZREMCDREMINDER VALUES(1,?,1,0,?,?,'',0,NULL)", ["示例提醒 \(i + 1)", t0 + 86400, t0]),
            ])
        }
        try sqlite("Library/Containers/com.apple.iBooksX/Data/Documents/BKLibrary/BKLibrary-1-100.sqlite", """
            CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY, ZTITLE TEXT, ZAUTHOR TEXT, ZGENRE TEXT, ZPAGECOUNT INTEGER,
                                         ZLASTOPENDATE REAL, ZCREATIONDATE REAL);
            """, [("INSERT INTO ZBKLIBRARYASSET VALUES(1,'示例图书','示例作者','小说',200,?,?)", [t0, t0 - 86400])])
        try sqlite("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db", """
            CREATE TABLE ZCLOUDRECORDING(Z_PK INTEGER PRIMARY KEY, ZCUSTOMLABEL TEXT, ZDATE REAL, ZDURATION REAL, ZPATH TEXT);
            """, [("INSERT INTO ZCLOUDRECORDING VALUES(1,'示例录音',?,42.5,'20260901 100000.m4a')", [t0])])
        let uEsc = "周末买菜".unicodeScalars.map { "\\u\($0.value) " }.joined()
        let rtf = "{\\rtf1\\ansi\\ansicpg1252\\cocoartf2822\n{\\fonttbl\\f0\\fswiss\\fcharset0 Helvetica;}\n"
            + "{\\colortbl;\\red255\\green255\\blue255;}\n\\pard\\f0\\fs24 \\cf0 \\uc0\(uEsc)\\\nCaf\\'e9 list\\par\n}"
        let pkg = try dir("Library/Containers/com.apple.Stickies/Data/Library/Stickies/FIXTURE-1.rtfd")
        try Data(rtf.utf8).write(to: pkg.appendingPathComponent("TXT.rtf"))
        let docs = try dir("Library/Mobile Documents/com~apple~CloudDocs/文稿")
        try Data("虚构".utf8).write(to: docs.appendingPathComponent("计划.txt"))
        try Data("x".utf8).write(to: docs.deletingLastPathComponent().appendingPathComponent("readme.md"))
        return root
    }
}

extension SelfTest {
    static func dataTests(_ ok: (Bool, String) -> Void, selfBin: String) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notihub-datafx-\(UUID().uuidString)")
        defer {
            for rel in ["Library/Messages", "Library/Safari"] {
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent(rel).path)
            }
            try? fm.removeItem(at: root)
        }
        do { try DataFixture.build(at: root) } catch { ok(false, "数据夹具建不起来: \(error)"); return }
        let prev = ProcessInfo.processInfo.environment["NOTIHUB_DATA_HOME"]
        setenv("NOTIHUB_DATA_HOME", root.path, 1)
        defer { if let prev { setenv("NOTIHUB_DATA_HOME", prev, 1) } else { unsetenv("NOTIHUB_DATA_HOME") } }
        let env = ["NOTIHUB_DATA_HOME": root.path]

        ok(DomainRegistry.all.count == 15, "应为 15 个域，实为 \(DomainRegistry.all.count)")
        var results: [String: DomainResult] = [:]
        for d in DomainRegistry.all { results[d.id] = Extractor.run(d, limit: 100) }
        let bad = DomainRegistry.all.filter { !(results[$0.id]?.isUsable ?? false) || (results[$0.id]?.rows.isEmpty ?? true) }
            .map { "\($0.id):\(results[$0.id]?.statusLabel ?? "?")" }
        ok(bad.isEmpty, "夹具上这些域没读出数据: \(bad)")

        let msgs = results["messages"]?.rows ?? []
        ok(msgs.contains { $0.last == DataFixture.onlyInAttributedBody }, "只存在 attributedBody 的消息没读回来（又只读 text 了？）")
        ok(msgs.count == 5, "信息应 5 条（纯附件应被滤掉），实为 \(msgs.count)")
        ok(msgs.contains { $0.last == "看这张图" }, "U+FFFC 附件占位没剥")
        let chk = try? IMessageBody.selfCheck(sources: DomainRegistry.messages.sources.flatMap { $0.resolve() })
        ok(chk?.compared == 3 && chk?.matched == 2 && chk?.invisibleOnly == 1 && chk?.mismatched == 0
           && chk?.recovered == 2 && chk?.passed == true,
           "attributedBody 解码对照应 3 条里逐字 2、仅差不可见 1、补回 2: \(String(describing: chk))")
        ok(IMessageBody.decode(DataFixture.typedstream(String(repeating: "长", count: 60))) == String(repeating: "长", count: 60),
           "0x81 长度前缀（>127 字节）解码错")

        let calls = results["callhistory"]?.rows ?? []
        ok(calls.contains { $0[3] == "125" && $0[4] == "呼出" && $0[5] == "已接通" }, "有时长的去电没判成已接通: \(calls.map { $0[3...5] })")
        ok(calls.contains { $0[3] == "0" && $0[5] == "未接通" }, "0 秒来电应判未接通")

        ok(results["stickies"]?.rows.first?[1] == DataFixture.stickyText && results["stickies"]?.note == Extractor.cliRichTextNote,
           "便签 RTF 回退解析不对: \(results["stickies"]?.rows.first?[1] ?? "nil")")
        let f = Extractor.timeFormatter()
        ok(results["podcasts"]?.rows.first?[3] == f.string(from: Date(timeIntervalSince1970: DataFixture.t0 + 978_307_200)),
           "时间列没按系统时区格式化")
        ok(results["safari-tabs"]?.rows.count == 1, "safari-tabs 应只取 type=0 的开着的标签")
        ok(results["contacts"]?.rows.count == 3 && results["reminders"]?.rows.count == 2, "多源（通讯录/提醒）没合并")

        let chat = root.appendingPathComponent("Library/Messages/chat.db")
        let before = try? Data(contentsOf: chat)
        _ = Extractor.run(DomainRegistry.messages, limit: 10)
        ok(before != nil && before == (try? Data(contentsOf: chat)) && !fm.fileExists(atPath: chat.path + "-shm"),
           "读完 chat.db 源文件变了或多出 -shm")

        let (rc1, masked) = notifhub.run(selfBin, ["data", "messages", "--json"], env: env)
        let (rc2, raw) = notifhub.run(selfBin, ["data", "messages", "--json", "--raw"], env: env)
        ok(rc1 == 0 && !masked.contains(DataFixture.phoneA) && masked.contains(Masker.addr(DataFixture.phoneA)),
           "data messages 默认应打码: rc=\(rc1)")
        ok(rc2 == 0 && raw.contains(DataFixture.phoneA), "--raw 应显示原文: rc=\(rc2)")
        ok(Masker.addr(DataFixture.phoneA) == "1380...00" && Masker.addr("123456") == "***", "打码形式应同 Python mask_addr")

        try? fm.removeItem(at: root.appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared"))
        let out = root.appendingPathComponent("out")
        let (rc3, eout) = notifhub.run(selfBin, ["data", "export", "--all", "--out", out.path], env: env)
        let exp = (try? fm.contentsOfDirectory(atPath: out.path))?.first { $0.hasPrefix("export-") }
        let expDir = exp.map { out.appendingPathComponent($0) }
        let files = expDir.flatMap { try? fm.contentsOfDirectory(atPath: $0.path) } ?? []
        let perm = expDir.flatMap { (try? fm.attributesOfItem(atPath: $0.path))?[.posixPermissions] as? Int }
        let csv = expDir.flatMap { try? Data(contentsOf: $0.appendingPathComponent("messages.csv")) }
        ok(rc3 == 1 && exp != nil && perm == 0o700, "export 目录结构/权限/退出码不对: rc=\(rc3) perm=\(perm.map { String($0, radix: 8) } ?? "nil") \(eout.prefix(120))")
        ok(files.contains("导出说明.md") && files.count == 15 && !files.contains("voicememos.csv"),
           "export 应 14 个 CSV + 说明、缺源域不写空文件: \(files.sorted())")
        ok(csv?.prefix(3) == Data([0xEF, 0xBB, 0xBF]), "CSV 没带 BOM")

        let (rc4, tl) = notifhub.run(selfBin, ["data", "people", "timeline", DataFixture.personA], env: env)
        ok(rc4 == 0 && tl.contains("\(DataFixture.personA) —— 5 条触点") && tl.contains("去电") && tl.contains("125s"),
           "people timeline 三源合并不对: rc=\(rc4) \(tl.split(separator: "\n").first ?? "")")
        let (rc5, tlB) = notifhub.run(selfBin, ["data", "people", "timeline", DataFixture.personB], env: env)
        ok(rc5 == 0 && tlB.contains("1 条触点"), "第二个通讯录来源的人没读到: rc=\(rc5)")

        let contactTimes = (results["contacts"]?.rows ?? []).map { $0.indices.contains(5) ? $0[5] : "" }
        ok(contactTimes == contactTimes.sorted(by: >), "多源合并后没按创建时间全局倒序: \(contactTimes)")
        if let drive = DomainRegistry.all.first(where: { $0.id == "icloud-drive" }),
           let driveRoot = drive.sources.flatMap({ $0.resolve() }).first {
            try? Data().write(to: URL(fileURLWithPath: driveRoot).appendingPathComponent(".合同.pdf.icloud"))
            let listed = Extractor.run(drive, limit: 100).rows
            ok(listed.contains { $0.last == "仅在云端" }, "iCloud 占位符 .xxx.icloud 被当成隐藏文件跳过了")
        } else { ok(false, "夹具里找不到 iCloud 云盘目录") }
        let stores = root.appendingPathComponent("Library/Group Containers/group.com.apple.reminders/Container_v1/Stores")
        let storeFiles = ((try? fm.contentsOfDirectory(atPath: stores.path)) ?? []).filter { $0.hasSuffix(".sqlite") }.sorted()
        if let last = storeFiles.last, storeFiles.count > 1 {
            try? Data(repeating: 0x5A, count: 4096).write(to: stores.appendingPathComponent(last))
            let (rcRem, _) = notifhub.run(selfBin, ["data", "reminders"], env: env)
            ok(rcRem == 1, "提醒事项第二个 store 损坏应退出 1，实为 \(rcRem)（被静默吞掉）")
        } else { ok(false, "夹具提醒事项应有多个 store，实为 \(storeFiles.count)") }
        let history = root.appendingPathComponent("Library/Safari/History.db")
        let savedHistory = try? Data(contentsOf: history)
        try? fm.removeItem(at: history)
        let (rcNoProbe, _) = notifhub.run(selfBin, ["data", "voicememos"], env: env)
        ok(rcNoProbe == 1, "探针文件不存在时缺源应退出 1，实为 \(rcNoProbe)（被误判成缺完全磁盘访问）")
        if let savedHistory { try? savedHistory.write(to: history) }

        try? Data(repeating: 0x5A, count: 4096).write(to: root.appendingPathComponent("Library/Application Support/Knowledge/knowledgeC.db"))
        let (rcBroken, _) = notifhub.run(selfBin, ["data", "screentime"], env: env)
        let (rcMissing, _) = notifhub.run(selfBin, ["data", "voicememos"], env: env)
        for rel in ["Library/Messages", "Library/Safari"] {
            try? fm.setAttributes([.posixPermissions: 0], ofItemAtPath: root.appendingPathComponent(rel).path)
        }
        let (rcDenied, _) = notifhub.run(selfBin, ["data", "messages"], env: env)
        let (rcPeople, _) = notifhub.run(selfBin, ["data", "people", "stats"], env: env)
        ok(rcBroken == 1 && rcMissing == 1 && rcDenied == 2 && rcPeople == 2,
           "退出码应 损坏1/缺源1/缺FDA 2/people 2，实为 \(rcBroken)/\(rcMissing)/\(rcDenied)/\(rcPeople)")
    }
}
