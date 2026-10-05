// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveTVSourceStorageTests.swift
//  RivuletTests
//
//  Dispatcharr keys move out of UserDefaults into the Keychain, the old iOS
//  store's single source is read back as a typed source, and favorites
//  reorder the way a List edits them.
//

import XCTest
@testable import Rivulet

@MainActor
final class LiveTVSourceStorageTests: XCTestCase {

    private typealias Config = LiveTVDataStore.SourceConfiguration

    // MARK: Keychain

    func test_plaintextKeyMovesToKeychain_andLeavesTheConfig() throws {
        let id = "dispatcharr:test-\(UUID().uuidString)"
        let key = LiveTVDataStore.apiTokenKey(sourceId: id)
        defer { KeychainHelper.delete(key) }
        var configs = [
            Config(id: id, type: "dispatcharr", name: "D", baseURL: "http://d", m3uURL: nil, epgURL: nil,
                   apiToken: "secret"),
            Config(id: "m3u:x", type: "m3u", name: "M", baseURL: nil, m3uURL: "http://m", epgURL: nil, apiToken: nil),
        ]

        XCTAssertTrue(LiveTVDataStore.moveAPITokensToKeychain(&configs))
        XCTAssertEqual(KeychainHelper.get(key), "secret")
        XCTAssertNil(configs[0].apiToken)

        let json = String(decoding: try JSONEncoder().encode(configs), as: UTF8.self)
        XCTAssertFalse(json.contains("secret"))
        XCTAssertFalse(json.contains("apiToken"))
        XCTAssertFalse(LiveTVDataStore.moveAPITokensToKeychain(&configs))
    }

    /// Saves from before channel profiles, and before the Keychain, still decode.
    func test_oldConfigJSONDecodes() throws {
        let json = #"[{"id":"dispatcharr:http://d","type":"dispatcharr","name":"D","baseURL":"http://d","apiToken":"k"}]"#
        let configs = try JSONDecoder().decode([Config].self, from: Data(json.utf8))
        XCTAssertEqual(configs.first?.apiToken, "k")
        XCTAssertNil(configs.first?.channelProfile)
    }

    // MARK: Legacy iOS source

    private func legacyDefaults(_ values: [String: String]) -> UserDefaults {
        let suite = "LiveTVSourceStorageTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        for (key, value) in values { defaults.set(value, forKey: "ios.liveTV.\(key)") }
        return defaults
    }

    func test_legacyDispatcharrPlaylist_becomesDispatcharrSource() {
        let defaults = legacyDefaults([
            "m3uURL": "http://192.168.1.140:9191/output/m3u/Kids%20TV",
            "xmltvURL": "http://192.168.1.140:9191/output/epg/Kids%20TV",
            "authorizationHeader": "ApiKey abc123",
            "userAgent": "VLC",
        ])
        XCTAssertEqual(LiveTVDataStore.legacyIOSSource(in: defaults),
                       .dispatcharr(baseURL: URL(string: "http://192.168.1.140:9191")!,
                                    channelProfile: "Kids TV", apiToken: "abc123"))
    }

    func test_legacyOtherPlaylist_becomesM3USource() {
        let defaults = legacyDefaults(["m3uURL": "https://iptv.test/get.php?u=1", "xmltvURL": "https://iptv.test/epg.xml"])
        XCTAssertEqual(LiveTVDataStore.legacyIOSSource(in: defaults),
                       .m3u(m3uURL: URL(string: "https://iptv.test/get.php?u=1")!,
                            epgURL: URL(string: "https://iptv.test/epg.xml")!))

        XCTAssertEqual(LiveTVDataStore.legacyIOSSource(in: legacyDefaults(["m3uURL": "https://iptv.test/a.m3u",
                                                                          "xmltvURL": ""])),
                       .m3u(m3uURL: URL(string: "https://iptv.test/a.m3u")!, epgURL: nil))
        XCTAssertNil(LiveTVDataStore.legacyIOSSource(in: legacyDefaults([:])))
    }

    func test_authorizationSchemeIsStripped() {
        XCTAssertEqual(LiveTVDataStore.apiKey(fromAuthorization: "Bearer eyJ.a.b"), "eyJ.a.b")
        XCTAssertEqual(LiveTVDataStore.apiKey(fromAuthorization: "token  k"), "k")
        XCTAssertEqual(LiveTVDataStore.apiKey(fromAuthorization: "bare"), "bare")
        XCTAssertNil(LiveTVDataStore.apiKey(fromAuthorization: "ApiKey "))
        XCTAssertNil(LiveTVDataStore.apiKey(fromAuthorization: nil))
    }

    // MARK: Favorites

    func test_moveFavorites_reordersShownIds_andLeavesHiddenOnesInPlace() {
        let ids = ["a", "offline", "b", "c", "d"]
        let shown: Set = ["a", "b", "c", "d"]
        // Shown list a b c d: drag "d" to the top, then "a" to the end.
        XCTAssertEqual(LiveTVDataStore.moving(ids, shown: shown, fromOffsets: [3], toOffset: 0),
                       ["d", "offline", "a", "b", "c"])
        XCTAssertEqual(LiveTVDataStore.moving(ids, shown: shown, fromOffsets: [0], toOffset: 4),
                       ["b", "offline", "c", "d", "a"])
        XCTAssertEqual(LiveTVDataStore.moving(ids, shown: shown, fromOffsets: [0, 2], toOffset: 4),
                       ["b", "offline", "d", "a", "c"])
        XCTAssertEqual(LiveTVDataStore.moving(ids, shown: shown, fromOffsets: [9], toOffset: 0), ids)
    }
}
