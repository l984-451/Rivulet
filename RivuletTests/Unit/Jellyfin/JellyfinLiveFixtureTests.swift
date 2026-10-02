// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  JellyfinLiveFixtureTests.swift
//  RivuletTests
//
//  The mapper against responses from a real Jellyfin 12.1.0 server. Expected
//  values are read off the captures themselves (ids, tags, counts).
//

import XCTest
@testable import Rivulet

@MainActor
final class JellyfinLiveFixtureTests: XCTestCase {
    private let base = JellyfinFixtures.baseURL
    private let pid = "jellyfin:live"

    private func item(_ json: String) -> MediaItem {
        JellyfinMediaMapper.item(JellyfinFixtures.decode(json), providerID: pid, baseURL: base)
    }

    func test_userViews_mapToMoviesAndShows() {
        let views: JFQueryResult = JellyfinFixtures.decode(JellyfinLiveFixtures.userViews)
        let libs = (views.items ?? []).compactMap { JellyfinMediaMapper.library($0, providerID: pid) }
        XCTAssertEqual(libs.map(\.title), ["Movies", "TV Shows"])
        XCTAssertEqual(libs.map(\.kind), [.movies, .shows])
    }

    func test_series_progressAndArtwork() {
        let show = item(JellyfinLiveFixtures.series)
        XCTAssertEqual(show.kind, .show)
        XCTAssertEqual(show.title, "Abbott Elementary")
        XCTAssertEqual(show.childProgress, ChildProgress(played: 0, total: 93))
        XCTAssertNil(show.parentRef)
        XCTAssertEqual(show.artwork.poster?.absoluteString,
                       "http://jf.local:8096/Items/53a49d65c4e6554a3587b738f71de0d6/Images/Primary?tag=18cb35d8970d074a9c72bee8217fbc4b")
        XCTAssertEqual(show.artwork.logo?.absoluteString,
                       "http://jf.local:8096/Items/53a49d65c4e6554a3587b738f71de0d6/Images/Logo?tag=b52472edd4c99506b1cfe2f93a08b875")
    }

    func test_series_detail_carriesTmdbIDForCastLookups() {
        let detail = JellyfinMediaMapper.detail(JellyfinFixtures.decode(JellyfinLiveFixtures.series),
                                                nextEpisode: nil, providerID: pid, baseURL: base, token: "t")
        XCTAssertFalse(detail.cast.isEmpty)
        XCTAssertEqual(detail.cast.first?.titleTmdbId, 125935)
    }

    func test_episode_hierarchyAndInheritedArtwork() {
        let ep = item(JellyfinLiveFixtures.episode)
        XCTAssertEqual(ep.kind, .episode)
        XCTAssertEqual(ep.parentRef?.itemID, "e2bb611259586ab1c91b7aa7a66e7c11")
        XCTAssertEqual(ep.grandparentRef?.itemID, "53a49d65c4e6554a3587b738f71de0d6")
        XCTAssertEqual(ep.seasonNumber, 1)
        XCTAssertEqual(ep.episodeNumber, 1)
        XCTAssertEqual(ep.parentArtwork?.poster?.absoluteString,
                       "http://jf.local:8096/Items/e2bb611259586ab1c91b7aa7a66e7c11/Images/Primary?tag=31c37fca14b551679378e51dd0c248e6")
        XCTAssertEqual(ep.grandparentArtwork?.poster?.absoluteString,
                       "http://jf.local:8096/Items/53a49d65c4e6554a3587b738f71de0d6/Images/Primary?tag=18cb35d8970d074a9c72bee8217fbc4b")
        XCTAssertEqual(ep.artwork.backdrop?.absoluteString,
                       "http://jf.local:8096/Items/53a49d65c4e6554a3587b738f71de0d6/Images/Backdrop?tag=fa0aaba0134dda5488b59ccbe5b69dee")
    }

    /// 28 Years Later: four external .srt files (Jellyfin Index 0 to 3), then
    /// the container's nine streams at Index 4 to 12. ffprobe on the same file
    /// reports them at 0 to 8.
    func test_28YearsLater_embeddedTracksUseContainerIndex() {
        let info: JFPlaybackInfoResponse = JellyfinFixtures.decode(JellyfinLiveFixtures.playbackInfo28YearsLater)
        let src = JellyfinMediaMapper.mediaSource(info.mediaSources![0], itemID: "9e48cea00cfa0b5b88364478d0854595",
                                                  playSessionID: info.playSessionId, baseURL: base, token: "t")
        XCTAssertEqual(src.audioTracks.map(\.index), [1])
        XCTAssertTrue(src.audioTracks[0].isSelected)
        let embedded = src.subtitleTracks.filter(\.isEmbedded)
        XCTAssertEqual(embedded.map(\.index), [2, 3, 4, 5, 6, 7, 8])
        let external = src.subtitleTracks.filter { !$0.isEmbedded }
        XCTAssertEqual(external.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(external.first?.externalURL?.absoluteString,
                       "http://jf.local:8096/Videos/9e48cea00cfa0b5b88364478d0854595/9e48cea00cfa0b5b88364478d0854595/Subtitles/0/Stream.srt")
        XCTAssertTrue(external[0].isSelected)
    }
}
