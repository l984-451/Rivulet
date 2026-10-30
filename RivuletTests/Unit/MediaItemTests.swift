// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaItemTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class MediaItemTests: XCTestCase {
    func test_sameCatalogItemInDifferentSiloProfilesHasDistinctGridIdentity() {
        let url = URL(string: "https://silo.invalid")!
        let parent = SiloProvider(serverID: "server", displayName: "Silo", profileID: "parent",
                                  client: SiloClient(baseURL: url, profileID: "parent"))
        let child = SiloProvider(serverID: "server", displayName: "Silo", profileID: "child",
                                 client: SiloClient(baseURL: url, profileID: "child"))
        let parentItem = JellyfinFixtures.mediaItem("same-content", providerID: parent.id)
        let childItem = JellyfinFixtures.mediaItem("same-content", providerID: child.id)
        XCTAssertEqual(Set([parentItem.id, childItem.id]).count, 2)
    }

    func test_loadingMovieAndShowLockupsUsePosterInsteadOfLandscapeThumb() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let poster = "https://images.invalid/poster/w1000.webp?signature=opaque%2Bposter&expires=123"
        let thumb = "https://images.invalid/thumb/w300.webp?signature=opaque%2Bthumb&expires=123"
        for type in ["movie", "series"] {
            let dto = try decoder.decode(SiloItem.self, from: Data("""
            {"content_id":"item","type":"\(type)","title":"Title",
             "poster_url":"\(poster)","thumb_url":"\(thumb)"}
            """.utf8))
            let item = SiloMediaMapper.item(dto, providerID: "silo:server:profile",
                                            baseURL: URL(string: "https://silo.invalid")!)

            let request = item.heroBackdropRequest()

            XCTAssertEqual(request.thumbnailURL?.absoluteString, poster,
                           "The portrait loading lockup must not crop and enlarge the landscape thumb")
            XCTAssertEqual(item.artwork.thumbnail?.absoluteString, thumb,
                           "Wide consumers still retain the native landscape artwork")
        }
    }

    func test_loadingEpisodeLockupRetainsItsOwnStillAndSignedResource() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let still = "https://images.invalid/still/original.webp?signature=opaque%2Bstill&expires=123"
        let dto = try decoder.decode(SiloItem.self, from: Data("""
        {"content_id":"episode","type":"episode","title":"Episode",
         "poster_url":"https://images.invalid/season/w1000.webp","still_url":"\(still)"}
        """.utf8))
        let item = SiloMediaMapper.item(dto, providerID: "silo:server:profile",
                                        baseURL: URL(string: "https://silo.invalid")!)

        XCTAssertEqual(item.heroBackdropRequest().thumbnailURL?.absoluteString, still)
        XCTAssertEqual(item.artwork.poster?.path, "/season/w1000.webp",
                       "The episode still must not displace the native portrait catalog poster")
    }

}
