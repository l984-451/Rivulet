// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import XCTest
@testable import Rivulet

@MainActor
final class PausedScrubPresentationTests: XCTestCase {
    private enum Entry: String, CaseIterable {
        case shuttle, direct, swipe, swipeUpdate, wheel, relative

        @MainActor
        func begin(_ model: UniversalPlayerViewModel) {
            switch self {
            case .shuttle: model.scrubInDirection(forward: true)
            case .direct: model.startScrubbing()
            case .swipe: model.startSwipeScrubbing()
            case .swipeUpdate: model.updateSwipeScrubPosition(by: 15)
            case .wheel: model.handleWheelScrub(by: 15)
            case .relative: model.scrubRelative(by: 15)
            }
        }
    }

    private func pausedModel() -> UniversalPlayerViewModel {
        let model = UniversalPlayerViewModel(
            metadata: PlexMetadata(ratingKey: "paused-scrub", type: "movie", title: "Paused scrub", duration: 600_000),
            serverURL: "http://127.0.0.1:9", authToken: "t")
        // Published's projected publisher shares its storage with the model.
        // Seed the existing state surface without loading a media engine or
        // calling private lifecycle methods, then arm timers through control input.
        var state = model.$playbackState
        Just(UniversalPlaybackState.paused).assign(to: &state)
        model.showControlsTemporarily()
        model.enterControlsFocus()
        XCTAssertEqual(model.playbackState, .paused)
        return model
    }

    /// Drive the real Foundation timers without waiting for wall-clock delays.
    /// Discover by type only: private names, timer counts and intervals are not
    /// part of the contract. Assertions below concern the player chrome alone.
    private func timers(_ model: UniversalPlayerViewModel) -> [Timer] {
        Mirror(reflecting: model).children.compactMap { field in
            if let timer = field.value as? Timer { return timer }
            let optional = Mirror(reflecting: field.value)
            guard optional.displayStyle == .optional else { return nil }
            return optional.children.first?.value as? Timer
        }.sorted { $0.fireDate < $1.fireDate }
    }

    private func drainTimerCallbacks() async {
        // Timer closures enqueue their mutations onto the main actor. Enqueue
        // a barrier on that same actor after firing, rather than sleeping.
        await Task { @MainActor in }.value
    }

    private func assertScrubChrome(_ model: UniversalPlayerViewModel, entry: Entry,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(model.isScrubbing, entry.rawValue, file: file, line: line)
        XCTAssertEqual(model.pausePresentation, .frame, entry.rawValue, file: file, line: line)
        XCTAssertFalse(model.showPausedPoster, entry.rawValue, file: file, line: line)
        XCTAssertTrue(model.showControls, entry.rawValue, file: file, line: line)
        XCTAssertTrue(model.controlsFocusActive, entry.rawValue, file: file, line: line)
    }

    private func expireTimers(_ scheduled: [Timer]) async {
        for timer in scheduled {
            timer.fire()
            await drainTimerCallbacks()
        }
    }

    private func assertAmbientTiersReturn(_ model: UniversalPlayerViewModel,
                                         file: StaticString = #filePath, line: UInt = #line) async {
        var presentations: [UniversalPlayerViewModel.PausePresentation] = []
        for timer in timers(model) {
            timer.fire()
            await drainTimerCallbacks()
            presentations.append(model.pausePresentation)
        }
        XCTAssertTrue(presentations.contains(.ambient), "The normal paused backdrop must return", file: file, line: line)
        XCTAssertEqual(model.pausePresentation, .dimmed, "The burn-in protection must also return", file: file, line: line)
        XCTAssertTrue(model.showPausedPoster, file: file, line: line)
        XCTAssertFalse(model.controlsFocusActive, file: file, line: line)
    }

    func test_pausedScrubEntryPaths_keepTransportAndFocusWhenTimersExpire() async {
        for entry in Entry.allCases {
            let model = pausedModel()
            let previouslyScheduled = timers(model)
            entry.begin(model)
            assertScrubChrome(model, entry: entry)
            // Include timers armed before entry AND timers restarted by entry
            // paths that hide the poster before setting isScrubbing.
            for timer in previouslyScheduled + timers(model) {
                timer.fire()
                await drainTimerCallbacks()
                assertScrubChrome(model, entry: entry)
            }
            model.cancelScrub()
            model.stopPlayback()
        }
    }

    func test_alreadyFiredPauseTimers_doNotCoverANewScrub() async {
        let model = pausedModel()
        // Queue both callbacks before entering: invalidating the Timer alone
        // cannot retract a main-actor task it has already submitted.
        for timer in timers(model) { timer.fire() }
        model.startSwipeScrubbing()
        await drainTimerCallbacks()
        assertScrubChrome(model, entry: .swipe)
        model.cancelScrub()
        model.stopPlayback()
    }

    func test_pausedScrubCommitAndCancel_rearmBothAmbientTiers() async {
        for entry in Entry.allCases {
            for commit in [true, false] {
                let model = pausedModel()
                entry.begin(model)
                // Consume the old deadlines while still scrubbing, so an exit
                // must rearm both tiers rather than relying on leftover timers.
                await expireTimers(timers(model))
                if commit {
                    await model.commitScrub()
                } else {
                    model.cancelScrub()
                }
                XCTAssertFalse(model.isScrubbing, entry.rawValue)
                XCTAssertEqual(model.playbackState, .paused, entry.rawValue)
                XCTAssertEqual(model.pausePresentation, .frame, entry.rawValue)
                await assertAmbientTiersReturn(model)
                model.stopPlayback()
            }
        }
    }

    func test_panelCloseDuringPausedScrub_keepsTransportAndFocus() async {
        let model = pausedModel()
        model.startSwipeScrubbing()
        model.isRailPanelOpen = true
        model.isRailPanelOpen = false
        await expireTimers(timers(model))
        assertScrubChrome(model, entry: .swipe)
        model.cancelScrub()
        await assertAmbientTiersReturn(model)
        model.stopPlayback()
    }

    func test_pausedControlInput_restartsBothAmbientTiers() async {
        let model = pausedModel()
        await assertAmbientTiersReturn(model)
        model.showControlsTemporarily()
        model.enterControlsFocus()
        XCTAssertEqual(model.pausePresentation, .frame)
        XCTAssertTrue(model.controlsFocusActive)
        await assertAmbientTiersReturn(model)
        model.stopPlayback()
    }
}
