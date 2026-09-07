import Foundation

#if canImport(SlackStatusSyncCore)
import SlackStatusSyncCore
#elseif canImport(SlackStatusSync)
@testable import SlackStatusSync
#endif

#if canImport(XCTest)
import XCTest
#endif

final class SlackClientTests: XCTestCase {
    func testTokenFormat() {
        XCTAssertTrue(SlackClient.validateTokenFormat("xoxp-1234567890"))
        XCTAssertFalse(SlackClient.validateTokenFormat("xoxb-bot"))
        XCTAssertFalse(SlackClient.validateTokenFormat("short"))
    }

    func testParseScopesHeader() {
        let url = URL(string: "https://slack.com/api/auth.test")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["X-OAuth-Scopes": "users.profile:read, users.profile:write, dnd:read, dnd:write"]
        )!
        let scopes = SlackClient.parseScopes(from: response)
        XCTAssertEqual(scopes, SlackRequiredScopes.all)
    }

    func testURLProtocolAuthAndMissingScopes() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer xoxp-valid-token")
            XCTAssertNil(request.url?.query)
            let body = #"{"ok":true,"user_id":"U1","team":"T1"}"#.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/json",
                    "X-OAuth-Scopes": "users.profile:read,users.profile:write",
                ]
            )!
            return (response, body)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = SlackClient(session: URLSession(configuration: config))
        do {
            _ = try await client.verifyToken("xoxp-valid-token")
            XCTFail("expected missing scopes")
        } catch let error as SlackClientError {
            guard case .missingScopes(let missing) = error else {
                return XCTFail("wrong error \(error)")
            }
            XCTAssertTrue(missing.contains("dnd:read"))
            XCTAssertTrue(missing.contains("dnd:write"))
        }
    }

    func testSetStatusEncodingAndProfileGet() async throws {
        MockURLProtocol.requestHandler = { request in
            let path = request.url!.lastPathComponent
            if path == "users.profile.set" {
                let bodyString = MockURLProtocol.bodyString(of: request)
                XCTAssertTrue(bodyString.contains("profile"), bodyString)
                XCTAssertFalse((request.url?.absoluteString ?? "").contains("xoxp-"))
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer "), true)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, #"{"ok":true}"#.data(using: .utf8)!)
            }
            if path == "users.profile.get" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, #"{"ok":true,"profile":{"status_text":"Focusing","status_emoji":":dart:","status_expiration":1700000000}}"#.data(using: .utf8)!)
            }
            if path == "dnd.info" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, #"{"ok":true,"snooze_enabled":true,"snooze_endtime":1700000060}"#.data(using: .utf8)!)
            }
            if path == "dnd.setSnooze" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, #"{"ok":true,"snooze_endtime":1700000060}"#.data(using: .utf8)!)
            }
            XCTFail("unexpected \(path)")
            throw URLError(.badURL)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = SlackClient(session: URLSession(configuration: config))
        try await client.setStatus(token: "xoxp-valid-token", text: "Focusing", emoji: ":dart:", expiration: Date(timeIntervalSince1970: 1_700_000_000))
        let profile = try await client.getProfile(token: "xoxp-valid-token")
        XCTAssertEqual(profile.statusText, "Focusing")
        let dnd = try await client.getDND(token: "xoxp-valid-token")
        XCTAssertTrue(dnd.snoozeEnabled)
        _ = try await client.setSnooze(token: "xoxp-valid-token", numMinutes: 10)
    }

    func testRateLimitAndAuthErrors() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "2"]
            )!
            return (response, Data())
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = SlackClient(session: URLSession(configuration: config))
        do {
            _ = try await client.authTest(token: "xoxp-valid-token")
            XCTFail("expected rate limit")
        } catch let error as SlackClientError {
            XCTAssertTrue(error.isRetryable)
            XCTAssertEqual(error.redactedDescription, "rate_limited")
        }

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, #"{"ok":false,"error":"invalid_auth"}"#.data(using: .utf8)!)
        }
        do {
            _ = try await client.authTest(token: "xoxp-valid-token")
            XCTFail("expected auth error")
        } catch let error as SlackClientError {
            XCTAssertFalse(error.isRetryable)
            guard case .permanentAuth = error else { return XCTFail("\(error)") }
        }
    }
}

final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func bodyString(of request: URLRequest) -> String {
        if let body = request.httpBody, let s = String(data: body, encoding: .utf8) {
            return s
        }
        guard let stream = request.httpBodyStream else { return "" }
        var data = Data()
        stream.open()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 1024)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
