import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import notifhub

enum DataTestKit {
    static func tempDir(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notihub-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return root
    }

    static func sqlite(_ url: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            throw XCTSkip("cannot create synthetic fixture")
        }
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw NSError(domain: "DataTestKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture SQL failed: \(message)"])
        }
    }

    static func domain(_ id: String, paths: [String], extraction: Extraction,
                       times: Set<Int> = [], sensitive: Set<Int> = []) -> DataDomain {
        DataDomain(id: id, name: id, symbol: "doc", summary: "Synthetic acceptance fixture",
                   sources: paths.map { SourceSpec($0) }, extraction: extraction,
                   timestampColumns: times, sensitiveColumns: sensitive)
    }

    static func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256Digest.hex(data)
    }

    static func systemTime(_ unix: TimeInterval) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Clock.tz
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: unix))
    }
}

@MainActor
func waitUntil(_ what: String, timeout: TimeInterval = 8, _ ready: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !ready() {
        guard Date() < deadline else { throw NSError(domain: "wait", code: 1, userInfo: [NSLocalizedDescriptionKey: "timed out: \(what)"]) }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

enum SHA256Digest {
    static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
