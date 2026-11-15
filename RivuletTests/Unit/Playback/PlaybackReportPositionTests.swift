// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Testing
@testable import Rivulet

struct PlaybackReportPositionTests {
    @Test(arguments: [0.0, 120.0])
    func newItemRejectsTheOutgoingClockBeforeItsLoadStarts(_ startTime: Double) {
        var position = PlaybackReportPosition(startTime: startTime)
        #expect(position.resolve(2536.401, isLoading: false, isStarting: false, hasStarted: false) == startTime)
        #expect(position.resolve(0, isLoading: true, isStarting: true, hasStarted: false) == startTime)
        #expect(position.resolve(startTime + 10, isLoading: false, isStarting: false, hasStarted: true) == startTime + 10)
    }

    @Test(arguments: [(true, false), (false, true), (true, true)])
    func stopDuringReloadRetainsProgress(_ loading: Bool, _ starting: Bool) {
        var position = PlaybackReportPosition()
        #expect(position.resolve(42, isLoading: false, isStarting: false) == 42)
        #expect(position.resolve(0, isLoading: loading, isStarting: starting) == 42)
        #expect(position.resolve(0, isLoading: loading, isStarting: starting) == 42)
        #expect(position.resolve(48, isLoading: false, isStarting: false) == 48)
        #expect(position.resolve(0, isLoading: false, isStarting: false) == 0)
    }

    @Test func newItemDoesNotInheritTheOutgoingResumePoint() {
        var position = PlaybackReportPosition()
        #expect(position.resolve(95, isLoading: false, isStarting: false) == 95)
        position = PlaybackReportPosition()
        #expect(position.resolve(0, isLoading: true, isStarting: true) == 0)
        #expect(position.resolve(100, isLoading: false, isStarting: false) == 100)
    }
}
