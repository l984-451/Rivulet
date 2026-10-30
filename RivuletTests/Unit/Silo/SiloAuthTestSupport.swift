// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import XCTest
@testable import Rivulet

/// An explicit request barrier, not a sleep or a poll. Tests decide exactly
/// whether a profile/PIN response arrives before or after cancellation.
actor SiloAuthRequestGate {
    nonisolated let entered = XCTestExpectation(description: "Silo transport reached response barrier")
    private var released = false
    private var response: CheckedContinuation<Void, Never>?

    func pause() async {
        entered.fulfill()
        if !released { await withCheckedContinuation { response = $0 } }
    }


    func release() {
        released = true
        response?.resume()
        response = nil
    }
}
actor SiloAuthTestServer {
    nonisolated struct Reply: Sendable {
        let status: Int
        let body: String
        let error: URLError.Code?
        let gate: SiloAuthRequestGate?
        init(status: Int = 200, body: String = "{}", error: URLError.Code? = nil, gate: SiloAuthRequestGate? = nil) {
            self.status = status; self.body = body; self.error = error; self.gate = gate
        }
    }

    private var routes: [String: [Reply]] = [:]
    private var received: [URLRequest] = []

    nonisolated var transport: SiloClient.Transport {
        { request in try await self.handle(request) }
    }

    func respond(_ method: String = "GET", _ path: String, _ replies: [Reply]) {
        routes[method + " " + path] = replies
    }

    func requests() -> [URLRequest] { received }

    private func handle(_ request: URLRequest) async throws -> (Data, URLResponse) {
        received.append(request)
        let key = (request.httpMethod ?? "GET") + " " + (request.url?.path ?? "")
        guard let reply = routes[key]?.first, let url = request.url else { throw URLError(.resourceUnavailable) }
        if routes[key]!.count > 1 { routes[key]!.removeFirst() }
        if let gate = reply.gate { await gate.pause() }
        if let error = reply.error { throw URLError(error) }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": reply.status >= 400 ? "application/problem+json" : "application/json"])!
        return (Data(reply.body.utf8), response)
    }

    func configureDiscovery(baseURL: URL, serverID: String = "silo-auth-test") {
        let root = baseURL.path == "/" ? "" : baseURL.path
        let info = """
        {"api_major":2,"server_version":"1.0-test","contract_digest":"test",
         "request_origin":"\(SiloClient.origin(baseURL)!)",
         "links":{"identity":"/api/v2/system/identity","capabilities":"/api/v2/capabilities","openapi":"/api/v2/openapi.json"}}
        """
        respond("GET", root + "/api/v2/system/info", [Reply(body: info)])
        respond("GET", root + "/api/v2/system/identity", [Reply(body: "{\"server_id\":\"\(serverID)\"}")])
        respond("GET", root + "/api/v2/theme/branding", [Reply(body: """
        {"server_name":"Harbor Cinema","login_subtitle":"Sign in with an existing account.","storage_available":false}
        """)])
    }

    func configureLogin(baseURL: URL, locked: Bool = false, loginGate: SiloAuthRequestGate? = nil) {
        configureDiscovery(baseURL: baseURL)
        let root = baseURL.path == "/" ? "" : baseURL.path
        respond("POST", root + "/api/v2/auth/login", [Reply(body: """
        {"access_token":"login-access","refresh_token":"login-refresh","expires_in":3600,
         "user":{"id":"account-a","username":"alice","password_change_required":false}}
        """, gate: loginGate)])
        respond("GET", root + "/api/v2/profiles", [Reply(body: """
        {"items":[{"id":"profile-a","name":"Alice","has_pin":\(locked)}]}
        """)])
        respond("GET", root + "/api/v2/home/capabilities", [Reply(body: """
        {"revision":"home-1","state":"available","allowed":true}
        """)])
        respond("POST", root + "/api/v2/auth/logout", [Reply(status: 204, body: "")])
    }

    nonisolated static func problem(status: Int, code: String, detail: String) -> String {
        """
        {"type":"https://siloserver.org/docs/api/v2/problems/\(code)","title":"Request refused",
         "status":\(status),"detail":"\(detail)","instance":"urn:silo:request:test"}
        """
    }
}

actor SiloAuthTokenRecorder {
    private var forced: [Bool] = []
    private var persisted: [SiloLoginCredentials] = []
    func token(_ force: Bool) -> String {
        forced.append(force)
        return force ? "refreshed-access" : "initial-access"
    }
    func calls() -> [Bool] { forced }
    func save(_ credentials: SiloLoginCredentials) { persisted.append(credentials) }
    func saves() -> [SiloLoginCredentials] { persisted }
}
