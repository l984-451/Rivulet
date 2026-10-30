// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class SiloClientTests: XCTestCase {
    private nonisolated struct Item: Decodable, Sendable { let id: String }

    func test_absentArtworkOrMediaReferenceDoesNotBecomeServerRoot() {
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid/proxy/silo")!)
        for absent in ["", " ", "\n\t"] {
            XCTAssertNil(client.mediaURL(absent))
        }
        XCTAssertEqual(client.mediaURL("/api/v2/images/poster-a")?.absoluteString,
                       "https://silo.invalid/proxy/silo/api/v2/images/poster-a")
    }

    func test_mediaAuthorityIsNotSentToForeignOriginsOrOutsideProxyRoot() async throws {
        let recorder = SiloAuthTokenRecorder()
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid/proxy/silo")!,
                                profileID: "profile-a", profileToken: "pin-proof",
                                tokenSource: { await recorder.token($0) },
                                deviceHeaders: ["X-Silo-Device-Id": "installation-a"])
        let foreign = [
            "https://cdn.invalid/proxy/silo/api/v3/stream",
            "http://silo.invalid/proxy/silo/api/v3/stream",
            "https://silo.invalid:8443/proxy/silo/api/v3/stream",
            "https://silo.invalid/other/api/v3/stream",
            "https://silo.invalid/proxy/silo-neighbor/api/v3/stream"
        ]
        for address in foreign {
            let headers = try await client.mediaHeaders(for: URL(string: address)!, supplied: ["X-Stream-Grant": "grant-a"])
            XCTAssertEqual(headers, ["X-Stream-Grant": "grant-a"], address)
        }
        let calls = await recorder.calls()
        XCTAssertTrue(calls.isEmpty, "foreign media must not even obtain login credentials")
        let owned = try await client.mediaHeaders(
            for: URL(string: "https://silo.invalid/proxy/silo/api/v3/stream")!,
            supplied: ["authorization": "Bearer stale-access", "X-Profile-Id": "another-profile",
                       "X-Profile-Token": "another-proof"]
        )
        XCTAssertEqual(owned["Authorization"], "Bearer initial-access")
        XCTAssertEqual(owned["X-Profile-Id"], "profile-a")
        XCTAssertEqual(owned["X-Profile-Token"], "pin-proof")
        XCTAssertEqual(owned["X-Silo-Device-Id"], "installation-a")
        XCTAssertNil(owned["authorization"], "case variants must not preserve a second, stale account credential")
    }

    func test_rejectedReadRefreshesOnceAndKeepsCapturedProfile() async throws {
        let server = SiloAuthTestServer()
        let recorder = SiloAuthTokenRecorder()
        let path = "/proxy/silo/api/v2/catalog/items/movie-a"
        await server.respond("GET", path, [
            .init(status: 401, body: SiloAuthTestServer.problem(status: 401, code: "unauthorized", detail: "Session expired.")),
            .init(body: #"{"id":"movie-a"}"#)
        ])
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid/proxy/silo")!,
                                profileID: "profile-a", profileToken: "proof-a", transport: server.transport,
                                tokenSource: { await recorder.token($0) })
        let item: Item = try await client.get("catalog/items/movie-a")
        XCTAssertEqual(item.id, "movie-a")
        let requests = await server.requests()
        let calls = await recorder.calls()
        XCTAssertEqual(calls, [false, true])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer initial-access", "Bearer refreshed-access"])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "X-Profile-Id") }, ["profile-a", "profile-a"])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "X-Profile-Token") }, ["proof-a", "proof-a"])
    }

    func test_pinWriteIsNeverReplayedAfter401OrUncertainTransportOutcome() async {
        for uncertain in [false, true] {
            let server = SiloAuthTestServer()
            let recorder = SiloAuthTokenRecorder()
            await server.respond("POST", "/api/v2/profiles/profile-a/verify-pin", [
                .init(status: 401,
                      body: SiloAuthTestServer.problem(status: 401, code: "unauthorized", detail: "Session ended."),
                      error: uncertain ? .networkConnectionLost : nil)
            ])
            let client = SiloClient(baseURL: URL(string: "https://silo.invalid")!, transport: server.transport,
                                    tokenSource: { await recorder.token($0) })
            do {
                let _: SiloProfileVerification = try await client.post("profiles/profile-a/verify-pin", body: SiloPINBody(pin: "1234"))
                XCTFail("A rejected or uncertain PIN write must fail.")
            } catch {
                if uncertain {
                    guard case MediaProviderError.unreachable = error else { XCTFail("Unexpected error: \(error)"); continue }
                } else {
                    XCTAssertEqual((error as? SiloAPIError)?.status, 401)
                }
            }
            let requests = await server.requests()
            let calls = await recorder.calls()
            XCTAssertEqual(requests.count, 1, "a repeated PIN check spends another server attempt")
            XCTAssertEqual(calls, [false], "writes must not refresh and replay on 401")
        }
    }


    func test_nativeProblemDetailsRemainAvailableForActionableUI() async {
        let server = SiloAuthTestServer()
        let problem = #"{"type":"https://siloserver.org/docs/api/v2/problems/validation_failed","title":"Validation failed","status":422,"detail":"Correct the fields below.","instance":"urn:silo:request:test","errors":[{"location":"body.username","code":"required","detail":"Enter a username."}]}"#
        await server.respond("POST", "/api/v2/auth/login", [.init(status: 422, body: problem)])
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid")!, transport: server.transport)
        do {
            let _: SiloTokenPair = try await client.post("auth/login", body: SiloLoginBody(username: "", password: "password"))
            XCTFail("Expected native validation failure")
        } catch let error as SiloAPIError {
            XCTAssertEqual(error.code, "validation_failed")
            XCTAssertTrue(error.errorDescription?.contains("Enter a username.") == true)
            XCTAssertEqual(error.errors?.first?.location, "body.username")
        } catch { XCTFail("Unexpected error: \(error)") }
    }
}
