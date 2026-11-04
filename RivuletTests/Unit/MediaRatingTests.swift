// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaRatingTests.swift
//  RivuletTests
//
//  Field shapes measured on PMS 1.43.4 and Jellyfin 12.1.
//

import XCTest
@testable import Rivulet

@MainActor
final class MediaRatingTests: XCTestCase {

    private func plex(
        rating: Double? = nil, ratingImage: String? = nil,
        audience: Double? = nil, audienceImage: String? = nil,
        entries: [PlexRatingEntry]? = nil
    ) -> [MediaRating] {
        var meta = PlexMetadata()
        meta.rating = rating
        meta.ratingImage = ratingImage
        meta.audienceRating = audience
        meta.audienceRatingImage = audienceImage
        meta.Rating = entries
        return PlexMediaMapper.ratings(meta)
    }

    private func jellyfin(_ fields: String) -> [MediaRating] {
        let json = #"{"Id":"m1","Name":"M","Type":"Movie"\#(fields)}"#
        return JellyfinMediaMapper.detail(
            JellyfinFixtures.decode(json), nextEpisode: nil,
            providerID: "jellyfin:srv", baseURL: JellyfinFixtures.baseURL, token: "t"
        ).ratings
    }

    private func texts(_ r: [MediaRating]) -> [String] {
        r.map { "\($0.name) \($0.badgeText)\($0.scale ?? "")" }
    }

    // MARK: - Plex

    /// The Matrix on PMS 1.43.4: the full `Rating` array beats the flat pair.
    func test_plex_ratingArray_allSourcesInOrder() {
        let r = plex(audience: 8.3, audienceImage: "themoviedb://image.rating", entries: [
            PlexRatingEntry(image: "imdb://image.rating", value: 8.7, type: "audience"),
            PlexRatingEntry(image: "rottentomatoes://image.rating.ripe", value: 8.3, type: "critic"),
            PlexRatingEntry(image: "rottentomatoes://image.rating.upright", value: 8.5, type: "audience"),
            PlexRatingEntry(image: "themoviedb://image.rating", value: 8.26, type: "audience"),
        ])
        XCTAssertEqual(texts(r), ["Rotten Tomatoes 83%", "RT Audience 85%", "IMDb 8.7/10", "TMDB 8.3/10"])
    }

    /// Hub items carry only the flat pair.
    func test_plex_flatPair_criticAndAudience() {
        let r = plex(rating: 8.9, ratingImage: "rottentomatoes://image.rating.ripe",
                     audience: 9.1, audienceImage: "rottentomatoes://image.rating.upright")
        XCTAssertEqual(texts(r), ["Rotten Tomatoes 89%", "RT Audience 91%"])
    }

    func test_plex_legacyRatingWithoutImage_isUnknownSource() {
        XCTAssertEqual(texts(plex(rating: 8.6)), ["Rating 8.6/10"])
    }

    func test_plex_nothing_isEmpty() {
        XCTAssertTrue(plex().isEmpty)
    }

    func test_zeroScore_isDropped() {
        XCTAssertTrue(plex(rating: 0, audience: 0, audienceImage: "themoviedb://image.rating").isEmpty)
    }

    // MARK: - Jellyfin

    func test_jellyfin_criticAndCommunity() {
        let r = jellyfin(#","CommunityRating":7.5,"CriticRating":89"#)
        XCTAssertEqual(texts(r), ["Rotten Tomatoes 89%", "Rating 7.5/10"])
    }

    func test_jellyfin_nothing_isEmpty() {
        XCTAssertTrue(jellyfin("").isEmpty)
    }

    // MARK: - Merge and Worker

    func test_ordered_providerWinsPerSource_unknownDroppedOnceNamed() {
        let r = MediaRating.ordered([
            MediaRating(7.5, source: .unknown),
            MediaRating(8.7, source: .imdb),
            MediaRating(9.0, source: .imdb),
        ])
        XCTAssertEqual(texts(r), ["IMDb 8.7/10"])
    }

    /// The Worker's response for The Matrix, native scales.
    func test_worker_decode_nativeScales() {
        let json = #"{"ratings":[{"source":"imdb","value":8.7},{"source":"metacritic","value":73},{"source":"tomatoes","value":83,"fresh":true},{"source":"popcorn","value":85},{"source":"tmdb","value":82},{"source":"letterboxd","value":4.2},{"source":"trakt","value":87}]}"#
        XCTAssertEqual(texts(RatingsClient.decode(Data(json.utf8))), [
            "Rotten Tomatoes 83%", "RT Audience 85%", "IMDb 8.7/10",
            "Metacritic 73/100", "Letterboxd 4.2/5", "TMDB 8.2/10",
        ])
    }

    func test_worker_decode_garbage_isEmpty() {
        XCTAssertTrue(RatingsClient.decode(Data("nope".utf8)).isEmpty)
    }

    // MARK: - Focused poster badge

    /// Runs `body` with Settings > Appearance > Rating set to `source`, then restores it.
    private func withDetailSource(_ source: MediaRating.Source, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: MediaRating.detailSourceKey)
        defaults.set(source.rawValue, forKey: MediaRating.detailSourceKey)
        defer { defaults.set(saved, forKey: MediaRating.detailSourceKey) }
        body()
    }

    /// Hub items carry only Plex's flat pair; the badge reads the same list data.
    func test_posterBadge_chosenSource() {
        let ratings = plex(rating: 8.3, ratingImage: "rottentomatoes://image.rating.ripe",
                           audience: 7.6, audienceImage: "imdb://image.rating")
        withDetailSource(.imdb) {
            XCTAssertEqual(MediaRating.posterRating(in: ratings)?.posterLine, "IMDb 7.6")
        }
    }

    /// Without the chosen source the poster shows the score the list has, named.
    func test_posterBadge_chosenSourceMissing_fallsBackToANamedScore() {
        let ratings = plex(rating: 8.3, ratingImage: "rottentomatoes://image.rating.ripe")
        withDetailSource(.imdb) {
            XCTAssertEqual(MediaRating.posterRating(in: ratings)?.posterLine, "🍅 83%")
            XCTAssertEqual(MediaRating.detailRating(in: ratings)?.source, .rottenTomatoes)
        }
    }

    /// Jellyfin's community score names no source, so a named choice shows nothing.
    func test_posterBadge_jellyfinUnnamedScore_showsNothing() {
        withDetailSource(.imdb) {
            XCTAssertNil(MediaRating.posterRating(in: jellyfin(#","CommunityRating":7.1"#))?.posterLine)
        }
    }

    func test_posterBadge_rottenTomatoesRotten_andAudience() {
        withDetailSource(.rottenTomatoes) {
            XCTAssertEqual(MediaRating.posterRating(in: plex(rating: 4.1, ratingImage: "rottentomatoes://image.rating.rotten"))?.posterLine,
                           "🤢 41%")
        }
        withDetailSource(.rottenTomatoesAudience) {
            XCTAssertEqual(MediaRating.posterRating(in: plex(audience: 9.2, audienceImage: "rottentomatoes://image.rating.upright"))?.posterLine,
                           "🍿 92%")
        }
    }

    /// A Plex TV library carries only TMDB: with IMDb chosen, a show still shows its score.
    func test_posterBadge_tvLibrary_showsTMDB_noScoreShowsNothing() {
        withDetailSource(.imdb) {
            XCTAssertEqual(MediaRating.posterRating(in: plex(audience: 7.6, audienceImage: "themoviedb://image.rating"))?.posterLine,
                           "TMDB 7.6")
            XCTAssertNil(MediaRating.posterRating(in: [])?.posterLine)
        }
    }

    /// The one home of the glyph rule, shared by the detail row and the poster badge.
    func test_glyph_rottenTomatoesOnly_freshFromSixUp() {
        XCTAssertEqual(MediaRating(6.0, source: .rottenTomatoes)?.glyph, "🍅")
        XCTAssertEqual(MediaRating(5.9, source: .rottenTomatoes)?.glyph, "🤢")
        XCTAssertEqual(MediaRating(9.2, source: .rottenTomatoesAudience)?.glyph, "🍿")
        XCTAssertNil(MediaRating(7.6, source: .imdb)?.glyph)
        XCTAssertNil(MediaRating(7.3, source: .metacritic)?.glyph)
    }

    /// The chosen source wins; a source lists never carry falls back to the list's first named score.
    func test_posterRating_chosenFirst_thenTheListsOwn() {
        let ratings = plex(rating: 8.3, ratingImage: "rottentomatoes://image.rating.ripe",
                           audience: 7.6, audienceImage: "imdb://image.rating")
        withDetailSource(.imdb) { XCTAssertEqual(MediaRating.posterRating(in: ratings)?.source, .imdb) }
        withDetailSource(.metacritic) { XCTAssertEqual(MediaRating.posterRating(in: ratings)?.source, .rottenTomatoes) }
    }

    /// MediaItem caches to disk: a list item's scores survive the round trip.
    func test_mediaRating_codableRoundTrip() throws {
        let ratings = [MediaRating(7.6, source: .imdb)!, MediaRating(8.3, source: .rottenTomatoes)!]
        let data = try JSONEncoder().encode(ratings)
        XCTAssertEqual(try JSONDecoder().decode([MediaRating].self, from: data), ratings)
    }
}
