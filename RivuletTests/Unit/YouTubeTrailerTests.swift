// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class YouTubeTrailerTests: XCTestCase {
    private func id(_ string: String) -> String? {
        URL(string: string).flatMap(YouTubeTrailer.videoID(from:))
    }

    func test_videoID_readsEveryYouTubeLinkShape() {
        XCTAssertEqual(id("https://www.youtube.com/watch?v=aqz-KE-bpKQ"), "aqz-KE-bpKQ")
        XCTAssertEqual(id("http://youtube.com/watch?feature=share&v=aqz-KE-bpKQ"), "aqz-KE-bpKQ")
        XCTAssertEqual(id("https://m.youtube.com/watch?v=aqz-KE-bpKQ"), "aqz-KE-bpKQ")
        XCTAssertEqual(id("https://youtu.be/aqz-KE-bpKQ"), "aqz-KE-bpKQ")
        XCTAssertEqual(id("https://www.youtube.com/embed/aqz-KE-bpKQ"), "aqz-KE-bpKQ")
    }

    func test_videoID_rejectsOtherHostsAndBadIDs() {
        XCTAssertNil(id("https://vimeo.com/watch?v=aqz-KE-bpKQ"))
        XCTAssertNil(id("https://www.youtube.com/watch?v=short"))
        XCTAssertNil(id("https://www.youtube.com/watch"))
        // A Plex trailer is a file on the server: no YouTube button.
        XCTAssertNil(id("http://192.168.1.2:32400/library/metadata/123"))
        XCTAssertNil(id("https://notyoutube.com/watch?v=aqz-KE-bpKQ"))
    }

    func test_firstLink_skipsNonYouTubeAndEmpty() {
        let link = YouTubeTrailer.firstLink([nil, "", "https://vimeo.com/1", "https://youtu.be/aqz-KE-bpKQ"])
        XCTAssertEqual(link?.absoluteString, "https://youtu.be/aqz-KE-bpKQ")
        XCTAssertNil(YouTubeTrailer.firstLink([]))
    }

    func test_appURL_opensTheYouTubeApp() {
        XCTAssertEqual(YouTubeTrailer.appURL(videoID: "aqz-KE-bpKQ")?.absoluteString, "youtube://watch/aqz-KE-bpKQ")
    }

    private func detail(trailer: String?, extras: [MediaItemDetail.Extra]) -> MediaItemDetail {
        let item = MediaItem(
            ref: MediaItemRef(providerID: "jellyfin:x", itemID: "m"), kind: .movie, title: "M",
            sortTitle: nil, overview: nil, year: nil, runtime: nil, parentRef: nil, grandparentRef: nil,
            episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: URL(string: "https://x/b.jpg"), thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil)
        var d = MediaItemDetail(
            item: item, tagline: nil, genres: [], studios: [], cast: [], directors: [], writers: [], chapters: [],
            mediaSources: [], trailerURL: trailer.flatMap(URL.init(string:)), contentRating: nil,
            nextEpisode: nil, collections: [])
        d.extras = extras
        return d
    }

    private func extra(_ subtype: ExtraSubtype) -> MediaItemDetail.Extra {
        MediaItemDetail.Extra(id: "e", title: "E", thumbnailURL: nil, duration: nil, playbackKey: "e",
                              providerID: "jellyfin:x", subtype: subtype)
    }

    @MainActor func test_youTubeTile_onlyWhenNoLocalTrailer() {
        let link = "https://youtu.be/aqz-KE-bpKQ"
        let without = detail(trailer: link, extras: [extra(.featurette)])
        let tiles = BelowFoldContentLoader.extraTiles(
            from: without.extras, fallbackArt: without.item.artwork.backdrop,
            youTubeVideoID: without.youTubeTrailerID, providerID: "jellyfin:x")
        XCTAssertEqual(tiles.trailers.map(\.youTubeVideoID), ["aqz-KE-bpKQ"])
        XCTAssertEqual(tiles.trailers.first?.artworkURL?.absoluteString, "https://x/b.jpg")
        XCTAssertEqual(tiles.extras.count, 1)

        let with = detail(trailer: link, extras: [extra(.trailer)])
        XCTAssertNil(with.youTubeTrailerID)
        XCTAssertNil(detail(trailer: nil, extras: []).youTubeTrailerID)
        XCTAssertNil(detail(trailer: "http://192.168.1.2:32400/x", extras: []).youTubeTrailerID)
    }
}
