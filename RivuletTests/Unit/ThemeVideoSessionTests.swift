// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class ThemeVideoSessionTests: XCTestCase {
    private let first = MediaItemRef(providerID: "jellyfin:srv", itemID: "first")
    private let second = MediaItemRef(providerID: "jellyfin:srv", itemID: "second")

    func test_leavingDuringLookupReleasesLateVideoWithoutDisplayingIt() async throws {
        let started = expectation(description: "lookup started")
        let stopped = expectation(description: "late video released")
        var continuation: CheckedContinuation<ThemeVideo?, Never>?
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
        let url = try XCTUnwrap(URL(string: "https://example.com/theme.mp4"))
        continuation?.resume(returning: ThemeVideo(url: url, stop: { stopped.fulfill() }))
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertFalse(displayed)
        XCTAssertNil(session.video)
    }

    func test_oldTitleCannotReplaceTheNewTitle() async throws {
        let started = expectation(description: "old lookup started")
        let displayed = expectation(description: "new video displayed")
        let stoppedOld = expectation(description: "old video released")
        let stoppedNew = expectation(description: "new video released")
        var continuation: CheckedContinuation<ThemeVideo?, Never>?
        let oldURL = try XCTUnwrap(URL(string: "https://example.com/old.mp4"))
        let newURL = try XCTUnwrap(URL(string: "https://example.com/new.mp4"))
        let first = first
        let session = ThemeVideoSession { ref in
            if ref == first {
                return await withCheckedContinuation {
                    continuation = $0
                    started.fulfill()
                }
            }
            return ThemeVideo(url: newURL, stop: { stoppedNew.fulfill() })
        }
        session.onChange = { if $0?.url == newURL { displayed.fulfill() } }
        session.update(for: first)
        await fulfillment(of: [started], timeout: 1)
        session.update(for: second)
        await fulfillment(of: [displayed], timeout: 1)
        continuation?.resume(returning: ThemeVideo(url: oldURL, stop: { stoppedOld.fulfill() }))
        await fulfillment(of: [stoppedOld], timeout: 1)
        XCTAssertEqual(session.video?.url, newURL)
        session.update(for: nil)
        await fulfillment(of: [stoppedNew], timeout: 1)
    }

    func test_failedPlaybackReleasesSessionAndDoesNotRetryWhileVisible() async throws {
        let displayed = expectation(description: "video displayed")
        let stopped = expectation(description: "video released")
        let url = try XCTUnwrap(URL(string: "https://example.com/theme.mp4"))
        var lookups = 0
        let session = ThemeVideoSession { _ in
            lookups += 1
            return ThemeVideo(url: url, stop: { stopped.fulfill() })
        }
        session.onChange = { if $0 != nil { displayed.fulfill() } }
        session.update(for: first)
        await fulfillment(of: [displayed], timeout: 1)
        session.playbackFailed()
        session.update(for: first)
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertEqual(lookups, 1)
        XCTAssertNil(session.video)
    }

    func test_hiddenSessionMakesNoRequestAndReturningStartsANewVisit() async {
        let firstLookup = expectation(description: "first visit")
        let secondLookup = expectation(description: "second visit")
        var lookups = 0
        let session = ThemeVideoSession { _ in
            lookups += 1
            (lookups == 1 ? firstLookup : secondLookup).fulfill()
            return nil
        }
        session.update(for: nil)
        XCTAssertEqual(lookups, 0)
        session.update(for: first)
        await fulfillment(of: [firstLookup], timeout: 1)
        session.update(for: first)
        session.update(for: nil)
        session.update(for: first)
        await fulfillment(of: [secondLookup], timeout: 1)
        XCTAssertEqual(lookups, 2)
    }
}
