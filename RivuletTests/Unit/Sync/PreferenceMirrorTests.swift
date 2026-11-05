// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class FakeKeyValueStore: KeyValueStore {
    var values: [String: Any] = [:]
    private(set) var writes = 0

    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) {
        writes += 1
        values[key] = value
    }
    func allKeys() -> [String] { Array(values.keys) }
    func synchronize() {}
}

@MainActor
final class PreferenceMirrorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: FakeKeyValueStore!
    private var mirror: PreferenceMirror!
    private let suite = "PreferenceMirrorTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        store = FakeKeyValueStore()
        mirror = PreferenceMirror(defaults: defaults, domain: suite, store: store)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func test_localKeyPushesToCloud() {
        defaults.set(true, forKey: "showHomeHero")
        XCTAssertEqual(mirror.reconcile(), [])
        XCTAssertEqual(store.values["showHomeHero"] as? Bool, true)
    }

    func test_unlistedKeysNeverLeaveTheDevice() {
        defaults.set("http://192.168.1.2:32400", forKey: "selectedServerURL")
        defaults.set(["a"], forKey: "liveTVRecentChannelIds")
        defaults.set("42", forKey: SyncCatalog.stateKey + "x")
        mirror.reconcile()
        XCTAssertTrue(store.values.isEmpty)
    }

    func test_registeredDefaultsAreNotAChoice() {
        defaults.register(defaults: ["showHomeHero": true])
        mirror.reconcile()
        XCTAssertTrue(store.values.isEmpty)
    }

    func test_cloudOnlyKeyPullsAndIsReported() {
        store.values["autoplayLimit"] = 3
        XCTAssertEqual(mirror.reconcile(), ["autoplayLimit"])
        XCTAssertEqual(defaults.integer(forKey: "autoplayLimit"), 3)
    }

    func test_cloudOnlyKeyThatIsNotListedIsIgnored() {
        store.values["plexAuthToken"] = "secret"
        XCTAssertEqual(mirror.reconcile(), [])
        XCTAssertNil(defaults.object(forKey: "plexAuthToken"))
    }

    func test_adoptionCloudWinsOnAConflict() {
        defaults.set(5, forKey: "autoplayLimit")
        store.values["autoplayLimit"] = 3
        XCTAssertEqual(mirror.reconcile(), ["autoplayLimit"])
        XCTAssertEqual(defaults.integer(forKey: "autoplayLimit"), 3)
        XCTAssertEqual(store.values["autoplayLimit"] as? Int, 3)
    }

    func test_adoptionFillsGapsBothWays() {
        defaults.set(true, forKey: "showHomeHero")
        store.values["useIntroDB"] = true
        XCTAssertEqual(mirror.reconcile(), ["useIntroDB"])
        XCTAssertEqual(store.values["showHomeHero"] as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "useIntroDB") as? Bool, true)
    }

    func test_pulledValueDoesNotEchoBack() {
        store.values["autoplayLimit"] = 3
        mirror.reconcile()
        let writes = store.writes
        XCTAssertEqual(mirror.reconcile(), [])
        XCTAssertEqual(store.writes, writes)
    }

    func test_pushedValueDoesNotComeBackAsAChange() {
        defaults.set(2, forKey: "autoplayLimit")
        mirror.reconcile()
        XCTAssertEqual(mirror.reconcile(), [])
        XCTAssertEqual(store.writes, 1)
    }

    func test_localChangeAfterSyncPushes() {
        defaults.set(2, forKey: "autoplayLimit")
        mirror.reconcile()
        defaults.set(5, forKey: "autoplayLimit")
        XCTAssertEqual(mirror.reconcile(), [])
        XCTAssertEqual(store.values["autoplayLimit"] as? Int, 5)
    }

    func test_cloudChangeAfterSyncPulls() {
        defaults.set(2, forKey: "autoplayLimit")
        mirror.reconcile()
        store.values["autoplayLimit"] = 5
        XCTAssertEqual(mirror.reconcile(), ["autoplayLimit"])
        XCTAssertEqual(defaults.integer(forKey: "autoplayLimit"), 5)
    }

    func test_bothChangedCloudWins() {
        defaults.set(2, forKey: "autoplayLimit")
        mirror.reconcile()
        defaults.set(3, forKey: "autoplayLimit")
        store.values["autoplayLimit"] = 5
        XCTAssertEqual(mirror.reconcile(), ["autoplayLimit"])
        XCTAssertEqual(defaults.integer(forKey: "autoplayLimit"), 5)
    }

    func test_localDeleteRemovesFromCloud() {
        defaults.set(2, forKey: "autoplayLimit")
        mirror.reconcile()
        defaults.removeObject(forKey: "autoplayLimit")
        XCTAssertEqual(mirror.reconcile(), [])
        XCTAssertNil(store.values["autoplayLimit"])
    }

    func test_cloudDeleteRemovesLocally() {
        defaults.set(2, forKey: "autoplayLimit")
        mirror.reconcile()
        store.values["autoplayLimit"] = nil
        XCTAssertEqual(mirror.reconcile(), ["autoplayLimit"])
        XCTAssertNil(defaults.object(forKey: "autoplayLimit"))
    }

    func test_deletedKeyDoesNotComeBackOnTheNextPass() {
        defaults.set(2, forKey: "autoplayLimit")
        mirror.reconcile()
        defaults.removeObject(forKey: "autoplayLimit")
        mirror.reconcile()
        XCTAssertEqual(mirror.reconcile(), [])
        XCTAssertNil(defaults.object(forKey: "autoplayLimit"))
        XCTAssertNil(store.values["autoplayLimit"])
    }

    func test_perProfileKeysSync() {
        defaults.set(["1", "2"], forKey: "hiddenLibraryKeys_user_9")
        mirror.reconcile()
        XCTAssertEqual(store.values["hiddenLibraryKeys_user_9"] as? [String], ["1", "2"])
    }

    func test_overlongKeyIsSkipped() {
        let key = "mediaLibrarySort." + String(repeating: "x", count: 200)
        defaults.set("titleAsc", forKey: key)
        mirror.reconcile()
        XCTAssertTrue(store.values.isEmpty)
    }

    func test_oversizedValueIsSkipped() {
        let small = PreferenceMirror(defaults: defaults, domain: suite, store: store, maxValueBytes: 100)
        defaults.set(Data(count: 500), forKey: "trackIntent.subtitle")
        defaults.set(true, forKey: "showHomeHero")
        small.reconcile()
        XCTAssertNil(store.values["trackIntent.subtitle"])
        XCTAssertEqual(store.values["showHomeHero"] as? Bool, true)
    }

    func test_heldValuesStayOutOfTheNewAccountUntilChangedHere() {
        defaults.set(true, forKey: "showHomeHero")
        defaults.set(2, forKey: "autoplayLimit")
        mirror.holdLocalValues()
        store.values["useIntroDB"] = false
        XCTAssertEqual(mirror.reconcile(), ["useIntroDB"])
        // Any number of later passes, as the state write itself triggers one.
        mirror.reconcile()
        mirror.reconcile()
        XCTAssertNil(store.values["showHomeHero"])
        XCTAssertNil(store.values["autoplayLimit"])
        // Changed on this device: that one goes up, the other stays.
        defaults.set(5, forKey: "autoplayLimit")
        mirror.reconcile()
        XCTAssertEqual(store.values["autoplayLimit"] as? Int, 5)
        XCTAssertNil(store.values["showHomeHero"])
    }

    func test_heldKeyTakesTheNewAccountsValue() {
        defaults.set(2, forKey: "autoplayLimit")
        mirror.holdLocalValues()
        store.values["autoplayLimit"] = 9
        XCTAssertEqual(mirror.reconcile(), ["autoplayLimit"])
        XCTAssertEqual(defaults.integer(forKey: "autoplayLimit"), 9)
    }

    // MARK: First sync of a fresh device against a configured one

    func test_emptyCloudValueNeverBeatsAConfiguredLocalOne() {
        store.values["liveTVUnfavoritedChannelIds"] = [String]()
        defaults.set(["xtream:xtream:ab:1"], forKey: "liveTVUnfavoritedChannelIds")
        XCTAssertEqual(mirror.reconcile(), [])
        XCTAssertEqual(defaults.stringArray(forKey: "liveTVUnfavoritedChannelIds"), ["xtream:xtream:ab:1"])
        XCTAssertEqual(store.values["liveTVUnfavoritedChannelIds"] as? [String], ["xtream:xtream:ab:1"])
    }

    func test_emptyLocalValueTakesAConfiguredCloudOne() {
        store.values["hiddenLibraryKeys"] = ["3"]
        defaults.set([String](), forKey: "hiddenLibraryKeys")
        XCTAssertEqual(mirror.reconcile(), ["hiddenLibraryKeys"])
        XCTAssertEqual(defaults.stringArray(forKey: "hiddenLibraryKeys"), ["3"])
    }

    func test_freshDeviceSyncingFirstDoesNotWipeTheConfiguredOne() {
        // Device B is fresh and wrote empty values at load. It syncs before A does.
        let suiteB = suite + ".b"
        let deviceB = UserDefaults(suiteName: suiteB)!
        deviceB.removePersistentDomain(forName: suiteB)
        defer { deviceB.removePersistentDomain(forName: suiteB) }
        deviceB.set([String](), forKey: "hiddenLibraryKeys")
        deviceB.set([String](), forKey: "liveTVUnfavoritedChannelIds")
        deviceB.set(Data("{}".utf8), forKey: "librarySortOptions")
        let mirrorB = PreferenceMirror(defaults: deviceB, domain: suiteB, store: store)
        mirrorB.reconcile()

        // Device A is configured.
        defaults.set(["2", "5"], forKey: "hiddenLibraryKeys")
        defaults.set(["xtream:xtream:ab:1"], forKey: "liveTVUnfavoritedChannelIds")
        defaults.set(Data(#"{"1":"titleAsc"}"#.utf8), forKey: "librarySortOptions")
        mirror.reconcile()
        XCTAssertEqual(defaults.stringArray(forKey: "hiddenLibraryKeys"), ["2", "5"])
        XCTAssertEqual(defaults.stringArray(forKey: "liveTVUnfavoritedChannelIds"), ["xtream:xtream:ab:1"])
        XCTAssertEqual(defaults.data(forKey: "librarySortOptions"), Data(#"{"1":"titleAsc"}"#.utf8))

        // And B ends up with A's choices.
        mirrorB.reconcile()
        XCTAssertEqual(deviceB.stringArray(forKey: "hiddenLibraryKeys"), ["2", "5"])
    }

    // MARK: Size

    func test_defaultCapIsFarBelowTheStoreLimit() {
        defaults.set(Data(count: 70_000), forKey: "trackIntent.subtitle")
        defaults.set(true, forKey: "showHomeHero")
        mirror.reconcile()
        XCTAssertNil(store.values["trackIntent.subtitle"])
        XCTAssertEqual(store.values["showHomeHero"] as? Bool, true)
    }

    // MARK: Channel ids that must stay home

    func test_urlShapedChannelIdsNeverReachTheCloud() {
        let leaky = "m3u:http://host/get.php?username=u&password=p:Channel 1"
        let plex = "plex:plex:http://192.168.1.5:32400:5"
        let safe = "xtream:xtream:ab12:7"
        defaults.set([leaky, safe, plex], forKey: "liveTVFavoriteChannelIds")
        mirror.reconcile()
        XCTAssertEqual(store.values["liveTVFavoriteChannelIds"] as? [String], [safe])
        for value in store.values.values {
            XCTAssertFalse(String(describing: value).contains("password"))
        }
    }

    func test_pullingChannelIdsKeepsTheOnesThatStayHome() {
        let plex = "plex:plex:http://192.168.1.5:32400:5"
        defaults.set([plex, "xtream:xtream:ab12:7"], forKey: "liveTVFavoriteChannelIds")
        mirror.reconcile()
        store.values["liveTVFavoriteChannelIds"] = ["xtream:xtream:ab12:7", "xtream:xtream:ab12:9"]
        XCTAssertEqual(mirror.reconcile(), ["liveTVFavoriteChannelIds"])
        XCTAssertEqual(defaults.stringArray(forKey: "liveTVFavoriteChannelIds"),
                       ["xtream:xtream:ab12:7", "xtream:xtream:ab12:9", plex])
        // Settled: nothing left to say either way.
        let writes = store.writes
        XCTAssertEqual(mirror.reconcile(), [])
        XCTAssertEqual(store.writes, writes)
    }

    func test_unsafeIdsAlreadyInTheCloudAreNotTaken() {
        store.values["liveTVFavoriteChannelIds"] = ["m3u:http://h/get.php?username=u&password=p:1", "xtream:xtream:ab:2"]
        mirror.reconcile()
        XCTAssertEqual(defaults.stringArray(forKey: "liveTVFavoriteChannelIds"), ["xtream:xtream:ab:2"])
        // The cloud copy is cleaned on the next pass.
        mirror.reconcile()
        XCTAssertEqual(store.values["liveTVFavoriteChannelIds"] as? [String], ["xtream:xtream:ab:2"])
    }

    func test_resetStateAdoptsAgain() {
        defaults.set(2, forKey: "autoplayLimit")
        mirror.reconcile()
        mirror.resetState()
        store.values["autoplayLimit"] = 9
        XCTAssertEqual(mirror.reconcile(), ["autoplayLimit"])
        XCTAssertEqual(defaults.integer(forKey: "autoplayLimit"), 9)
    }

    func test_fingerprintIgnoresDictionaryOrderAndTellsValuesApart() {
        let a: [String: Any] = ["x": 1, "y": ["b", "a"]]
        let b: [String: Any] = ["y": ["b", "a"], "x": 1]
        XCTAssertEqual(PreferenceMirror.fingerprint(a), PreferenceMirror.fingerprint(b))
        XCTAssertNotEqual(PreferenceMirror.fingerprint(["a", "b"]), PreferenceMirror.fingerprint(["b", "a"]))
        XCTAssertNotEqual(PreferenceMirror.fingerprint(true), PreferenceMirror.fingerprint(1))
        XCTAssertNotEqual(PreferenceMirror.fingerprint("1"), PreferenceMirror.fingerprint(1))
        XCTAssertNil(PreferenceMirror.fingerprint(nil))
    }
}
