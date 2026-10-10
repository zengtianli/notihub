import Foundation

final class MailCollector: Collector {
    let name = "mail"
    private let wmKey = "wm.mail.stamp"

    var mailRoot: URL {
        if let s = ProcessInfo.processInfo.environment["NOTIFHUB_MAIL_ROOT"] {
            return URL(fileURLWithPath: s.expandingTilde)
        }
        return Paths.home.appendingPathComponent("Library/Mail")
    }

    func health() -> (Bool, String) {
        let (rc, _) = run("/usr/bin/python3", ["-c", "from email.parser import BytesParser; from html.parser import HTMLParser"], timeout: 10)
        if rc != 0 { return (false, "系统 Python 邮件解析器不可用（rc=\(rc)）") }
        let boxes = inboxes()
        if boxes.isEmpty { return (false, "找不到 INBOX.mbox（没用 Mail.app？那这条源本来就用不上）") }
        return (true, "\(boxes.count) 个 INBOX")
    }

    private func inboxes() -> [URL] {
        let fm = FileManager.default
        guard let vs = try? fm.contentsOfDirectory(at: mailRoot, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        for v in vs where v.lastPathComponent.hasPrefix("V") {
            guard let accts = try? fm.contentsOfDirectory(at: v, includingPropertiesForKeys: nil) else { continue }
            for a in accts {
                let box = a.appendingPathComponent("INBOX.mbox")
                if fm.fileExists(atPath: box.path) { out.append(box) }
            }
        }
        return out
    }

    func collect(_ store: Store) -> [Event] {
        let boxes = inboxes()
        guard !boxes.isEmpty else { return [] }
        let last = Double(store.watermark(wmKey) ?? "") ?? -1
        let now = nowUnix()
        if last < 0 {
            store.setWatermark(wmKey, "\(now)")
            Log.write("mail: 基线时间戳已建")
            return []
        }
        defer { store.setWatermark(wmKey, "\(now)") }

        var out: [Event] = []
        let fm = FileManager.default
        for box in boxes {
            guard let e = fm.enumerator(at: box, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { continue }
            for case let f as URL in e {
                guard f.pathExtension == "emlx" else { continue }
                guard let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      m.timeIntervalSince1970 > last else { continue }
                guard let (subject, body) = Self.parse(f) else { continue }
                if subject.isEmpty && body.isEmpty { continue }
                out.append(Event(ts: m.timeIntervalSince1970, source: name,
                                 bundle: "com.apple.mail", app: "邮件",
                                 title: subject, subtitle: "", body: body,
                                 extID: f.lastPathComponent, recID: nil))
                if out.count >= 20 { break }
            }
        }
        return out
    }

    static func parse(_ url: URL) -> (String, String)? {
        let (rc, output) = run("/usr/bin/python3", ["-c", mimeParser, url.path], timeout: 10)
        guard rc == 0, let data = output.data(using: .utf8),
              let parts = try? JSONDecoder().decode([String].self, from: data), parts.count == 2 else {
            Log.err("mail: MIME 正文解析失败（rc=\(rc)）")
            return nil
        }
        return (parts[0], parts[1])
    }

    static let mimeParser = #"""
import sys, json, re
from email import policy
from email.parser import BytesParser
from html.parser import HTMLParser

class TextHTML(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.hidden = []
    def handle_starttag(self, tag, attrs):
        if tag in ('script', 'style', 'head', 'title'):
            self.hidden.append(tag)
        if not self.hidden and tag in ('br', 'p', 'div', 'tr', 'li', 'table', 'h1', 'h2', 'h3'):
            self.parts.append('\n')
    def handle_endtag(self, tag):
        if self.hidden:
            if tag == self.hidden[-1]: self.hidden.pop()
        elif tag in ('p', 'div', 'tr', 'li', 'table', 'h1', 'h2', 'h3'):
            self.parts.append('\n')
    def handle_data(self, data):
        if not self.hidden: self.parts.append(data)

def parse_mail(path):
    with open(path, 'rb') as f:
        first = f.readline()
        if first.strip().isdigit():
            size = int(first.strip())
            if size > 32 * 1024 * 1024: raise ValueError('mail too large')
            raw = f.read(size)
        else:
            raw = first + f.read(32 * 1024 * 1024)
    msg = BytesParser(policy=policy.default).parsebytes(raw)
    # HTML 正文只取可见文字，避免纯文本替代版把追踪 URL 大段铺进日报。
    part = msg.get_body(preferencelist=('html', 'plain'))
    if part is not None and part.get_content_type() == 'text/plain' and not (part.get_payload(decode=True) or b'').strip():
        part = msg.get_body(preferencelist=('html',)) or part
    text = ''
    if part is not None:
        payload = part.get_payload(decode=True) or b''
        charset = part.get_content_charset() or 'utf-8'
        try: text = payload.decode(charset, errors='replace')
        except LookupError: text = payload.decode('utf-8', errors='replace')
        if part.get_content_type() == 'text/html' or re.search(r'<(?:html|br|div|p|table|a)(?:\s[^<>]*|\s*/?)>', text, re.I):
            parser = TextHTML()
            parser.feed(text)
            text = ''.join(parser.parts)
    text = '\n'.join(re.sub(r'[ \t\r\f\v\xa0]+', ' ', line).strip() for line in text.splitlines())
    text = '\n'.join('' if re.fullmatch(r'[\s\u034f\u200b-\u200f\u2060\ufeff]*', line) else line for line in text.splitlines())
    text = re.sub(r'\n{3,}', '\n\n', text).strip()
    return [str(msg.get('Subject', '')), text[:65536]]

if __name__ == '__main__':
    print(json.dumps(parse_mail(sys.argv[1]), ensure_ascii=False))
"""#
}
