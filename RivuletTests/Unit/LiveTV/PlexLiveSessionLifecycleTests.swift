// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexLiveSessionLifecycleTests.swift
//  RivuletTests
//
//  Releasing a Plex Live TV session: "stopped" must be the last timeline the
//  server sees, or a late "playing" renews the grab, and a start.m3u8 session's
//  transcode job is stopped after it. Automatic retunes are bounded, because
//  each one grabs a tuner again.
//

import XCTest
@testable import Rivulet

@MainActor
final class PlexLiveSessionLifecycleTests: XCTestCase {

    /// Records what reached the server. The first request is held until the
    /// test releases it, standing in for a slow PMS answer.
    @MainActor
    private final class Server {
        var sent: [String] = []
        var held: CheckedContinuation<Void, Never>?

        func receive(_ request: URLRequest) async {
            let url = request.url!
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "state" })?.value
            let session = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "session" })?.value
            sent.append(state ?? "\(url.path)?session=\(session ?? "")")
            if sent.count == 1 { await withCheckedContinuation { held = $0 } }
        }
    }

    private let transcodeURL = URL(string: "http://pms.local:32400/video/:/transcode/universal/start.m3u8"
        + "?path=/livetv/sessions/abc&session=TX1&X-Plex-Session-Identifier=SID&X-Plex-Token=t")!
    private let directURL = URL(string: "http://pms.local:32400/livetv/sessions/abc/consumer/index.m3u8"
        + "?offset=0&X-Plex-Session-Identifier=SID&X-Plex-Token=t")!

    private func settle(_ server: Server, count: Int) async throws {
        for _ in 0..<200 where server.sent.count < count { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))  // room for anything that should not come
    }

    func test_stopWaitsOutASlowPing_dropsQueuedPings_thenStopsTheTranscode() async throws {
        let server = Server()
        let keepalive = PlexLiveTimelineKeepalive(transport: server.receive)
        keepalive.start(url: transcodeURL)
        keepalive.ping()  // in flight, PMS slow to answer
        keepalive.ping()  // queued behind it
        try await settle(server, count: 1)

        keepalive.stop()
        XCTAssertNil(keepalive.ping(), "no ping may start after stop")
        XCTAssertEqual(server.sent, ["playing"], "stopped must wait for the ping in flight")

        server.held?.resume()
        try await settle(server, count: 3)
        XCTAssertEqual(server.sent, [
            "playing",
            "stopped",
            "\(PlexLiveTimelineKeepalive.transcodeStopPath)?session=TX1",
        ])
    }

    /// A direct-play grant plays the tuner's own playlist: no transcoder job
    /// exists, so only the timeline is released.
    func test_directPlaySession_releasesTheTimelineOnly() async throws {
        let server = Server()
        let keepalive = PlexLiveTimelineKeepalive(transport: server.receive)
        keepalive.start(url: directURL)
        keepalive.stop()
        try await settle(server, count: 1)
        server.held?.resume()
        try await settle(server, count: 2)
        XCTAssertEqual(server.sent, ["stopped"])
    }

    func test_retuneBudget_spacesRetunesAndRunsOut() {
        var budget = LiveRetuneBudget()
        XCTAssertEqual(budget.reserve(now: 100), 0, "the first retune starts at once")
        XCTAssertEqual(budget.reserve(now: 105), 15, "the next waits out the spacing")
        XCTAssertEqual(budget.reserve(now: 500), 0)
        XCTAssertNil(budget.reserve(now: 10_000), "spent for this viewing; time does not refill it")
    }
}
