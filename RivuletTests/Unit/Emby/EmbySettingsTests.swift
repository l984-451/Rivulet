// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbySettingsTests.swift
//  RivuletTests
//
//  The Emby Settings page, its panel descriptors, its failure copy and its
//  setup-landing card. A sign-in already on the simulator is set aside.
//

import XCTest
@testable import Rivulet

@MainActor
final class EmbySettingsTests: XCTestCase {
    private var existingAccount: Data?
    private var window: UIWindow?

    override func setUp() async throws {
        try await super.setUp()
        existingAccount = UserDefaults.standard.data(forKey: EmbySession.accountKey)
        UserDefaults.standard.removeObject(forKey: EmbySession.accountKey)
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        SettingsContent.addSourceDraft = nil
        if let existingAccount {
            UserDefaults.standard.set(existingAccount, forKey: EmbySession.accountKey)
        } else {
            UserDefaults.standard.removeObject(forKey: EmbySession.accountKey)
        }
        try await super.tearDown()
    }

    private func signInStub() throws {
        let account = EmbySession.Account(
            serverURL: URL(string: "http://127.0.0.1:9")!, serverID: "settings-test",
            serverName: "Den Emby", userID: "u1", userName: "bain", policy: EmbySession.Policy())
        UserDefaults.standard.set(try JSONEncoder().encode(account), forKey: EmbySession.accountKey)
    }

    private func ids(_ page: SettingsPage) -> [String] { SettingsContent.rows(for: page).map(\.id) }

    // MARK: - Rows

    func test_signedOut_isTheFormWithoutQuickConnect() {
        SettingsContent.addSourceDraft = AddSourceDraft()
        XCTAssertEqual(ids(.emby), ["embyURL", "embyUsername", "embyPassword", "embySignIn"])
    }

    func test_signedOut_withoutADraft_hasNoRows() {
        SettingsContent.addSourceDraft = nil
        XCTAssertTrue(ids(.emby).isEmpty)
    }

    func test_signedIn_showsServerUserRefreshSignOut() throws {
        try signInStub()
        XCTAssertEqual(ids(.emby), ["embyServerInfo", "embyUserInfo", "embyRefresh", "embySignOut"])
        let values = SettingsContent.rows(for: .emby).compactMap(\.valueText)
        XCTAssertEqual(Array(values.prefix(2)), ["Den Emby", "bain"])
    }

    /// The row shows only while the server's Live TV is installed or hidden, and sits between Server and User.
    func test_signedIn_liveTVToggle_followsTheSource() throws {
        try signInStub()
        EmbyLiveTVProvider.hiddenSource = nil
        XCTAssertFalse(ids(.emby).contains("embyLiveTV"))

        EmbyLiveTVProvider.hiddenSource = LiveTVDataStore.LiveTVSourceInfo(
            id: "emby:settings-test", sourceType: .emby, displayName: "Den Emby Live TV",
            channelCount: 0, isConnected: false, lastSync: nil)
        defer { EmbyLiveTVProvider.hiddenSource = nil }
        XCTAssertEqual(ids(.emby), ["embyServerInfo", "embyLiveTV", "embyUserInfo", "embyRefresh", "embySignOut"])
        XCTAssertNotNil(SettingsDescriptorStore.descriptor(for: "embyLiveTV"))
    }

    /// A hidden source's detail page is the toggle alone, the way back; the Jellyfin rule.
    func test_hiddenEmbySource_detailPageIsTheToggleAlone() {
        let source = LiveTVDataStore.LiveTVSourceInfo(
            id: "emby:x", sourceType: .emby, displayName: "Den Emby Live TV",
            channelCount: 0, isConnected: false, lastSync: nil)
        EmbyLiveTVProvider.hiddenSource = source
        defer { EmbyLiveTVProvider.hiddenSource = nil; SettingsContent.pendingSourceDetail = nil }
        SettingsContent.pendingSourceDetail = source
        XCTAssertEqual(ids(.liveTVSourceDetail), ["src_showInLiveTV"])

        EmbyLiveTVProvider.hiddenSource = nil
        XCTAssertEqual(ids(.liveTVSourceDetail).first, "src_showInLiveTV", "shown beside the status rows while on")
        XCTAssertGreaterThan(ids(.liveTVSourceDetail).count, 1)
        XCTAssertFalse(ids(.liveTVSourceDetail).contains("removeSource"), "a server's Live TV leaves with its sign-in")
    }

    func test_liveTVSourcesList_includesTheHiddenEmbySourceAsOff() {
        let source = LiveTVDataStore.LiveTVSourceInfo(
            id: "emby:x", sourceType: .emby, displayName: "Den Emby Live TV",
            channelCount: 0, isConnected: false, lastSync: nil)
        EmbyLiveTVProvider.hiddenSource = source
        defer { EmbyLiveTVProvider.hiddenSource = nil }
        let row = SettingsContent.rows(for: .iptv).first { $0.id == "src_emby:x" }
        XCTAssertEqual(row?.valueText, "Off")
    }

    func test_serversPage_listsEmbyBesideJellyfin_withTheServerName() throws {
        try signInStub()
        let servers = SettingsContent.rows(for: .servers)
        XCTAssertEqual(servers.map(\.id), ["plexServer", "jellyfinServer", "embyServer"])
        XCTAssertEqual(servers.last?.valueText, "Den Emby")
        guard case .navigationAction(let page, _, let prepare) = servers.last?.kind else { return XCTFail("not a navigation row") }
        XCTAssertEqual(page, .emby)
        SettingsContent.addSourceDraft = nil
        prepare()
        XCTAssertNotNil(SettingsContent.addSourceDraft)
    }

    func test_signInFormTitles_areTheFieldNames() {
        let titles = SettingsContent.embySteps(AddSourceDraft()).map(\.title)
        XCTAssertEqual(titles, ["Server Address", "Username", "Password"])
    }

    // MARK: - Descriptors

    func test_everyEmbyRowHasADescriptor() throws {
        SettingsContent.addSourceDraft = AddSourceDraft()
        var all = ids(.emby)
        try signInStub()
        all += ids(.emby) + SettingsContent.rows(for: .servers).map(\.id)
        for id in all where id.hasPrefix("emby") {
            XCTAssertNotNil(SettingsDescriptorStore.descriptor(for: id), "\(id) has no description panel entry")
        }
    }

    func test_pageInfo_usesGreen_notJellyfinPurpleOrServersOrange() {
        XCTAssertEqual(SettingsDescriptorStore.pageInfo(for: .emby).color, .systemGreen)
        XCTAssertEqual(SettingsPage.emby.title, "Emby Server")
    }

    func test_serversDescriptor_namesEveryServerKind() {
        let text = SettingsDescriptorStore.descriptor(for: "cat_servers")?.description ?? ""
        XCTAssertTrue(text.contains("Jellyfin") && text.contains("Emby"), text)
    }

    // MARK: - Failure copy

    func test_failureCopy_eachSignInError() {
        let copy = EmbySession.failureMessage
        XCTAssertTrue(copy(EmbySignInError.notEmby).contains("isn't an Emby server"))
        XCTAssertTrue(copy(EmbySignInError.notEmby).contains("Jellyfin"))
        XCTAssertEqual(copy(EmbySignInError.serverTooOld(version: "4.7.0.0")), "Rivulet needs Emby Server 4.8.11 or newer.")
        XCTAssertTrue(copy(EmbySignInError.untrustedCertificate).localizedCaseInsensitiveContains("certificate"))
        XCTAssertEqual(copy(EmbySignInError.invalidCredentials), "Emby didn't accept that username and password.")
        XCTAssertEqual(copy(MediaProviderError.unauthorized), copy(EmbySignInError.invalidCredentials))
        XCTAssertEqual(copy(MediaProviderError.unreachable), "Couldn't reach that server. Check the address and port.")
    }

    func test_failureCopy_showsTheServersOwnMessageForEveryForbiddenCause() {
        let locked = "Your account has been temporarily locked out. Try again later."
        let disabled = "Your account has been disabled. Please contact your system administrator."
        let blocked = "You've not been granted remote access to this server."
        XCTAssertEqual(EmbySession.failureMessage(for: EmbySignInError.lockedOut(message: locked)), locked)
        XCTAssertEqual(EmbySession.failureMessage(for: EmbySignInError.accountDisabled(message: disabled)), disabled)
        XCTAssertEqual(EmbySession.failureMessage(for: EmbySignInError.notAllowed(message: blocked)), blocked)
    }

    func test_signInWithNoAddress_isAPopup_notARow() throws {
        SettingsContent.addSourceDraft = AddSourceDraft()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let page = SettingsPageViewController(page: .emby)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = page
        window.makeKeyAndVisible()
        self.window = window

        let row = try XCTUnwrap(SettingsContent.rows(for: .emby).first { $0.id == "embySignIn" })
        guard case .action(_, let handler) = row.kind else { return XCTFail("not an action row") }
        handler(page)

        XCTAssertTrue(page.presentedViewController is ConfirmationPopupViewController)
        XCTAssertEqual(SettingsContent.addSourceDraft?.status, .idle)
    }

    // MARK: - Setup landing

    private func cardSubtitle(_ landing: SetupLandingViewController, title: String) -> String? {
        func buttons(_ view: UIView) -> [UIButton] { ((view as? UIButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons) }
        let card = buttons(landing.view).first { $0.configuration?.title == title }
        return card?.configuration?.attributedSubtitle.map { String($0.characters) }
    }

    func test_landing_hasAnEmbyCard_thatPromptsThenNamesTheServer() throws {
        let landing = SetupLandingViewController()
        landing.loadViewIfNeeded()
        XCTAssertEqual(cardSubtitle(landing, title: "Emby"), "Sign In")

        try signInStub()
        XCTAssertTrue(SetupLandingViewController.hasAnySource)
        let signedIn = SetupLandingViewController()
        signedIn.loadViewIfNeeded()
        XCTAssertEqual(cardSubtitle(signedIn, title: "Emby"), "✓ Den Emby")
    }

    func test_landing_fourCardsFitInsideTheMargins() {
        let landing = SetupLandingViewController()
        landing.loadViewIfNeeded()
        landing.view.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        landing.view.layoutIfNeeded()
        func cards(_ view: UIView) -> [UIButton] {
            ((view as? UIButton).flatMap { $0.bounds.height == 300 ? [$0] : nil } ?? []) + view.subviews.flatMap(cards)
        }
        let frames = cards(landing.view).map { $0.convert($0.bounds, to: landing.view) }
        XCTAssertEqual(frames.count, 4)
        XCTAssertGreaterThanOrEqual(frames.map(\.minX).min() ?? 0, 80)
        XCTAssertLessThanOrEqual(frames.map(\.maxX).max() ?? 0, 1920 - 80)
    }
}
