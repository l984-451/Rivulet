// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SidebarNowPlayingFeed.swift
//  Rivulet
//
//  What the sidebar's Now Playing pill shows, and for how long.
//

import Combine
import Foundation

/// A pause or stop keeps the pill for `window`; no track at all drops it at once.
struct NowPlayingGrace {
    static let window: TimeInterval = 30

    private var held: SidebarNowPlaying?
    private var idleSince: Date?

    mutating func update(_ track: SidebarNowPlaying?, now: Date) {
        held = track
        guard let track, !track.isPlaying else { idleSince = nil; return }
        idleSince = idleSince ?? now
    }

    /// The track to show at `now`, nil once the grace has run out.
    func shown(at now: Date) -> SidebarNowPlaying? {
        guard let held else { return nil }
        guard let idleSince, now.timeIntervalSince(idleSince) >= Self.window else { return held }
        return nil
    }

    /// When a shown track will be dropped; nil while it plays or nothing shows.
    var expiry: Date? { held == nil ? nil : idleSince?.addingTimeInterval(Self.window) }
}

/// Publishes the pill's track from `MusicQueue`, applying the grace.
@MainActor
final class SidebarNowPlayingFeed: ObservableObject {
    @Published private(set) var track: SidebarNowPlaying?

    private var grace = NowPlayingGrace()
    private var expiryTask: Task<Void, Never>?
    private var subscription: AnyCancellable?

    init(queue: MusicQueue = .shared) {
        // Track and state only: the queue's clock publishes several times a second.
        subscription = queue.$currentTrack.combineLatest(queue.$playbackState)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] current, state in
                // A track change passes through .loading; that is not a pause.
                let playing = state == .playing || state == .loading
                self?.apply(current.map {
                    SidebarNowPlaying(title: $0.title, artist: $0.artistName, isPlaying: playing)
                })
            }
    }

    deinit { expiryTask?.cancel() }

    private func apply(_ new: SidebarNowPlaying?) {
        grace.update(new, now: Date())
        refresh()
        expiryTask?.cancel()
        guard let expiry = grace.expiry else { return }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func refresh() {
        let shown = grace.shown(at: Date())
        if shown != track { track = shown }
    }
}
