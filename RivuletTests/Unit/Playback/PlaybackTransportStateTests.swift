// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import Testing
@testable import Rivulet

@MainActor
struct PlaybackTransportStateTests {
    @Test func rebufferingPreservesPlayIntentButReplacementMustStartAgain() {
        let state = CurrentValueSubject<PlaybackTransportState.State, Never>(.playing)
        let phase = CurrentValueSubject<PlaybackTransportState.Phase, Never>(.playing)
        let ready = CurrentValueSubject<Bool, Never>(true)
        var reports: [PlaybackTransportState.State] = []
        let subscription = PlaybackTransportState.publisher(state: state.eraseToAnyPublisher(),
                                                             phase: phase.eraseToAnyPublisher(),
                                                             nativeReady: ready.eraseToAnyPublisher())
            .sink { reports.append($0) }
        defer { subscription.cancel() }

        ready.send(false)
        phase.send(.rebuffering)
        #expect(reports == [.playing])
        state.send(.paused)
        phase.send(.paused)
        #expect(reports == [.playing, .paused])

        state.send(.loading)
        phase.send(.loading)
        state.send(.playing)
        phase.send(.playing)
        #expect(reports == [.playing, .paused, .loading])
        ready.send(true)
        #expect(reports == [.playing, .paused, .loading, .playing])
    }

    @Test func nativeHandoffRejectsPlayingUntilTheIncomingItemIsReady() {
        let state = CurrentValueSubject<PlaybackTransportState.State, Never>(.loading)
        let phase = CurrentValueSubject<PlaybackTransportState.Phase, Never>(.loading)
        let ready = CurrentValueSubject<Bool, Never>(false)
        var reports: [PlaybackTransportState.State] = []
        let subscription = PlaybackTransportState.publisher(state: state.eraseToAnyPublisher(),
                                                             phase: phase.eraseToAnyPublisher(),
                                                             nativeReady: ready.eraseToAnyPublisher())
            .sink { reports.append($0) }
        defer { subscription.cancel() }
        state.send(.playing)
        phase.send(.playing)
        #expect(reports == [.loading])
        ready.send(true)
        #expect(reports == [.loading, .playing])
    }

    @Test func incomingItemWaitsForTransportInsteadOfPlayIntent() {
        let state = CurrentValueSubject<PlaybackTransportState.State, Never>(.playing)
        let phase = CurrentValueSubject<PlaybackTransportState.Phase, Never>(.playing)
        var reports: [PlaybackTransportState.State] = []
        let subscription = PlaybackTransportState.publisher(state: state.eraseToAnyPublisher(),
                                                             phase: phase.eraseToAnyPublisher())
            .sink { reports.append($0) }
        defer { subscription.cancel() }

        state.send(.loading)
        phase.send(.loading)
        state.send(.playing)
        #expect(reports == [.playing, .loading])

        phase.send(.playing)
        #expect(reports == [.playing, .loading, .playing])
    }

    @Test func pausedMountResumeAndRebufferDoNotInventExtraStarts() {
        let state = CurrentValueSubject<PlaybackTransportState.State, Never>(.loading)
        let phase = CurrentValueSubject<PlaybackTransportState.Phase, Never>(.loading)
        var reports: [PlaybackTransportState.State] = []
        let subscription = PlaybackTransportState.publisher(state: state.eraseToAnyPublisher(),
                                                             phase: phase.eraseToAnyPublisher())
            .sink { reports.append($0) }
        defer { subscription.cancel() }

        state.send(.paused)
        phase.send(.paused)
        state.send(.playing)
        phase.send(.loading)
        phase.send(.playing)
        phase.send(.rebuffering)
        phase.send(.playing)
        state.send(.paused)
        phase.send(.paused)
        state.send(.ended)
        #expect(reports == [.loading, .paused, .loading, .playing, .paused, .ended])
    }
}
