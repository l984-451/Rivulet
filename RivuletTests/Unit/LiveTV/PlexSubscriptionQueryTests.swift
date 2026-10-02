// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexSubscriptionQueryTests.swift
//  RivuletTests
//
//  The query that creates a Plex DVR rule. PMS answers 400 without the
//  top-level `type`, which the template's own query never carries (#318).
//

import XCTest
@testable import Rivulet

@MainActor
final class PlexSubscriptionQueryTests: XCTestCase {

    private func option(type: Int?, parameters: String = "hints%5Btype%5D=4&params%5BmediaProviderID%5D=12") -> PlexSubscriptionTemplateOption {
        PlexSubscriptionTemplateOption(
            title: "Episode", type: type, parameters: parameters,
            targetLibrarySectionID: 3, targetSectionLocationID: nil,
            librarySectionTitle: "TV", airingsType: nil,
            prefs: ["oneShot": "true"], selected: true)
    }

    private func value(_ name: String, in items: [URLQueryItem]) -> String? {
        items.first { $0.name == name }?.value
    }

    func test_sendsTemplateType() {
        let items = PlexNetworkManager.subscriptionQueryItems(for: option(type: 4))
        XCTAssertEqual(value("type", in: items), "4")
        XCTAssertEqual(value("hints[type]", in: items), "4")
        XCTAssertEqual(value("targetLibrarySectionID", in: items), "3")
        XCTAssertEqual(value("prefs[oneShot]", in: items), "true")
    }

    func test_keepsTypeTheTemplateAlreadyNames() {
        let items = PlexNetworkManager.subscriptionQueryItems(for: option(type: 4, parameters: "type=2"))
        XCTAssertEqual(items.filter { $0.name == "type" }.map(\.value), ["2"])
    }

    func test_omitsTypeWhenTemplateHasNone() {
        let items = PlexNetworkManager.subscriptionQueryItems(for: option(type: nil))
        XCTAssertNil(value("type", in: items))
    }
}
