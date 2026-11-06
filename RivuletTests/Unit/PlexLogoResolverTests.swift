// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexLogoResolverTests.swift
//  RivuletTests
//
//  A miss is remembered only when Plex answered and the title has no clear logo.
//  A failed or cancelled fetch is asked again, and a fetch that outlives `reset()` writes nothing.
//

import XCTest
@testable import Rivulet

@MainActor
final class PlexLogoResolverTests: XCTestCase {

    /// Opens once; `wait()` suspends until then.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            await withCheckedContinuation { continuation in
                let resume = lock.withLock { () -> Bool in
                    if !isOpen { waiters.append(continuation) }
                    return isOpen
                }
                if resume { continuation.resume() }
            }
        }
        func open() {
            let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                isOpen = true
                defer { waiters = [] }
                return waiters
            }
            pending.forEach { $0.resume() }
        }
    }

    private final class StubNetwork: PlexNetworkManager, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.withLock { _calls } }
        var failures = 0
        var gate: Gate?
        var reply = PlexMetadata()
        /// A real request throws when its task is cancelled; the default stub finishes anyway.
        var honorsCancellation = false

        override func getMetadata(serverURL: String, authToken: String, ratingKey: String,
                                  includeGuids: Bool) async throws -> PlexMetadata {
            let shouldFail = lock.withLock { () -> Bool in
                _calls += 1
                defer { if failures > 0 { failures -= 1 } }
                return failures > 0
            }
            await gate?.wait()
            if honorsCancellation { try Task.checkCancellation() }
            if shouldFail { throw PlexAPIError.invalidURL }
            return reply
        }
    }

    private func withLogo() -> PlexMetadata {
        var m = PlexMetadata()
        m.Image = [PlexImage(alt: nil, type: "clearLogo", url: "/l/1")]
        return m
    }

    private func ask(_ resolver: PlexLogoResolver, _ network: StubNetwork) async -> URL? {
        await resolver.logo(serverURL: "http://plex.test", token: "t", network: network, sourceKey: "show", direct: nil)
    }

    private func waitForCall(_ network: StubNetwork) async {
        while network.calls == 0 { await Task.yield() }
    }

    func test_aFailedFetchIsAskedAgain() async {
        let network = StubNetwork()
        network.failures = 1
        network.reply = withLogo()
        let resolver = PlexLogoResolver()
        let first = await ask(resolver, network)
        let second = await ask(resolver, network)
        XCTAssertNil(first)
        XCTAssertEqual(second?.absoluteString, "http://plex.test/l/1?X-Plex-Token=t")
        XCTAssertEqual(network.calls, 2)
    }

    func test_aTitleWithNoLogoIsAMissRememberedOnce() async {
        let network = StubNetwork()
        let resolver = PlexLogoResolver()
        let first = await ask(resolver, network)
        let second = await ask(resolver, network)
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(network.calls, 1)
    }

    /// `reset()` cancels what is running; the cancelled fetch throws and must not leave a miss behind.
    func test_aFetchCancelledByResetIsNotAMiss() async {
        let network = StubNetwork()
        let gate = Gate()
        network.gate = gate
        network.honorsCancellation = true
        network.reply = withLogo()
        let resolver = PlexLogoResolver()
        let pending = Task { await ask(resolver, network) }
        await waitForCall(network)
        resolver.reset()
        gate.open()
        let cancelled = await pending.value
        XCTAssertNil(cancelled)
        network.gate = nil
        let again = await ask(resolver, network)
        XCTAssertNotNil(again, "a cancelled fetch must not have recorded a miss")
    }

    func test_aFetchThatOutlivesResetWritesNothing() async {
        let network = StubNetwork()
        let gate = Gate()
        network.gate = gate
        network.reply = withLogo()
        let resolver = PlexLogoResolver()
        let pending = Task { await ask(resolver, network) }
        await waitForCall(network)
        resolver.reset()
        gate.open()
        let answer = await pending.value
        XCTAssertNotNil(answer, "the caller still gets what it asked for")
        XCTAssertNil(resolver.cached(serverURL: "http://plex.test", sourceKey: "show"), "but the new state stays empty")
    }

    func test_aMissThatOutlivesResetIsNotRemembered() async {
        let network = StubNetwork()
        let gate = Gate()
        network.gate = gate
        let resolver = PlexLogoResolver()
        let pending = Task { await ask(resolver, network) }
        await waitForCall(network)
        resolver.reset()
        gate.open()
        _ = await pending.value
        network.gate = nil
        network.reply = withLogo()
        let again = await ask(resolver, network)
        XCTAssertNotNil(again, "the old fetch's miss belongs to the old state")
    }
}
