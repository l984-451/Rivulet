// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Synchronization
import XCTest
@testable import Rivulet

/// Use in Discover: libraries left out of Discover, such as one of placeholder videos.
@MainActor
final class DiscoverLibrariesTests: XCTestCase {
    private let userIdKey = PlexProfileSession.savedUserIDKey
    private let profileA = 987_654_331
    private let profileB = 987_654_332
    private var savedUserId: Any?

    override func setUp() {
        super.setUp()
        savedUserId = UserDefaults.standard.object(forKey: userIdKey)
        removeTestKeys()
        UserDefaults.standard.set(profileA, forKey: userIdKey)
    }

    override func tearDown() {
        removeTestKeys()
        if let savedUserId { UserDefaults.standard.set(savedUserId, forKey: userIdKey) } else {
            UserDefaults.standard.removeObject(forKey: userIdKey)
        }
        super.tearDown()
    }

    private func removeTestKeys() {
        for profile in [profileA, profileB] {
            UserDefaults.standard.removeObject(forKey: "\(DiscoverLibraries.storeBase)_user_\(profile)")
        }
    }

    private func library(_ id: String, _ kind: MediaLibrary.LibraryKind, on provider: String = "plex:a") -> MediaLibrary {
        MediaLibrary(id: id, providerID: provider, title: id, kind: kind)
    }

    func test_everyLibraryIsUsedUntilOneIsTurnedOff_perProfile_andTheListSyncs() {
        XCTAssertEqual(DiscoverLibraries.excluded(), [])
        DiscoverLibraries.setUsed(false, key: "plex:a/9")
        DiscoverLibraries.setUsed(false, key: "jellyfin:s/x")
        XCTAssertEqual(DiscoverLibraries.excluded(), ["plex:a/9", "jellyfin:s/x"])

        UserDefaults.standard.set(profileB, forKey: userIdKey)
        XCTAssertEqual(DiscoverLibraries.excluded(), [], "another profile's list")

        UserDefaults.standard.set(profileA, forKey: userIdKey)
        DiscoverLibraries.setUsed(true, key: "plex:a/9")
        DiscoverLibraries.setUsed(true, key: "jellyfin:s/x")
        XCTAssertEqual(DiscoverLibraries.excluded(), [])
        XCTAssertNil(UserDefaults.standard.object(forKey: "\(DiscoverLibraries.storeBase)_user_\(profileA)"),
                     "back to the default leaves nothing stored")

        XCTAssertTrue(SyncCatalog.isSynced("\(DiscoverLibraries.storeBase)_user_7"))
        XCTAssertTrue(SyncCatalog.isSynced(DiscoverLibraries.storeBase), "a profile-less device")
    }

    func test_aCopyInAnExcludedLibraryDoesNotCount() {
        var placeholder = watchedListItem("p", genres: [])
        placeholder.libraryID = "9"
        var real = watchedListItem("r", genres: [])
        real.libraryID = "1"
        var otherServer = watchedListItem("o", genres: [], provider: "plex:b")
        otherServer.libraryID = "9"
        let excluded: Set = ["plex:a/9"]

        XCTAssertFalse(DiscoverLibraries.counts(placeholder, excluded: excluded, selectedPlex: .noPlex))
        XCTAssertTrue(DiscoverLibraries.counts(real, excluded: excluded, selectedPlex: .noPlex))
        XCTAssertTrue(DiscoverLibraries.counts(otherServer, excluded: excluded, selectedPlex: .noPlex), "same section id, other server")
        XCTAssertTrue(DiscoverLibraries.counts(watchedListItem("n", genres: []), excluded: excluded, selectedPlex: .noPlex),
                      "names no library")
    }

    /// The selected Plex server is named by a hash of its URL after a relaunch, and by its machine id once
    /// chosen this session: both name one stored entry, under the machine id, on every device.
    func test_theSelectedPlexServerIsKeyedByItsMachineID_whateverTheRegistryCallsIt() {
        let plex = DiscoverLibraries.SelectedPlex(providerIDs: ["plex:5e1fhash", "plex:abc123"], machineID: "abc123")
        let underHash = DiscoverLibraries.key(providerID: "plex:5e1fhash", libraryID: "9", selectedPlex: plex)
        XCTAssertEqual(underHash, "plex:abc123/9")
        XCTAssertEqual(DiscoverLibraries.key(providerID: "plex:abc123", libraryID: "9", selectedPlex: plex), underHash)

        // Turned off from a launch that named the server by its URL hash…
        DiscoverLibraries.setUsed(false, key: underHash)
        XCTAssertEqual(DiscoverLibraries.excluded(), ["plex:abc123/9"])
        // …and read back after a relaunch or a URL change mints another hash.
        let relaunched = DiscoverLibraries.SelectedPlex(providerIDs: ["plex:77aahash"], machineID: "abc123")
        var copy = watchedListItem("p", genres: [], provider: "plex:77aahash")
        copy.libraryID = "9"
        XCTAssertFalse(DiscoverLibraries.counts(copy, excluded: DiscoverLibraries.excluded(), selectedPlex: relaunched))
        XCTAssertEqual(DiscoverLibraries.libraryIDs(DiscoverLibraries.excluded(), providerID: "plex:77aahash",
                                                    selectedPlex: relaunched), ["9"])
        let library = MediaLibrary(id: "9", providerID: "plex:77aahash", title: "Suggestions", kind: .movies)
        XCTAssertTrue(DiscoverLibraries.used([library], excluded: DiscoverLibraries.excluded(), selectedPlex: relaunched).isEmpty)

        // Other servers keep their own ids, and with no machine id known the registry's id stands.
        XCTAssertEqual(DiscoverLibraries.key(providerID: "plex:extra", libraryID: "1", selectedPlex: relaunched), "plex:extra/1")
        XCTAssertEqual(DiscoverLibraries.key(providerID: "jellyfin:s", libraryID: "x", selectedPlex: relaunched), "jellyfin:s/x")
        let unknown = DiscoverLibraries.SelectedPlex(providerIDs: ["plex:77aahash"], machineID: nil)
        XCTAssertEqual(DiscoverLibraries.key(providerID: "plex:77aahash", libraryID: "9", selectedPlex: unknown),
                       "plex:77aahash/9")
    }

    /// Switching from server A to B leaves A's id among the selected ones; A comes back as an extra server
    /// and its libraries must keep A's keys, or A's section 1 and B's section 1 would share one.
    func test_aServerSwitchedAwayFromKeepsItsOwnKeys() {
        let savedSelected = MediaItemRef.selectedPlexIDs.withLock { $0 }
        let savedExtra = MediaItemRef.extraPlexIDs.withLock { $0 }
        defer {
            MediaItemRef.selectedPlexIDs.withLock { $0 = savedSelected }
            MediaItemRef.extraPlexIDs.withLock { $0 = savedExtra }
        }
        MediaItemRef.selectedPlexIDs.withLock { $0 = ["plex:a", "plex:b"] }
        MediaItemRef.extraPlexIDs.withLock { $0 = ["plex:a"] }

        let current = DiscoverLibraries.SelectedPlex.current
        XCTAssertFalse(current.providerIDs.contains("plex:a"))
        let plex = DiscoverLibraries.SelectedPlex(providerIDs: current.providerIDs, machineID: "b")
        XCTAssertEqual(DiscoverLibraries.key(providerID: "plex:a", libraryID: "1", selectedPlex: plex), "plex:a/1")
        XCTAssertEqual(DiscoverLibraries.key(providerID: "plex:b", libraryID: "1", selectedPlex: plex), "plex:b/1")
    }

    func test_forYouHistorySkipsAnExcludedLibrary() {
        let shown = [library("sugg", .shows), library("movies", .movies), library("tv", .shows),
                     library("kids", .movies)]

        let read = DiscoverForYou.historyLibraries(DiscoverLibraries.used(shown, excluded: ["plex:a/sugg"], selectedPlex: .noPlex))

        XCTAssertEqual(read.map(\.id), ["movies", "tv", "kids"])
    }

    func test_oneServersExcludedSections() {
        let excluded: Set = ["plex:a/9", "plex:a/12", "plex:ab/3", "jellyfin:s/x"]
        XCTAssertEqual(DiscoverLibraries.libraryIDs(excluded, providerID: "plex:a", selectedPlex: .noPlex), ["9", "12"])
    }

    /// tvOS: a title in a placeholder section and a real one is still owned through the real copy.
    func test_tvOSIndexSkipsAnExcludedSection() async {
        func entry(_ key: String, section: String) -> LibraryGUIDIndex.Entry? {
            var item = PlexMetadata(ratingKey: key, type: "movie", title: key)
            item.Guid = [PlexGuid(id: "tmdb://100")]
            return LibraryGUIDIndex.Entry(item, sectionID: section)
        }
        let index = LibraryGUIDIndex()
        await index.replace(with: [entry("real", section: "1"), entry("placeholder", section: "9")].compactMap { $0 },
                            completeness: .partial)

        let unfiltered = await index.lookup(tmdbId: 100, type: .movie)
        let skipping = await index.lookup(tmdbId: 100, type: .movie, excludingSections: ["9"])
        let none = await index.lookup(tmdbId: 100, type: .movie, excludingSections: ["1", "9"])
        XCTAssertEqual(unfiltered?.ratingKey, "placeholder", "the copy ingested last, as before")
        XCTAssertEqual(skipping?.ratingKey, "real")
        XCTAssertNil(none)
    }
}

private extension DiscoverLibraries.SelectedPlex {
    /// No selected Plex server known: every id stands as it is.
    static let noPlex = DiscoverLibraries.SelectedPlex(providerIDs: [], machineID: nil)
}
