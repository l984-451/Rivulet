// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class EpisodePickerTests: XCTestCase {

    // MARK: - Builders

    private func episode(
        _ id: String,
        season: Int? = 1,
        number: Int?,
        played: Bool = false,
        offset: TimeInterval = 0
    ) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: "plex:test", itemID: id),
            kind: .episode,
            title: "Episode \(number.map(String.init) ?? "?")",
            sortTitle: nil,
            overview: nil,
            year: nil,
            runtime: 1800,
            parentRef: nil,
            grandparentRef: nil,
            episodeNumber: number,
            seasonNumber: season,
            childProgress: nil,
            userState: MediaUserState(
                isPlayed: played, viewOffset: offset, isFavorite: false, lastViewedAt: nil
            ),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil,
            grandparentArtwork: nil
        )
    }

    // MARK: - firstUnplayed

    func testEmptySeasonReturnsNil() {
        XCTAssertNil(EpisodePicker.firstUnplayed(in: []))
    }

    func testFreshSeasonStartsAtEpisodeOne() {
        let eps = [episode("e1", number: 1), episode("e2", number: 2)]
        XCTAssertEqual(EpisodePicker.firstUnplayed(in: eps)?.ref.itemID, "e1")
    }

    func testSkipsWatchedEpisodesToFirstUnplayed() {
        let eps = [
            episode("e1", number: 1, played: true),
            episode("e2", number: 2, played: true),
            episode("e3", number: 3),
            episode("e4", number: 4),
        ]
        XCTAssertEqual(EpisodePicker.firstUnplayed(in: eps)?.ref.itemID, "e3")
    }

    func testInProgressEpisodeWinsOverLaterUnplayed() {
        // e1 watched, e2 started but unfinished, e3 untouched → resume e2.
        let eps = [
            episode("e1", number: 1, played: true),
            episode("e2", number: 2, offset: 300),
            episode("e3", number: 3),
        ]
        XCTAssertEqual(EpisodePicker.firstUnplayed(in: eps)?.ref.itemID, "e2")
    }

    func testFullyWatchedSeasonRestartsAtEpisodeOne() {
        let eps = [
            episode("e1", number: 1, played: true),
            episode("e2", number: 2, played: true),
        ]
        XCTAssertEqual(EpisodePicker.firstUnplayed(in: eps)?.ref.itemID, "e1")
    }

    func testPlayedEpisodeWithResumeOffsetIsNotTreatedAsInProgress() {
        // A rewatch leaves viewCount > 0 AND a viewOffset. The next NEW episode
        // should still win over resuming a finished one.
        let eps = [
            episode("e1", number: 1, played: true, offset: 120),
            episode("e2", number: 2),
        ]
        XCTAssertEqual(EpisodePicker.firstUnplayed(in: eps)?.ref.itemID, "e2")
    }

    func testUnorderedInputIsSortedBeforePicking() {
        let eps = [
            episode("e3", number: 3),
            episode("e1", number: 1, played: true),
            episode("e2", number: 2),
        ]
        XCTAssertEqual(EpisodePicker.firstUnplayed(in: eps)?.ref.itemID, "e2")
    }

    func testSortsAcrossSeasonsBeforeEpisodes() {
        let eps = [
            episode("s2e1", season: 2, number: 1),
            episode("s1e2", season: 1, number: 2),
            episode("s1e1", season: 1, number: 1, played: true),
        ]
        XCTAssertEqual(EpisodePicker.firstUnplayed(in: eps)?.ref.itemID, "s1e2")
    }

    func testMissingEpisodeNumbersFallBackToServerOrder() {
        let eps = [
            episode("first", season: nil, number: nil, played: true),
            episode("second", season: nil, number: nil),
        ]
        XCTAssertEqual(EpisodePicker.firstUnplayed(in: eps)?.ref.itemID, "second")
    }

    // MARK: - playTitle

    func testShowPageNamesTheNextEpisode() {
        let ep = episode("e3", season: 1, number: 3)
        XCTAssertEqual(EpisodePicker.playTitle(for: ep, on: .show), "Play S1, E3")
        XCTAssertEqual(EpisodePicker.playTitle(for: ep, on: .season), "Play S1, E3")
    }

    func testShowPageResumesAnInProgressEpisode() {
        let ep = episode("e5", season: 2, number: 5, offset: 300)
        XCTAssertEqual(EpisodePicker.playTitle(for: ep, on: .show), "Resume S2, E5")
    }

    func testUntouchedFirstEpisode() {
        XCTAssertEqual(EpisodePicker.playTitle(for: episode("e1", number: 1), on: .show), "Play First Episode")
        // A later season's opener is the first episode of its own page only.
        let s2e1 = episode("s2e1", season: 2, number: 1)
        XCTAssertEqual(EpisodePicker.playTitle(for: s2e1, on: .show), "Play S2, E1")
        XCTAssertEqual(EpisodePicker.playTitle(for: s2e1, on: .season), "Play First Episode")
        // Started, so it resumes instead.
        XCTAssertEqual(
            EpisodePicker.playTitle(for: episode("e1", number: 1, offset: 300), on: .show), "Resume S1, E1")
    }

    func testFullyWatchedShowPlaysAgain() {
        // The picker falls back to a played first episode only when all are played.
        let ep = episode("e1", number: 1, played: true)
        XCTAssertEqual(EpisodePicker.playTitle(for: ep, on: .show), "Play Again")
    }

    func testWithoutNumberingFallsBackToPlainWording() {
        let ep = episode("e1", season: nil, number: nil)
        XCTAssertEqual(EpisodePicker.playTitle(for: ep, on: .show), "Play")
        let started = episode("e1", season: nil, number: nil, offset: 300)
        XCTAssertEqual(EpisodePicker.playTitle(for: started, on: .show), "Resume")
    }

    // MARK: - episodeDescription

    func testDescriptionNamesTheEpisodeWhenThePillDoes() {
        let ep = episode("e5", season: 7, number: 5)
        let d = EpisodePicker.episodeDescription(for: ep, overview: "Plot.", on: .show)
        XCTAssertEqual(d?.prefix, "S7, E5 \u{00B7} Episode 5:")
        XCTAssertEqual(d?.body, "Plot.")
        let resume = episode("e5", season: 7, number: 5, offset: 300)
        XCTAssertNotNil(EpisodePicker.episodeDescription(for: resume, overview: "Plot.", on: .season))
    }

    func testDescriptionKeepsSynopsisForPlainPills() {
        XCTAssertNil(EpisodePicker.episodeDescription(for: episode("e1", number: 1), overview: "x", on: .show))
        XCTAssertNil(EpisodePicker.episodeDescription(
            for: episode("e3", number: 3, played: true), overview: "x", on: .show))
        XCTAssertNil(EpisodePicker.episodeDescription(for: episode("e3", number: 3), overview: "x", on: .episode))
        XCTAssertNil(EpisodePicker.episodeDescription(for: episode("e3", number: 3), overview: "", on: .show))
        XCTAssertNil(EpisodePicker.episodeDescription(for: episode("e3", number: 3), overview: nil, on: .show))
    }

    /// An item's own page (movie or episode) never names the episode.
    func testOwnPageWording() {
        XCTAssertEqual(EpisodePicker.playTitle(for: episode("e3", number: 3), on: .episode), "Play")
        XCTAssertEqual(EpisodePicker.playTitle(for: episode("e1", number: 1), on: .episode), "Play")
        XCTAssertEqual(
            EpisodePicker.playTitle(for: episode("e3", number: 3, offset: 300), on: .episode), "Resume")
        XCTAssertEqual(
            EpisodePicker.playTitle(for: episode("e3", number: 3, played: true), on: .episode), "Play Again")
    }

    /// A resume point outranks the watched flag (a rewatch in progress).
    func testRewatchInProgressResumes() {
        let ep = episode("e3", number: 3, played: true, offset: 300)
        XCTAssertEqual(EpisodePicker.playTitle(for: ep, on: .episode), "Resume")
    }

    /// Past the policy's completion ceiling there is nothing worth resuming:
    /// the old "under a minute left" case of the time readout.
    func testNearlyFinishedItemDoesNotResume() {
        XCTAssertEqual(
            EpisodePicker.playTitle(for: episode("e3", number: 3, offset: 1780), on: .episode), "Play")
    }

    /// A show before its episode resolves: no runtime, no numbering.
    func testUnresolvedShowSaysPlay() {
        XCTAssertEqual(EpisodePicker.playTitle(resumes: false, watched: false), "Play")
        XCTAssertEqual(EpisodePicker.playTitle(resumes: false, watched: true), "Play Again")
    }

    // MARK: - isInProgress

    func testIsInProgressSemantics() {
        let untouched = MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil)
        let started = MediaUserState(isPlayed: false, viewOffset: 60, isFavorite: false, lastViewedAt: nil)
        let finished = MediaUserState(isPlayed: true, viewOffset: 0, isFavorite: false, lastViewedAt: nil)
        let rewatching = MediaUserState(isPlayed: true, viewOffset: 60, isFavorite: false, lastViewedAt: nil)

        XCTAssertFalse(untouched.isInProgress)
        XCTAssertTrue(started.isInProgress)
        XCTAssertFalse(finished.isInProgress)
        XCTAssertFalse(rewatching.isInProgress)
    }
}
