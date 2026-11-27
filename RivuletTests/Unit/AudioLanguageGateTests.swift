// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  AudioLanguageGateTests.swift
//  RivuletTests
//
//  Only My Audio Language: the gate, and each server's answer to "does it have this language".
//  The gate's answers live in the test host's UserDefaults; they are cleared around each test.
//

import XCTest
@testable import Rivulet

@MainActor
final class AudioLanguageGateTests: XCTestCase {

    private func item(_ id: String, kind: MediaKind = .movie, provider: String = "stub") -> MediaItem {
        MediaItem(ref: MediaItemRef(providerID: provider, itemID: id), kind: kind, title: id, sortTitle: nil,
                  overview: nil, year: nil, runtime: nil, parentRef: nil, grandparentRef: nil,
                  episodeNumber: nil, seasonNumber: nil, childProgress: nil,
                  userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
                  artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
                  parentArtwork: nil, grandparentArtwork: nil)
    }

    private var existingEnabled: Any?

    override func setUp() async throws {
        try await super.setUp()
        existingEnabled = UserDefaults.standard.object(forKey: AudioLanguageGate.enabledKey)
        AudioLanguageGate.forgetAnswers()
    }

    override func tearDown() async throws {
        AudioLanguageGate.forgetAnswers()
        UserDefaults.standard.set(existingEnabled, forKey: AudioLanguageGate.enabledKey)
        try await super.tearDown()
    }

    // MARK: - The gate

    func test_offByDefault() {
        UserDefaults.standard.removeObject(forKey: AudioLanguageGate.enabledKey)
        XCTAssertNil(AudioLanguageGate.language)
    }

    func test_noLanguage_keepsEverything_andAsksNothing() async {
        let stub = StubMediaProvider()
        stub.audioAnswers = [item("1").ref: false]
        let kept = await AudioLanguageGate.filter([item("1")], language: nil, providerFor: { _ in stub })
        XCTAssertEqual(kept.map(\.ref.itemID), ["1"])
        XCTAssertTrue(stub.audioAsks.isEmpty)
    }

    func test_dropsTitlesWithoutTheLanguage_keepsUnknownOnes() async {
        let stub = StubMediaProvider()
        stub.audioAnswers = [item("dubbed").ref: true, item("subbed").ref: false]
        let kept = await AudioLanguageGate.filter([item("dubbed"), item("subbed"), item("unknown")],
                                                  language: "deu", providerFor: { _ in stub })
        XCTAssertEqual(kept.map(\.ref.itemID), ["dubbed", "unknown"])
    }

    func test_aKnownAnswer_isNotAskedAgain_whileFresh() async {
        let stub = StubMediaProvider()
        stub.audioAnswers = [item("1").ref: false]
        let now = Date()
        _ = await AudioLanguageGate.filter([item("1")], language: "deu", now: now, providerFor: { _ in stub })
        let kept = await AudioLanguageGate.filter([item("1"), item("2")], language: "deu",
                                                  now: now.addingTimeInterval(60), providerFor: { _ in stub })
        XCTAssertEqual(kept.map(\.ref.itemID), ["2"])
        XCTAssertEqual(stub.audioAsks, [["1"], ["2"]], "only the new title is asked")
    }

    func test_aStaleAnswer_isUsed_andAskedAgainBehind() async throws {
        let stub = StubMediaProvider()
        stub.audioAnswers = [item("1").ref: false]
        let then = Date().addingTimeInterval(-2 * AudioLanguageGate.lifetime)
        _ = await AudioLanguageGate.filter([item("1")], language: "deu", now: then, providerFor: { _ in stub })
        stub.audioAnswers = [item("1").ref: true]   // dubbed since

        let first = await AudioLanguageGate.filter([item("1")], language: "deu", providerFor: { _ in stub })
        XCTAssertEqual(first, [], "the old answer stands until the new one is in")
        for _ in 0..<50 where stub.audioAsks.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        let second = await AudioLanguageGate.filter([item("1")], language: "deu", providerFor: { _ in stub })
        XCTAssertEqual(second.map(\.ref.itemID), ["1"])
    }

    func test_answersAreKeptPerLanguage() async {
        let stub = StubMediaProvider()
        stub.audioAnswers = [item("1").ref: false]
        _ = await AudioLanguageGate.filter([item("1")], language: "deu", providerFor: { _ in stub })
        _ = await AudioLanguageGate.filter([item("1")], language: "eng", providerFor: { _ in stub })
        XCTAssertEqual(stub.audioAsks.count, 2)
    }

    // MARK: - Emby

    func test_emby_readsMoviesInOneRequest_andShowsByNextUp() async {
        let server = FakeEmbyServer()
        let uid = EmbyLiveFixtures.userID
        server.respond("/Users/\(uid)/Items", body: """
            {"Items":[
              {"Id":"m1","Name":"A","Type":"Movie","MediaSources":[{"MediaStreams":[{"Type":"Audio","Language":"ger"}]}]},
              {"Id":"m2","Name":"B","Type":"Movie","MediaSources":[{"MediaStreams":[{"Type":"Audio","Language":"jpn"}]}]},
              {"Id":"m3","Name":"C","Type":"Movie","MediaSources":[{"MediaStreams":[{"Type":"Video"}]}]}
            ],"TotalRecordCount":3}
            """)
        server.respond("/Shows/NextUp", query: ["SeriesId": "s1"], body: """
            {"Items":[{"Id":"e1","Name":"E","Type":"Episode",
              "MediaSources":[{"MediaStreams":[{"Type":"Audio","Language":"jpn"}]}]}],"TotalRecordCount":1}
            """)
        server.respond("/Shows/NextUp", query: ["SeriesId": "s2"], body: #"{"Items":[],"TotalRecordCount":0}"#)
        let emby = EmbyProvider(serverID: "srv", displayName: "Emby", userID: uid, policy: EmbySession.Policy(),
                                client: EmbyClient(baseURL: EmbyBrowseFixtures.baseURL, token: "tok",
                                                   transport: server.transport))
        let p = "emby:srv"
        let found = await emby.audioLanguageAvailability("deu", for: [
            item("m1", provider: p), item("m2", provider: p), item("m3", provider: p),
            item("s1", kind: .show, provider: p), item("s2", kind: .show, provider: p)])

        XCTAssertEqual(found[item("m1", provider: p).ref], true)
        XCTAssertEqual(found[item("m2", provider: p).ref], false)
        XCTAssertNil(found[item("m3", provider: p).ref], "no audio listed: unknown")
        XCTAssertEqual(found[item("s1", provider: p).ref], false, "the next episode decides")
        XCTAssertEqual(found[item("s2", provider: p).ref], true, "nothing left to watch")
        XCTAssertEqual(server.requests("GET", "/Users/\(uid)/Items").count, 1)
        XCTAssertEqual(server.headerProblems, [])
    }

    // MARK: - Jellyfin

    func test_jellyfin_readsMoviesInOneRequest_andShowsByNextUp() async {
        let server = FakeJellyfinServer()
        server.respond("/Items", body: """
            {"Items":[
              {"Id":"m1","Name":"A","Type":"Movie","MediaSources":[{"MediaStreams":[{"Type":"Audio","Language":"deu"}]}]},
              {"Id":"m2","Name":"B","Type":"Movie","MediaSources":[{"MediaStreams":[{"Type":"Audio","Language":"jpn"}]}]}
            ],"TotalRecordCount":2}
            """)
        server.respond("/Shows/NextUp", body: """
            {"Items":[{"Id":"e1","Name":"E","Type":"Episode",
              "MediaSources":[{"MediaStreams":[{"Type":"Audio","Language":"ger"}]}]}],"TotalRecordCount":1}
            """)
        let jellyfin = JellyfinProvider(serverID: "srv", displayName: "NAS", userID: "user-1",
                                        client: JellyfinClient(baseURL: JellyfinFixtures.baseURL, token: "tok",
                                                               transport: server.transport))
        let p = "jellyfin:srv"
        let found = await jellyfin.audioLanguageAvailability("deu", for: [
            item("m1", provider: p), item("m2", provider: p), item("s1", kind: .show, provider: p)])

        XCTAssertEqual(found[item("m1", provider: p).ref], true)
        XCTAssertEqual(found[item("m2", provider: p).ref], false)
        XCTAssertEqual(found[item("s1", provider: p).ref], true)
    }

    // MARK: - Plex

    private final class StreamsNetwork: PlexNetworkManager, @unchecked Sendable {
        var metadata: [String: PlexMetadata] = [:]
        var nextEpisode: [String: String?] = [:]
        private(set) var streamRequests: [[String]] = []

        override func getStreams(serverURL: String, authToken: String, ratingKeys: [String]) async throws -> [PlexMetadata] {
            streamRequests.append(ratingKeys)
            return ratingKeys.compactMap { metadata[$0] }
        }

        override func getNextEpisodeKey(serverURL: String, authToken: String, showRatingKey: String) async throws -> String? {
            guard let key = nextEpisode[showRatingKey] else { throw PlexAPIError.notFound }
            return key
        }
    }

    private func plexMeta(_ key: String, audio: [String]) throws -> PlexMetadata {
        let streams = audio.enumerated().map { #"{"id":\#($0.offset + 10),"streamType":2,"languageCode":"\#($0.element)"}"# }
        let json = #"{"ratingKey":"\#(key)","Media":[{"id":1,"Part":[{"id":2,"Stream":[\#(streams.joined(separator: ","))]}]}]}"#
        return try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
    }

    func test_plex_readsStreams_andAShowByItsOnDeckEpisode() async throws {
        let network = StreamsNetwork()
        network.metadata = ["m1": try plexMeta("m1", audio: ["jpn", "ger"]),
                            "m2": try plexMeta("m2", audio: ["jpn"]),
                            "e1": try plexMeta("e1", audio: ["jpn"])]
        let noneLeft: String? = nil
        network.nextEpisode = ["s1": "e1", "s2": noneLeft]
        let plex = PlexProvider(machineIdentifier: "t", displayName: "T", serverURL: "http://plex.test",
                                authToken: "t", networkManager: network)
        let p = "plex:t"
        let found = await plex.audioLanguageAvailability("deu", for: [
            item("m1", provider: p), item("m2", provider: p),
            item("s1", kind: .show, provider: p), item("s2", kind: .show, provider: p),
            item("s3", kind: .show, provider: p)])

        XCTAssertEqual(found[item("m1", provider: p).ref], true)
        XCTAssertEqual(found[item("m2", provider: p).ref], false)
        XCTAssertEqual(found[item("s1", provider: p).ref], false, "the On Deck episode decides")
        XCTAssertEqual(found[item("s2", provider: p).ref], true, "nothing left to watch")
        XCTAssertNil(found[item("s3", provider: p).ref], "a failed lookup is unknown")
        XCTAssertEqual(network.streamRequests.count, 1, "movies and episodes share one request")
        XCTAssertEqual(Set(network.streamRequests.first ?? []), ["m1", "m2", "e1"])
    }
}
