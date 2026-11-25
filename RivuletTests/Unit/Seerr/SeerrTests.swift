// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Seerr parsing, status rules and address handling.

import XCTest
@testable import Rivulet

final class SeerrTests: XCTestCase {

    // MARK: - Status

    func test_availability_mapsSeerrMediaStatus() {
        XCTAssertEqual(SeerrAvailability(mediaStatus: nil), .requestable)
        XCTAssertEqual(SeerrAvailability(mediaStatus: .unknown), .requestable)
        XCTAssertEqual(SeerrAvailability(mediaStatus: .deleted), .requestable)
        XCTAssertEqual(SeerrAvailability(mediaStatus: .pending), .requested)
        XCTAssertEqual(SeerrAvailability(mediaStatus: .processing), .processing)
        XCTAssertEqual(SeerrAvailability(mediaStatus: .partiallyAvailable), .partiallyAvailable)
        XCTAssertEqual(SeerrAvailability(mediaStatus: .available), .available)
        XCTAssertEqual(SeerrAvailability(mediaStatus: .blocklisted), .blocklisted)
    }

    /// The server code's numbering, not the published spec's (which stops at 6 = Deleted).
    func test_mediaStatus_followsServerNumbering() {
        XCTAssertEqual(SeerrMediaStatus(rawValue: 6), .blocklisted)
        XCTAssertEqual(SeerrMediaStatus(rawValue: 7), .deleted)
    }

    func test_requestableBadge_isNil_othersNamed() {
        XCTAssertNil(SeerrAvailability.requestable.badge)
        XCTAssertNotNil(SeerrAvailability.requested.badge)
        XCTAssertNotNil(SeerrAvailability.partiallyAvailable.badge)
    }

    // MARK: - Search

    func test_search_parsesMoviesAndShows_skipsPeople_andDropsAvailable() throws {
        let json = """
        {"page":1,"totalPages":1,"totalResults":4,"results":[
          {"id":438631,"mediaType":"movie","title":"Dune","releaseDate":"2021-09-15","posterPath":"/d5NXSklXo0qyIYkgV94XAgMIckC.jpg","overview":"x"},
          {"id":90228,"mediaType":"tv","name":"Dune: Prophecy","firstAirDate":"2024-11-17","mediaInfo":{"status":3}},
          {"id":841,"mediaType":"movie","title":"Dune","releaseDate":"1984-12-14","mediaInfo":{"status":5}},
          {"id":1,"mediaType":"person","name":"Frank Herbert","knownFor":[]}
        ]}
        """
        let titles = try SeerrClient.titles(fromSearch: Data(json.utf8))
        XCTAssertEqual(titles.map(\.tmdbID), [438631, 90228, 841])
        XCTAssertEqual(titles[0].kind, .movie)
        XCTAssertEqual(titles[0].releaseDate, "2021-09-15")
        XCTAssertEqual(titles[0].availability, .requestable)
        XCTAssertEqual(titles[1].kind, .tv)
        XCTAssertEqual(titles[1].title, "Dune: Prophecy")
        XCTAssertEqual(titles[1].releaseDate, "2024-11-17")
        XCTAssertEqual(titles[1].availability, .processing)

        XCTAssertEqual(SeerrTitle.requestable(titles).map(\.tmdbID), [438631, 90228])
    }

    func test_search_rejectsNonSeerrBody() {
        XCTAssertThrowsError(try SeerrClient.titles(fromSearch: Data("<html>Login</html>".utf8))) { error in
            XCTAssertEqual(error as? SeerrError, .notSeerr)
        }
    }

    // MARK: - Seasons

    func test_seasons_mergeMediaStatusAndLiveRequests_skipSpecials() throws {
        let json = """
        {"id":1399,"name":"Show",
         "seasons":[{"seasonNumber":0,"name":"Specials","episodeCount":3},
                    {"seasonNumber":1,"name":"Season 1","episodeCount":10},
                    {"seasonNumber":2,"name":"Season 2","episodeCount":10},
                    {"seasonNumber":3,"name":"Season 3","episodeCount":10},
                    {"seasonNumber":4,"name":"Season 4","episodeCount":10}],
         "mediaInfo":{"status":4,
           "seasons":[{"seasonNumber":1,"status":5},{"seasonNumber":2,"status":3}],
           "requests":[{"status":2,"seasons":[{"seasonNumber":3,"status":2}]},
                       {"status":3,"seasons":[{"seasonNumber":4,"status":3}]}]}}
        """
        let seasons = try SeerrClient.seasons(fromShow: Data(json.utf8))
        XCTAssertEqual(seasons.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(seasons.map(\.availability), [.available, .processing, .requested, .requestable])
        XCTAssertEqual(SeerrSeasons.requestableNumbers(seasons), [4])
    }

    func test_seasons_withoutMediaInfo_areAllRequestable() throws {
        let json = #"{"seasons":[{"seasonNumber":2,"name":"Season 2"},{"seasonNumber":1,"name":"Season 1"}]}"#
        let seasons = try SeerrClient.seasons(fromShow: Data(json.utf8))
        XCTAssertEqual(seasons.map(\.number), [1, 2])
        XCTAssertEqual(SeerrSeasons.requestableNumbers(seasons), [1, 2])
    }

    func test_showAvailability_afterRequest() {
        let seasons = [
            SeerrSeason(number: 1, name: "", episodeCount: nil, availability: .requestable),
            SeerrSeason(number: 2, name: "", episodeCount: nil, availability: .requestable)
        ]
        // One of two seasons asked for: the show can still be requested.
        XCTAssertEqual(SeerrSeasons.availability(after: [1], of: seasons, was: .requestable), .requestable)
        XCTAssertEqual(SeerrSeasons.availability(after: [1, 2], of: seasons, was: .requestable), .requested)
        // A partly available show keeps saying so.
        XCTAssertEqual(SeerrSeasons.availability(after: [1, 2], of: seasons, was: .partiallyAvailable), .partiallyAvailable)
    }

    // MARK: - Address and URLs

    func test_apiBase_normalizesWhatPeopleType() {
        XCTAssertEqual(SeerrSettings.apiBase(from: "10.0.0.5:5055")?.absoluteString, "http://10.0.0.5:5055/api/v1")
        XCTAssertEqual(SeerrSettings.apiBase(from: " http://seerr.lan:5055/ ")?.absoluteString, "http://seerr.lan:5055/api/v1")
        XCTAssertEqual(SeerrSettings.apiBase(from: "https://seerr.example.com/api/v1/")?.absoluteString, "https://seerr.example.com/api/v1")
        XCTAssertEqual(SeerrSettings.apiBase(from: "https://example.com/seerr")?.absoluteString, "https://example.com/seerr/api/v1")
        XCTAssertNil(SeerrSettings.apiBase(from: ""))
        XCTAssertNil(SeerrSettings.apiBase(from: "ftp://seerr.lan"))
        XCTAssertNil(SeerrSettings.apiBase(from: "http://"))
    }

    func test_searchURL_encodesReservedCharacters() {
        let client = SeerrClient(base: URL(string: "http://seerr.lan:5055/api/v1")!, apiKey: "k")
        let url = client.url("search", query: [("query", "Ocean's Eleven (2001)!"), ("page", "1")])
        XCTAssertEqual(url.absoluteString,
                       "http://seerr.lan:5055/api/v1/search?query=Ocean%27s%20Eleven%20%282001%29%21&page=1")
    }

    func test_errorMessage_neverEmpty() {
        let errors: [SeerrError] = [.notConfigured, .unauthorized, .notSeerr,
                                    .server(status: 500, message: nil), .server(status: 409, message: "Request exists")]
        for error in errors { XCTAssertFalse((error.errorDescription ?? "").isEmpty) }
        XCTAssertEqual(SeerrError.server(status: 409, message: "Request exists").errorDescription, "Request exists")
    }

    // MARK: - Detail status

    func test_movieAvailability_readsMediaInfo() throws {
        XCTAssertEqual(try SeerrClient.movieAvailability(fromDetails: Data(#"{"id":1,"mediaInfo":{"status":2}}"#.utf8)), .requested)
        XCTAssertEqual(try SeerrClient.movieAvailability(fromDetails: Data(#"{"id":1}"#.utf8)), .requestable)
    }

    func test_showPillState_requestUntilNothingLeft() throws {
        let partly = """
        {"seasons":[{"seasonNumber":1,"name":"S1"},{"seasonNumber":2,"name":"S2"}],
         "mediaInfo":{"status":4,"seasons":[{"seasonNumber":1,"status":5}]}}
        """
        let show = try SeerrClient.show(fromDetails: Data(partly.utf8))
        XCTAssertEqual(show.availability, .partiallyAvailable)
        XCTAssertEqual(show.pillState, .requestable)

        let done = """
        {"seasons":[{"seasonNumber":1,"name":"S1"}],"mediaInfo":{"status":3,"seasons":[{"seasonNumber":1,"status":3}]}}
        """
        XCTAssertEqual(try SeerrClient.show(fromDetails: Data(done.utf8)).pillState, .processing)
    }

    // MARK: - Quality

    func test_qualityOptions_defaultFirst_then4KLast() {
        let servers: [SeerrQualityOption.Server] = [
            .init(id: 1, is4K: true, isDefault: true, activeProfileID: 7),
            .init(id: 0, is4K: false, isDefault: true, activeProfileID: 4),
        ]
        let profiles: [Int: [(id: Int, name: String)]] = [
            0: [(1, "SD"), (4, "HD-1080p"), (6, "HD-720p")],
            1: [(7, "Ultra-HD")],
        ]
        let options = SeerrQualityOption.options(servers: servers, profiles: profiles)
        XCTAssertEqual(options.map(\.name), ["HD-1080p", "HD-720p", "SD", "Ultra-HD"])
        XCTAssertEqual(options.map(\.isDefault), [true, false, false, false])
        XCTAssertEqual(options.last?.is4K, true)
        XCTAssertEqual(options.last?.serverID, 1)
        XCTAssertTrue(options[0].title.contains("HD-1080p"))
        XCTAssertNotEqual(options[0].title, "HD-1080p")   // marked as the default
        XCTAssertNotEqual(options.last?.title, "Ultra-HD") // marked as 4K
    }

    func test_qualityOptions_skipServersWithoutProfiles() {
        let servers: [SeerrQualityOption.Server] = [.init(id: 0, is4K: false, isDefault: true, activeProfileID: 1),
                                                    .init(id: 2, is4K: false, isDefault: false, activeProfileID: nil)]
        XCTAssertEqual(SeerrQualityOption.options(servers: servers, profiles: [0: [(1, "Any")]]).count, 1)
    }

    // MARK: - Plex Discover detail

    func test_discoverMatches_readsFirstRatingKey() throws {
        let json = #"{"MediaContainer":{"Metadata":[{"ratingKey":"abc"},{"ratingKey":"def"}]}}"#
        XCTAssertEqual(try DiscoverDetailSource.ratingKey(fromMatches: Data(json.utf8)), "abc")
    }

    // MARK: - Seerr detail (installs without Plex)

    @MainActor
    func test_seerrMovieDetail_fillsTheDetailPage() throws {
        let json = """
        {"id":438631,"title":"Dune","overview":"Paul Atreides...","tagline":"Beyond fear, destiny awaits.",
         "releaseDate":"2021-09-15","runtime":155,"voteAverage":7.8,"imdbId":"tt1160419",
         "genres":[{"id":878,"name":"Science Fiction"},{"id":12,"name":"Adventure"}],
         "productionCompanies":[{"id":923,"name":"Legendary Pictures"}],
         "credits":{"cast":[{"id":1190668,"name":"Timothée Chalamet","character":"Paul Atreides","profilePath":"/x.jpg"}],
                    "crew":[{"id":137427,"name":"Denis Villeneuve","job":"Director","department":"Directing"},
                            {"id":2,"name":"Jon Spaihts","job":"Screenplay","department":"Writing"},
                            {"id":137427,"name":"Denis Villeneuve","job":"Screenplay","department":"Writing"}]},
         "releases":{"results":[{"iso_3166_1":"GB","release_dates":[{"certification":"12A","type":3}]},
                                {"iso_3166_1":"US","release_dates":[{"certification":"","type":1},{"certification":"PG-13","type":3}]}]}}
        """
        let scores = #"{"rt":{"criticsScore":83,"audienceScore":90},"imdb":{"criticsScore":8.0}}"#
        let ratings = SeerrClient.ratings(from: Data(scores.utf8), kind: .movie)
        let detail = try SeerrClient.detail(from: Data(json.utf8), kind: .movie, ratings: ratings)

        XCTAssertEqual(detail.item.ref.providerID, TMDBMediaMapper.providerID)
        XCTAssertTrue(detail.item.isMetadataOnly)
        XCTAssertEqual(detail.contentRating, "PG-13")
        XCTAssertEqual(detail.item.runtime, 155 * 60)
        XCTAssertEqual(detail.tagline, "Beyond fear, destiny awaits.")
        XCTAssertEqual(detail.genres, ["Science Fiction", "Adventure"])
        XCTAssertEqual(detail.studios, ["Legendary Pictures"])
        XCTAssertEqual(detail.cast.first?.name, "Timothée Chalamet")
        XCTAssertEqual(detail.cast.first?.imageURL?.absoluteString, "https://image.tmdb.org/t/p/w185/x.jpg")
        XCTAssertEqual(detail.directors.map(\.name), ["Denis Villeneuve"])
        XCTAssertEqual(detail.writers.map(\.name), ["Jon Spaihts", "Denis Villeneuve"])
        XCTAssertEqual(detail.externalIDs["imdb"], "tt1160419")
        let sources = detail.ratings.map(\.source)
        XCTAssertTrue(sources.contains(.rottenTomatoes))
        XCTAssertTrue(sources.contains(.rottenTomatoesAudience))
        XCTAssertTrue(sources.contains(.imdb))
        XCTAssertEqual(detail.ratings.first { $0.source == .rottenTomatoes }?.value ?? 0, 8.3, accuracy: 0.001)
        XCTAssertTrue(detail.mediaSources.isEmpty)
    }

    @MainActor
    func test_seerrShowDetail_usesCreatorsNetworksAndUSRating() throws {
        let json = """
        {"id":1399,"name":"Show","firstAirDate":"2011-04-17","episodeRunTime":[60],
         "networks":[{"name":"HBO"}],"createdBy":[{"id":9813,"name":"David Benioff"}],
         "contentRatings":{"results":[{"iso_3166_1":"DE","rating":"16"},{"iso_3166_1":"US","rating":"TV-MA"}]},
         "credits":{"cast":[],"crew":[]}}
        """
        let detail = try SeerrClient.detail(from: Data(json.utf8), kind: .tv, ratings: [])
        XCTAssertEqual(detail.item.kind, .show)
        XCTAssertEqual(detail.contentRating, "TV-MA")
        XCTAssertEqual(detail.studios, ["HBO"])
        XCTAssertEqual(detail.writers.map(\.name), ["David Benioff"])
        XCTAssertEqual(detail.item.runtime, 3600)
    }
}
