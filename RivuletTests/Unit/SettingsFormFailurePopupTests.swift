// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SettingsFormFailurePopupTests.swift
//  RivuletTests
//
//  A Settings form that fails (Jellyfin sign-in, Live TV add-source) says so
//  in the app's popup card with one OK button, not in a row under the button.
//

import XCTest
@testable import Rivulet

@MainActor
final class SettingsFormFailurePopupTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        SettingsContent.addSourceDraft = nil
        SettingsContent.plexStatus = .idle
        try await super.tearDown()
    }

    private func onScreen(_ page: SettingsPage) throws -> SettingsPageViewController {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let vc = SettingsPageViewController(page: page)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = vc
        window.makeKeyAndVisible()
        self.window = window
        return vc
    }

    private func press(_ rowID: String, on page: SettingsPageViewController) throws {
        let row = try XCTUnwrap(SettingsContent.rows(for: page.page).first { $0.id == rowID })
        guard case .action(_, let handler) = row.kind else { return XCTFail("\(rowID) is not an action row") }
        handler(page)
    }

    private func focusableViews(in view: UIView) -> Int {
        view.subviews.reduce(view.canBecomeFocused ? 1 : 0) { $0 + focusableViews(in: $1) }
    }

    func test_popupWithoutCancelTitle_hasOneButton() {
        let popup = ConfirmationPopupViewController(title: "Couldn't Sign In", message: "Something failed.",
                                                    confirmTitle: "OK", cancelTitle: nil, onConfirm: {})
        popup.loadViewIfNeeded()
        XCTAssertEqual(focusableViews(in: popup.view), 1)
    }

    func test_jellyfinSignInFailure_isAPopup_notARow() throws {
        guard JellyfinSession.account == nil else { throw XCTSkip("a Jellyfin sign-in exists on this simulator") }
        SettingsContent.addSourceDraft = AddSourceDraft()   // no address, no username
        let page = try onScreen(.jellyfin)

        try press("jellyfinSignIn", on: page)

        XCTAssertTrue(page.presentedViewController is ConfirmationPopupViewController)
        XCTAssertFalse(SettingsContent.rows(for: .jellyfin).contains { $0.id == "addSourceError" })
        XCTAssertEqual(SettingsContent.addSourceDraft?.status, .idle, "the button keeps its idle title")
    }

    func test_liveTVFormFailure_isAPopup_notARow() throws {
        SettingsContent.addSourceDraft = AddSourceDraft()   // no address
        let page = try onScreen(.addOwnServer)

        try press("addSourceConfirm", on: page)

        XCTAssertTrue(page.presentedViewController is ConfirmationPopupViewController)
        XCTAssertFalse(SettingsContent.rows(for: .addOwnServer).contains { $0.id == "addSourceError" })
    }
}
