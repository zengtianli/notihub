import AppKit
import Foundation

enum DataRichText {
    static func read(_ url: URL) -> String? {
        let type: NSAttributedString.DocumentType = url.pathExtension.lowercased() == "rtfd" ? .rtfd : .rtf
        return try? NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil).string
    }

    static func install() {
        Extractor.richTextReader = read
    }
}
