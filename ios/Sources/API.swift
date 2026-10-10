import Foundation


enum FeedError: Error, Equatable {
    #if DEBUG
    case demo
    #endif
    case network(url: String, underlying: String)
    case http(url: String, status: Int, body: String)
    case decoding(url: String, field: String, detail: String)
    case gate(url: String, reason: String)

    var headline: String {
        switch self {
        #if DEBUG
        case .demo: return "演示模式只读"
        #endif
        case .network:            return T("error.network_headline", "连不上 day 站")
        case .http(_, let s, _):  return "站点返回 HTTP \(s)"
        case .decoding:           return T("error.decoding_headline", "拿到的数据对不上契约")
        case .gate:               return T("error.gate_headline", "被访问闸拦住了")
        }
    }

    var detail: String {
        switch self {
        #if DEBUG
        case .demo: return "演示内容不会发送到云端，也不会导出提醒事项。"
        #endif
        case .network(let url, let e):        return "\(url)\n\(e)"
        case .http(let url, let s, let body): return "\(url)\n状态 \(s)\n\(body.prefix(300))"
        case .decoding(let url, let f, let d): return "\(url)\n字段 `\(f)`\n\(d)"
        case .gate(let url, let r):           return "\(url)\n\(r)"
        }
    }

    var whatToDo: String {
        switch self {
        #if DEBUG
        case .demo: return "请退出演示模式后再保存；当前草稿仍保留在此设备。"
        #endif
        case .network:
            return T("error.network_advice", "请检查网络后重试；离线时仍可阅读上次缓存的记录。")
        case .http(_, let s, _):
            return s == 404
                ? T("error.no_day_advice", "云端还没有这一天的记录，请选择其他日期或稍后刷新。")
                : T("error.server_advice", "云端暂时无法处理请求，请稍后重试。")
        case .decoding(_, let field, _):
            return "请更新应用后重试；不兼容的字段是 \(field)，上次可读记录仍保留。"
        case .gate:
            return T("error.gate_advice", "请在应用的连接设置中重新登录。")
        }
    }
}

final class API: @unchecked Sendable {
    static let shared = API()

    let base = ProcessInfo.processInfo.environment["NOTIHUB_SERVICE_URL"]
        ?? Bundle.main.object(forInfoDictionaryKey: "NotihubServiceURL") as? String
        ?? "https://day.example.invalid"
    let session: URLSession
    let cache: Cache

    init(session: URLSession? = nil, cacheDirectory: URL? = nil) {
        cache = Cache(directory: cacheDirectory)
        if let session { self.session = session; return }
        let c = URLSessionConfiguration.default
        c.httpCookieStorage = .shared          // 域 .example.invalid，跨启动保留，也跨子站共用
        c.httpShouldSetCookies = true
        c.timeoutIntervalForRequest = 20
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: c)
    }

    func fetch(_ url: URL) async -> Result<Data, FeedError> {
        await request(URLRequest(url: url))
    }

    func request(_ request: URLRequest) async -> Result<Data, FeedError> {
        #if DEBUG
        guard !DemoData.enabled else { return .failure(.demo) }
        #endif
        guard let url = request.url, url.scheme == "https", url.host == URL(string: base)?.host, url.port == URL(string: base)?.port else {
            return .failure(.network(url: base, underlying: "请求域名无效"))
        }
        let shown = url.absoluteString
        await Gate.seedFromLaunchArg(session: session)
        do {
            var (data, resp) = try await session.data(for: request)
            if Gate.blocked(resp) {
                guard let pw = Gate.password else {
                    return .failure(.gate(url: shown, reason: "这台设备还没有闸凭证（iOS 钥匙串里没有密码）"))
                }
                do { try await Gate.login(password: pw, session: session) }
                catch {
                    return .failure(.gate(url: shown,
                        reason: (error as? Gate.Failure)?.message ?? "登录失败"))
                }
                (data, resp) = try await session.data(for: request)
                if Gate.blocked(resp) {
                    return .failure(.gate(url: shown, reason: "拿密码换了会话之后仍被拦 —— 密码可能已经改了"))
                }
            }
            guard let http = resp as? HTTPURLResponse else {
                return .failure(.network(url: shown, underlying: "响应不是 HTTP"))
            }
            guard http.statusCode == 200 else {
                return .failure(.http(url: shown, status: http.statusCode,
                                      body: String(data: data, encoding: .utf8) ?? "<非文本>"))
            }
            return .success(data)
        } catch {
            return .failure(.network(url: shown, underlying: (error as NSError).localizedDescription))
        }
    }

    func decode<T: Decodable>(_ data: Data, as type: T.Type, from shown: String) -> Result<T, FeedError> {
        do { return .success(try JSONDecoder().decode(T.self, from: data)) }
        catch let DecodingError.keyNotFound(key, ctx) {
            return .failure(.decoding(url: shown, field: key.stringValue, detail: ctx.debugDescription))
        }
        catch let DecodingError.typeMismatch(_, ctx) {
            return .failure(.decoding(url: shown,
                                      field: ctx.codingPath.map(\.stringValue).joined(separator: "."),
                                      detail: ctx.debugDescription))
        }
        catch let DecodingError.valueNotFound(_, ctx) {
            return .failure(.decoding(url: shown,
                                      field: ctx.codingPath.map(\.stringValue).joined(separator: "."),
                                      detail: "值是 null，但契约要求非空：" + ctx.debugDescription))
        }
        catch { return .failure(.decoding(url: shown, field: "(整个响应体)", detail: "\(error)")) }
    }

    func get<T: Decodable>(_ path: String, as type: T.Type) async -> (value: T?, error: FeedError?, cachedAt: Date?) {
        guard let url = URL(string: base + path) else {
            return (nil, .network(url: base + path, underlying: "URL 拼不出来"), nil)
        }
        switch await fetch(url) {
        case .success(let data):
            switch decode(data, as: T.self, from: url.absoluteString) {
            case .success(let v):
                guard !Task.isCancelled else { return (nil, nil, nil) }
                cache.write(data, for: path)
                return (v, nil, Date())
            case .failure(let e):
                return (cache.load(path, as: T.self, api: self)?.0, e, cache.stamp(path))
            }
        case .failure(let e):
            if let (v, at) = cache.load(path, as: T.self, api: self) { return (v, e, at) }
            return (nil, e, nil)
        }
    }
}

struct Cache {
    let dir: URL
    init(directory: URL? = nil) {
        dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("feed-vps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func file(_ path: String) -> URL {
        dir.appendingPathComponent(path.replacingOccurrences(of: "/", with: "_"))
    }

    func write(_ data: Data, for path: String) {
        try? data.write(to: file(path), options: .atomic)
    }

    func stamp(_ path: String) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: file(path).path)[.modificationDate] as? Date
    }

    func load<T: Decodable>(_ path: String, as type: T.Type, api: API) -> (T, Date)? {
        guard let d = try? Data(contentsOf: file(path)),
              case .success(let v) = api.decode(d, as: T.self, from: "cache:" + path),
              let at = stamp(path) else { return nil }
        return (v, at)
    }

    func invalidate(_ path: String) {
        guard FileManager.default.fileExists(atPath: file(path).path) else { return }
        try? FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: file(path).path)
    }
}
