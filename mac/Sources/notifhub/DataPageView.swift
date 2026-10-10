import AppKit
import SwiftUI

enum DataPageStyle {
    static let ink = Color(red: 0.18, green: 0.20, blue: 0.22)
    static let muted = Color(red: 0.48, green: 0.49, blue: 0.49)
    static let accent = Color(red: 0.87, green: 0.34, blue: 0.23)
    static let accentSoft = Color(red: 0.99, green: 0.935, blue: 0.87)
    static let paper = Color(red: 0.98, green: 0.975, blue: 0.96)
    static let rail = Color(red: 0.968, green: 0.960, blue: 0.943)
    static let card = Color.white
    static let stripe = Color(red: 0.992, green: 0.988, blue: 0.980)
    static let header = Color(red: 0.955, green: 0.947, blue: 0.925)
    static let line = Color.black.opacity(0.065)
    static let ok = Color(red: 0.16, green: 0.50, blue: 0.33)
    static let warn = Color(red: 0.70, green: 0.42, blue: 0.05)
    static let bad = Color(red: 0.72, green: 0.18, blue: 0.16)
    static let permissionBG = Color(red: 1.0, green: 0.965, blue: 0.90)

    static func color(for verdict: SourceVerdict) -> Color {
        switch verdict {
        case .ok: return ok
        case .notFound: return muted
        case .denied: return warn
        case .failed: return bad
        }
    }
}

struct DataPagePill: View {
    let text: String
    var color: Color = DataPageStyle.muted
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct DataPageView: View {
    @ObservedObject var model: DataPageModel
    var scansOnAppear = true
    @State private var showExportSheet = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(DataPageStyle.line).frame(height: 1)
            if !model.deniedDomains.isEmpty { DataPermissionBanner(model: model) }
            if let banner = model.banner { DataMessageBanner(banner: banner) { model.banner = nil } }
            HStack(spacing: 0) {
                DataDomainList(model: model).frame(width: 262)
                Rectangle().fill(DataPageStyle.line).frame(width: 1)
                DataDetailView(model: model)
            }
        }
        .background(DataPageStyle.paper)
        .foregroundStyle(DataPageStyle.ink)
        .tint(DataPageStyle.accent)
        .preferredColorScheme(.light)
        .sheet(isPresented: $showExportSheet) { DataExportSheet(model: model, presented: $showExportSheet) }
        .task { if scansOnAppear && model.results.isEmpty && !model.isScanning { model.scanAll() } }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("本机数据").font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("只读取 Apple 自带 App 的本机数据；内容不上云，也不进每日总结。")
                    .font(.system(size: 11)).foregroundStyle(DataPageStyle.muted)
            }
            Spacer()
            if model.isScanning { ProgressView().controlSize(.small) }
            Button { model.scanAll() } label: {
                Label(model.isScanning ? "读取中…" : "重新扫描", systemImage: "arrow.clockwise")
            }
            .disabled(model.isScanning)
            .keyboardShortcut("r", modifiers: .command)
            .help("重新读取全部 \(model.domains.count) 类数据（⌘R）")
            Menu {
                ForEach(DataPageModel.limitOptions, id: \.self) { n in
                    Button {
                        model.limit = n
                        model.scanAll() // 改了上限必须重扫，否则条数与新上限对不上
                    } label: {
                        if model.limit == n { Label("每类上限 \(n.formatted())", systemImage: "checkmark") }
                        else { Text("每类上限 \(n.formatted())") }
                    }
                }
            } label: { Text("每类上限 \(model.limit.formatted())") }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(model.isScanning)
                .help("同时作用于预览与导出；改了会立刻重新读取")
            Button { showExportSheet = true } label: {
                Label(model.exporting ? "导出中…" : "导出所选…", systemImage: "square.and.arrow.up").padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(model.selected.isEmpty || model.isScanning || model.exporting)
            .help("先确认清单，再选目录")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 24).padding(.vertical, 14)
    }
}


struct DataPermissionBanner: View {
    @ObservedObject var model: DataPageModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield").font(.system(size: 15, weight: .semibold)).foregroundStyle(DataPageStyle.warn)
            VStack(alignment: .leading, spacing: 3) {
                Text("需要完全磁盘访问权限").font(.system(size: 12.5, weight: .semibold))
                Text("读不到：\(model.deniedDomains.map(\.name).joined(separator: "、"))。请在 系统设置 → 隐私与安全性 → 完全磁盘访问 打开 Notihub，退出并重新打开。")
                    .font(.system(size: 11.5)).foregroundStyle(DataPageStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("打开系统设置") { model.openFullDiskAccessSettings() }.controlSize(.small)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(DataPageStyle.permissionBG)
        .overlay(alignment: .bottom) { Rectangle().fill(DataPageStyle.line).frame(height: 1) }
    }
}

struct DataMessageBanner: View {
    let banner: DataPageBanner
    let dismiss: () -> Void

    private var tint: Color {
        switch banner.kind {
        case .info: return DataPageStyle.ok
        case .warning: return DataPageStyle.warn
        case .failure: return DataPageStyle.bad
        }
    }
    private var icon: String {
        switch banner.kind {
        case .info: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .failure: return "xmark.octagon"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(.system(size: 12.5, weight: .semibold))
                Text(banner.detail).font(.system(size: 11.5)).foregroundStyle(DataPageStyle.muted)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("知道了", action: dismiss).controlSize(.small)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(tint.opacity(0.07))
        .overlay(alignment: .bottom) { Rectangle().fill(DataPageStyle.line).frame(height: 1) }
    }
}


struct DataDomainList: View {
    @ObservedObject var model: DataPageModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button("全选") { model.selectAll() }
                Button("全不选") { model.selectNone() }
                Button("只选有数据的") { model.selectReadable() }
            }
            .controlSize(.small).font(.system(size: 11))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(DataPageStyle.line).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.domains) { domain in
                        DataDomainRow(model: model, domain: domain)
                        Rectangle().fill(DataPageStyle.line).frame(height: 1).padding(.leading, 40)
                    }
                }
            }
            Rectangle().fill(DataPageStyle.line).frame(height: 1)
            let summary = model.exportableSummary
            HStack(spacing: 6) {
                Text("已勾 \(model.selected.count) / \(model.domains.count) 类").font(.system(size: 11, weight: .medium))
                Spacer()
                Text("可导出 \(summary.rows.formatted()) 条").font(.system(size: 11)).foregroundStyle(DataPageStyle.muted)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
        }
        .background(DataPageStyle.rail)
    }
}

struct DataDomainRow: View {
    @ObservedObject var model: DataPageModel
    let domain: DataDomain

    private var result: DomainResult? { model.results[domain.id] }
    private var focused: Bool { model.focus == domain.id }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Toggle("", isOn: Binding(get: { model.selected.contains(domain.id) }, set: { _ in model.toggle(domain) }))
                .labelsHidden().toggleStyle(.checkbox).padding(.top, 1)
                .accessibilityLabel("勾选\(domain.name)")
            Image(systemName: domain.symbol).font(.system(size: 12)).foregroundStyle(DataPageStyle.accent)
                .frame(width: 17).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(domain.name).font(.system(size: 12.5, weight: .medium))
                status
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(focused ? DataPageStyle.accentSoft : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.focus(on: domain) }
    }

    @ViewBuilder private var status: some View {
        if model.scanning.contains(domain.id) {
            DataPagePill(text: "读取中…")
        } else if let r = result {
            HStack(spacing: 5) {
                if let failure = r.failure {
                    DataPagePill(text: "失败", color: DataPageStyle.bad)
                    Text(failure).font(.system(size: 10)).foregroundStyle(DataPageStyle.bad).lineLimit(1)
                } else if r.verdict.isOK {
                    DataPagePill(text: "\(r.rowCount.formatted()) 条", color: r.rowCount > 0 ? DataPageStyle.ok : DataPageStyle.muted)
                    if r.truncated { DataPagePill(text: "触上限", color: DataPageStyle.warn) }
                } else {
                    DataPagePill(text: r.verdict.label, color: DataPageStyle.color(for: r.verdict))
                }
            }
        } else {
            DataPagePill(text: "待读取")
        }
    }
}


struct DataDetailView: View {
    @ObservedObject var model: DataPageModel

    var body: some View {
        if let domain = model.focusedDomain {
            VStack(alignment: .leading, spacing: 0) {
                DataDetailHeader(model: model, domain: domain)
                Rectangle().fill(DataPageStyle.line).frame(height: 1)
                content(for: domain)
            }
        } else {
            Text("在左侧选一类数据").foregroundStyle(DataPageStyle.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func content(for domain: DataDomain) -> some View {
        if model.scanning.contains(domain.id) {
            centered { ProgressView("正在快照并读取\(domain.name)…").controlSize(.small) }
        } else if let r = model.results[domain.id] {
            if let failure = r.failure {
                centered { DataEmptyState(icon: "exclamationmark.triangle", tint: DataPageStyle.bad, title: "读取失败", detail: failure) }
            } else if !r.verdict.isOK {
                centered { DataUnreadableState(model: model, domain: domain, verdict: r.verdict) }
            } else if r.rows.isEmpty {
                centered { DataEmptyState(icon: "tray", tint: DataPageStyle.muted, title: "读到 0 条",
                                          detail: "数据源可读，但里面确实没有记录 —— 这是真实结果，不是失败。") }
            } else {
                DataTableView(columns: r.columns, rows: r.rows, cap: DataPageModel.previewCap)
            }
        } else {
            centered { DataEmptyState(icon: "clock", tint: DataPageStyle.muted, title: "尚未读取", detail: "点右上角「重新扫描」（⌘R）。") }
        }
    }

    private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DataDetailHeader: View {
    @ObservedObject var model: DataPageModel
    let domain: DataDomain

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: domain.symbol).foregroundStyle(DataPageStyle.accent)
                Text(domain.name).font(.system(size: 16, weight: .semibold))
                if let r = model.results[domain.id], r.isUsable {
                    DataPagePill(text: "\(r.rowCount.formatted()) 条", color: DataPageStyle.ok)
                    if r.truncated { DataPagePill(text: "已达上限 \(model.limit.formatted())，更早的记录未取", color: DataPageStyle.warn) }
                }
                Spacer()
                Toggle("导出这一类", isOn: Binding(get: { model.selected.contains(domain.id) }, set: { _ in model.toggle(domain) }))
                    .toggleStyle(.checkbox).font(.system(size: 11.5))
            }
            Text(domain.summary).font(.system(size: 11.5)).foregroundStyle(DataPageStyle.muted)
            ForEach(domain.sources.map(\.display), id: \.self) { path in
                HStack(spacing: 5) {
                    Image(systemName: "folder").font(.system(size: 9)).foregroundStyle(DataPageStyle.muted)
                    Text(path).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(DataPageStyle.muted)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DataPageStyle.card)
    }
}

struct DataUnreadableState: View {
    @ObservedObject var model: DataPageModel
    let domain: DataDomain
    let verdict: SourceVerdict

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: verdict == .denied ? "lock.shield" : "questionmark.folder")
                .font(.system(size: 30)).foregroundStyle(DataPageStyle.color(for: verdict))
            Text(verdict.label).font(.system(size: 14, weight: .semibold))
            Text(explanation).font(.system(size: 11.5)).foregroundStyle(DataPageStyle.muted)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
            if verdict == .denied {
                Button("打开系统设置 › 隐私与安全性 › 完全磁盘访问") { model.openFullDiskAccessSettings() }
            }
        }.padding(28)
    }

    private var explanation: String {
        switch verdict {
        case .denied:
            return "在 系统设置 → 隐私与安全性 → 完全磁盘访问 打开 Notihub，然后退出并重新打开 Notihub —— macOS 只在启动时发放这个权限。没有权限时这里保持空白，不用假数据填充。"
        case .notFound:
            return "这些路径在本机不存在：\n\(domain.sources.map(\.display).joined(separator: "\n"))\n\n这不是权限问题（被拒绝时系统报的是 EPERM，不是「不存在」）。多半是这个 App 从未用过，或 macOS 换了存放位置。"
        case .failed(let message):
            return message
        case .ok:
            return ""
        }
    }
}

struct DataEmptyState: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundStyle(tint)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 11.5)).foregroundStyle(DataPageStyle.muted)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
        }.padding(28)
    }
}


struct DataTableView: View {
    let columns: [String]
    let rows: [[String]]
    let cap: Int

    private var shown: ArraySlice<[String]> { rows.prefix(cap) }

    private var widths: [CGFloat] {
        columns.indices.map { i in
            var maxLen = columns[i].count * 2
            for row in shown where i < row.count {
                maxLen = max(maxLen, displayLength(row[i]))
                if maxLen > 120 { break }
            }
            return min(max(CGFloat(maxLen) * 6.6 + 22, 74), 420)
        }
    }

    private func displayLength(_ s: String) -> Int {
        var n = 0
        for u in s.unicodeScalars {
            n += (u.value >= 0x2E80 && u.value <= 0xD7FF) || (u.value >= 0xFF00 && u.value <= 0xFFEF) ? 2 : 1
            if n > 130 { break }
        }
        return n
    }

    var body: some View {
        let w = widths
        VStack(alignment: .leading, spacing: 0) {
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(Array(shown.enumerated()), id: \.offset) { idx, row in
                            HStack(spacing: 0) {
                                ForEach(columns.indices, id: \.self) { i in
                                    Text(i < row.count ? row[i] : "")
                                        .font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
                                        .textSelection(.enabled)
                                        .padding(.horizontal, 8).frame(width: w[i], alignment: .leading)
                                }
                            }
                            .frame(height: 25)
                            .background(idx.isMultiple(of: 2) ? DataPageStyle.card : DataPageStyle.stripe)
                            .overlay(alignment: .bottom) { Rectangle().fill(DataPageStyle.line).frame(height: 0.5) }
                        }
                    } header: {
                        HStack(spacing: 0) {
                            ForEach(columns.indices, id: \.self) { i in
                                Text(columns[i]).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                    .padding(.horizontal, 8).frame(width: w[i], alignment: .leading)
                            }
                        }
                        .frame(height: 28)
                        .background(DataPageStyle.header)
                        .overlay(alignment: .bottom) { Rectangle().fill(DataPageStyle.line).frame(height: 1) }
                    }
                }
            }
            .topLeadingScrollAnchor()   // 表比显示区宽时从第一列开始,不从中间(离屏渲染实测第一列左侧被裁 8px)
            .background(DataPageStyle.card)
            if rows.count > cap {
                Text("界面只显示前 \(cap) 条（共 \(rows.count.formatted()) 条）；导出写的是全部 \(rows.count.formatted()) 条。")
                    .font(.system(size: 10.5)).foregroundStyle(DataPageStyle.muted)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DataPageStyle.header)
            }
        }
    }
}


struct DataExportSheet: View {
    @ObservedObject var model: DataPageModel
    @Binding var presented: Bool

    func cancel() { presented = false }

    private var readyDomains: [DataDomain] {
        model.selectedDomains.filter { model.results[$0.id]?.isUsable == true && model.results[$0.id]?.rows.isEmpty == false }
    }

    private var blockedDomains: [(DataDomain, String)] {
        model.selectedDomains.compactMap { d in
            guard let r = model.results[d.id] else { return (d, "尚未读取") }
            if let failure = r.failure { return (d, failure) }
            if !r.verdict.isOK { return (d, r.verdict.label) }
            if r.rows.isEmpty { return (d, "读到 0 条（数据源为空）") }
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up").foregroundStyle(DataPageStyle.accent)
                Text("确认导出清单").font(.system(size: 15, weight: .semibold))
            }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            Rectangle().fill(DataPageStyle.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("将导出 \(readyDomains.count) 类", tint: DataPageStyle.ok) {
                        if readyDomains.isEmpty {
                            Text("没有可导出的数据 —— 先读取，或改勾选。").font(.system(size: 11.5)).foregroundStyle(DataPageStyle.warn)
                        }
                        ForEach(readyDomains) { d in
                            let r = model.results[d.id]!
                            HStack(spacing: 8) {
                                Image(systemName: d.symbol).font(.system(size: 11)).foregroundStyle(DataPageStyle.accent).frame(width: 16)
                                Text(d.name).font(.system(size: 12))
                                Text("\(d.id).\(model.format.ext)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(DataPageStyle.muted)
                                Spacer()
                                if r.truncated { DataPagePill(text: "触上限", color: DataPageStyle.warn) }
                                if model.masked && !d.sensitiveColumns.isEmpty { DataPagePill(text: "将脱敏", color: DataPageStyle.accent) }
                                Text("\(r.rowCount.formatted()) 条").font(.system(size: 11, weight: .medium))
                            }
                        }
                    }
                    if !blockedDomains.isEmpty {
                        section("不会导出 \(blockedDomains.count) 类", tint: DataPageStyle.warn) {
                            ForEach(blockedDomains, id: \.0.id) { d, reason in
                                HStack(spacing: 8) {
                                    Image(systemName: d.symbol).font(.system(size: 11)).foregroundStyle(DataPageStyle.muted).frame(width: 16)
                                    Text(d.name).font(.system(size: 12))
                                    Spacer()
                                    Text(reason).font(.system(size: 11)).foregroundStyle(DataPageStyle.warn).lineLimit(1)
                                }
                            }
                            Text("这些类别不会生成空文件 —— 空文件和「没数据」在磁盘上分不出来。原因写进《导出说明.md》。")
                                .font(.system(size: 10.5)).foregroundStyle(DataPageStyle.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    section("选项", tint: DataPageStyle.accent) {
                        Picker("格式", selection: $model.format) {
                            ForEach(ExportFormat.allCases) { f in Text(f.rawValue).tag(f) }
                        }.pickerStyle(.segmented).frame(width: 220)
                        Toggle("脱敏电话与邮箱（只影响导出文件，预览始终是原值）", isOn: $model.masked)
                            .font(.system(size: 11.5)).toggleStyle(.checkbox)
                        Text("每次导出新建 export-<编号>/ 目录（仅本人可读），另附《导出说明.md》：每类从哪读的、多少条、是否触上限、哪些没导出及原因。")
                            .font(.system(size: 10.5)).foregroundStyle(DataPageStyle.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(20)
            }
            Rectangle().fill(DataPageStyle.line).frame(height: 1)
            HStack {
                let s = model.exportableSummary
                Text("合计 \(s.domains) 个文件 / \(s.rows.formatted()) 条").font(.system(size: 11.5)).foregroundStyle(DataPageStyle.muted)
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("选择目录并导出") {
                    presented = false
                    model.chooseDirectoryAndExport()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(readyDomains.isEmpty)
            }.padding(.horizontal, 20).padding(.vertical, 13)
        }
        .frame(width: 620, height: 520)
        .background(DataPageStyle.card)
        .foregroundStyle(DataPageStyle.ink)
        .tint(DataPageStyle.accent)
        .preferredColorScheme(.light)
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, tint: Color, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(DataPageStyle.paper, in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension View {
    @ViewBuilder func topLeadingScrollAnchor() -> some View {
        if #available(macOS 14.0, *) { self.defaultScrollAnchor(.topLeading) } else { self }
    }
}
