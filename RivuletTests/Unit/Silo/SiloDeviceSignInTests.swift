// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class SiloDeviceSignInTests: XCTestCase {
    private let base = URL(string: "https://device-login.invalid/proxy/silo")!
    private let root = "/proxy/silo/api/v2"

    private func configured(_ server: SiloAuthTestServer, capability: String = "available") async {
        await server.configureDiscovery(baseURL: base)
        await server.respond("GET", root + "/auth/device/capability", [.init(body: "{\"state\":\"\(capability)\",\"cancel\":true}")])
        await server.respond("POST", root + "/auth/device/start", [.init(status: 201, body: """
        {"device_code":"private-code","user_code":"1234-5678","verification_uri":"https://device-login.invalid/activate",
         "verification_uri_complete":"https://device-login.invalid/activate?token=synthetic","expires_at":"2030-01-01T00:00:00Z",
         "expires_in":300,"interval":1,"device_name":"Test TV","device_platform":"tvos","client_purpose":"device_login","temporary":false}
        """)])
        await server.respond("POST", root + "/auth/device/cancel", [.init(body: "{\"status\":\"canceled\"}")])
        await server.respond("GET", root + "/profiles", [.init(body: "{\"items\":[{\"id\":\"profile-a\",\"name\":\"Alice\",\"has_pin\":false}]}")])
        await server.respond("POST", root + "/auth/logout", [.init(status: 204, body: "")])
    }

    func testApprovalStagesProfilesWithoutCommittingAccount() async throws {
        let existing = SiloSession.account
        let server = SiloAuthTestServer()
        await configured(server)
        defer { SiloSession.cancelPendingSignIn() }
        await server.respond("POST", root + "/auth/device/poll", [.init(body: """
        {"status":"approved","poll_after":1,"temporary":false,"profile_id":"","profile_token":"",
         "tokens":{"access_token":"synthetic-access","refresh_token":"synthetic-refresh","expires_in":3600,
         "user":{"id":"account-a","username":"alice","password_change_required":false}}}
        """)])
        let started = try await SiloSession.startDeviceSignIn(serverURL: base, transport: server.transport)
        let profiles = try await SiloSession.awaitDeviceSignIn(started)
        XCTAssertEqual(profiles.map(\.id), ["profile-a"])
        XCTAssertTrue(SiloSession.hasPendingSignIn)
        XCTAssertEqual(SiloSession.account, existing)
        let requests = await server.requests()
        XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/home/capabilities") == true })
    }

    func testUnsupportedCapabilityDoesNotRequestCode() async {
        let server = SiloAuthTestServer()
        await configured(server, capability: "disabled")
        defer { SiloSession.cancelPendingSignIn() }
        do {
            _ = try await SiloSession.startDeviceSignIn(serverURL: base, transport: server.transport)
            XCTFail("Disabled capability must not start device sign in")
        } catch SiloDeviceSignInError.unsupported {} catch { XCTFail("Unexpected error: \(error)") }
        let requests = await server.requests()
        XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/auth/device/start") == true })
    }

    func testDeniedAndExpiredCannotStageAccount() async throws {
        for state in ["denied", "expired"] {
            let server = SiloAuthTestServer()
            await configured(server)
            await server.respond("POST", root + "/auth/device/poll", [.init(body: "{\"status\":\"\(state)\",\"poll_after\":1}")])
            let started = try await SiloSession.startDeviceSignIn(serverURL: base, transport: server.transport)
            do { _ = try await SiloSession.awaitDeviceSignIn(started); XCTFail("Terminal state must fail") }
            catch SiloDeviceSignInError.denied where state == "denied" {}
            catch SiloDeviceSignInError.expired where state == "expired" {}
            catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertFalse(SiloSession.hasPendingSignIn)
            SiloSession.cancelPendingSignIn()
        }
    }

    func testLateApprovalAfterCancellationCannotStageAccount() async throws {
        let server = SiloAuthTestServer()
        await configured(server)
        let gate = SiloAuthRequestGate()
        await server.respond("POST", root + "/auth/device/poll", [.init(body: """
        {"status":"approved","poll_after":1,"temporary":false,
         "tokens":{"access_token":"synthetic-access","refresh_token":"synthetic-refresh","expires_in":3600,
         "user":{"id":"account-a","username":"alice","password_change_required":false}}}
        """, gate: gate)])
        let started = try await SiloSession.startDeviceSignIn(serverURL: base, transport: server.transport)
        let operation = Task { try await SiloSession.awaitDeviceSignIn(started) }
        await fulfillment(of: [gate.entered], timeout: 5)
        SiloSession.cancelPendingSignIn()
        await gate.release()
        do { _ = try await operation.value; XCTFail("Late approval must be discarded") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(SiloSession.hasPendingSignIn)
    }

    func testChangedServerIdentityRejectsApprovedTokens() async throws {
        let server = SiloAuthTestServer()
        await configured(server)
        await server.respond("GET", root + "/system/identity", [
            .init(body: "{\"server_id\":\"silo-auth-test\"}"),
            .init(body: "{\"server_id\":\"other-server\"}")
        ])
        await server.respond("POST", root + "/auth/device/poll", [.init(body: """
        {"status":"approved","poll_after":1,"temporary":false,
         "tokens":{"access_token":"synthetic-access","refresh_token":"synthetic-refresh","expires_in":3600,
         "user":{"id":"account-a","username":"alice","password_change_required":false}}}
        """)])
        defer { SiloSession.cancelPendingSignIn() }
        let started = try await SiloSession.startDeviceSignIn(serverURL: base, transport: server.transport)
        do { _ = try await SiloSession.awaitDeviceSignIn(started); XCTFail("Changed server must be rejected") }
        catch SiloSignInError.serverChanged {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(SiloSession.hasPendingSignIn)
    }
}
