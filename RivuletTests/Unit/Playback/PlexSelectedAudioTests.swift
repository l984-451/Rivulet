// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class PlexSelectedAudioTests: XCTestCase {
    func test_noStoredIntent_followsPlexSelectionEvenWhenItIsTheDefault() {
        XCTAssertTrue(TrackIntentResolver.plexSelectedAudioMayOverride(
            selectedId: 2, defaultId: 2, hasStoredIntent: false))
        XCTAssertTrue(TrackIntentResolver.plexSelectedAudioMayOverride(
            selectedId: 3, defaultId: 2, hasStoredIntent: false))
        XCTAssertTrue(TrackIntentResolver.plexSelectedAudioMayOverride(
            selectedId: 3, defaultId: nil, hasStoredIntent: false))
    }

    func test_storedIntent_onlyFollowsSelectionThatDiffersFromDefault() {
        XCTAssertFalse(TrackIntentResolver.plexSelectedAudioMayOverride(
            selectedId: 2, defaultId: 2, hasStoredIntent: true))
        XCTAssertFalse(TrackIntentResolver.plexSelectedAudioMayOverride(
            selectedId: 2, defaultId: nil, hasStoredIntent: true))
        XCTAssertTrue(TrackIntentResolver.plexSelectedAudioMayOverride(
            selectedId: 3, defaultId: 2, hasStoredIntent: true))
    }
}
