// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SettingsAsyncFormFinishTests.swift
//  RivuletTests
//
//  The Jellyfin sign-in and the Live TV add-source forms finish after a
//  network call. By then the user may have pressed Menu and moved on; the
//  late finish must not pop someone else's page or erase their new draft.
//

import XCTest
@testable import Rivulet

@MainActor
final class SettingsAsyncFormFinishTests: XCTestCase {

    override func tearDown() async throws {
        SettingsContent.addSourceDraft = nil
        try await super.tearDown()
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(700))   // one page transition is 0.45s
    }

    private func page(_ page: SettingsPage, in container: SettingsContainerViewController) -> SettingsPageViewController? {
        container.children.compactMap { $0 as? SettingsPageViewController }.first { $0.page == page }
    }

    func test_pageThatIsNoLongerOnTop_cannotPop() async throws {
        let container = SettingsContainerViewController()
        container.loadViewIfNeeded()
        container.push(.servers)
        try await settle()
        container.push(.jellyfin)
        try await settle()
        XCTAssertEqual(container.depth, 3)

        page(.servers, in: container)?.onPop?()
        try await settle()

        XCTAssertEqual(container.depth, 3, "a page underneath the top one popped the top one")
    }

    func test_topPage_canStillPop() async throws {
        let container = SettingsContainerViewController()
        container.loadViewIfNeeded()
        container.push(.servers)
        try await settle()

        page(.servers, in: container)?.onPop?()
        try await settle()

        XCTAssertEqual(container.depth, 1)
    }

    func test_lateFinish_leavesANewerDraftAlone() {
        let stale = AddSourceDraft()
        let current = AddSourceDraft()
        SettingsContent.addSourceDraft = current

        SettingsContent.finish(nil, draft: stale)

        XCTAssertTrue(SettingsContent.addSourceDraft === current)
    }

    func test_finish_clearsItsOwnDraft() {
        let draft = AddSourceDraft()
        SettingsContent.addSourceDraft = draft

        SettingsContent.finish(nil, draft: draft)

        XCTAssertNil(SettingsContent.addSourceDraft)
    }

    // MARK: - Jellyfin failure copy

    func test_tooOldCopy_namesBothVersions() {
        let copy = SettingsContent.jellyfinFailureCopy(for: JellyfinSignInError.serverTooOld(version: "10.8.13"))
        let floor = "\(JellyfinSession.minimumVersion.major).\(JellyfinSession.minimumVersion.minor)"
        XCTAssertTrue(copy.contains("10.8.13"), copy)
        XCTAssertTrue(copy.contains(floor), copy)
    }

    func test_untrustedCertificateCopy_namesTheCertificate() {
        let copy = SettingsContent.jellyfinFailureCopy(for: JellyfinSignInError.untrustedCertificate)
        XCTAssertTrue(copy.localizedCaseInsensitiveContains("certificate"), copy)
    }
}
