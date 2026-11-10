// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// `/hubs/promoted` hubs name no section; they are filed under their items' section (#474).
final class PlexPromotedHubsTests: XCTestCase {
    // Shape of a PMS 1.43.4 answer for contentDirectoryID=1,25,26,2.
    private let body = """
    {"MediaContainer":{"size":4,"Hub":[
      {"hubIdentifier":"movie.recentlyadded.1","key":"/library/sections/1/all?sort=addedAt:desc","title":"Recently Added in Movies",
       "type":"movie","promoted":true,"size":1,"Metadata":[{"ratingKey":"10","type":"movie","title":"A","librarySectionID":1}]},
      {"hubIdentifier":"custom.collection.1.9144","key":"/library/collections/9144/children","title":"Picks",
       "type":"movie","promoted":true,"size":1,"Metadata":[{"ratingKey":"11","type":"movie","title":"B","librarySectionID":1}]},
      {"hubIdentifier":"movie.recentlyadded.26","key":"/library/sections/26/all?sort=addedAt:desc","title":"Recently Added in Recordings",
       "type":"movie","promoted":true,"size":0},
      {"hubIdentifier":"tv.recentlyadded.25","key":"/hubs/home/recentlyAdded?type=2&sectionID=25","title":"Recently Added in TV",
       "type":"mixed","promoted":true,"size":1,"Metadata":[{"ratingKey":"12","type":"episode","title":"C","librarySectionID":25}]},
      {"hubIdentifier":"tv.recentlyadded.9","key":"/hubs/home/recentlyAdded?type=2&sectionID=9","title":"Not asked for",
       "type":"mixed","promoted":true,"size":1,"Metadata":[{"ratingKey":"13","type":"episode","title":"D","librarySectionID":9}]}
    ]}}
    """

    private final class CountingNetwork: PlexNetworkManager {
        var promotedCalls: [[String]] = []
        var libraryHubCalls = 0
        var sections: [PlexLibrary] = []
        var promoted: [String: [PlexHub]] = [:]
        override func getPromotedHubs(serverURL: String, authToken: String, sectionIDs: [String],
                                      userId: Int? = nil, count: Int = 24) async throws -> [String: [PlexHub]] {
            promotedCalls.append(sectionIDs)
            return promoted
        }
        override func getLibraryHubs(serverURL: String, authToken: String, sectionId: String,
                                     userId: Int? = nil, count: Int = 24) async throws -> [PlexHub] {
            libraryHubCalls += 1
            return []
        }
    }

    func test_plexHome_isOneRequestForEveryPinnedLibrary() async throws {
        let network = CountingNetwork()
        let hubs = try JSONDecoder().decode(PlexMediaContainerWrapper.self, from: Data(body.utf8)).MediaContainer.Hub ?? []
        network.promoted = PlexNetworkManager.promotedHubsBySection(hubs, sectionIDs: ["1", "25"])
        let plex = PlexProvider(machineIdentifier: "t", displayName: "T", serverURL: "http://plex.test",
                                authToken: "t", networkManager: network)
        let libraries = ["1", "25"].map { MediaLibrary(id: $0, providerID: "plex:t", title: $0, kind: .movies) }

        let rows = try await plex.promotedHubs(in: libraries)

        XCTAssertEqual(network.promotedCalls, [["1", "25"]])
        XCTAssertEqual(network.libraryHubCalls, 0, "no per-library /hubs/sections fan-out")
        XCTAssertEqual(rows["1"]?.count, 2)
        XCTAssertEqual(rows["25"]?.first?.items.map(\.ref.itemID), ["12"])
    }

    func test_filesEachHubUnderItsItemsSection() throws {
        let hubs = try JSONDecoder().decode(PlexMediaContainerWrapper.self, from: Data(body.utf8)).MediaContainer.Hub ?? []

        let bySection = PlexNetworkManager.promotedHubsBySection(hubs, sectionIDs: ["1", "25", "26", "2"])

        XCTAssertEqual(bySection["1"]?.map(\.hubIdentifier), ["movie.recentlyadded.1", "custom.collection.1.9144"],
                       "a collection hub's identifier ends in its collection id, so the items decide")
        XCTAssertEqual(bySection["25"]?.map(\.hubIdentifier), ["tv.recentlyadded.25"])
        XCTAssertEqual(bySection["26"]?.count, 0, "an empty hub has no section to file it under, and draws no row")
        XCTAssertEqual(bySection["2"]?.count, 0, "a library that promotes nothing answered, so it is empty, not missing")
        XCTAssertNil(bySection["9"], "a section that was not asked for is left out")
    }
}
