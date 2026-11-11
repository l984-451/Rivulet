// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AVFoundation
import Combine

enum PlaybackTransportState {
    enum State: Equatable {
        case idle, loading, playing, paused, seeking, ended
        case error(String)
    }
    enum Phase { case loading, playing, paused, rebuffering }

    static func publisher(state: AnyPublisher<State, Never>,
                          phase: AnyPublisher<Phase, Never>,
                          nativeReady: AnyPublisher<Bool, Never> = Just(true).eraseToAnyPublisher()) -> AnyPublisher<State, Never> {
        state.combineLatest(phase, nativeReady)
            // Engine state records play intent before the incoming transport has rolled.
            .scan((state: State.idle, hasStarted: false)) { previous, input in
                let (state, phase, nativeReady) = input
                guard state == .playing else {
                    switch state {
                    case .idle, .loading, .ended, .error: return (state, false)
                    default: return (state, previous.hasStarted)
                    }
                }
                if phase == .paused { return (.paused, previous.hasStarted) }
                if previous.hasStarted { return (.playing, true) }
                guard nativeReady, phase == .playing || phase == .rebuffering else { return (.loading, false) }
                return (.playing, true)
            }
            .map(\.state)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    static func nativeReadiness(_ players: AnyPublisher<AVPlayer?, Never>) -> AnyPublisher<Bool, Never> {
        players.map { player -> AnyPublisher<Bool, Never> in
            guard let player else { return Just(true).eraseToAnyPublisher() }
            return player.publisher(for: \.currentItem)
                .map { item -> AnyPublisher<Bool, Never> in
                    guard let item else { return Just(false).eraseToAnyPublisher() }
                    return item.publisher(for: \.status)
                        .combineLatest(player.publisher(for: \.timeControlStatus))
                        .map { status, transport in status == .readyToPlay && transport == .playing }
                        .eraseToAnyPublisher()
                }
                .switchToLatest()
                .eraseToAnyPublisher()
        }
        .switchToLatest()
        .removeDuplicates()
        .eraseToAnyPublisher()
    }
}
