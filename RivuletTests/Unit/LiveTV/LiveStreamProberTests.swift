// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveStreamProberTests.swift
//  RivuletTests
//
//  The List's quality reader: a stopped loop finishing late must not forget a
//  newer one, or a later probe would run two loops (two open streams) at once.
//

import XCTest
@testable import Rivulet

@MainActor
final class LiveStreamProberTests: XCTestCase {
    private actor Gate {
        var opened = 0
        var waiting: [CheckedContinuation<Void, Never>] = []
        func enter() async {
            opened += 1
            await withCheckedContinuation { waiting.append($0) }
        }
        func release() { waiting.forEach { $0.resume() }; waiting = [] }
    }

    func test_aStoppedLoopFinishingLate_keepsTheNewerOne() async throws {
        let suite = "LiveStreamProberTests"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = LiveStreamQualityStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let gate = Gate()
        let prober = LiveStreamProber(store: store) { _, _ in
            await gate.enter()
            return nil
        }
        func channel(_ id: String) -> UnifiedChannel {
            UnifiedChannel(id: id, sourceType: .xtream, sourceId: "x", name: id, streamURL: URL(string: "http://h/\(id).ts"))
        }
        prober.probe([channel("a")], while: { true })
        try await Task.sleep(for: .milliseconds(100))
        prober.stop()
        prober.probe([channel("b")], while: { true })
        XCTAssertTrue(prober.isRunning)
        // Loop A's fetch returns now, after B started.
        await gate.release()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(prober.isRunning, "the late loop forgot the newer one")
        prober.stop()
        await gate.release()
    }
}
