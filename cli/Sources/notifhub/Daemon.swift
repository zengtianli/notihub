import Foundation

final class FileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private let url: URL
    private let queue: DispatchQueue
    private let onChange: () -> Void

    init?(url: URL, queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.url = url
        self.queue = queue
        self.onChange = onChange
        guard arm() else { return nil }
    }

    @discardableResult
    private func arm() -> Bool {
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .link, .revoke],
            queue: queue)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.source?.data ?? []
            self.onChange()
            if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
                self.rearm()
            }
        }
        s.setCancelHandler { [weak self] in
            if let f = self?.fd, f >= 0 { close(f) }
        }
        s.resume()
        source = s
        return true
    }

    private func rearm() {
        source?.cancel()
        source = nil
        fd = -1
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if !self.arm() {
                self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in _ = self?.arm() }
            } else {
                self.onChange()
            }
        }
    }

    deinit { source?.cancel() }
}


final class Daemon {
    private let store: Store
    private var config: Config
    private let collectors: [Collector]
    private let queue = DispatchQueue(label: "notifhub.watch")
    private var watchers: [FileWatcher] = []
    private var pending = false
    private var lastConfigLoad = Date()
    private let jobs = Jobs.Runner()

    init?() {
        guard let s = Store() else { return nil }
        store = s
        config = Config.load()
        collectors = Sources.all()   // 唯一清单在 Collectors.swift 的 Sources —— 别在这里再列一遍
    }

    func run() -> Never {
        Log.write("daemon 启动 pid=\(getpid())")
        store.applyRetention(days: config.retentionDays)

        var targets: [URL] = [Paths.usernotedWAL, Paths.usernotedDB, Paths.chatWAL, Paths.remoteRoot]
        let remoteFiles = RemoteCollector.plistFiles()
        targets.append(contentsOf: remoteFiles)
        remoteWatched = Set(remoteFiles.map(\.path))
        for t in targets {
            if let w = FileWatcher(url: t, queue: queue, onChange: { [weak self] in self?.schedule() }) {
                watchers.append(w)
            } else {
                Log.write("监视挂载失败（跳过）: \(t.path)")
            }
        }
        if watchers.isEmpty {
            Log.write("警告: 一个监视点都挂不上（多半没给全磁盘访问），转 60s 重试模式")
            Log.err("一个监视点都挂不上 —— 大概率是没给全磁盘访问。跑 `notihub doctor` 看详情。")
        } else {
            Log.write("已挂 \(watchers.count) 个监视点")
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()

        queue.async { [weak self] in self?.ingest() }

        jobs.start()

        signal(SIGTERM) { _ in Log.write("收到 SIGTERM，退出"); exit(0) }
        signal(SIGINT) { _ in Log.write("收到 SIGINT，退出"); exit(0) }

        dispatchMain()
    }

    private func schedule() {
        guard !pending else { return }
        pending = true
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.pending = false
            self?.ingest()
        }
    }

    private func tick() {
        if watchers.isEmpty { retryMount() }
        ingest()
        markDismissed()
        if Date().timeIntervalSince(lastConfigLoad) > 6 * 3600 {
            config = Config.load()
            store.applyRetention(days: config.retentionDays)
            lastConfigLoad = Date()
        }
        refreshRemoteWatchers()
    }

    private var remoteWatched = Set<String>()

    private func retryMount() {
        var targets: [URL] = [Paths.usernotedWAL, Paths.usernotedDB, Paths.chatWAL, Paths.remoteRoot]
        targets.append(contentsOf: RemoteCollector.plistFiles())
        for t in targets {
            if let w = FileWatcher(url: t, queue: queue, onChange: { [weak self] in self?.schedule() }) {
                watchers.append(w)
            }
        }
        if !watchers.isEmpty { Log.write("重试挂载成功，已挂 \(watchers.count) 个监视点") }
    }

    private func refreshRemoteWatchers() {
        for f in RemoteCollector.plistFiles() where !remoteWatched.contains(f.path) {
            if let w = FileWatcher(url: f, queue: queue, onChange: { [weak self] in self?.schedule() }) {
                watchers.append(w)
                remoteWatched.insert(f.path)
            }
        }
    }

    func ingest() {
        var newCount = 0
        for c in collectors {
            for e in c.collect(store) {
                if store.isSelfEmitted(e) { continue }
                guard let id = store.insert(e) else { continue }   // nil = 跨源重复，已有
                newCount += 1
                let age = nowUnix() - e.ts
                if age > Double(config.maxActionAgeSeconds) {
                    if OTP.find(in: "\(e.title) \(e.body)") != nil {
                        Log.write("跳过动作: \(e.app) 的验证码已 \(Int(age))s 前，超过 maxActionAge")
                    }
                    continue
                }
                let hits = Engine.match(e, config: config)
                for hit in hits {
                    let done = Actions.perform(hit, event: e, config: config, store: store, eventID: id)
                    if !done.isEmpty {
                        Log.write("规则[\(hit.rule.name)] 命中 \(e.app)/\(e.title.truncated(20)) → \(done.joined(separator: ","))")
                    }
                }
            }
        }
        if newCount > 0 { Log.write("入库 \(newCount) 条") }
    }

    func markDismissed() {
        let live = UsernotedCollector.liveRecIDs()
        store.db.run("""
            UPDATE events SET dismissed_at=?
             WHERE rec_id IS NOT NULL AND dismissed_at IS NULL
               AND rec_id NOT IN (\(live.map(String.init).joined(separator: ",").ifEmpty("-1")))
            """, [nowUnix()])
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
