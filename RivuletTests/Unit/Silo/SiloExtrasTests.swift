// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class SiloExtrasTests: XCTestCase {
    func test_nativeDetailShowsLocalAndRemoteVideosAndLocalSelectionResolvesTheExtra() async throws {
        let server = SiloAuthTestServer()
        await server.respond("GET", "/api/v2/catalog/items/movie-a", [.init(body: """
        {"content_id":"movie-a","type":"movie","title":"A Movie",
         "extras":[
           {"content_id":"extra-trailer","kind":"trailer","title":"Local Trailer","duration_seconds":120,"file_id":81},
           {"content_id":"extra-making-of","kind":"behind_the_scenes","title":"Making Of","duration_seconds":360,"file_id":82,"still_url":"/api/v2/images/extra-still"}
         ],
         "videos":[
           {"kind":"trailer","site":"YouTube","site_key":"dQw4w9WgXcQ","name":"Official Trailer","is_official":true},
           {"kind":"teaser","site":"vimeo","site_key":"123456","name":"Teaser","is_official":false},
           {"kind":"clip","site":"youtube","site_key":"bbbbbbbbbbb","name":"A Clip","is_official":false}
         ]}
        """)])
        await server.respond("GET", "/api/v2/recommendations/similar/movie-a", [.init(body: #"{"items":[]}"#)])
        await server.respond("GET", "/api/v2/catalog/items/extra-making-of", [.init(body: """
        {"content_id":"extra-making-of","type":"extra","title":"Making Of",
         "versions":[{"file_id":"82","resolution":"1080p","codec_video":"h264","codec_audio":"aac",
          "hdr":false,"container":"mp4","file_size":1200000,"bitrate":1000,"duration_seconds":360}]}
        """)])
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid")!, transport: server.transport)
        let provider = SiloProvider(serverID: "extras-server", displayName: "Silo", profileID: "extras-profile", client: client)
        MediaProviderRegistry.shared.register(provider)
        defer { MediaProviderRegistry.shared.unregister(providerID: provider.id) }

        let detail = try await provider.fullDetail(for: MediaItemRef(providerID: provider.id, itemID: "movie-a"))
        let content = await BelowFoldContentLoader().load(for: detail.item, detail: detail)

        XCTAssertEqual(content.trailers.map(\.title), ["Local Trailer", "Official Trailer", "Teaser"])
        XCTAssertEqual(content.extras.map(\.title), ["Making Of", "A Clip"])
        XCTAssertEqual(content.extras.first?.subtype, .behindTheScenes)
        XCTAssertEqual(content.extras.first?.artworkURL?.path, "/api/v2/images/extra-still")
        XCTAssertEqual(content.extras.first?.durationFormatted, "6m")
        XCTAssertNil(content.trailers.first?.externalURL, "Local media must stay on the native negotiated player")
        XCTAssertEqual(content.trailers[1].externalURL?.host, "www.youtube.com")
        XCTAssertEqual(content.trailers[2].externalURL?.host, "vimeo.com")
        XCTAssertNil(detail.trailerURL, "A watch page is not a playable media URL")

        let selected = try XCTUnwrap(content.extras.first)
        let playbackRef = MediaItemRef(providerID: selected.providerID, itemID: try XCTUnwrap(selected.playbackKey))
        let selectedDetail = try await provider.fullDetail(for: playbackRef)
        XCTAssertEqual(selectedDetail.item.title, "Making Of", "Selecting an extra must not play the parent movie")
        XCTAssertEqual(selectedDetail.mediaSources.first?.id, "82")
        XCTAssertEqual(selectedDetail.mediaSources.first?.duration, 360)
    }

    func test_nativeKindsSplitTrailersFromOtherExtrasWithoutPlexSpelling() throws {
        let dto = try SiloJSON.decoder().decode(SiloItem.self, from: Data("""
        {"content_id":"movie-a","title":"A Movie","extras":[
          {"content_id":"1","kind":"trailer"}, {"content_id":"2","kind":"teaser"},
          {"content_id":"3","kind":"featurette"}, {"content_id":"4","kind":"clip"},
          {"content_id":"5","kind":"behind_the_scenes"}, {"content_id":"6","kind":"bloopers"},
          {"content_id":"7","kind":"deleted_scene"}, {"content_id":"8","kind":"other"}
        ]}
        """.utf8))
        let detail = SiloMediaMapper.detail(dto, providerID: "silo:test", baseURL: URL(string: "https://silo.invalid")!)
        XCTAssertEqual(detail.extras.filter(\.isTrailer).map(\.id), ["1", "2"])
        XCTAssertEqual(detail.extras.filter { !$0.isTrailer }.count, 6)
        XCTAssertEqual(detail.extras[3].subtype, .scene)
        XCTAssertEqual(detail.extras[4].subtype, .behindTheScenes)
        XCTAssertEqual(detail.extras[6].subtype, .deletedScene)
        XCTAssertTrue(detail.extras.allSatisfy { $0.playbackKey == $0.id && $0.externalURL == nil })
    }

    func test_absentNativeMediaDoesNotInventTrailersOrExtras() throws {
        let dto = try SiloJSON.decoder().decode(SiloItem.self, from: Data(#"{"content_id":"movie-a","title":"A Movie"}"#.utf8))
        let detail = SiloMediaMapper.detail(dto, providerID: "silo:test", baseURL: URL(string: "https://silo.invalid")!)
        XCTAssertTrue(detail.extras.isEmpty)
        XCTAssertNil(detail.trailerURL)
    }

    func test_remoteWatchPagesNeverBecomeLocalPlaybackKeysOrArbitraryStreamURLs() throws {
        let dto = try SiloJSON.decoder().decode(SiloItem.self, from: Data("""
        {"content_id":"movie-a","title":"A Movie","videos":[
          {"kind":"trailer","site":"youtube","site_key":"dQw4w9WgXcQ"},
          {"kind":"clip","site":"YouTube","site_key":"dQw4w9WgXcQ"},
          {"kind":"featurette","site":"vimeo","site_key":"123456"},
          {"kind":"trailer","site":"unknown","site_key":"https://untrusted.invalid/video.mp4"}
        ]}
        """.utf8))
        let detail = SiloMediaMapper.detail(dto, providerID: "silo:test", baseURL: URL(string: "https://silo.invalid")!)
        XCTAssertEqual(detail.extras.count, 2, "Duplicate hosted videos and unsupported sites must not become unplayable tiles")
        XCTAssertTrue(detail.extras.allSatisfy { $0.externalURL?.scheme == "https" && $0.playbackKey == nil })
        XCTAssertEqual(detail.extras.map { $0.externalURL?.host }, ["www.youtube.com", "vimeo.com"])
    }
}
