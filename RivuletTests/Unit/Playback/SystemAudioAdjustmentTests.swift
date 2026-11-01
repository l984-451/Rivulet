// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class SystemAudioAdjustmentTests: XCTestCase {

    private typealias Level = SystemAudioAdjustment.DialogueLevel

    // MARK: - Effective level

    func test_disabled_isOffWhateverTheStoredLevel() {
        for raw in [nil, 0, 1, 2, 3, 7] {
            XCTAssertEqual(SystemAudioAdjustment.effectiveLevel(enabled: false, rawLevel: raw), .off)
        }
    }

    func test_missingLevel_readsAsEnhance() {
        XCTAssertEqual(SystemAudioAdjustment.effectiveLevel(enabled: true, rawLevel: nil), .enhance)
    }

    func test_storedLevels_mapOneToOne() {
        XCTAssertEqual(SystemAudioAdjustment.effectiveLevel(enabled: true, rawLevel: 1), .enhance)
        XCTAssertEqual(SystemAudioAdjustment.effectiveLevel(enabled: true, rawLevel: 2), .enhanceMore)
        XCTAssertEqual(SystemAudioAdjustment.effectiveLevel(enabled: true, rawLevel: 3), .isolate)
    }

    func test_outOfRangeLevels_clampToEnhance() {
        XCTAssertEqual(SystemAudioAdjustment.effectiveLevel(enabled: true, rawLevel: 0), .enhance)
        XCTAssertEqual(SystemAudioAdjustment.effectiveLevel(enabled: true, rawLevel: -1), .enhance)
        XCTAssertEqual(SystemAudioAdjustment.effectiveLevel(enabled: true, rawLevel: 4), .enhance)
    }

    func test_levelTitles_matchAppleOrder() {
        XCTAssertEqual(Level.allCases.map(\.title), ["Off", "Enhance", "Enhance More", "Isolate"])
        XCTAssertEqual(Level.allCases.map(\.rawValue), [0, 1, 2, 3])
    }

    // MARK: - Which rows appear

    func test_levelsAvailable_replaceTheDialogueToggle() {
        let all = SystemAudioAdjustment.allCases
        XCTAssertTrue(SystemAudioAdjustment.showsLevels(available: all, levelsAvailable: true))
        XCTAssertEqual(SystemAudioAdjustment.menuToggleCases(available: all, levelsAvailable: true),
                       [.reduceLoudSounds])
    }

    func test_noLevels_keepsBothToggles() {
        let all = SystemAudioAdjustment.allCases
        XCTAssertFalse(SystemAudioAdjustment.showsLevels(available: all, levelsAvailable: false))
        XCTAssertEqual(SystemAudioAdjustment.menuToggleCases(available: all, levelsAvailable: false), all)
    }

    func test_levelsWithoutEnhanceDialogue_showNothingForDialogue() {
        let available: [SystemAudioAdjustment] = [.reduceLoudSounds]
        XCTAssertFalse(SystemAudioAdjustment.showsLevels(available: available, levelsAvailable: true))
        XCTAssertEqual(SystemAudioAdjustment.menuToggleCases(available: available, levelsAvailable: true),
                       [.reduceLoudSounds])
    }

    func test_nothingAvailable_showsNothing() {
        XCTAssertFalse(SystemAudioAdjustment.showsLevels(available: [], levelsAvailable: true))
        XCTAssertEqual(SystemAudioAdjustment.menuToggleCases(available: [], levelsAvailable: true), [])
    }

    func test_dialogueSummary_namesTheLevelOnlyWhenTheRouteOffersLevels() {
        XCTAssertEqual(SystemAudioAdjustment.dialogueSummary(levelsAvailable: true, level: .enhanceMore), "Enhance More")
        XCTAssertEqual(SystemAudioAdjustment.dialogueSummary(levelsAvailable: true, level: .off), "Off")
        XCTAssertEqual(SystemAudioAdjustment.dialogueSummary(levelsAvailable: false, level: .enhance), "On")
        XCTAssertEqual(SystemAudioAdjustment.dialogueSummary(levelsAvailable: false, level: .off), "Off")
    }
}
