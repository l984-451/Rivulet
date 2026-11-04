// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// #491: trailers and pre-rolls before a movie.
final class CinemaExtrasTests: XCTestCase {
    func test_appliesOnlyToAMovieStartedFromTheBeginning() {
        XCTAssertTrue(CinemaExtras.applies(type: "movie", startOffset: nil, inPlaylist: false, count: 2))
        XCTAssertTrue(CinemaExtras.applies(type: "movie", startOffset: 0, inPlaylist: false, count: 1))
        XCTAssertFalse(CinemaExtras.applies(type: "movie", startOffset: nil, inPlaylist: false, count: 0), "off by default")
        XCTAssertFalse(CinemaExtras.applies(type: "movie", startOffset: 90, inPlaylist: false, count: 2), "a resume goes straight in")
        XCTAssertFalse(CinemaExtras.applies(type: "movie", startOffset: nil, inPlaylist: true, count: 2))
        XCTAssertFalse(CinemaExtras.applies(type: "episode", startOffset: nil, inPlaylist: false, count: 2))
        XCTAssertFalse(CinemaExtras.applies(type: "clip", startOffset: nil, inPlaylist: false, count: 2), "a trailer has no trailers")
    }

    /// The shape of PMS 1.43.5's reply: trailers, pre-rolls, then the movie.
    func test_clipsKeepTheServersOrderAndDropTheMovie() {
        func item(_ key: String, _ type: String) -> PlexMetadata {
            var meta = PlexMetadata()
            meta.ratingKey = key
            meta.type = type
            return meta
        }
        let clips = PlexNetworkManager.cinemaClips(in: [item("22", "clip"), item("238", "clip"), item("3", "movie")])
        XCTAssertEqual(clips.map(\.ratingKey), ["22", "238"])
    }

    /// A clip that can't start moves on, and the movie comes back with its timeline duties.
    @MainActor
    func test_failedClip_handsOverToTheMovie() async throws {
        UserDefaults.standard.set(2, forKey: CinemaExtras.countKey)
        defer { UserDefaults.standard.removeObject(forKey: CinemaExtras.countKey) }
        var movie = PlexMetadata()
        movie.ratingKey = "3"
        movie.type = "movie"
        var clip = PlexMetadata()
        clip.ratingKey = "22"
        clip.type = "clip"
        let vm = UniversalPlayerViewModel(metadata: movie, serverURL: "http://127.0.0.1:9", authToken: "t")
        var asked = 0
        vm.plexCinemaExtras = { _, _, key, count in
            asked += 1
            XCTAssertEqual(key, "3")
            XCTAssertEqual(count, 2)
            return [clip]
        }
        await vm.startPlayback()
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(vm.metadata.ratingKey, "3")
        XCTAssertFalse(vm.isPlayingCinemaExtra)
    }

    /// Closing the player during a clip must not start the movie behind it.
    @MainActor
    func test_stoppedPlayer_neverAdvances() async {
        UserDefaults.standard.set(1, forKey: CinemaExtras.countKey)
        defer { UserDefaults.standard.removeObject(forKey: CinemaExtras.countKey) }
        var movie = PlexMetadata()
        movie.ratingKey = "3"
        movie.type = "movie"
        var clip = PlexMetadata()
        clip.ratingKey = "22"
        clip.type = "clip"
        let vm = UniversalPlayerViewModel(metadata: movie, serverURL: "http://127.0.0.1:9", authToken: "t")
        vm.plexCinemaExtras = { [weak vm] _, _, _, _ in
            await MainActor.run { vm?.stopPlayback() }
            return [clip]
        }
        await vm.startPlayback()
        XCTAssertEqual(vm.metadata.ratingKey, "3", "stopped during the request, so no clip took over")
        XCTAssertFalse(vm.isPlayingCinemaExtra)
    }
}
