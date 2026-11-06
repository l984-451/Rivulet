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

    func test_plex_certifiedMarkRetainsEvidenceInFullAndFlatMetadata() {
        let image = "rottentomatoes://image.rating.certified"
        let full = plex(rating: 9.9, ratingImage: "rottentomatoes://image.rating.ripe", entries: [
            PlexRatingEntry(image: image, value: 8.3, type: "critic"),
        ]).first
        XCTAssertEqual(full?.value, 8.3)
        XCTAssertEqual(full?.rottenTomatoesDesignation, .certifiedFresh)
        XCTAssertEqual(full?.rottenTomatoesStatus, .certifiedFresh)
        XCTAssertEqual(full?.plexRatingImage, image)
        XCTAssertEqual(plex(rating: 8.3, ratingImage: image).first?.rottenTomatoesStatus, .certifiedFresh)
    }

    func test_plex_fullOrdinaryMarkWinsOverFlatCertifiedMark() {
        let ratings = plex(rating: 9.9, ratingImage: "rottentomatoes://image.rating.certified", entries: [
            PlexRatingEntry(image: "rottentomatoes://image.rating.ripe", value: 8.3, type: "critic"),
        ])
        XCTAssertEqual(ratings.first?.rottenTomatoesStatus, .fresh)
        XCTAssertNil(ratings.first?.rottenTomatoesDesignation)
    }

    func test_plex_certifiedMarkCannotUpgradeAudienceOrUnknownMarks() {
        XCTAssertEqual(plex(audience: 9.9, audienceImage: "rottentomatoes://image.rating.certified")
            .first?.rottenTomatoesStatus, .hot)
        XCTAssertEqual(plex(rating: 9.9, ratingImage: "rottentomatoes://image.rating.certified-unrecognized")
            .first?.rottenTomatoesStatus, .fresh)
    }

    func test_rottenTomatoesOrdinaryThresholdsDoNotInventAwards() {
        let cases: [(MediaRating.Source, MediaRating.RottenTomatoesStatus, MediaRating.RottenTomatoesStatus)] = [
            (.rottenTomatoes, .rotten, .fresh),
            (.rottenTomatoesAudience, .stale, .hot),
        ]
        for (source, low, high) in cases {
            XCTAssertEqual(MediaRating(5.99, source: source)?.rottenTomatoesStatus, low)
            XCTAssertEqual(MediaRating(6, source: source)?.rottenTomatoesStatus, high)
            XCTAssertEqual(MediaRating(10, source: source)?.rottenTomatoesStatus, high)
        }
    }

    func test_officialAwardsRequireMatchingRatingFamily() {
        let critic = MediaRating(8, source: .rottenTomatoes, rottenTomatoesDesignation: .certifiedFresh)
        let audience = MediaRating(9.5, source: .rottenTomatoesAudience, rottenTomatoesDesignation: .verifiedHot)
        let wrongCritic = MediaRating(9.5, source: .rottenTomatoes, rottenTomatoesDesignation: .verifiedHot)
        let wrongAudience = MediaRating(9.5, source: .rottenTomatoesAudience, rottenTomatoesDesignation: .certifiedFresh)
        let unrelated = MediaRating(9.5, source: .imdb, rottenTomatoesDesignation: .certifiedFresh)
        XCTAssertEqual(critic?.rottenTomatoesStatus, .certifiedFresh)
        XCTAssertEqual(audience?.rottenTomatoesStatus, .verifiedHot)
        XCTAssertEqual(wrongCritic?.rottenTomatoesStatus, .fresh)
        XCTAssertEqual(wrongAudience?.rottenTomatoesStatus, .hot)
        XCTAssertNil(unrelated?.rottenTomatoesStatus)
    }

    func test_nativeScoreAndDisplayCannotEstablishOfficialAward() throws {
        let json = """
        {"content_id":"rt-title","type":"movie","title":"Title","ratings":[
          {"source":"rt_critic","name":"RT","score":99,"display":"99%"},
          {"source":"rt_audience","name":"RT Audience","score":99,"display":"99%"}
        ]}
        """
        let dto = try SiloJSON.decoder().decode(SiloItem.self, from: Data(json.utf8))
        let detail = SiloMediaMapper.detail(dto, providerID: "silo:test", baseURL: URL(string: "https://silo.invalid")!)
        XCTAssertEqual(detail.ratings.map(\.rottenTomatoesStatus), [.fresh, .hot])
        XCTAssertTrue(detail.ratings.allSatisfy { $0.rottenTomatoesDesignation == nil })
        XCTAssertEqual(detail.ratings.map(\.badgeText), ["99%", "99%"])
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

    func test_preferredDetailScoreStillUsesAppearanceAndCriticFallbackOnly() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: MediaRating.detailSourceKey)
        defer {
            if let previous { defaults.set(previous, forKey: MediaRating.detailSourceKey) }
            else { defaults.removeObject(forKey: MediaRating.detailSourceKey) }
        }
        let ratings = [MediaRating(8.5, source: .imdb), MediaRating(9, source: .rottenTomatoes)].compactMap { $0 }
        defaults.set(MediaRating.Source.imdb.rawValue, forKey: MediaRating.detailSourceKey)
        XCTAssertEqual(MediaRating.detailRating(in: ratings)?.source, .imdb)
        defaults.set(MediaRating.Source.letterboxd.rawValue, forKey: MediaRating.detailSourceKey)
        XCTAssertEqual(MediaRating.detailRating(in: ratings)?.source, .rottenTomatoes)
        XCTAssertNil(MediaRating.detailRating(in: ratings.filter { $0.source == .imdb }))
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
}
