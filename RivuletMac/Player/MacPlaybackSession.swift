// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Combine

/// What `MacPlaybackController` needs of a session: a title (`MacPlexPlayback`) or a channel
/// (`MacLivePlayback`).
@MainActor
protocol MacPlaybackSession: AnyObject {
    var player: AetherPlayer { get }
    var nowPlayingItem: MacNowPlaying.Item { get }
    var onItemChange: (() -> Void)? { get set }
    var changes: AnyPublisher<Void, Never> { get }
    var audioTracks: [AetherPlayer.Track] { get }
    var subtitleTracks: [AetherPlayer.Track] { get }
    var selectedAudioID: Int? { get }
    var selectedSubtitleID: Int? { get }
    func selectAudio(_ id: Int)
    func selectSubtitle(_ id: Int?)
    func begin() async
    func end()
}

extension MacPlexPlayback: MacPlaybackSession {
    var changes: AnyPublisher<Void, Never> { objectWillChange.map { _ in () }.eraseToAnyPublisher() }
}
