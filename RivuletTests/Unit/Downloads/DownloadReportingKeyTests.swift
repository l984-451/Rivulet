// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Which Plex server a progress report or offline entry belongs to. A downloaded item's own metadata
/// carries no server id, so the download's key decides.
final class DownloadReportingKeyTests: XCTestCase {
    func test_aLocalPlayOfAnExtraServersDownloadIsFiledUnderThatServer() {
        XCTAssertEqual(DownloadIdentity.reportingKey(isLocal: true, downloadProviderID: "plex:EXTRA", itemServerID: nil,
                                                     currentMachineID: "SELECTED"), "plex:EXTRA")
    }

    func test_aLocalPlayOfTheSelectedServersDownloadKeepsItsMachineId() {
        XCTAssertEqual(DownloadIdentity.reportingKey(isLocal: true, downloadProviderID: "plex:SELECTED", itemServerID: nil,
                                                     currentMachineID: "SELECTED"), "plex:SELECTED")
    }

    func test_aBareDownloadKeyMeansTheCurrentServer() {
        XCTAssertEqual(DownloadIdentity.reportingKey(isLocal: true, downloadProviderID: "plex:", itemServerID: nil,
                                                     currentMachineID: "SELECTED"), "plex:SELECTED")
        XCTAssertNil(DownloadIdentity.reportingKey(isLocal: true, downloadProviderID: "plex:", itemServerID: nil, currentMachineID: nil))
    }

    func test_aStreamIsFiledUnderTheItemsServerElseTheCurrentOne() {
        XCTAssertEqual(DownloadIdentity.reportingKey(isLocal: false, downloadProviderID: nil, itemServerID: "EXTRA",
                                                     currentMachineID: "SELECTED"), "plex:EXTRA")
        XCTAssertEqual(DownloadIdentity.reportingKey(isLocal: false, downloadProviderID: nil, itemServerID: nil,
                                                     currentMachineID: "SELECTED"), "plex:SELECTED")
    }

    func test_withNoServerKnownThereIsNoKeyAndSoNoEntry() {
        XCTAssertNil(DownloadIdentity.reportingKey(isLocal: false, downloadProviderID: nil, itemServerID: nil, currentMachineID: nil))
        XCTAssertNil(DownloadIdentity.reportingKey(isLocal: false, downloadProviderID: nil, itemServerID: nil, currentMachineID: ""))
    }
}
