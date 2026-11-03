// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AVFoundation
import UIKit
import XCTest
@testable import Rivulet

@MainActor
final class HeroThemeVideoTests: XCTestCase {
    private let first = MediaItemRef(providerID: "jellyfin:hero-test", itemID: "first")
    private let second = MediaItemRef(providerID: "jellyfin:hero-test", itemID: "second")
    private let third = MediaItemRef(providerID: "jellyfin:hero-test", itemID: "third")

    private func clipURL() throws -> URL {
        // Two seconds of generated moving test bars plus a tone. No server,
        // credentials, or copyrighted media are needed to exercise AVPlayer.
        let bundle = Bundle(for: Self.self)
        return try XCTUnwrap(bundle.url(forResource: "hero-theme", withExtension: "mp4")
            ?? bundle.url(forResource: "hero-theme", withExtension: "mp4", subdirectory: "Fixtures"))
    }

    private func artworkURL(_ name: String = "shared") throws -> URL {
        try XCTUnwrap(URL(string: "https://hero-test.invalid/\(name).jpg"))
    }

    private static func still(_ color: UIColor = .blue) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 18)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 18))
        }
    }

    private func eventually(_ message: String, timeout: Duration = .seconds(5),
                            file: StaticString = #filePath, line: UInt = #line,
                            _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(predicate(), message, file: file, line: line)
    }

    @MainActor
    private final class Fixture {
        let root = UIViewController()
        let host = UIViewController()
        let window: UIWindow
        let video: ThemeVideoBackdropView
        let hero: HeroBackdropView
        private let previousWindow: UIWindow?
        private let previousSetting: Any?

        var playerLayer: AVPlayerLayer? { video.layer.sublayers?.compactMap { $0 as? AVPlayerLayer }.first }
        var stillView: UIImageView? { video.superview as? UIImageView }

        init(resolve: @escaping ThemeVideoSession.Resolver,
             loadImage: @escaping @MainActor @Sendable (URL) async -> UIImage? = { _ in HeroThemeVideoTests.still() }) throws {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
            previousWindow = scene.windows.first(where: \.isKeyWindow)
            previousSetting = UserDefaults.standard.object(forKey: ThemeVideoBackdropView.enabledKey)
            UserDefaults.standard.set(true, forKey: ThemeVideoBackdropView.enabledKey)
            video = ThemeVideoBackdropView(resolve: resolve)
            hero = HeroBackdropView(themeVideo: video, loadImage: loadImage)
            window = UIWindow(windowScene: scene)
            window.rootViewController = root
            root.addChild(host)
            root.view.addSubview(host.view)
            host.didMove(toParent: root)
            window.makeKeyAndVisible()
            host.view.frame = root.view.bounds
            hero.frame = host.view.bounds
            host.view.addSubview(hero)
            window.layoutIfNeeded()
            hero.setActive(true)
        }

        func close() {
            hero.setActive(false)
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
            UserDefaults.standard.set(previousSetting, forKey: ThemeVideoBackdropView.enabledKey)
        }
    }

    func test_videoRendersOverArtworkUnderScrimsAndLoopsMuted() async throws {
        let clip = try clipURL()
        let fixture = try Fixture(resolve: { _ in ThemeVideo(url: clip) })
        defer { fixture.close() }
        fixture.hero.setBackdrop(url: try artworkURL(), item: first, host: fixture.host)

        try await eventually("The first video frame appears over the still") {
            fixture.playerLayer?.isReadyForDisplay == true && fixture.video.alpha == 1
        }
        let layer = try XCTUnwrap(fixture.playerLayer)
        let player = try XCTUnwrap(layer.player)
        let still = try XCTUnwrap(fixture.stillView)
        let page = try XCTUnwrap(still.superview)
        XCTAssertNotNil(still.image, "The fallback artwork remains underneath the video")
        XCTAssertEqual(fixture.video.bounds, still.bounds)
        XCTAssertEqual(still.bounds, fixture.hero.bounds)
        XCTAssertTrue(still.clipsToBounds)
        XCTAssertEqual(layer.videoGravity, .resizeAspectFill)
        XCTAssertTrue(player.isMuted)
        XCTAssertFalse(player.allowsExternalPlayback)
        XCTAssertFalse(player.preventsDisplaySleepDuringVideoPlayback)
        let layers = try XCTUnwrap(fixture.hero.layer.sublayers)
        let pageIndex = try XCTUnwrap(layers.firstIndex(of: page.layer))
        XCTAssertTrue(layers.suffix(from: pageIndex + 1).contains { $0 is CAGradientLayer },
                      "The hero scrims must shade the video as well as the still")

        var previousTime = player.currentTime().seconds
        var looped = false
        try await eventually("The decorative clip actually loops", timeout: .seconds(4)) {
            let time = player.currentTime().seconds
            if previousTime > 1 && time < previousTime - 0.5 { looped = true }
            previousTime = time
            return looped
        }
        XCTAssertGreaterThan(player.rate, 0)
    }

    func test_sharedArtworkStillSwitchesTitleAndMissingVideoKeepsStill() async throws {
        let clip = try clipURL()
        let first = first
        var requests: [MediaItemRef] = []
        let fixture = try Fixture(resolve: { ref in
            requests.append(ref)
            return ref == first ? ThemeVideo(url: clip) : nil
        })
        defer { fixture.close() }
        let artwork = try artworkURL()
        fixture.hero.setBackdrop(url: artwork, item: first, host: fixture.host)
        try await eventually("First title starts") { fixture.playerLayer?.player != nil }
        let still = fixture.stillView?.image
        fixture.hero.setBackdrop(url: artwork, item: second, host: fixture.host, paging: true)
        XCTAssertNil(fixture.playerLayer?.player, "The previous title stops immediately")
        try await eventually("The new title is looked up even with the same image URL") { requests.count == 2 }
        XCTAssertEqual(requests, [first, second])
        XCTAssertEqual(fixture.video.alpha, 0)
        XCTAssertTrue(fixture.stillView?.image === still)
        fixture.hero.setBackdrop(url: artwork, item: second, host: fixture.host)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(requests.count, 2, "A title without a clip must not retry on each visibility check")
    }

    func test_rapidPagingDiscardsLateArtworkAndStartsOnlySettledTitle() async throws {
        let clip = try clipURL()
        let slowURL = try artworkURL("slow")
        let thirdImage = Self.still(.green)
        let imageStarted = expectation(description: "second artwork requested")
        var lateImage: CheckedContinuation<UIImage?, Never>?
        var requests: [MediaItemRef] = []
        let fixture = try Fixture(resolve: { ref in
            requests.append(ref)
            return ThemeVideo(url: clip)
        }, loadImage: { url in
            if url == slowURL {
                return await withCheckedContinuation {
                    lateImage = $0
                    imageStarted.fulfill()
                }
            }
            return url.lastPathComponent == "third.jpg" ? thirdImage : Self.still()
        })
        defer { fixture.close() }
        fixture.hero.setBackdrop(url: try artworkURL(), item: first, host: fixture.host)
        try await eventually("First title starts") { requests.count == 1 }
        fixture.hero.setBackdrop(url: slowURL, item: second, host: fixture.host, paging: true)
        await fulfillment(of: [imageStarted], timeout: 1)
        XCTAssertNil(fixture.playerLayer?.player)
        fixture.hero.setBackdrop(url: try artworkURL("third"), item: third, host: fixture.host, paging: true)
        lateImage?.resume(returning: Self.still(.red))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(requests, [first], "Do not start a theme during the page slide")
        try await eventually("Only the final page starts its theme") { requests.count == 2 }
        XCTAssertEqual(requests, [first, third])
        XCTAssertTrue(fixture.stillView?.image === thirdImage, "A late image cannot replace the selected page")
        XCTAssertEqual(fixture.stillView?.transform, .identity)
        XCTAssertEqual(fixture.stillView?.superview?.transform, .identity)
    }

    func test_scrollHidingAndLeavingReleasePlaybackAndReturningRestarts() async throws {
        let clip = try clipURL()
        var requests = 0
        let fixture = try Fixture(resolve: { _ in
            requests += 1
            return ThemeVideo(url: clip)
        })
        defer { fixture.close() }
        fixture.hero.setBackdrop(url: try artworkURL(), item: first, host: fixture.host)
        try await eventually("Initial visit") { fixture.playerLayer?.player != nil }

        fixture.hero.applyScrollOffset(920 - HeroBackdropView.meetY, shelfTop: 920)
        XCTAssertNil(fixture.playerLayer?.player)
        fixture.hero.applyScrollOffset(0, shelfTop: 920)
        try await eventually("Scroll back to hero") { requests == 2 && fixture.playerLayer?.player != nil }
        fixture.hero.isHidden = true
        XCTAssertNil(fixture.playerLayer?.player)
        fixture.hero.isHidden = false
        try await eventually("Unhide hero") { requests == 3 && fixture.playerLayer?.player != nil }
        fixture.hero.setActive(false)
        XCTAssertNil(fixture.playerLayer?.player)
        fixture.hero.setActive(true)
        try await eventually("Return to screen") { requests == 4 && fixture.playerLayer?.player != nil }
        fixture.hero.setBackdrop(url: nil, host: fixture.host)
        XCTAssertNil(fixture.playerLayer?.player)
        XCTAssertNil(fixture.stillView?.image)
    }

    func test_interruptingASlideKeepsVideoStoppedUntilNextArtworkArrives() async throws {
        let clip = try clipURL()
        let slowURL = try artworkURL("slow")
        let imageStarted = expectation(description: "next artwork requested")
        var lateImage: CheckedContinuation<UIImage?, Never>?
        var requests: [MediaItemRef] = []
        let fixture = try Fixture(resolve: { ref in
            requests.append(ref)
            return ThemeVideo(url: clip)
        }, loadImage: { url in
            if url == slowURL {
                return await withCheckedContinuation {
                    lateImage = $0
                    imageStarted.fulfill()
                }
            }
            return Self.still()
        })
        defer { fixture.close() }
        fixture.hero.setBackdrop(url: try artworkURL(), item: first, host: fixture.host)
        try await eventually("First title starts") { requests.count == 1 }
        fixture.hero.setBackdrop(url: try artworkURL("second"), item: second, host: fixture.host, paging: true)
        try await Task.sleep(for: .milliseconds(100))
        fixture.hero.setBackdrop(url: slowURL, item: third, host: fixture.host, paging: true)
        await fulfillment(of: [imageStarted], timeout: 1)
        try await Task.sleep(for: .milliseconds(1100))
        let requestedWhileLoading = requests
        let wasStopped = fixture.playerLayer?.player == nil
        lateImage?.resume(returning: Self.still(.green))
        XCTAssertEqual(requestedWhileLoading, [first], "The interrupted animator cannot start the next theme early")
        XCTAssertTrue(wasStopped)
        try await eventually("The selected title starts after its own image and slide") { requests.count == 2 }
        XCTAssertEqual(requests, [first, third])
    }

    func test_shellPresentationAndSettingDisablePlayback() async throws {
        let clip = try clipURL()
        var requests = 0
        let fixture = try Fixture(resolve: { _ in
            requests += 1
            return ThemeVideo(url: clip)
        })
        defer { fixture.close() }
        fixture.hero.setBackdrop(url: try artworkURL(), item: first, host: fixture.host)
        try await eventually("Initial visit") { fixture.playerLayer?.player != nil }
        let detail = UIViewController()
        detail.modalPresentationStyle = .overFullScreen
        fixture.root.present(detail, animated: false)
        try await eventually("The shell's presentation covers its child hero") { fixture.playerLayer?.player == nil }
        fixture.root.dismiss(animated: false)
        try await eventually("Dismissal resumes the hero") { requests == 2 && fixture.playerLayer?.player != nil }
        UserDefaults.standard.set(false, forKey: ThemeVideoBackdropView.enabledKey)
        try await eventually("Turning off animated backdrops releases the player") { fixture.playerLayer?.player == nil }
        XCTAssertNotNil(fixture.stillView?.image)
        UserDefaults.standard.set(true, forKey: ThemeVideoBackdropView.enabledKey)
        try await eventually("Re-enabling starts a fresh visit") { requests == 3 && fixture.playerLayer?.player != nil }
    }

    func test_videoCanPlayWithoutArtworkAndFailedVideoFallsBack() async throws {
        let clip = try clipURL()
        let first = first
        let missing = clip.deletingLastPathComponent().appendingPathComponent("missing-theme.mp4")
        var requests = 0
        let fixture = try Fixture(resolve: { ref in
            requests += 1
            return ThemeVideo(url: ref == first ? clip : missing)
        })
        defer { fixture.close() }
        fixture.hero.setBackdrop(url: nil, item: first, host: fixture.host)
        try await eventually("A missing still does not block a valid theme") {
            fixture.playerLayer?.isReadyForDisplay == true && fixture.video.alpha == 1
        }
        fixture.hero.setBackdrop(url: try artworkURL(), item: second, host: fixture.host)
        try await eventually("An invalid clip falls back to artwork") {
            requests == 2 && fixture.playerLayer?.player == nil && fixture.stillView?.image != nil
        }
        XCTAssertEqual(fixture.video.alpha, 0)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(requests, 2)
    }
}
