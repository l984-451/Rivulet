// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AVFoundation
import UIKit
import XCTest
@testable import Rivulet

/// The hero's own stop rules: scrolled away, hidden, page changing, page off screen, covered.
@MainActor
final class HeroThemeVideoTests: XCTestCase {
    private let first = MediaItemRef(providerID: "jellyfin:hero", itemID: "first")
    private let second = MediaItemRef(providerID: "jellyfin:hero", itemID: "second")
    /// Two seconds of generated test bars: no server needed to exercise AVPlayer.
    private let clip: URL = {
        let bundle = Bundle(for: HeroThemeVideoTests.self)
        return bundle.url(forResource: "hero-theme", withExtension: "mp4")
            ?? bundle.url(forResource: "hero-theme", withExtension: "mp4", subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: "/missing.mp4")
    }()

    @MainActor
    private final class Counter { var lookups = 0 }

    @MainActor
    private struct Fixture {
        let hero: HeroBackdropView
        let backdrop: ThemeBackdrop
        let host = UIViewController()
        let counter = Counter()

        init(clip: URL) {
            let counter = counter
            backdrop = ThemeBackdrop(
                resolve: { _ in counter.lookups += 1; return clip },
                systemAllows: { true }, isForeground: { true }
            )
            hero = HeroBackdropView(themeVideo: ThemeVideoBackdropView(backdrop: backdrop))
            hero.setActive(true)
        }

        var playing: Bool { backdrop.layer.player != nil }
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(60)) }

    func test_playsOverTheArtworkOnlyWhileShowcasedVisibleAndActive() async {
        let fixture = Fixture(clip: clip)
        fixture.hero.setBackdrop(url: nil, item: first, host: fixture.host)
        await settle()
        XCTAssertTrue(fixture.playing)
        XCTAssertEqual(fixture.counter.lookups, 1)

        fixture.hero.applyScrollOffset(920 - HeroBackdropView.meetY, shelfTop: 920)
        XCTAssertFalse(fixture.playing, "Scrolled away")
        fixture.hero.applyScrollOffset(0, shelfTop: 920)
        await settle()
        XCTAssertTrue(fixture.playing)
        XCTAssertEqual(fixture.counter.lookups, 2)

        fixture.hero.isHidden = true
        XCTAssertFalse(fixture.playing)
        fixture.hero.isHidden = false
        await settle()
        XCTAssertTrue(fixture.playing)

        fixture.hero.setActive(false)
        XCTAssertFalse(fixture.playing, "Another page on top")
        fixture.hero.setActive(true)
        await settle()
        XCTAssertTrue(fixture.playing)
    }

    func test_newArtworkStopsTheClipUntilItsOwnImageSettles() async throws {
        try await expectClipWaitsForPage(.forward)
    }

    func test_backwardPageStopsTheClipUntilItsOwnImageSettles() async throws {
        try await expectClipWaitsForPage(.backward)
    }

    private func expectClipWaitsForPage(_ direction: HeroPageDirection) async throws {
        let fixture = Fixture(clip: clip)
        fixture.hero.setBackdrop(url: nil, item: first, host: fixture.host)
        await settle()
        XCTAssertTrue(fixture.playing)

        // An unreachable image: the page stays changing until the load fails.
        let url = try XCTUnwrap(URL(string: "https://hero-test.invalid/a.jpg"))
        fixture.hero.setBackdrop(url: url, item: second, host: fixture.host, paging: direction)
        XCTAssertFalse(fixture.playing, "No theme during a page change")
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !fixture.playing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(fixture.playing, "Resumes for the settled title")
        XCTAssertEqual(fixture.counter.lookups, 2)
    }

    func test_clearingTheBackdropStopsTheClip() async {
        let fixture = Fixture(clip: clip)
        fixture.hero.setBackdrop(url: nil, item: first, host: fixture.host)
        await settle()
        fixture.hero.setBackdrop(url: nil, item: nil, host: fixture.host)
        XCTAssertFalse(fixture.playing)
    }

    func test_aPresentationOverTheHostStopsTheClip() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let fixture = Fixture(clip: clip)
        root.addChild(fixture.host)
        root.view.addSubview(fixture.host.view)
        fixture.host.didMove(toParent: root)
        fixture.hero.frame = fixture.host.view.bounds
        fixture.host.view.addSubview(fixture.hero)
        fixture.hero.setBackdrop(url: nil, item: first, host: fixture.host)
        await settle()
        XCTAssertTrue(fixture.playing)

        let cover = UIViewController()
        cover.modalPresentationStyle = .overFullScreen
        root.present(cover, animated: false)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(fixture.playing, "The shell presenting on behalf of its child covers the hero")
        root.dismiss(animated: false)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(fixture.playing)
    }
}
