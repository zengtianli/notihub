
import SwiftUI


#if os(macOS)
import AppKit
private let mdFill = Color(nsColor: .quaternarySystemFill)
private let mdSeparator = Color(nsColor: .separatorColor)
#else
import UIKit
private let mdFill = Color(uiColor: .quaternarySystemFill)
private let mdSeparator = Color(uiColor: .separator)
#endif


enum MDBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(lang: String, text: String)
    case table(header: [String], rows: [[String]])
    case quote(text: String)      // 引用体原文（已剥 "> "），渲染时递归解析——引用内的表格/列表照常成块
    case list(items: [MDListItem])
    case rule
}

struct MDListItem: Equatable {
    var indent: Int      // 嵌套层级 0..n（每 2 空格算 1 级）
    var marker: String   // "•" / "1." / "2." …
    var text: String
}

private func isTableRow(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard t.contains("|") else { return false }
    return t.hasPrefix("|") || t.contains(" | ")
}

private func isTableSeparator(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard t.contains("|"), t.contains("-") else { return false }
    guard t.allSatisfy({ "|-: \t".contains($0) }) else { return false }
    for seg in t.split(separator: "|", omittingEmptySubsequences: false) {
        var s = seg.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { continue }
        if s.hasPrefix(":") { s.removeFirst() }
        if s.hasSuffix(":") { s.removeLast() }
        if s.count < 3 || !s.allSatisfy({ $0 == "-" }) { return false }
    }
    return true
}

private func splitTableCells(_ line: String) -> [String] {
    var t = line.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("|") { t.removeFirst() }
    if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
    var cells: [String] = []
    var cur = ""
    var escaped = false
    for ch in t {
        if escaped {
            cur.append(ch == "|" ? "|" : "\\\(ch)")
            escaped = false
        } else if ch == "\\" {
            escaped = true
        } else if ch == "|" {
            cells.append(cur.trimmingCharacters(in: .whitespaces))
            cur = ""
        } else {
            cur.append(ch)
        }
    }
    if escaped { cur.append("\\") }
    cells.append(cur.trimmingCharacters(in: .whitespaces))
    return cells
}

private func matchListItem(_ line: String) -> (Int, String, String)? {
    var indent = 0
    var idx = line.startIndex
    while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
        indent += line[idx] == "\t" ? 2 : 1
        idx = line.index(after: idx)
    }
    let rest = String(line[idx...])
    for m in ["- ", "* ", "+ "] where rest.hasPrefix(m) {
        let body = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return (indent / 2, "•", body)
    }
    var digits = ""
    var j = rest.startIndex
    while j < rest.endIndex, rest[j].isNumber, digits.count < 3 {
        digits.append(rest[j]); j = rest.index(after: j)
    }
    if !digits.isEmpty, j < rest.endIndex, rest[j] == "." || rest[j] == ")" {
        let afterDot = rest.index(after: j)
        if afterDot < rest.endIndex, rest[afterDot] == " " {
            let body = String(rest[rest.index(after: afterDot)...])
                .trimmingCharacters(in: .whitespaces)
            return (indent / 2, "\(digits).", body)
        }
    }
    return nil
}

private func matchHeading(_ line: String) -> (Int, String)? {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard t.hasPrefix("#") else { return nil }
    let level = t.prefix(while: { $0 == "#" }).count
    guard (1...6).contains(level) else { return nil }
    let rest = t.dropFirst(level)
    guard rest.first == " " else { return nil }
    var body = rest.trimmingCharacters(in: .whitespaces)
    let trailing = body.reversed().prefix(while: { $0 == "#" }).count
    if trailing > 0, trailing < body.count {
        let cut = body.index(body.endIndex, offsetBy: -trailing)
        if body[..<cut].hasSuffix(" ") {
            body = body[..<cut].trimmingCharacters(in: .whitespaces)
        }
    }
    return (level, body)
}

private func isRule(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
    guard t.count >= 3 else { return false }
    return t.allSatisfy { $0 == "-" } || t.allSatisfy { $0 == "*" } || t.allSatisfy { $0 == "_" }
}

func parseMarkdownBlocks(_ text: String) -> [MDBlock] {
    let normalized = text.unicodeScalars.contains("\r")
        ? text.replacingOccurrences(of: "\r\n", with: "\n")
              .replacingOccurrences(of: "\r", with: "\n")
        : text
    let lines = normalized.components(separatedBy: "\n")
    var blocks: [MDBlock] = []
    var para: [String] = []

    func flushPara() {
        if !para.isEmpty {
            blocks.append(.paragraph(para.joined(separator: "\n")))
            para = []
        }
    }

    var i = 0
    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            flushPara()
            let fenceChar = trimmed.first!
            let fenceLen = trimmed.prefix(while: { $0 == fenceChar }).count
            var lang = String(trimmed.dropFirst(fenceLen)).trimmingCharacters(in: .whitespaces)
            if lang.contains("`") { lang = "" }
            func isClose(_ s: String) -> Bool {
                let t = s.trimmingCharacters(in: .whitespaces)
                return t.count >= 3 && t.allSatisfy { $0 == fenceChar }
            }
            var code: [String] = []
            i += 1
            while i < lines.count, !isClose(lines[i]) {
                code.append(lines[i]); i += 1
            }
            if i < lines.count { i += 1 }   // 吃掉闭栏；EOF 未闭合 = 流式中，照常渲染
            blocks.append(.code(lang: lang, text: code.joined(separator: "\n")))
            continue
        }

        if trimmed.isEmpty {
            flushPara()
            i += 1
            continue
        }

        if isTableRow(line), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
            flushPara()
            let header = splitTableCells(line)
            var rows: [[String]] = []
            i += 2
            while i < lines.count {
                if isTableSeparator(lines[i]) { i += 1; continue }
                guard lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") else { break }
                var cells = splitTableCells(lines[i])
                if cells.count > header.count { cells = Array(cells.prefix(header.count)) }
                while cells.count < header.count { cells.append("") }
                rows.append(cells)
                i += 1
            }
            blocks.append(.table(header: header, rows: rows))
            continue
        }

        if let (level, txt) = matchHeading(line) {
            flushPara()
            blocks.append(.heading(level: level, text: txt))
            i += 1
            continue
        }

        if isRule(line) {
            flushPara()
            blocks.append(.rule)
            i += 1
            continue
        }

        if trimmed.hasPrefix(">") {
            flushPara()
            var qlines: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix(">") else { break }
                var inner = String(t.dropFirst())
                if inner.hasPrefix(" ") { inner.removeFirst() }
                qlines.append(inner)
                i += 1
            }
            blocks.append(.quote(text: qlines.joined(separator: "\n")))
            continue
        }

        if matchListItem(line) != nil {
            flushPara()
            var items: [MDListItem] = []
            while i < lines.count {
                if let (indent, marker, body) = matchListItem(lines[i]) {
                    items.append(MDListItem(indent: indent, marker: marker, text: body))
                    i += 1
                } else if !items.isEmpty,
                          lines[i].hasPrefix("  "),
                          !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    items[items.count - 1].text += "\n"
                        + lines[i].trimmingCharacters(in: .whitespaces)
                    i += 1
                } else {
                    break
                }
            }
            blocks.append(.list(items: items))
            continue
        }

        para.append(line)
        i += 1
    }
    flushPara()
    return blocks
}


private let strongPairRegex = try! NSRegularExpression(
    pattern: "\\*\\*(?![*\\s])((?:(?!\\*\\*).)+?)(?<![*\\s])\\*\\*")

private func sentinelizeStrong(_ s: String) -> String {
    guard s.contains("**") else { return s }
    let ns = s as NSString
    let matches = strongPairRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return s }
    var out = ""
    var last = 0
    for m in matches {
        out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
        out += "**\u{200B}" + ns.substring(with: m.range(at: 1)) + "\u{200B}**"
        last = m.range.location + m.range.length
    }
    out += ns.substring(from: last)
    return out
}

func inlineAttributed(_ s: String) -> AttributedString {
    var opts = AttributedString.MarkdownParsingOptions()
    opts.interpretedSyntax = .inlineOnlyPreservingWhitespace
    guard var attr = try? AttributedString(markdown: sentinelizeStrong(s), options: opts) else {
        return AttributedString(s)
    }
    while let r = attr.range(of: "\u{200B}") { attr.removeSubrange(r) }
    for run in attr.runs {
        if let intent = run.inlinePresentationIntent, intent.contains(.code) {
            attr[run.range].font = .system(.body, design: .monospaced)
            attr[run.range].backgroundColor = mdFill
        }
    }
    return attr
}

enum MDInlineCache {
    static var store: [String: AttributedString] = [:]
    static func attributed(_ s: String) -> AttributedString {
        if let hit = store[s] { return hit }
        if store.count > 4096 { store.removeAll(keepingCapacity: true) }
        let v = inlineAttributed(s)
        store[s] = v
        return v
    }
}


struct MarkdownText: View {
    let text: String

    var body: some View {
        let blocks = parseMarkdownBlocks(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let txt):
            Text(MDInlineCache.attributed(txt))
                .font(headingFont(level))
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 4 : 2)

        case .paragraph(let txt):
            Text(MDInlineCache.attributed(txt))
                .textSelection(.enabled)

        case .code(let lang, let code):
            VStack(alignment: .leading, spacing: 4) {
                if !lang.isEmpty {
                    Text(lang).font(.caption2).foregroundStyle(.tertiary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(mdFill))   // 与气泡底(controlBackground)差一档,代码块才像代码块
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(mdSeparator, lineWidth: 0.5))

        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            Text(MDInlineCache.attributed(cell))
                                .fontWeight(.semibold)
                                .textSelection(.enabled)
                                .frame(maxWidth: 280, alignment: .leading)
                                .gridColumnAlignment(.leading)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(rows.enumerated()), id: \.offset) { ri, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(MDInlineCache.attributed(cell))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: 280, alignment: .leading)
                                    .gridColumnAlignment(.leading)
                            }
                        }
                        if ri < rows.count - 1 {
                            Divider().gridCellUnsizedAxes(.horizontal)
                                .opacity(0.4)
                        }
                    }
                }
                .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(mdFill.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(mdSeparator, lineWidth: 0.5))

        case .quote(let inner):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: 3)
                MarkdownText(text: inner)     // 递归:引用内的表格/列表/代码照常渲染
                    .foregroundStyle(.secondary)
            }

        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .foregroundStyle(.secondary)
                            .font(.callout)
                        Text(MDInlineCache.attributed(item.text))
                            .textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(item.indent) * 16)
                }
            }

        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.bold()
        case 3: return .headline
        default: return .subheadline.bold()
        }
    }
}
