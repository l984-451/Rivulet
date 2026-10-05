// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class PlayerVersionSelectionTests: XCTestCase {

    /// Sweeney Todd with its SD file listed first, as a server might.
    private func sweeneyTodd(withMedia: Bool = true) throws -> PlexMetadata {
        let media = withMedia ? """
        ,"Media":[
         {"id":22249,"videoResolution":"sd","height":336,"bitrate":695,
          "Part":[{"id":2,"key":"/library/parts/2/b.avi","Stream":[{"id":21,"streamType":1,"codec":"mpeg4","height":336}]}]},
         {"id":260721,"videoResolution":"1080","height":1080,"bitrate":6564,
          "Part":[{"id":1,"key":"/library/parts/1/a.mkv","Stream":[{"id":11,"streamType":1,"codec":"hevc","height":1080}]}]}]
        """ : ""
        let json = #"{"ratingKey":"14675","type":"movie","title":"Sweeney Todd""# + media + "}"
        return try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
    }

    private func viewModel(_ metadata: PlexMetadata, picked: String? = nil) -> UniversalPlayerViewModel {
        UniversalPlayerViewModel(metadata: metadata, serverURL: "http://plex.local:32400", authToken: "t",
                                 preferredMediaID: picked)
    }

    func test_init_playsTheBestVersion() throws {
        let vm = viewModel(try sweeneyTodd())
        XCTAssertEqual(vm.metadata.Media?.first?.id, 260721)
        XCTAssertEqual(vm.playingMediaID, "260721")
    }

    func test_init_recordsTheServerIndexOfTheBestVersion() throws {
        // The HLS fallback sends this as mediaIndex; it must be the server's position.
        XCTAssertEqual(viewModel(try sweeneyTodd()).playingMediaServerIndex, 1)
    }

    func test_init_pickedVersionWins() throws {
        let vm = viewModel(try sweeneyTodd(), picked: "22249")
        XCTAssertEqual(vm.metadata.Media?.first?.id, 22249)
        XCTAssertEqual(vm.playingMediaServerIndex, 0)
    }

    func test_init_withoutMedia_keepsThePickedID() throws {
        let vm = viewModel(try sweeneyTodd(withMedia: false), picked: "22249")
        XCTAssertEqual(vm.playingMediaID, "22249")
    }

    // Up Next must not ratchet down: without a pick, every episode gets its best file.
    func test_upNext_withoutAPick_playsTheBest() throws {
        XCTAssertEqual(viewModel(try sweeneyTodd()).upNextVersionChoice(), .best)
    }

    func test_upNext_afterAPick_keepsThePickedTier() throws {
        XCTAssertEqual(viewModel(try sweeneyTodd(), picked: "22249").upNextVersionChoice(), .matchingTier(480))
    }

    private func providerViewModel(picked: String?) -> UniversalPlayerViewModel {
        let source = MediaSource(id: "hd", container: "mkv", duration: 100, bitrate: nil, fileSize: nil,
                                 fileName: nil, videoResolution: "1080", videoTracks: [], audioTracks: [],
                                 subtitleTracks: [], streamKind: .directPlay,
                                 streamURL: URL(string: "http://media.local/Videos/m1/stream"))
        let item = JellyfinFixtures.mediaItem("m1")
        let detail = MediaItemDetail(
            item: item, tagline: nil, genres: [], studios: [], cast: [], directors: [], writers: [],
            chapters: [], mediaSources: [source], trailerURL: nil, contentRating: nil, rating: nil,
            nextEpisode: nil, collections: [])
        let playback = ProviderPlayback(
            provider: StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin), item: item, detail: detail,
            stream: StreamInfo(source: source, playSessionID: nil, trackInfoAvailable: true),
            extras: PlaybackExtras())
        return UniversalPlayerViewModel(providerPlayback: playback, startOffset: nil, preferredMediaID: picked)
    }

    func test_upNext_provider_followsThePickOnly() {
        XCTAssertEqual(providerViewModel(picked: nil).upNextVersionChoice(), .best)
        XCTAssertEqual(providerViewModel(picked: "hd").upNextVersionChoice(), .matchingTier(1080))
    }
}
