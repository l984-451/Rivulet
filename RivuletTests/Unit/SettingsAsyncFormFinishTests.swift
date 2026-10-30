// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SettingsAsyncFormFinishTests.swift
//  RivuletTests
//
//  Server sign-in/profile and Live TV forms finish after a network call.
//  A fast finish must survive the incoming transition; a late finish must
//  not navigate someone else's page or erase their new draft.
//

import XCTest
@testable import Rivulet

@MainActor
final class SettingsAsyncFormFinishTests: XCTestCase {

    override func tearDown() async throws {
        SettingsContent.cancelSiloFlow()
        SettingsContent.addSourceDraft = nil
        try await super.tearDown()
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(700))
    }

    private func page(_ page: SettingsPage, in container: SettingsContainerViewController) -> SettingsPageViewController? {
        container.children.compactMap { $0 as? SettingsPageViewController }.first { $0.page == page }
    }

    func test_pageThatIsNoLongerOnTop_cannotNavigate() async throws {
        let container = SettingsContainerViewController()
        container.loadViewIfNeeded()
        container.push(.servers)
        try await settle()
        container.push(.jellyfin)
        try await settle()
        XCTAssertEqual(container.depth, 3)

        page(.servers, in: container)?.onPush?(.servers)
        page(.servers, in: container)?.onPop?()
        try await settle()

        XCTAssertEqual(container.depth, 3, "a stale page changed the navigation stack")
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

    func test_fastProfileCompletionDuringIncomingTransition_returnsToServerPage() async throws {
        for hasPIN in [false, true] {
            let container = SettingsContainerViewController(rootPage: .silo)
            container.loadViewIfNeeded()
            let serverPage = try XCTUnwrap(page(.silo, in: container))
            container.push(.siloProfiles)
            if hasPIN {
                page(.siloProfiles, in: container)?.onPush?(.siloProfilePIN)
                let deadline = Date().addingTimeInterval(5)
                while page(.siloProfilePIN, in: container) == nil, Date() < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            let completingPage = try XCTUnwrap(page(hasPIN ? .siloProfilePIN : .siloProfiles, in: container))
            if hasPIN { completingPage.onPopTwo?() }
            else { completingPage.onPop?() }

            let deadline = Date().addingTimeInterval(5)
            while completingPage.parent != nil, Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(container.children.compactMap { ($0 as? SettingsPageViewController)?.page }, [.silo])
            XCTAssertTrue(container.children.first === serverPage)
            XCTAssertEqual(container.depth, 1)
        }
    }

}
