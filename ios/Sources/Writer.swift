import Foundation

enum Writer {
    static func note(_ text: String, date: String, idempotencyKey: String,
                     api: API = .shared) async -> Result<Void, FeedError> {
        let expected = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await send("/api/notes", method: "POST",
                                body: ["text": text, "date": date, "idempotencyKey": idempotencyKey], api: api)
        switch result {
        case .failure(let e): return .failure(e)
        case .success(let data):
            switch api.decode(data, as: CloudNote.self, from: api.base + "/api/notes") {
            case .failure(let e): return .failure(e)
            case .success(let note):
                guard note.text == expected, note.date == date else {
                    return .failure(.decoding(url: api.base, field: "text/date", detail: "保存回执与笔记不一致，草稿已保留"))
                }
                api.cache.invalidate("/api/day/" + date)
                return .success(())
            }
        }
    }

    static func mark(_ id: Int64, to status: String, title: String,
                     api: API = .shared) async -> Result<Void, FeedError> {
        let path = "/api/agenda/\(id)"
        switch await send(path, method: "PATCH", body: ["status": status], api: api) {
        case .failure(let e): return .failure(e)
        case .success(let data):
            struct Receipt: Decodable { let id: Int64; let status: String }
            switch api.decode(data, as: Receipt.self, from: api.base + path) {
            case .failure(let e): return .failure(e)
            case .success(let value):
                guard value.id == id, value.status == status else {
                    return .failure(.decoding(url: api.base + path, field: "id/status", detail: "状态回执不一致，请刷新核对"))
                }
                return .success(())
            }
        }
    }

    static func push(_ id: Int64, title: String, api: API = .shared) async -> Result<Void, FeedError> {
        let path = "/api/agenda-queue"
        switch await send(path, method: "POST", body: ["kind": "push", "agendaId": id, "title": title, "force": true], api: api) {
        case .failure(let e): return .failure(e)
        case .success(let data):
            guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], value["item"] != nil else {
                return .failure(.decoding(url: api.base + path, field: "item", detail: "未收到排队回执"))
            }
            return .success(())
        }
    }

    private static func send(_ path: String, method: String, body: [String: Any], api: API) async -> Result<Data, FeedError> {
        var request = URLRequest(url: URL(string: api.base + path)!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(api.base, forHTTPHeaderField: "Origin")
        request.setValue("1", forHTTPHeaderField: "X-Notifhub-Request")
        do { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        catch { return .failure(.decoding(url: api.base + path, field: "request", detail: error.localizedDescription)) }
        return await api.request(request)
    }
}
