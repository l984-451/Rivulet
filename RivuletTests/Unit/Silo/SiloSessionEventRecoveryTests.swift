// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class SiloSessionEventRecoveryTests: XCTestCase {
    private func problem(_ status: Int, _ code: String) -> SiloAPIError {
        SiloAPIError(type: "https://siloserver.org/docs/api/v2/problems/\(code)", title: "Synthetic",
                     status: status, detail: "Synthetic", errors: nil)
    }

    func testProgress404SuspendsWritesButRetainsPlayedSessionForRenewal() async throws {
        let responseBody = Data("""
        {"type":"https://siloserver.org/docs/api/v2/problems/session_not_found",\
        "title":"Missing","status":404,"detail":"Synthetic"}
        """.utf8)
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid")!, profileID: "profile-a",
                                transport: { request in
            (responseBody, HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/problem+json"])!)
        })
        let provider = SiloProvider(serverID: "server-a", displayName: "Synthetic", profileID: "profile-a", client: client)
        let relay = try await SiloMediaRelay.start(client: client)
        defer { relay.stop() }
        let lifetime = SiloPlaybackLifetime()
        let context = SiloReportContext(installationID: "installation-a", sessionID: "session-a", lifetime: lifetime, relay: relay)
        let reporter = SiloProgressReporter(client: client, provider: provider,
                                            ref: MediaItemRef(providerID: provider.id, itemID: "movie-a"), context: context)
        _ = lifetime.attach(reporter)
        let events = lifetime.events.stream()
        await reporter.start(position: 725)
        XCTAssertTrue(lifetime.isActive)
        XCTAssertTrue(lifetime.isSuspended)
        let hasPlayed = await reporter.hasPlayed
        XCTAssertTrue(hasPlayed)
        var iterator = events.makeAsyncIterator()
        guard case .some(.renewalRequired(let fault)) = await iterator.next() else { return XCTFail("Expected renewable fault") }
        XCTAssertEqual(fault.status, 404)
        lifetime.deactivate()
    }

    func testInstallationChangeReplaysOnePendingEventAndStopsAtRetirement() async {
        let lifetime = SiloPlaybackLifetime()
        lifetime.receive(problem(409, "installation_changed"))
        lifetime.receive(problem(409, "installation_changed"))
        XCTAssertTrue(lifetime.isActive)
        XCTAssertTrue(lifetime.isSuspended)
        var iterator = lifetime.events.stream().makeAsyncIterator()
        guard case .some(.renewalRequired(let fault)) = await iterator.next() else { return XCTFail("Expected installation fault") }
        XCTAssertEqual(fault.code, "installation_changed")
        lifetime.deactivate()
        let finished = await iterator.next()
        XCTAssertNil(finished)
    }

    func testAdminEndSupersedesPendingRenewalAndBlocksFreshAttempt() async {
        let lifetime = SiloPlaybackLifetime()
        lifetime.receive(problem(404, "session_not_found"))
        lifetime.receive(problem(410, "playback_session_ended"))
        XCTAssertTrue(lifetime.isEnded)
        XCTAssertFalse(SiloPlaybackSessionRenewal.permitsFreshAttempt(after: problem(410, "playback_session_ended")))
        var iterator = lifetime.events.stream().makeAsyncIterator()
        guard case .some(.ended) = await iterator.next() else { return XCTFail("Expected terminal event") }
        lifetime.deactivate()
        let finished = await iterator.next()
        XCTAssertNil(finished)
    }

    func testForeignAndUnrelatedMediaErrorsDoNotBecomeSessionFaults() {
        XCTAssertNil(SiloPlaybackSessionFault.classifyMedia(problem(404, "not_found")))
        XCTAssertNil(SiloPlaybackSessionFault.classifyMedia(problem(404, "session_not_found")))
        XCTAssertNil(SiloPlaybackSessionFault.classifyMedia(problem(401, "session_expired")))
        XCTAssertNil(SiloPlaybackSessionFault.classifyMedia(problem(409, "progress_conflict")))
        XCTAssertNotNil(SiloPlaybackSessionFault.classifyMedia(problem(404, "playback_session_not_found")))
    }
}
