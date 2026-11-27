// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AVFoundation
import Testing
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

@MainActor
struct DetailBackdropBlurTests {
    @Test func entryReturnAndReversalKeepTheEffectHierarchyOpaque() throws {
        let view = DetailBackdropBlurView()
        view.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        view.layoutIfNeeded()
        let effect = try #require(view.subviews.compactMap { $0 as? UIVisualEffectView }.first)

        for progress: CGFloat in [-0.5, 0, 0.25, 0.5, 0.25, 1, 1.5, 0.75, 0] {
            view.update(progress: progress)
            #expect(view.alpha == 1)
            #expect(view.isHidden == (progress <= 0))
            #expect(effect.effect is UIBlurEffect)
            #expect(effect.alpha == 1)
            #expect(effect.frame == view.bounds)
            let mask = try #require(effect.mask)
            #expect(mask.frame == effect.bounds)
            #expect(mask.backgroundColor?.cgColor.alpha == max(0, min(1, progress)))
            #expect(effect.contentView.subviews.isEmpty,
                    "A sharp artwork cover would hide a video behind the backdrop")
        }
        view.frame.size = CGSize(width: 960, height: 540)
        view.layoutIfNeeded()
        #expect(effect.frame == view.bounds)
        #expect(effect.mask?.frame == effect.bounds)
    }

    @Test func renderedMidpointBlendsSharpAndBlurredArtworkInBothDirections() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        let frame = host.view.bounds
        let pattern = UIGraphicsImageRenderer(size: frame.size, format: .layeredArtwork(scale: 1)).image { context in
            let colors: [UIColor] = [.red, .yellow, .cyan, .blue, .white, .black]
            for y in 0..<12 {
                for x in 0..<20 {
                    colors[(x + y) % colors.count].setFill()
                    context.fill(CGRect(x: CGFloat(x) * frame.width / 20, y: CGFloat(y) * frame.height / 12,
                                        width: frame.width / 20, height: frame.height / 12))
                }
            }
        }
        let artwork = UIImageView(image: pattern)
        artwork.frame = frame
        host.view.addSubview(artwork)
        let view = DetailBackdropBlurView()
        view.frame = frame
        host.view.addSubview(view)

        func capture(_ progress: CGFloat) throws -> [UInt8] {
            view.update(progress: progress)
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: frame, format: .layeredArtwork(scale: 1)).image { _ in
                window.drawHierarchy(in: frame, afterScreenUpdates: true)
            }
            return try sampledPixels(image)
        }

        let sharp = try capture(0)
        let entering = try capture(0.5)
        let blurred = try capture(1)
        let returning = try capture(0.5)
        var blendError = 0.0
        var reversalError = 0.0
        var endpointDifference = 0.0
        for i in sharp.indices where i % 4 != 3 {
            let expected = (Double(sharp[i]) + Double(blurred[i])) / 2
            blendError += abs(Double(entering[i]) - expected)
            reversalError += abs(Double(entering[i]) - Double(returning[i]))
            endpointDifference += abs(Double(sharp[i]) - Double(blurred[i]))
        }
        let colorSamples = Double(sharp.count / 4 * 3)
        try #require(endpointDifference / colorSamples > 20,
                     "The window capture must render distinct sharp and blurred endpoints")
        #expect(blendError / colorSamples < 12,
                "The midpoint must blend sharp detail with full blur, rather than scrub blur strength")
        #expect(reversalError / colorSamples < 1,
                "The same progress must render consistently on entry and return")
    }

    @Test func carouselKeepsTheSameFadeWhenVideoStartsAndStopsMidSlide() async throws {
        let bundle = Bundle(for: FixtureBundle.self)
        let file = try #require(bundle.url(forResource: "hero-theme", withExtension: "mp4")
            ?? bundle.url(forResource: "hero-theme", withExtension: "mp4", subdirectory: "Fixtures"))
        let backdrop = ThemeBackdrop(resolve: { _ in file }, systemAllows: { true }, isForeground: { true })
        backdrop.isSuspended = true
        let item = MediaItem(
            ref: MediaItemRef(providerID: "detail-backdrop-test", itemID: "title"), kind: .movie,
            title: "Title", sortTitle: nil, overview: nil, year: nil, runtime: nil,
            parentRef: nil, grandparentRef: nil, episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil
        )
        let controller = PreviewCarouselViewController(
            items: [item], selectedIndex: 0, sourceFrame: .zero, sourceTarget: nil,
            standaloneDetail: true, themeBackdrop: backdrop, onDismiss: { _ in }
        )
        controller.view.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        controller.view.layoutIfNeeded()
        let detail = try #require(controller.view.subviews.compactMap { $0 as? ExpandedDetailContainerView }.first)
        let plane = try #require(controller.view.subviews.compactMap { $0 as? BackdropPlaneView }.first)
        let artwork = try #require(plane.subviews.flatMap(\.subviews).compactMap { $0 as? UIImageView }.first)
        artwork.image = image()
        let view = try #require(controller.view.subviews.compactMap { $0 as? DetailBackdropBlurView }.first)
        let effect = try #require(view.subviews.compactMap { $0 as? UIVisualEffectView }.first)
        let distance = detail.belowFoldCollection.detailsRestOff
        try #require(distance > 0)
        detail.setBelowFoldScrollActive(true)
        func scroll(to progress: CGFloat) {
            detail.driveScrollProgress(fromCollectionOffset: distance * progress)
            let opacity = effect.mask?.backgroundColor?.cgColor.alpha ?? -1
            #expect(abs(opacity - progress) < 0.001)
            #expect(view.isHidden == (progress == 0))
            #expect(view.alpha == 1)
            #expect(effect.alpha == 1)
            #expect(effect.contentView.subviews.isEmpty)
        }

        scroll(to: 0.4)
        try #require(backdrop.isActive && backdrop.item == item.ref)
        backdrop.isSuspended = false
        defer { backdrop.isSuspended = true }

        let deadline = ContinuousClock.now + .seconds(5)
        while backdrop.layer.opacity < 1 {
            try #require(ContinuousClock.now < deadline, "The local video fixture must display its first frame")
            try await Task.sleep(for: .milliseconds(20))
        }
        let player = try #require(backdrop.layer.player)
        for progress: CGFloat in [0.6, 1, 0.6, 0] {
            scroll(to: progress)
            #expect(backdrop.layer.player === player)
            #expect(player.rate > 0, "The fade must not pause or replace the playing backdrop")
        }

        scroll(to: 0.4)
        backdrop.isSuspended = true
        #expect(backdrop.layer.player == nil)
        scroll(to: 0.6)
        scroll(to: 0)
    }

    @Test func backdropIsReleasedAfterIntermediateProgress() {
        weak var releasedView: DetailBackdropBlurView?
        do {
            let view = DetailBackdropBlurView()
            view.update(progress: 0.5)
            releasedView = view
        }
        #expect(releasedView == nil)
    }

    private final class FixtureBundle: NSObject {}

    private func sampledPixels(_ image: UIImage) throws -> [UInt8] {
        let cgImage = try #require(image.cgImage)
        let width = 320, height = 180
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: width, height: height,
                                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                                    | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }
}
