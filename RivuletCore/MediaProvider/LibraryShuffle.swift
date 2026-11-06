// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LibraryShuffle.swift
//  Rivulet
//
//  Shuffle for a video library or a show (#543), played as a playlist queue.
//

import Foundation

extension MediaLibrary {
    /// Video libraries only: music has its own shuffle, photos and Live TV none.
    var canShuffle: Bool { kind == .movies || kind == .shows || kind == .mixed }

    /// The most titles one library shuffle asks for, so a huge library is never fetched whole.
    static let shuffleLimit = 200
}

extension MediaProvider {
    /// The library's playable videos in the server's random order, nil when there are none.
    func shuffleQueue(for library: MediaLibrary, unwatchedOnly: Bool = false) async throws -> PlayQueue<MediaItem>? {
        PlayQueue(entries: try await shuffledItems(in: library, unwatchedOnly: unwatchedOnly,
                                                   limit: MediaLibrary.shuffleLimit), startingAt: 0)
    }

    /// Every episode of the show in random order, nil when it has none.
    func shuffleQueue(forShow show: MediaItemRef) async throws -> PlayQueue<MediaItem>? {
        PlayQueue.shuffled(try await allEpisodes(of: show))
    }
}
