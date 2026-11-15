// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AVFoundation
import UIKit
import XCTest
@testable import Rivulet

@MainActor
final class ThemeBackdropTests: XCTestCase {
    private let first = MediaItemRef(providerID: "jellyfin:srv", itemID: "first")
    private let second = MediaItemRef(providerID: "jellyfin:srv", itemID: "second")
    private let clip = URL(string: "https://example.com/theme.mp4")!

    @MainActor
    private final class Switches {
        var systemAllows = true
        var foreground = true
        var covered = false
        var lookups: [MediaItemRef] = []
    }

    private func backdrop(_ switches: Switches, url: URL? = nil) -> ThemeBackdrop {
        let backdrop = ThemeBackdrop(
            resolve: { ref in
                switches.lookups.append(ref)
                return url
            },
            systemAllows: { switches.systemAllows },
            isForeground: { switches.foreground }
        )
        backdrop.isCovered = { switches.covered }
        return backdrop
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(50)) }

    // MARK: - Pure rules

    func test_wantedItemNeedsEveryCondition() {
        func wanted(active: Bool = true, suspended: Bool = false, covered: Bool = false,
                    foreground: Bool = true, system: Bool = true) -> MediaItemRef? {
            ThemeBackdrop.wantedItem(first, isActive: active, isSuspended: suspended, isCovered: covered,
                                     isForeground: foreground, systemAllows: system)
        }
        XCTAssertEqual(wanted(), first)
        XCTAssertNil(wanted(active: false))
        XCTAssertNil(wanted(suspended: true))
        XCTAssertNil(wanted(covered: true))
        XCTAssertNil(wanted(foreground: false))
        XCTAssertNil(wanted(system: false))
        XCTAssertNil(ThemeBackdrop.wantedItem(nil, isActive: true, isSuspended: false, isCovered: false,
                                              isForeground: true, systemAllows: true))
    }

    func test_pickClipSkipsMissingAndEmptyIDs() {
        XCTAssertNil(ThemeBackdrop.pickClip(from: []))
        XCTAssertNil(ThemeBackdrop.pickClip(from: [nil, ""]))
        XCTAssertEqual(ThemeBackdrop.pickClip(from: [nil, "", "a"]), "a")
        XCTAssertTrue(["a", "b"].contains(ThemeBackdrop.pickClip(from: ["a", "b"])))
    }

    func test_coverCheckWalksUpToTheParent() {
        let parent = UIViewController()
        let child = UIViewController()
        parent.addChild(child)
        XCTAssertFalse(ThemeBackdrop.isCovered(child))
        XCTAssertFalse(ThemeBackdrop.isCovered(nil))
    }

    func test_plexKeepsTheDefaultOfNoThemeVideo() async throws {
        let plex = PlexProvider(machineIdentifier: "test", displayName: "Test", serverURL: "http://plex.test",
                                authToken: "t", networkManager: PlexNetworkManager())
        let url = try await plex.themeVideoURL(for: MediaItemRef(providerID: plex.id, itemID: "1"))
        XCTAssertNil(url)
    }

    // MARK: - Session

    func test_leavingDuringLookupDropsTheLateAnswer() async throws {
        let started = expectation(description: "lookup started")
        var continuation: CheckedContinuation<URL?, Never>?
        let session = ThemeVideoSession { _ in
            await withCheckedContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        var displayed = false
        session.onChange = { if $0 != nil { displayed = true } }
        session.update(for: first)
        await fulfillment(of: [started], timeout: 1)
        session.update(for: nil)
        continuation?.resume(returning: clip)
        await settle()
        XCTAssertFalse(displayed)
        XCTAssertNil(session.url)
    }

    func test_oldTitleCannotReplaceTheNewTitle() async throws {
        let started = expectation(description: "old lookup started")
        var continuation: CheckedContinuation<URL?, Never>?
        let newURL = URL(string: "https://example.com/new.mp4")!
        let first = first
        let session = ThemeVideoSession { ref in
            if ref == first {
                return await withCheckedContinuation {
                    continuation = $0
                    started.fulfill()
                }
            }
            return newURL
        }
        session.update(for: first)
        await fulfillment(of: [started], timeout: 1)
        session.update(for: second)
        await settle()
        continuation?.resume(returning: clip)
        await settle()
        XCTAssertEqual(session.url, newURL)
    }

    func test_failedPlaybackStaysOnArtworkForTheVisit() async {
        var lookups = 0
        let session = ThemeVideoSession { _ in
            lookups += 1
            return URL(string: "https://example.com/theme.mp4")
        }
        session.update(for: first)
        await settle()
        XCTAssertNotNil(session.url)
        session.playbackFailed()
        session.update(for: first)
        await settle()
        XCTAssertNil(session.url)
        XCTAssertEqual(lookups, 1)
        session.update(for: nil)
        session.update(for: first)
        await settle()
        XCTAssertEqual(lookups, 2, "A new visit looks up again")
    }

    func test_aFailedLookupKeepsArtworkAndDoesNotRetry() async {
        var lookups = 0
        let session = ThemeVideoSession { _ in
            lookups += 1
            throw MediaProviderError.unreachable
        }
        session.update(for: first)
        session.update(for: first)
        await settle()
        XCTAssertNil(session.url)
        XCTAssertEqual(lookups, 1)
    }

    // MARK: - Controller gating

    func test_noLookupUntilActiveAndEveryGateHolds() async {
        let switches = Switches()
        let backdrop = backdrop(switches)
        backdrop.item = first
        await settle()
        XCTAssertTrue(switches.lookups.isEmpty, "Not active yet")

        backdrop.isActive = true
        await settle()
        XCTAssertEqual(switches.lookups, [first])

        backdrop.isSuspended = true
        backdrop.isSuspended = false
        await settle()
        XCTAssertEqual(switches.lookups, [first, first], "Scrolling away and back is a new visit")
    }

    func test_systemSettingsAndForegroundGateLookups() async {
        let switches = Switches()
        switches.systemAllows = false
        let backdrop = backdrop(switches)
        backdrop.item = first
        backdrop.isActive = true
        await settle()
        XCTAssertTrue(switches.lookups.isEmpty, "Video previews or Reduce Motion block the lookup")

        switches.systemAllows = true
        backdrop.refresh()
        await settle()
        XCTAssertEqual(switches.lookups.count, 1)

        switches.foreground = false
        backdrop.refresh()
        switches.foreground = true
        backdrop.refresh()
        await settle()
        XCTAssertEqual(switches.lookups.count, 2, "Backgrounding releases the clip")
    }

    func test_aPresentedPageOnTopStopsItAndLeavingItResumes() async {
        let switches = Switches()
        let backdrop = backdrop(switches)
        backdrop.item = first
        backdrop.isActive = true
        await settle()
        switches.covered = true
        try? await Task.sleep(for: .milliseconds(450))
        switches.covered = false
        try? await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(switches.lookups, [first, first])
    }

    func test_changingTheTitleLooksUpTheNewOne() async {
        let switches = Switches()
        let backdrop = backdrop(switches)
        backdrop.isActive = true
        backdrop.item = first
        backdrop.item = second
        await settle()
        XCTAssertEqual(switches.lookups.last, second)
    }

    // MARK: - Player

    func test_clipPlaysMutedAndLoopsWithoutTouchingTheAudioSession() async throws {
        let bundle = Bundle(for: Self.self)
        let file = try XCTUnwrap(bundle.url(forResource: "hero-theme", withExtension: "mp4")
            ?? bundle.url(forResource: "hero-theme", withExtension: "mp4", subdirectory: "Fixtures"))
        let session = AVAudioSession.sharedInstance()
        let categoryBefore = session.category
        let switches = Switches()
        let backdrop = backdrop(switches, url: file)
        backdrop.item = first
        backdrop.isActive = true

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while backdrop.layer.opacity < 1, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(backdrop.layer.opacity, 1, "The first frame fades in over the artwork")
        let player = try XCTUnwrap(backdrop.layer.player)
        XCTAssertTrue(player.isMuted)
        XCTAssertFalse(player.allowsExternalPlayback)
        XCTAssertFalse(player.preventsDisplaySleepDuringVideoPlayback)
        XCTAssertEqual(backdrop.layer.videoGravity, .resizeAspectFill)

        var previous = player.currentTime().seconds
        var looped = false
        let loopDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !looped, ContinuousClock.now < loopDeadline {
            try await Task.sleep(for: .milliseconds(20))
            let time = player.currentTime().seconds
            if previous > 1 && time < previous - 0.5 { looped = true }
            previous = time
        }
        XCTAssertTrue(looped)
        XCTAssertEqual(session.category, categoryBefore)

        backdrop.isActive = false
        XCTAssertNil(backdrop.layer.player)
        XCTAssertEqual(backdrop.layer.opacity, 0)
    }

    func test_anUnplayableClipFallsBackToArtwork() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent/theme.mp4")
        let switches = Switches()
        let backdrop = backdrop(switches, url: missing)
        backdrop.item = first
        backdrop.isActive = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while switches.lookups.isEmpty || backdrop.layer.player != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(backdrop.layer.player)
        XCTAssertEqual(backdrop.layer.opacity, 0)
        XCTAssertEqual(switches.lookups.count, 1)
    }
}
