// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexProfileSessionTests.swift
//  RivuletTests
//
//  A saved Plex Home profile launches on its own stored token or on none,
//  never on the account's. Pure functions only: this runs on a signed-in
//  simulator, so nothing here touches its Keychain or UserDefaults.
//

import XCTest
@testable import Rivulet

final class PlexProfileSessionTests: XCTestCase {

    private typealias Session = PlexProfileSession

    private func content(account: String? = "acct", saved: Int? = 7,
                         session: Session?, everResolved: Bool = true) -> Session.Content {
        Session.content(accountToken: account, savedUserID: saved, session: session, everResolved: everResolved)
    }

    // MARK: The launch rule

    func test_signedOut_isWithheld() {
        XCTAssertEqual(content(account: nil, session: nil), .withheld)
    }

    func test_noSavedProfile_usesTheAccount() {
        XCTAssertEqual(content(saved: nil, session: nil), .account)
        // A leftover session for some profile changes nothing.
        let stale = Session(userID: 7, accountToken: "acct", access: .token("kid"))
        XCTAssertEqual(content(saved: nil, session: stale), .account)
    }

    func test_savedProfileWithItsSession_usesItsToken() {
        let session = Session(userID: 7, accountToken: "acct", access: .token("kid"))
        XCTAssertEqual(content(session: session), .profile("kid"))
    }

    func test_sessionForAnotherProfile_isWithheld() {
        let session = Session(userID: 8, accountToken: "acct", access: .token("other"))
        XCTAssertEqual(content(session: session), .withheld)
        // Even one that says "account": the owner marker follows the user id.
        let owner = Session(userID: 1, accountToken: "acct", access: .account)
        XCTAssertEqual(content(session: owner), .withheld)
    }

    func test_sessionFromAnotherAccount_isWithheld() {
        let session = Session(userID: 7, accountToken: "old-acct", access: .token("kid"))
        XCTAssertEqual(content(session: session), .withheld)
    }

    func test_ownerProfile_usesTheAccount() {
        let session = Session(userID: 7, accountToken: "acct", access: .account)
        XCTAssertEqual(content(session: session), .account)
    }

    func test_profileThatNeedsPlexTV_isWithheld() {
        let session = Session(userID: 7, accountToken: "acct", access: .withheld)
        XCTAssertEqual(content(session: session), .withheld)
    }

    /// A lost Keychain item must not hand a resolved profile the account's token.
    func test_resolvedProfileWithNoSession_isWithheld() {
        XCTAssertEqual(content(session: nil, everResolved: true), .withheld)
    }

    /// The first launch after the update asks plex.tv before loading anything:
    /// a saved profile never starts on the account's token.
    func test_neverResolved_isUnresolved_notTheAccount() {
        XCTAssertEqual(content(session: nil, everResolved: false), .unresolved)
    }

    /// A record in a shape this build cannot read counts as no record.
    func test_unreadableRecord_isNoSession() {
        let old = Data(#"{"userID":7,"accountToken":"acct","access":{"account":{}}}"#.utf8)
        XCTAssertNil(try? JSONDecoder().decode(Session.self, from: old))
    }

    func test_recordHoldsNoCopyOfTheAccountToken() throws {
        let session = Session(userID: 7, accountToken: "acct-secret", access: .account)
        let stored = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        XCTAssertFalse(stored.contains("acct-secret"))
        XCTAssertEqual(session.accountTokenHash.count, 64)
    }

    // MARK: Who the account is

    /// A Home member signed in with their own account: their profile is the
    /// account, and the Home admin's is somebody else's.
    func test_accountIsTheSignedInUser_notTheAdmin() {
        XCTAssertTrue(Session.isAccount(userID: 7, admin: false, accountUserID: 7))
        XCTAssertFalse(Session.isAccount(userID: 1, admin: true, accountUserID: 7))
    }

    /// Until the account's id is known the admin flag stands in, as before.
    func test_unknownAccountID_fallsBackToTheAdminFlag() {
        XCTAssertTrue(Session.isAccount(userID: 1, admin: true, accountUserID: nil))
        XCTAssertFalse(Session.isAccount(userID: 7, admin: false, accountUserID: nil))
    }

    // MARK: What an entry stores

    func test_accountEntry_storesNoToken() {
        XCTAssertEqual(Session.access(isAccount: true, usedPin: false, serverToken: "t"), .account)
        XCTAssertEqual(Session.access(isAccount: true, usedPin: true, serverToken: "t"), .account)
    }

    /// A PIN entry must not leave a token a later launch could use without the PIN.
    func test_pinEntry_storesWithheld() {
        XCTAssertEqual(Session.access(isAccount: false, usedPin: true, serverToken: "t"), .withheld)
    }

    func test_pinlessEntry_storesItsToken() {
        XCTAssertEqual(Session.access(isAccount: false, usedPin: false, serverToken: "t"), .token("t"))
    }

    // MARK: Storage shape

    func test_sessionRoundTripsThroughJSON() throws {
        for access in [Session.Access.account, .token("kid"), .withheld] {
            let session = Session(userID: 7, accountToken: "acct", access: access)
            let data = try JSONEncoder().encode(session)
            XCTAssertEqual(try JSONDecoder().decode(Session.self, from: data), session)
        }
    }

    // MARK: Restoring the saved profile

    private typealias Manager = PlexUserProfileManager

    func test_entered_changesNothing() {
        XCTAssertEqual(Manager.restoreAction(after: .entered, isAccount: false, ownTokenInUse: false), .none)
    }

    /// The account's own profile keeps the account's token whatever plex.tv says, as before.
    func test_account_fallsBackToTheAccount() {
        for entry in [Manager.Entry.rejected, .unavailable] {
            XCTAssertEqual(Manager.restoreAction(after: entry, isAccount: true, ownTokenInUse: false), .useAccount)
        }
    }

    /// PIN added or changed, or the profile refused: lock even a working session.
    func test_rejectedProfile_locks() {
        XCTAssertEqual(Manager.restoreAction(after: .rejected, isAccount: false, ownTokenInUse: true), .lock)
        XCTAssertEqual(Manager.restoreAction(after: .rejected, isAccount: false, ownTokenInUse: false), .lock)
    }

    /// A plex.tv outage keeps the profile's own session and never borrows the account's.
    func test_outage_keepsOwnSession_elseLocks() {
        XCTAssertEqual(Manager.restoreAction(after: .unavailable, isAccount: false, ownTokenInUse: true), .keep)
        XCTAssertEqual(Manager.restoreAction(after: .unavailable, isAccount: false, ownTokenInUse: false), .lock)
    }

    // MARK: /switch response

    func test_switchResponse_returnsTheProfileToken() throws {
        let body = Data(#"{"authToken":"kid-plex-token"}"#.utf8)
        XCTAssertEqual(try PlexNetworkManager.homeUserToken(status: 201, data: body), "kid-plex-token")
    }

    /// A success with no token used to hand back the caller's own (the owner's).
    func test_switchResponse_withoutToken_throws() {
        XCTAssertThrowsError(try PlexNetworkManager.homeUserToken(status: 200, data: Data("{}".utf8)))
    }

    func test_switchResponse_refusedPin_isNil() throws {
        XCTAssertNil(try PlexNetworkManager.homeUserToken(status: 401, data: Data()))
        XCTAssertNil(try PlexNetworkManager.homeUserToken(status: 403, data: Data()))
    }

    func test_switchResponse_serverError_throws() {
        XCTAssertThrowsError(try PlexNetworkManager.homeUserToken(status: 500, data: Data()))
    }

    // MARK: Account content token (#562)

    private func contentToken(user: Int, unlocked: Bool = true, account: String? = "acct",
                              profile: String? = "prof") -> String? {
        Session.accountContentToken(accountToken: account, contentUserID: user,
                                    contentUnlocked: unlocked, profileToken: profile)
    }

    func test_contentToken_owner_usesAccountToken() {
        XCTAssertEqual(contentToken(user: 0), "acct")
    }

    func test_contentToken_otherProfile_usesItsOwnToken() {
        XCTAssertEqual(contentToken(user: 7), "prof")
    }

    func test_contentToken_otherProfileWithoutToken_isNilNeverTheAccounts() {
        XCTAssertNil(contentToken(user: 7, profile: nil))
    }

    func test_contentToken_lockedOrSignedOut_isNil() {
        XCTAssertNil(contentToken(user: 0, unlocked: false))
        XCTAssertNil(contentToken(user: 0, account: nil))
        XCTAssertNil(contentToken(user: 7, account: nil))
    }
}
