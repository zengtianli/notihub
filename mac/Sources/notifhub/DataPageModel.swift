import AppKit
import Foundation

struct DataPageBanner: Identifiable {
    enum Kind { case info, warning, failure }
    let id = UUID()
    let kind: Kind
    let title: String
    let detail: String
}

@MainActor
final class DataPageModel: ObservableObject {

    static let limitOptions = [1_000, 5_000, 20_000, 100_000]
    static let previewCap = 500

    typealias Extract = @Sendable (DataDomain, Int) -> DomainResult

    @Published var selected: Set<String> = []
    @Published var results: [String: DomainResult] = [:]
    @Published var scanning: Set<String> = []
    @Published var limit: Int = 5_000
    @Published var masked: Bool = false
    @Published var format: ExportFormat = .csv
    @Published var focus: String?
    @Published var banner: DataPageBanner?
    @Published var lastExport: ExportOutcome?
    @Published var exporting = false
    private var scanGeneration: [String: UUID] = [:]
    private let extractDomain: Extract
    let domains: [DataDomain]

    init(domains: [DataDomain] = DomainRegistry.all,
         extract: @escaping Extract = { Extractor.run($0, limit: $1) }) {
        self.domains = domains
        extractDomain = extract
        focus = domains.first?.id
    }

    var focusedDomain: DataDomain? { domains.first { $0.id == focus } }
    var selectedDomains: [DataDomain] { domains.filter { selected.contains($0.id) } }
    var isScanning: Bool { !scanning.isEmpty }

    var exportableSummary: (domains: Int, rows: Int) {
        var d = 0, r = 0
        for domain in selectedDomains {
            guard let res = results[domain.id], res.isUsable, !res.rows.isEmpty else { continue }
            d += 1; r += res.rowCount
        }
        return (d, r)
    }

    var deniedDomains: [DataDomain] { domains.filter { results[$0.id]?.verdict == .denied } }


    func scanAll() { scan(domains) }

    func scan(_ targets: [DataDomain], extract: Extract? = nil) {
        guard !targets.isEmpty else { return }
        let extract = extract ?? extractDomain
        let limit = self.limit
        let generation = UUID()
        for domain in targets { scanning.insert(domain.id); scanGeneration[domain.id] = generation }
        Task.detached(priority: .userInitiated) { [weak self] in
            await withTaskGroup(of: DomainResult.self) { group in
                for domain in targets { group.addTask { extract(domain, limit) } }
                for await result in group {
                    await MainActor.run { [weak self] in
                        guard let self, self.scanGeneration[result.domainID] == generation else { return }
                        self.results[result.domainID] = result
                        self.scanning.remove(result.domainID)
                    }
                }
            }
        }
    }

    func release() {
        scanGeneration.removeAll()
        scanning.removeAll()
        results.removeAll()
        selected.removeAll()
        lastExport = nil
        banner = nil
    }


    func toggle(_ domain: DataDomain) {
        if selected.contains(domain.id) { selected.remove(domain.id) } else { selected.insert(domain.id) }
    }
    func selectAll() { selected = Set(domains.map(\.id)) }
    func selectNone() { selected.removeAll() }
    func focus(on domain: DataDomain) { focus = domain.id }
    func selectReadable() {
        selected = Set(domains.filter { results[$0.id]?.isUsable == true && results[$0.id]?.rows.isEmpty == false }.map(\.id))
    }


    func chooseDirectoryAndExport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "导出到这里"
        panel.message = "选择导出目录 —— 每次导出新建 export-<编号>/，每个域一个文件，另附《导出说明.md》"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        performExport(to: dir)
    }

    func performExport(to dir: URL) {
        guard !exporting else { return }
        let targets = selectedDomains
        guard !targets.isEmpty else {
            banner = DataPageBanner(kind: .warning, title: "没有勾选任何数据", detail: "先在左侧勾上要导出的数据类别。")
            return
        }
        let snapshot = results, chosenFormat = format, chosenMask = masked
        exporting = true
        Task { @MainActor in
            defer { exporting = false }
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try Exporter.export(domains: targets, results: snapshot,
                                        format: chosenFormat, masked: chosenMask, to: dir)
                }.value
                lastExport = outcome
                let rows = outcome.files.reduce(0) { $0 + $1.rows }
                if outcome.files.isEmpty {
                    banner = DataPageBanner(kind: .warning, title: "没有任何文件被写出",
                                            detail: "勾选的 \(targets.count) 类数据都无法导出，原因见目录下的《导出说明.md》。")
                } else {
                    banner = DataPageBanner(kind: .info,
                                            title: "已导出 \(outcome.files.count) 个文件 / 共 \(rows) 条",
                                            detail: outcome.skipped.isEmpty
                                                ? outcome.directory
                                                : "\(outcome.directory)（另有 \(outcome.skipped.count) 类未导出，原因见《导出说明.md》）")
                }
            } catch {
                banner = DataPageBanner(kind: .failure, title: "导出失败", detail: error.localizedDescription)
            }
        }
    }

    func revealLastExport() {
        guard let dir = lastExport?.directory else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir)
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}
