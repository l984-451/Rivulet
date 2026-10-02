// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class ShellSidebarModelTests: XCTestCase {

    private func sections(jellyfinName: String?, jellyfin: [MediaLibrary]) -> [ShellSidebarSection] {
        ShellSidebarModel.sections(
            libraries: [], liveTVSources: [], combineLiveTV: true,
            showDiscover: false, discoverAbove: true, showWatchlist: false,
            liveTVAbove: false, serverName: "Angel", profileName: "Bain",
            jellyfinServerName: jellyfinName, jellyfinLibraries: jellyfin)
    }

    func test_jellyfinLibraries_getAServerNamedSection_withProviderTabs() {
        let libs = [MediaLibrary(id: "lib-m", providerID: "jellyfin:srv", title: "Movies", kind: .movies),
                    MediaLibrary(id: "lib-t", providerID: "jellyfin:srv", title: "TV Shows", kind: .shows),
                    MediaLibrary(id: "lib-x", providerID: "jellyfin:srv", title: "Home Videos", kind: .mixed)]

        let jf = sections(jellyfinName: "jellyfin-test", jellyfin: libs).first { $0.title == "jellyfin-test" }

        XCTAssertEqual(jf?.items.map(\.title), ["Movies", "TV Shows", "Home Videos"])
        XCTAssertEqual(jf?.items.map(\.icon), ["film.fill", "tv.fill", "folder.fill"])
        XCTAssertEqual(jf?.items.first?.tab, .providerLibrary(providerID: "jellyfin:srv", libraryID: "lib-m"))
    }

    func test_noJellyfin_noJellyfinSection() {
        XCTAssertEqual(sections(jellyfinName: nil, jellyfin: []).map(\.title), [nil, nil])
    }

    func test_jellyfinSectionSitsBeforeSettings() {
        let libs = [MediaLibrary(id: "lib-m", providerID: "jellyfin:srv", title: "Movies", kind: .movies)]
        XCTAssertEqual(sections(jellyfinName: "jellyfin-test", jellyfin: libs).map(\.title),
                       [nil, "jellyfin-test", nil])
    }
}
