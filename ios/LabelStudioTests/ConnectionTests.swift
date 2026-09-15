import Foundation
import XCTest
@testable import LabelStudio

final class ConnectionTests: XCTestCase {
    private let token = String(repeating: "k", count: 32)

    func testSettingsAcceptOnlyHTTPSOrigins() throws {
        for value in ["https://example.com", "https://example.com/", "  https://example.com:8443/\n"] {
            let settings = try ConnectionSettings(endpoint: value, token: token)
            XCTAssertEqual(settings.endpoint.scheme, "https")
            XCTAssertEqual(settings.endpoint.host, "example.com")
            XCTAssertEqual(settings.token, token)
        }
        for value in ["http://example.com", "example.com", "https://", "https://example.com/api",
                      "https://example.com/?key=value", "https://example.com/#fragment",
                      "https://owner@example.com", "https://owner:password@example.com"] {
            XCTAssertThrowsError(try ConnectionSettings(endpoint: value, token: token), value) { error in
                guard case ConnectionError.invalidURL = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testSettingsRejectShortOrWhitespaceContainingCodes() throws {
        for code in ["", String(repeating: "a", count: 31), token + " ", "\n" + token,
                     String(repeating: "a", count: 16) + "\t" + String(repeating: "b", count: 16)] {
            XCTAssertThrowsError(try ConnectionSettings(endpoint: "https://example.com", token: code)) { error in
                guard case ConnectionError.invalidToken = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
        XCTAssertNoThrow(try ConnectionSettings(endpoint: "https://example.com", token: token + "-longer"))
    }

    func testSavedCodeCanOnlyBeReusedForItsHTTPSHostAndPort() throws {
        let saved = try ConnectionSettings(endpoint: "https://owner.example.com:8443", token: token)
        for endpoint in ["https://owner.example.com:8443", "https://OWNER.example.com:8443/",
                         "  https://owner.example.com:8443/\n"] {
            XCTAssertEqual(try ConnectionSettings.tokenFor(endpoint: endpoint, enteredCode: "", saved: saved), token)
        }
        for endpoint in ["https://other.example.com:8443", "https://owner.example.com.attacker.invalid:8443",
                         "https://owner.example.com", "https://owner.example.com:443",
                         "http://owner.example.com:8443", "https://owner.example.com:8443/api",
                         "https://owner.example.com:8443/?query=value", "https://owner.example.com:8443/#fragment",
                         "https://user@owner.example.com:8443"] {
            XCTAssertThrowsError(try ConnectionSettings.tokenFor(endpoint: endpoint, enteredCode: "", saved: saved), endpoint) { error in
                guard case ConnectionError.invalidToken = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
        let defaultPort = try ConnectionSettings(endpoint: "https://owner.example.com/", token: token)
        XCTAssertEqual(try ConnectionSettings.tokenFor(endpoint: "https://owner.example.com", enteredCode: "", saved: defaultPort), token)
    }

    func testChangingServerRequiresAnExplicitNewCodeAndMissingSavedCodeFails() throws {
        let saved = try ConnectionSettings(endpoint: "https://old.example.com", token: token)
        let newCode = String(repeating: "n", count: 40)
        XCTAssertEqual(try ConnectionSettings.tokenFor(endpoint: "https://new.example.com", enteredCode: " \(newCode)\n", saved: saved), newCode)
        XCTAssertEqual(try ConnectionSettings.tokenFor(endpoint: "https://new.example.com", enteredCode: newCode, saved: nil), newCode)
        XCTAssertThrowsError(try ConnectionSettings.tokenFor(endpoint: "https://old.example.com", enteredCode: "", saved: nil)) { error in
            guard case ConnectionError.invalidToken = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testDefaultSessionRejectsEveryRedirectWithoutForwardingCredentials() throws {
        let settings = try ConnectionSettings(endpoint: "https://owner.example.com", token: token)
        let client = GenerationClient(settings: settings)
        XCTAssertTrue(client.session === GenerationClient.secureSession)
        let delegate = try XCTUnwrap(client.session.delegate as? URLSessionTaskDelegate)
        let originalURL = try XCTUnwrap(URL(string: "https://owner.example.com/v1/config"))
        // This task is intentionally never resumed; directly exercise the actual
        // session delegate installed by production, without starting a network request.
        let task = client.session.dataTask(with: originalURL)
        defer { task.cancel() }
        for status in [301, 302, 303, 307, 308] {
            for destination in ["https://owner.example.com/other", "https://other.example.com/v1/config",
                                "http://owner.example.com/v1/config", "https://owner.example.com:8443/v1/config"] {
                let response = try XCTUnwrap(HTTPURLResponse(url: originalURL, statusCode: status, httpVersion: "HTTP/1.1",
                                                             headerFields: ["Location": destination]))
                var redirected = URLRequest(url: try XCTUnwrap(URL(string: destination)))
                redirected.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let rejected = expectation(description: "Reject HTTP \(status) redirect to \(destination)")
                delegate.urlSession?(client.session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) { request in
                    XCTAssertNil(request, "The authenticated request must not be forwarded to any redirect target")
                    rejected.fulfill()
                }
                wait(for: [rejected], timeout: 1)
            }
        }
    }

    func testCreateRetainsIdempotentPUTIdentityPromptAndBearerCode() async throws {
        let id = try XCTUnwrap(UUID(uuidString: "B63F4385-5283-42D2-A0AA-70E11612FC18"))
        let prompt = "A red kōwhai flower\nwith \"hello\" on white"
        let fixture = try HTTPFixture(token: token, status: 202, json: [
            "id": id.uuidString.lowercased(), "status": "queued", "model": "gpt-image-2.5-sunburst"
        ])
        defer { fixture.close() }
        let first = try await fixture.client.create(id: id, prompt: prompt)
        let resumed = try await fixture.client.create(id: id, prompt: prompt)
        XCTAssertEqual(first.id, id.uuidString.lowercased())
        XCTAssertEqual(resumed.id, first.id)
        XCTAssertEqual(first.status, "queued")
        let requests = fixture.requests
        XCTAssertEqual(requests.count, 2)
        for recorded in requests {
            XCTAssertEqual(recorded.request.httpMethod, "PUT")
            XCTAssertEqual(recorded.request.url?.path, "/v1/jobs/b63f4385-5283-42d2-a0aa-70e11612fc18")
            XCTAssertEqual(recorded.request.url?.host, fixture.host)
            XCTAssertEqual(recorded.request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
            XCTAssertEqual(recorded.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: recorded.body), ["prompt": prompt])
        }
        XCTAssertEqual(requests.first?.body, requests.last?.body)
    }

    func testStatusAndImageUseSameJobWithoutCreatingAnother() async throws {
        let id = UUID()
        let status = try HTTPFixture(token: token, status: 200, json: [
            "id": id.uuidString.lowercased(), "status": "completed", "model": "gpt-image-2.5-sunburst"
        ])
        defer { status.close() }
        let job = try await status.client.status(id: id)
        XCTAssertEqual(job.status, "completed")
        let statusRequest = try XCTUnwrap(status.requests.first?.request)
        XCTAssertEqual(statusRequest.httpMethod, "GET")
        XCTAssertEqual(statusRequest.url?.path, "/v1/jobs/\(id.uuidString.lowercased())")

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let image = try HTTPFixture(token: token, status: 200, data: png)
        defer { image.close() }
        let imageData = try await image.client.image(id: id)
        XCTAssertEqual(imageData, png)
        let imageRequest = try XCTUnwrap(image.requests.first?.request)
        XCTAssertEqual(imageRequest.httpMethod, "GET")
        XCTAssertEqual(imageRequest.url?.path, "/v1/jobs/\(id.uuidString.lowercased())/image")
        XCTAssertEqual(imageRequest.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
    }

    func testUnauthorizedAndRateLimitedResponsesHaveActionableErrors() async throws {
        for (status, expectedDescription) in [
            (401, "Your connection code was not accepted. Reconnect in Settings."),
            (429, "The server is busy. Wait a minute, then resume this request.")
        ] {
            let fixture = try HTTPFixture(token: token, status: status, json: [
                "error": ["code": "test_error", "message": "Private upstream detail"]
            ])
            defer { fixture.close() }
            do {
                _ = try await fixture.client.create(id: UUID(), prompt: "test")
                XCTFail("HTTP \(status) must fail")
            } catch let error as GenerationError {
                guard case .server(let actualStatus, let message) = error else {
                    XCTFail("Unexpected error: \(error)"); continue
                }
                XCTAssertEqual(actualStatus, status)
                XCTAssertEqual(message, "Private upstream detail")
                XCTAssertEqual(error.errorDescription, expectedDescription)
            }
            XCTAssertEqual(fixture.requests.count, 1, "The client must not silently generate again after an error")
        }
    }

    func testConfigurationAcceptsExpectedPanelAndReportsReadiness() async throws {
        for ready in [true, false] {
            var configuration = validConfiguration
            configuration["ready"] = ready
            configuration["palette"] = ["#ff0000", "#ffff00", "#ffffff", "#000000"]
            let fixture = try HTTPFixture(token: token, status: 200, json: configuration)
            defer { fixture.close() }
            let result = try await fixture.client.configuration()
            XCTAssertEqual(result.ready, ready)
            XCTAssertEqual(result.width, 400)
            XCTAssertEqual(result.height, 300)
            let request = try XCTUnwrap(fixture.requests.first?.request)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/config")
        }
    }

    func testMismatchedServerConfigurationIsRejected() async throws {
        let mismatches: [(String, Any)] = [
            ("width", 300), ("height", 400), ("model", "different-image-model"),
            ("palette", ["#000000", "#FFFFFF", "#FF0000"]),
            ("palette", ["#000000", "#FFFFFF", "#00FF00", "#FF0000"])
        ]
        for (key, value) in mismatches {
            var configuration = validConfiguration
            configuration[key] = value
            let fixture = try HTTPFixture(token: token, status: 200, json: configuration)
            defer { fixture.close() }
            do {
                _ = try await fixture.client.configuration()
                XCTFail("Must reject mismatched \(key): \(value)")
            } catch {
                guard case GenerationError.incompatibleServer = error else {
                    XCTFail("Unexpected error: \(error)"); continue
                }
            }
        }
    }

    func testMalformedOrOversizedJSONResponseIsRejected() async throws {
        for body in [Data("not JSON".utf8), Data(repeating: 0x20, count: 65_537)] {
            let fixture = try HTTPFixture(token: token, status: 200, data: body)
            defer { fixture.close() }
            do {
                _ = try await fixture.client.configuration()
                XCTFail("Invalid response must fail")
            } catch {
                guard case GenerationError.invalidResponse = error else {
                    XCTFail("Unexpected error: \(error)"); continue
                }
            }
        }
    }

    private var validConfiguration: [String: Any] {
        ["model": "gpt-image-2.5-sunburst", "width": 400, "height": 300,
         "palette": ["#000000", "#FFFFFF", "#FFFF00", "#FF0000"], "ready": true]
    }
}

/// Each session gets a distinct host and fixture, keeping parallel tests isolated.
private final class HTTPFixture {
    struct RecordedRequest { let request: URLRequest; let body: Data }
    let host = "test-\(UUID().uuidString.lowercased()).example.invalid"
    let status: Int
    let data: Data
    private let lock = NSLock()
    private var recorded: [RecordedRequest] = []
    private(set) var client: GenerationClient!

    var requests: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    convenience init(token: String, status: Int, json: [String: Any]) throws {
        try self.init(token: token, status: status, data: JSONSerialization.data(withJSONObject: json))
    }

    init(token: String, status: Int, data: Data) throws {
        self.status = status
        self.data = data
        let settings = try ConnectionSettings(endpoint: "https://\(host)", token: token)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        client = GenerationClient(settings: settings, session: URLSession(configuration: configuration))
        FixtureURLProtocol.register(self)
    }

    func close() {
        client.session.invalidateAndCancel()
        FixtureURLProtocol.remove(host: host)
    }

    func record(_ request: URLRequest) {
        var body = request.httpBody ?? Data()
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        lock.lock(); defer { lock.unlock() }
        recorded.append(RecordedRequest(request: request, body: body))
    }
}

private final class FixtureURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var fixtures: [String: HTTPFixture] = [:]

    static func register(_ fixture: HTTPFixture) {
        lock.lock(); defer { lock.unlock() }
        fixtures[fixture.host] = fixture
    }
    static func remove(host: String) {
        lock.lock(); defer { lock.unlock() }
        fixtures.removeValue(forKey: host)
    }
    private static func fixture(for request: URLRequest) -> HTTPFixture? {
        lock.lock(); defer { lock.unlock() }
        return request.url?.host.flatMap { fixtures[$0] }
    }

    // Intercept every request in these dedicated sessions so a bad URL can
    // never escape the test and make a real network request.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.fixture(for: request), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Length": String(fixture.data.count)]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        fixture.record(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
