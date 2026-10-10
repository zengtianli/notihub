import XCTest
@testable import notifhub

final class PrivacyAcceptanceTests: XCTestCase {
    private func client(_ id: String = "privacy-acceptance") -> CloudClient {
        let connection = CloudConnection(id: id, url: URL(string: "https://fixture.example.invalid")!,
                                         token: String(repeating: "x", count: 40))
        let client = CloudClient(connection: connection)
        addTeardownBlock { client.session.invalidateAndCancel() }
        return client
    }

    func testProductionSessionDoesNotUseDiskCacheOrCookieStorage() {
        let session = client().session
        let config = session.configuration
        XCTAssertNil(config.identifier, "The native client must not use a background disk session")
        XCTAssertNil(config.httpCookieStorage, "Native credentials must not share browser cookies")
        XCTAssertEqual(config.urlCache?.diskCapacity ?? 0, 0)
        if let cache = config.urlCache {
            XCTAssertFalse(cache === URLCache.shared, "Native responses must not enter the shared cache")
        }
        XCTAssertTrue(session.delegate is CloudRedirectGuard)
    }

    func testInstalledRedirectDelegateRejectsSameAndCrossOriginRedirects() throws {
        let session = client().session
        let guardDelegate = try XCTUnwrap(session.delegate as? CloudRedirectGuard)
        let original = URL(string: "https://fixture.example.invalid/native/api/index")!
        let task = session.dataTask(with: original) // Never resumed; no network request is made.
        defer { task.cancel() }
        for destination in ["https://fixture.example.invalid/login", "https://other.example.invalid/collect"] {
            var redirected = URLRequest(url: URL(string: destination)!)
            redirected.setValue("Bearer synthetic-fixture", forHTTPHeaderField: "Authorization")
            let response = try XCTUnwrap(HTTPURLResponse(url: original, statusCode: 302,
                                                       httpVersion: nil, headerFields: ["Location": destination]))
            var callbacks = 0
            guardDelegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                     newRequest: redirected) { result in
                callbacks += 1
                XCTAssertNil(result, "Redirects must not forward the instance credential")
            }
            XCTAssertEqual(callbacks, 1)
        }
    }

    @MainActor
    func testDraftsAreIsolatedByInstanceAndRestoredOnlyToTheirOwner() throws {
        let suite = "PrivacyAcceptanceTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let firstClient = client("first-fixture")
        let secondClient = client("second-fixture")
        let first = CloudModel(client: firstClient, defaults: preferences)
        first.beginNote()
        first.draft = "First fixture private draft"
        let firstDate = first.draftDate

        let second = CloudModel(client: secondClient, defaults: preferences)
        second.beginNote()
        XCTAssertEqual(second.draft, "")
        second.draft = "Second fixture private draft"

        let restoredFirst = CloudModel(client: firstClient, defaults: preferences)
        restoredFirst.beginNote()
        XCTAssertEqual(restoredFirst.draft, "First fixture private draft")
        XCTAssertEqual(restoredFirst.draftDate, firstDate)
        restoredFirst.draft = ""

        let restoredSecond = CloudModel(client: secondClient, defaults: preferences)
        restoredSecond.beginNote()
        XCTAssertEqual(restoredSecond.draft, "Second fixture private draft")
    }
}
