// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class NowPlayingGraceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func track(playing: Bool) -> SidebarNowPlaying {
        SidebarNowPlaying(title: "A", artist: "B", isPlaying: playing)
    }

    func test_playing_showsAndNeverExpires() {
        var grace = NowPlayingGrace()
        grace.update(track(playing: true), now: t0)
        XCTAssertNotNil(grace.shown(at: t0.addingTimeInterval(3_600)))
        XCTAssertNil(grace.expiry)
    }

    func test_pause_keepsThePillFor30Seconds() {
        var grace = NowPlayingGrace()
        grace.update(track(playing: true), now: t0)
        grace.update(track(playing: false), now: t0.addingTimeInterval(10))
        XCTAssertNotNil(grace.shown(at: t0.addingTimeInterval(39.9)))
        XCTAssertNil(grace.shown(at: t0.addingTimeInterval(40)))
        XCTAssertEqual(grace.expiry, t0.addingTimeInterval(40))
    }

    func test_resumeWithinTheWindow_cancelsTheExpiry() {
        var grace = NowPlayingGrace()
        grace.update(track(playing: false), now: t0)
        grace.update(track(playing: true), now: t0.addingTimeInterval(20))
        XCTAssertNil(grace.expiry)
        XCTAssertNotNil(grace.shown(at: t0.addingTimeInterval(500)))
    }

    func test_repeatedPausedUpdates_doNotRestartTheClock() {
        var grace = NowPlayingGrace()
        grace.update(track(playing: false), now: t0)
        grace.update(track(playing: false), now: t0.addingTimeInterval(25))
        XCTAssertNil(grace.shown(at: t0.addingTimeInterval(30)))
    }

    func test_noTrack_dropsImmediately() {
        var grace = NowPlayingGrace()
        grace.update(track(playing: false), now: t0)
        grace.update(nil, now: t0.addingTimeInterval(1))
        XCTAssertNil(grace.shown(at: t0.addingTimeInterval(1)))
        XCTAssertNil(grace.expiry)
    }
}
