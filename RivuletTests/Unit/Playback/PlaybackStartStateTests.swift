// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Testing
@testable import Rivulet

@MainActor
struct PlaybackStartStateTests {
    @Test func reloadPreservesItemHistoryButReopensStartupFallback() {
        var state = PlaybackStartState()
        state.beginLoad(startsItem: true)
        state.didPlay()
        state.beginLoad(startsItem: false)
        #expect(state.itemHasPlayed)
        #expect(state.streamHasPlayed == false)
        state.didPlay()
        #expect(state.streamHasPlayed)
        state.beginLoad(startsItem: true)
        #expect(state.itemHasPlayed == false)
        #expect(state.streamHasPlayed == false)
    }

    @Test func pausedReloadHeartbeatUsesCurrentStartupAndSeekState() {
        var state = PlaybackStartState()
        #expect(state.heartbeatState(isPaused: true, isLoading: false, isStarting: true,
                                     isSeeking: true, isStalled: false) == nil)
        state.didPlay()
        state.beginLoad(startsItem: false)
        #expect(state.heartbeatState(isPaused: true, isLoading: false, isStarting: true,
                                     isSeeking: true, isStalled: false) == "buffering")
        #expect(state.heartbeatState(isPaused: true, isLoading: false, isStarting: false,
                                     isSeeking: true, isStalled: false) == "buffering")
        #expect(state.heartbeatState(isPaused: true, isLoading: false, isStarting: false,
                                     isSeeking: false, isStalled: false) == "paused")
        #expect(state.heartbeatState(isPaused: false, isLoading: false, isStarting: false,
                                     isSeeking: false, isStalled: true) == "buffering")
        #expect(state.heartbeatState(isPaused: false, isLoading: false, isStarting: false,
                                     isSeeking: false, isStalled: false) == nil)
    }

    @Test func onlyAnExplicitSeekRequestsAnAdditionalPlayingReport() {
        var state = PlaybackStartState()
        state.beginLoad(startsItem: true)
        #expect(state.seekCompleted(isSeeking: true, isStarting: true) == false)
        state.didPlay()
        #expect(state.seekCompleted(isSeeking: true, isStarting: false) == false)
        #expect(state.seekCompleted(isSeeking: false, isStarting: false) == false)
        #expect(state.seekCompleted(isSeeking: true, isStarting: false) == false)
        #expect(state.seekCompleted(isSeeking: false, isStarting: false) == true)
        #expect(state.seekCompleted(isSeeking: false, isStarting: false) == false)
        #expect(state.seekCompleted(isSeeking: true, isStarting: false) == false)
        state.beginLoad(startsItem: false)
        #expect(state.seekCompleted(isSeeking: false, isStarting: false) == false)
    }

}
