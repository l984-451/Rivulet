// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class SiloPersonFilmographyTests: XCTestCase {
    private func provider(profile: String, revision: UInt64 = 4) -> SiloProvider {
        let client = SiloClient(baseURL: URL(string: "https://media.invalid")!, profileID: profile)
        return SiloProvider(serverID: "synthetic", displayName: "Synthetic",
                            profileID: profile, client: client, authorityRevision: revision)
    }

    func testOpaqueIdentityPreservesPersonIDAndRejectsForeignAuthority() {
        let owner = provider(profile: "profile-a")
        let nativeID = "person:opaque/with?delimiters"
        let identity = SiloPersonContext.identity(nativeID, provider: owner)
        XCTAssertEqual(SiloPersonContext.personID(identity, provider: owner), nativeID)
        XCTAssertNil(SiloPersonContext.personID(identity, provider: provider(profile: "profile-b")))
        XCTAssertNil(SiloPersonContext.personID(identity, provider: provider(profile: "profile-a", revision: 5)))
        XCTAssertNil(SiloPersonContext.personID("tmdb:123", provider: owner))
    }

    @MainActor
    func testCastRouteRejectsUnresolvedAndForeignPerson() {
        let owner = provider(profile: "profile-a")
        let foreign = provider(profile: "profile-b")
        let person = MediaPerson(id: SiloPersonContext.identity("opaque", provider: owner),
                                 name: "Synthetic Actor", role: "Lead", imageURL: nil)
        XCTAssertNoThrow(try PersonDetailViewController.silo(cast: person, provider: owner, inLibraries: []))
        XCTAssertThrowsError(try PersonDetailViewController.silo(cast: person, provider: foreign, inLibraries: []))
        let unresolved = MediaPerson(id: "", name: "Synthetic Actor", role: nil, imageURL: nil)
        XCTAssertThrowsError(try PersonDetailViewController.silo(cast: unresolved, provider: owner, inLibraries: []))
    }
}
