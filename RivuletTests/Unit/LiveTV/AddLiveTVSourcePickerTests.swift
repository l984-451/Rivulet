// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AddLiveTVSourcePickerTests.swift
//  RivuletTests
//
//  The add-source picker names each app, and each app's form asks only for
//  what that app uses, with its usual address filled in.
//

import XCTest
@testable import Rivulet

@MainActor
final class AddLiveTVSourcePickerTests: XCTestCase {

    override func tearDown() {
        SettingsContent.addSourceDraft = nil
        super.tearDown()
    }

    private func open(_ rowId: String) throws {
        let row = try XCTUnwrap(SettingsContent.rows(for: .addLiveTVSource).first { $0.id == rowId })
        guard case .navigationAction(_, _, let prepare) = row.kind else { return XCTFail("\(rowId) is not a form row") }
        prepare()
    }

    func test_picker_rowsAndHeadersInOrder() {
        XCTAssertEqual(SettingsContent.rows(for: .addLiveTVSource).map(\.id),
                       ["hdr_Your Server", "addDispatcharr", "addTvheadend", "addThreadfin",
                        "hdr_Provider", "addXtream", "addPlaylistURL"])
    }

    func test_tvheadendForm_fieldIds() throws {
        try open("addTvheadend")
        XCTAssertEqual(SettingsContent.rows(for: .addTvheadend).map(\.id),
                       ["tvhServerField", "tvhUsernameField", "tvhPasswordField", "displayNameField", "addSourceConfirm"])
        XCTAssertEqual(SettingsContent.addSourceDraft?.serverURL,
                       LiveTVSourceConnector.defaultAddress(for: .tvheadend))
    }

    func test_threadfinForm_fieldIds() throws {
        try open("addThreadfin")
        XCTAssertEqual(SettingsContent.rows(for: .addThreadfin).map(\.id),
                       ["threadfinServerField", "displayNameField", "addSourceConfirm"])
        XCTAssertEqual(SettingsContent.addSourceDraft?.serverURL,
                       LiveTVSourceConnector.defaultAddress(for: .threadfin))
    }

    func test_dispatcharrForm_keepsItsFields() throws {
        try open("addDispatcharr")
        XCTAssertEqual(SettingsContent.rows(for: .addDispatcharr).map(\.id),
                       ["serverURL", "usernameField", "passwordField", "channelProfileField", "displayNameField",
                        "addSourceConfirm"])
        XCTAssertEqual(SettingsContent.addSourceDraft?.serverURL,
                       LiveTVSourceConnector.defaultAddress(for: .dispatcharr))
    }

    func test_everyFormRowHasADescription() throws {
        for (row, page) in [("addDispatcharr", SettingsPage.addDispatcharr), ("addTvheadend", .addTvheadend),
                            ("addThreadfin", .addThreadfin)] {
            try open(row)
            for id in SettingsContent.rows(for: page).map(\.id) + [row] {
                XCTAssertNotNil(SettingsDescriptorStore.descriptor(for: id), id)
            }
        }
    }
}
