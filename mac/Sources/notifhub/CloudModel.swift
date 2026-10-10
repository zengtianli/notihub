import Foundation
import SwiftUI

#if DEMO_CAPTURE
extension CloudModel {
    static func documentationModel(index: CloudIndex, day: CloudDay) -> CloudModel {
        let connection = CloudConnection(id: "documentation", url: URL(string: "https://demo.example.invalid")!, token: "synthetic-not-a-credential")
        let client = CloudClient(connection: connection, session: URLSession(configuration: .ephemeral))
        let model = CloudModel(client: client, defaults: UserDefaults(suiteName: "Notihub.Documentation.\(UUID().uuidString)")!)
        model.index = index
        model.day = day
        model.selectedDate = day.date
        model.opened = day.agenda.filter { $0.status == "open" }
        return model
    }
}
#endif


struct CloudIndexFeed: Decodable {
    let index: CloudIndex
    let ui: Lenient<FeedUI>?
    private enum Key: String, CodingKey { case ui }
    init(from decoder: Decoder) throws {
        index = try CloudIndex(from: decoder)
        ui = try decoder.container(keyedBy: Key.self).decodeIfPresent(Lenient<FeedUI>.self, forKey: .ui)
    }
}

enum CloudCopy {
    static func connection(problem: Bool, connected: Bool) -> String {
        if problem { return Remote.label("conn.retry", "连接需要重试") }
        return connected ? Remote.label("conn.ok", "云端已连接") : Remote.label("conn.none", "尚未连接")
    }

    static func problem(_ error: Error) -> String {
        let builtin = error.localizedDescription
        guard let failure = error as? CloudFailure else { return builtin }
        switch (failure.kind, failure.status) {
        case (.http, 401?): return T("mac.error.unauthorized", builtin)
        case (.http, let code?) where (300...399).contains(code): return T("mac.error.redirected", builtin)
        case (.http, let code?): return T("mac.error.http", builtin, ["code": String(code)])
        case (.network, _): return T("mac.error.network", builtin)
        case (.format, _): return T("mac.error.format", builtin)
        default: return builtin
        }
    }
}

@MainActor
final class CloudModel: ObservableObject {
    @Published private(set) var index: CloudIndex?
    @Published private(set) var day: CloudDay?
    @Published private(set) var opened: [CloudAgenda] = []
    @Published private(set) var selectedDate = ""
    @Published private(set) var loading = false
    @Published private(set) var writing = false
    @Published private(set) var problem: String?
    @Published private(set) var writeProblem: String?
    @Published private(set) var notice: String?
    @Published var draft = "" { didSet { persistDraft() } }
    private var noteKey = UUID().uuidString
    private var noteDate = ""
    private var restoringDraft = false
    private var client: CloudClient?
    private var readTask: Task<Void, Never>?
    private var revision = 0
    private var days: [String: (value: CloudDay, fetched: Date)] = [:]
    private let defaults: UserDefaults
    private let draftPrefix: String
    var siteURL: URL { client?.connection.url ?? CloudConnection.expectedURL }

    func select(date: String) {
        guard date != selectedDate || day == nil else { return }
        revision += 1
        let current = revision
        readTask?.cancel()
        selectedDate = date
        day = days[date]?.value
        problem = nil
        if let cached = days[date], Date().timeIntervalSince(cached.fetched) < 60 {
            loading = false
            return
        }
        loading = true
        readTask = Task {
            do {
                if client == nil { client = CloudClient(connection: try CloudConnection.load()) }
                guard let client else { return }
                let fresh: CloudDay = try await client.request("day/" + date)
                guard !Task.isCancelled, current == revision else { return }
                day = fresh
                cache(fresh)
            } catch {
                guard !Task.isCancelled, current == revision else { return }
                problem = CloudCopy.problem(error)
            }
            if current == revision { loading = false }
        }
    }

    private func cache(_ value: CloudDay) {
        days[value.date] = (value, Date())
        if days.count > 10, let oldest = days.min(by: { $0.value.fetched < $1.value.fetched })?.key {
            days.removeValue(forKey: oldest)
        }
    }

    init(client: CloudClient? = nil, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        self.draftPrefix = "notihub.draft." + (client?.connection.id ?? Instance.current?.id ?? "personal")
    }

    func refresh(date: String? = nil) {
        if let date { selectedDate = date }
        revision += 1
        let current = revision
        readTask?.cancel()
        if day?.date != selectedDate { day = nil }
        loading = true
        problem = nil
        readTask = Task {
            do {
                if client == nil { client = CloudClient(connection: try CloudConnection.load()) }
                guard let client else { return }
                async let newIndex: CloudIndexFeed = client.request("index")
                async let newOpen: CloudOpen = client.request("open")
                let (feed, pending) = try await (newIndex, newOpen)
                let idx = feed.index
                guard !Task.isCancelled, current == revision else { return }
                let date = selectedDate.isEmpty ? idx.initialDate() : selectedDate
                let fresh: CloudDay? = date.isEmpty ? nil : try await client.request("day/" + date)
                guard !Task.isCancelled, current == revision else { return }
                Remote.ui = feed.ui?.value
                index = idx; opened = pending.items; selectedDate = date; day = fresh
                if let fresh { cache(fresh) }
            } catch {
                guard !Task.isCancelled, current == revision else { return }
                problem = CloudCopy.problem(error)
            }
            if current == revision { loading = false }
        }
    }

    func beginNote() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: index?.timezone ?? "") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: Date())
        noteDate = selectedDate.isEmpty ? String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!) : selectedDate
        restoringDraft = true
        draft = defaults.string(forKey: draftPrefix + ".text") ?? ""
        if !draft.isEmpty { noteDate = defaults.string(forKey: draftPrefix + ".date") ?? noteDate }
        noteKey = defaults.string(forKey: draftPrefix + ".key") ?? UUID().uuidString
        restoringDraft = false
        writeProblem = nil
    }

    var draftDate: String { noteDate }
    private func persistDraft() {
        guard !restoringDraft else { return }
        noteKey = UUID().uuidString
        defaults.set(draft, forKey: draftPrefix + ".text")
        defaults.set(noteDate, forKey: draftPrefix + ".date")
        defaults.set(noteKey, forKey: draftPrefix + ".key")
    }

    func saveNote() async -> Bool {
        guard !writing, let client, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        writing = true; writeProblem = nil; notice = nil
        defer { writing = false }
        do {
            _ = try await client.saveNote(CloudNoteInput(text: draft, date: noteDate, idempotencyKey: noteKey))
            draft = ""
            notice = T("mac.notice.note_saved", "随手记已保存到云端")
            days.removeValue(forKey: noteDate)
            refresh(date: noteDate)
            return true
        } catch { writeProblem = CloudCopy.problem(error); return false }
    }

    func setStatus(_ item: CloudAgenda, status: String) async {
        guard !writing, let client else { return }
        writing = true; writeProblem = nil; notice = nil
        defer { writing = false }
        do {
            _ = try await client.setStatus(id: item.id, status: status)
            notice = status == "done" ? T("mac.notice.done", "待办已完成") : T("mac.notice.reopened", "待办已重新打开")
            days.removeAll()
            refresh()
        } catch { writeProblem = CloudCopy.problem(error) }
    }
}
