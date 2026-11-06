// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyMediaMapperTests.swift
//  RivuletTests
//
//  Decoding and mapping against responses captured from real Emby servers.
//

import XCTest
@testable import Rivulet

@MainActor
final class EmbyMediaMapperTests: XCTestCase {
    private let base = EmbyBrowseFixtures.baseURL
    private let pid = "emby:srv"

    private func items(_ json: String) throws -> [MediaItem] {
        try EmbyTestJSON.items(json).map { EmbyMediaMapper.item($0, providerID: pid, baseURL: base) }
    }

    private func libraries(_ json: String, homeVideos: HomeVideosContent = .videos) throws -> [MediaLibrary] {
        try EmbyTestJSON.items(json).compactMap { EmbyMediaMapper.library($0, providerID: pid, homeVideos: homeVideos) }
    }

    // MARK: - Libraries

    func test_library_collectionTypesMapToKinds() throws {
        let byID = Dictionary(uniqueKeysWithValues: try libraries(EmbyBrowseFixtures.views).map { ($0.id, $0) })
        XCTAssertEqual(byID["3"]?.kind, .movies)
        XCTAssertEqual(byID["5"]?.kind, .shows)
        XCTAssertEqual(byID["7"]?.kind, .music)
        XCTAssertEqual(byID["3"]?.title, "Movies")
        XCTAssertEqual(byID["3"]?.providerID, pid)
    }

    func test_library_absentCollectionType_isMixedAndBrowsesByFolder() throws {
        let mixed = try XCTUnwrap(try libraries(EmbyBrowseFixtures.views).first { $0.id == "11" })
        XCTAssertEqual(mixed.kind, .mixed)
        XCTAssertTrue(mixed.browsesByFolder)
    }

    func test_library_homeVideos_isPhotosOnlyAfterTheProbe() throws {
        XCTAssertEqual(try libraries(EmbyBrowseFixtures.views).first { $0.id == "9" }?.kind, .mixed)
        XCTAssertEqual(try libraries(EmbyBrowseFixtures.views, homeVideos: .photosOnly).first { $0.id == "9" }?.kind, .photos)
    }

    func test_library_dropsBoxSetAndPlaylistViews() throws {
        let ids = try libraries(EmbyBrowseFixtures.viewsWithBoxSetsAndPlaylists).map(\.id)
        XCTAssertEqual(ids, ["11", "3", "7", "9", "5"])
    }

    func test_views_with4_9_5YearOneDateModified_decode() throws {
        XCTAssertEqual(try libraries(EmbyLiveFixtures.views4_9_5).map(\.id), ["3", "7", "5"])
    }

    // MARK: - Items

    func test_movie_mapsFieldsAndIgnoresItsFolderParent() throws {
        let movie = try XCTUnwrap(try items(EmbyBrowseFixtures.moviesPage).first)
        XCTAssertEqual(movie.ref, MediaItemRef(providerID: pid, itemID: "166"))
        XCTAssertEqual(movie.kind, .movie)
        XCTAssertEqual(movie.title, "01 Sample Clip")
        XCTAssertEqual(movie.year, 2020)
        XCTAssertEqual(movie.releaseDate, "2020-05-17")
        XCTAssertEqual(movie.contentRating, "PG-13")
        XCTAssertEqual(movie.runtime, 1119.338)
        XCTAssertNil(movie.parentRef, "a movie's ParentId is its folder")
    }

    func test_movie_halfWatched_keepsItsResumePointAndIsNotPlayed() throws {
        let state = try XCTUnwrap(try items(EmbyBrowseFixtures.moviesPage).first).userState
        XCTAssertFalse(state.isPlayed)
        XCTAssertEqual(state.viewOffset, 300)
    }

    func test_page_decodesIntegerStudioAndGenreIds() throws {
        let dto = try XCTUnwrap(try EmbyTestJSON.items(EmbyBrowseFixtures.moviesPage).first)
        XCTAssertEqual(dto.studios?.first?.id?.value, "1768")
        XCTAssertEqual(dto.people?.first?.id?.value, "1765")
    }

    func test_kinds() {
        XCTAssertEqual(EmbyMediaMapper.kind("Movie"), .movie)
        XCTAssertEqual(EmbyMediaMapper.kind("Video"), .movie)
        XCTAssertEqual(EmbyMediaMapper.kind("Series"), .show)
        XCTAssertEqual(EmbyMediaMapper.kind("Season"), .season)
        XCTAssertEqual(EmbyMediaMapper.kind("Episode"), .episode)
        XCTAssertEqual(EmbyMediaMapper.kind("BoxSet"), .collection)
        XCTAssertEqual(EmbyMediaMapper.kind("Playlist"), .playlist)
        XCTAssertEqual(EmbyMediaMapper.kind("Folder"), .unknown)
        XCTAssertEqual(EmbyMediaMapper.kind("Genre"), .unknown)
    }

    func test_libraryRootRead_isAllFolderWrappers() throws {
        XCTAssertTrue(try items(EmbyBrowseFixtures.moviesLibraryRoot).allSatisfy { $0.kind == .unknown })
    }

    func test_boxSets_mapToCollections() throws {
        XCTAssertEqual(try items(EmbyBrowseFixtures.boxSets).map(\.kind), [.collection, .collection])
    }

    func test_music_albumIsMusic() throws {
        let album = try XCTUnwrap(try items(EmbyBrowseFixtures.latestGrouped.asItemsEnvelope()).first { $0.title == "Strange and Beautiful" })
        XCTAssertEqual(album.isMusic, true)
    }

    // MARK: - Episodes and seasons

    func test_episode_hierarchyAndArtwork() throws {
        let dto: EmbyItem = try EmbyTestJSON.decode(EmbyBrowseFixtures.episodeDetail)
        let episode = EmbyMediaMapper.item(dto, providerID: pid, baseURL: base)
        XCTAssertEqual(episode.kind, .episode)
        XCTAssertEqual(episode.parentRef?.itemID, "833", "the season, not the series folder in ParentId")
        XCTAssertEqual(episode.grandparentRef?.itemID, "14")
        XCTAssertEqual(episode.seriesTitle, "10 Minute Trainer")
        XCTAssertEqual(episode.episodeNumber, 3)
        XCTAssertEqual(episode.seasonNumber, 1)
        XCTAssertEqual(episode.grandparentArtwork?.poster?.path, "/Items/14/Images/Primary")
        XCTAssertEqual(episode.grandparentArtwork?.backdrop?.path, "/Items/14/Images/Backdrop")
        XCTAssertEqual(episode.artwork.poster?.path, "/Items/54/Images/Primary")
        XCTAssertEqual(episode.artwork.logo?.path, "/Items/14/Images/Logo", "the show's logo through ParentLogoItemId")
    }

    func test_images_carryATagAndNeverAToken() throws {
        let dto: EmbyItem = try EmbyTestJSON.decode(EmbyBrowseFixtures.episodeDetail)
        let artwork = EmbyMediaMapper.item(dto, providerID: pid, baseURL: base).artwork
        let urls = [artwork.poster, artwork.backdrop, artwork.logo, artwork.thumbnail].compactMap { $0 }
        XCTAssertFalse(urls.isEmpty)
        for url in urls {
            XCTAssertNotNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "Tag" }?.value)
            XCTAssertFalse(url.absoluteString.lowercased().contains("api_key"), url.absoluteString)
            XCTAssertFalse(url.absoluteString.contains("ApiKey"))
        }
    }

    func test_images_keepAProxySubpath() throws {
        let dto: EmbyItem = try EmbyTestJSON.decode(EmbyBrowseFixtures.episodeDetail)
        let proxied = URL(string: "https://host.example/emby/")!
        let poster = EmbyMediaMapper.item(dto, providerID: pid, baseURL: proxied).artwork.poster
        XCTAssertEqual(poster?.path, "/emby/Items/54/Images/Primary")
    }

    func test_item_withoutImageTags_hasNoArtworkURLs() throws {
        let movie = try XCTUnwrap(try items(EmbyBrowseFixtures.moviesPage).dropFirst().first)
        XCTAssertNil(movie.artwork.poster)
        XCTAssertNil(movie.artwork.backdrop)
    }

    func test_artwork_albumWithoutItsOwnImage_usesTheChildImagePointer() throws {
        let album = try XCTUnwrap(try items(EmbyBrowseFixtures.photoAlbums).first)
        XCTAssertEqual(album.artwork.poster?.path, "/Items/1659/Images/Primary")
    }

    func test_season_withoutItsOwnImage_usesTheShowsPoster() throws {
        let season: EmbyItem = try EmbyTestJSON.decode(
            #"{"Id":"5","Name":"Season 1","Type":"Season","SeriesId":"4","SeriesPrimaryImageTag":"abc","ImageTags":{}}"#)
        let mapped = EmbyMediaMapper.item(season, providerID: pid, baseURL: base)
        XCTAssertEqual(mapped.artwork.poster?.path, "/Items/4/Images/Primary")
        XCTAssertEqual(mapped.parentArtwork?.poster?.path, "/Items/4/Images/Primary")
    }

    func test_seasons_numbersAndShowLink() throws {
        let seasons = try items(EmbyBrowseFixtures.seasonsWithSpecials)
        XCTAssertEqual(seasons.map(\.seasonNumber), [0, 1])
        XCTAssertEqual(seasons.first?.parentRef?.itemID, "13")
        XCTAssertEqual(seasons.first?.seriesTitle, "Sample Series")
    }

    // MARK: - Series progress

    func test_showProgress_listCarriesTheUnplayedCountAlone() throws {
        let p90x = try XCTUnwrap(try items(EmbyBrowseFixtures.seriesWithSpecials).first)
        // Recursive 13 (specials counted) minus Unplayed 12 would be "1 watched" on an untouched show.
        XCTAssertEqual(p90x.childProgress, ChildProgress(played: 0, total: 12, unplayedOnly: true))
        let abbott = try XCTUnwrap(try items(EmbyBrowseFixtures.seriesList4_9_5).first)
        XCTAssertEqual(abbott.childProgress, ChildProgress(played: 0, total: 97, unplayedOnly: true))
    }

    func test_showProgress_fullyWatchedShow() throws {
        let watched = EmbyBrowseFixtures.seriesWithSpecials.replacingOccurrences(of: #""UnplayedItemCount":12"#, with: #""UnplayedItemCount":0"#)
        let show = try XCTUnwrap(try items(watched).first)
        XCTAssertEqual(show.childProgress, ChildProgress(played: 13, total: 13))
    }

    func test_showProgress_sumsSeasonsAndSkipsSpecials() throws {
        let seasons = try EmbyTestJSON.items(EmbyBrowseFixtures.seasonsWithSpecials)
        XCTAssertEqual(EmbyMediaMapper.showProgress(seasons: seasons), ChildProgress(played: 0, total: 12))
        let partly = EmbyBrowseFixtures.seasonsWithSpecials.replacingOccurrences(of: #""UnplayedItemCount":12"#, with: #""UnplayedItemCount":5"#)
        XCTAssertEqual(EmbyMediaMapper.showProgress(seasons: try EmbyTestJSON.items(partly)), ChildProgress(played: 7, total: 12))
    }

    func test_seasonProgress_isExact() throws {
        let partly = EmbyBrowseFixtures.seasonsAbbott.replacingOccurrences(of: #""UnplayedItemCount":13"#, with: #""UnplayedItemCount":9"#)
        let first = try XCTUnwrap(try items(partly).first)
        XCTAssertEqual(first.childProgress, ChildProgress(played: 4, total: 13))
    }

    // MARK: - Provider ids

    func test_providerIDs_readCaseInsensitively() throws {
        let movie = try XCTUnwrap(try EmbyTestJSON.items(EmbyBrowseFixtures.moviesPage).first)
        XCTAssertEqual(movie.providerID("imdb"), "tt9990001")
        XCTAssertEqual(movie.providerID("TMDB"), "999001")
        let show = try XCTUnwrap(try EmbyTestJSON.items(EmbyBrowseFixtures.seriesList4_8_11).first)
        XCTAssertEqual(show.providerID("Imdb"), "tt14218830", "the same server wrote IMDB on a series")
        XCTAssertNil(show.providerID("nothing"))
    }

    func test_providerIDs_keysWithSpacesSurviveDecoding() throws {
        let show = try XCTUnwrap(try EmbyTestJSON.items(EmbyBrowseFixtures.seriesList4_9_5).first)
        XCTAssertEqual(show.providerIds?["TV Maze"], "55350")
        XCTAssertEqual(show.providerIds?["X (Twitter)"], "AbbottElemABC")
    }

    func test_externalIDs_areLowercased() throws {
        let show = try XCTUnwrap(try EmbyTestJSON.items(EmbyBrowseFixtures.seriesList4_8_11).first)
        XCTAssertEqual(EmbyMediaMapper.externalIDs(show), ["imdb": "tt14218830", "tmdb": "125935", "tvdb": "402910"])
    }

    // MARK: - Detail

    private func detail(_ json: String = EmbyBrowseFixtures.movieDetail) throws -> MediaItemDetail {
        let dto: EmbyItem = try EmbyTestJSON.decode(json)
        return EmbyMediaMapper.detail(dto, nextEpisode: nil, providerID: pid, baseURL: base)
    }

    func test_detail_peopleGenresStudiosAndIds() throws {
        let detail = try detail()
        XCTAssertEqual(detail.genres, ["zz-browse-genre"])
        XCTAssertEqual(detail.studios, ["zz-browse-studio"])
        XCTAssertEqual(detail.cast.map(\.name), ["zz-browse-person"])
        XCTAssertEqual(detail.cast.first?.role, "Tester")
        XCTAssertEqual(detail.directors.map(\.name), ["zz-browse-director"])
        XCTAssertEqual(detail.cast.first?.titleTmdbId, 999001)
        XCTAssertEqual(detail.cast.first?.titleIsMovie, true)
        XCTAssertEqual(detail.contentRating, "PG-13")
        XCTAssertEqual(detail.externalIDs["tmdb"], "999001")
        XCTAssertEqual(detail.externalIDs["imdb"], "tt9990001")
    }

    func test_detail_ratings() throws {
        let ratings = try detail().ratings
        XCTAssertEqual(ratings.map(\.source), [.rottenTomatoes, .unknown])
        XCTAssertEqual(ratings.first?.value ?? 0, 8.8, accuracy: 0.001)
    }

    func test_detail_chaptersCarryStartAndEnd() throws {
        let chapters = try detail().chapters
        XCTAssertEqual(chapters.count, 4)
        XCTAssertEqual(chapters[1].start, 300)
        XCTAssertEqual(chapters[0].end, 300)
        XCTAssertNil(chapters[3].end)
    }

    func test_detail_markersAreNotChapters() throws {
        let marked = EmbyBrowseFixtures.movieDetail.replacingOccurrences(
            of: #"{"StartPositionTicks":0,"Name":"Chapter 1","MarkerType":"Chapter","ChapterIndex":0}"#,
            with: #"{"StartPositionTicks":0,"Name":"Intro","MarkerType":"IntroStart","ChapterIndex":0}"#)
        let chapters = try detail(marked).chapters
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters.first?.start, 300)
    }

    func test_detail_collectionsAreNames() throws {
        let box = EmbyBrowseFixtures.movieDetail.replacingOccurrences(
            of: #""Taglines":[]"#, with: #""Taglines":[],"Collections":[{"Name":"zz-box","Id":1778}]"#)
        XCTAssertEqual(try detail(box).collections, ["zz-box"])
    }

    func test_detail_extras_areTrailersFirst_unverified() throws {
        let dto: EmbyItem = try EmbyTestJSON.decode(EmbyBrowseFixtures.movieDetail)
        let trailer: EmbyItem = try EmbyTestJSON.decode(#"{"Id":"900","Name":"Trailer","Type":"Trailer","RunTimeTicks":600000000}"#)
        let featurette: EmbyItem = try EmbyTestJSON.decode(#"{"Id":"901","Name":"Making Of","Type":"Video","ExtraType":"BehindTheScenes"}"#)
        let detail = EmbyMediaMapper.detail(dto, nextEpisode: nil, trailers: [trailer], specialFeatures: [featurette],
                                            providerID: pid, baseURL: base)
        XCTAssertEqual(detail.extras.map(\.id), ["900", "901"])
        XCTAssertEqual(detail.extras.first?.isTrailer, true)
        XCTAssertEqual(detail.extras.last?.subtype, .behindTheScenes)
        XCTAssertEqual(detail.extras.first?.duration, 60)
    }

    func test_detail_showUsesTheSeasonSumForProgress() throws {
        let dto: EmbyItem = try EmbyTestJSON.decode(EmbyBrowseFixtures.seriesDetail)
        let progress = ChildProgress(played: 10, total: 97)
        let detail = EmbyMediaMapper.detail(dto, nextEpisode: nil, showProgress: progress, providerID: pid, baseURL: base)
        XCTAssertEqual(detail.item.childProgress, progress)
    }

    // MARK: - Dates

    func test_releaseDate_yearOneIsAbsent() throws {
        let dto: EmbyItem = try EmbyTestJSON.decode(#"{"Id":"1","Name":"X","Type":"Movie","PremiereDate":"0001-01-01T00:00:00.0000000Z"}"#)
        XCTAssertNil(EmbyMediaMapper.item(dto, providerID: pid, baseURL: base).releaseDate)
    }
}

private extension String {
    /// A bare array body (Items/Latest) as the `{Items: [...]}` envelope the item helpers read.
    func asItemsEnvelope() -> String { #"{"Items":"# + self + "}" }
}
