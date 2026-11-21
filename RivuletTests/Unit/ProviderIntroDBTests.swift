// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import XCTest
@testable import Rivulet

/// IntroDB for Jellyfin and Emby episodes (`ProviderIntroDB`).
final class ProviderIntroDBTests: XCTestCase {

    private let key = ProviderIntroDB.EpisodeKey(seriesIMDbID: "tt7587890", season: 8, episode: 12)

    private func plexMarker(_ type: String, _ start: Int, _ end: Int) -> PlexMarker {
        PlexMarker(id: -1, type: type, startTimeOffset: start * 1000, endTimeOffset: end * 1000)
    }

    private var community: [PlexMarker] {
        [plexMarker("recap", 0, 47), plexMarker("intro", 362, 367), plexMarker("credits", 2543, 2589)]
    }

    func test_fillsEveryMissingKind() async {
        let found = community
        let markers = await ProviderIntroDB.filling([], enabled: true, episode: { self.key }, lookup: { _, _, _ in found })
        XCTAssertEqual(Set(markers.map(\.kind)), [.recap, .intro, .credits])
        XCTAssertEqual(markers.first { $0.kind == .credits }?.start, 2543)
    }

    func test_serverMarkersWin() async {
        let found = community
        let server = [PlaybackMarker(kind: .credits, start: 2500, end: 2589)]
        let markers = await ProviderIntroDB.filling(server, enabled: true, episode: { self.key }, lookup: { _, _, _ in found })
        XCTAssertEqual(markers.filter { $0.kind == .credits }, server)
        XCTAssertEqual(markers.count, 3)
    }

    func test_offAsksNothing() async {
        var asked = false
        let markers = await ProviderIntroDB.filling([], enabled: false, episode: { asked = true; return self.key },
                                                    lookup: { _, _, _ in [] })
        XCTAssertTrue(markers.isEmpty)
        XCTAssertFalse(asked)
    }

    func test_completeServerMarkersAskNothing() async {
        var asked = false
        let server = [PlaybackMarker(kind: .intro, start: 1, end: 2), PlaybackMarker(kind: .recap, start: 0, end: 1),
                      PlaybackMarker(kind: .credits, start: 9, end: 10)]
        let markers = await ProviderIntroDB.filling(server, enabled: true, episode: { asked = true; return self.key },
                                                    lookup: { _, _, _ in [] })
        XCTAssertEqual(markers, server)
        XCTAssertFalse(asked)
    }

    func test_noEpisodeKeyLeavesMarkers() async {
        let markers = await ProviderIntroDB.filling([], enabled: true, episode: { nil }, lookup: { _, _, _ in XCTFail(); return [] })
        XCTAssertTrue(markers.isEmpty)
    }

    func test_imdbIDKeyCaseDoesNotMatter() {
        XCTAssertEqual(ProviderIntroDB.imdbID(in: ["Imdb": "tt1"]), "tt1")
        XCTAssertEqual(ProviderIntroDB.imdbID(in: ["IMDB": "tt2"]), "tt2")
        XCTAssertNil(ProviderIntroDB.imdbID(in: ["Tmdb": "1"]))
        XCTAssertNil(ProviderIntroDB.imdbID(in: ["Imdb": ""]))
        XCTAssertNil(ProviderIntroDB.imdbID(in: nil))
    }
}
