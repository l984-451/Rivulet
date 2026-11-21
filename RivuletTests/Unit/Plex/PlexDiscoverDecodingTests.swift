// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Plex Discover (metadata.provider.plex.tv) answers `/library/metadata/<key>` in a server's shape,
/// but types two fields differently. Before these were read leniently, either one rejected the
/// whole answer.
final class PlexDiscoverDecodingTests: XCTestCase {

    func test_discoverMetadata_decodes() throws {
        let json = """
        {"MediaContainer":{"size":1,"librarySectionID":"movie","Metadata":[
          {"ratingKey":"5d77682b2ec6b5001f6bac01","key":"/library/metadata/5d77682b2ec6b5001f6bac01",
           "type":"movie","title":"Dune","contentRating":"PG-13","year":2021,
           "Genre":[{"id":"5d7768","tag":"Science Fiction"},{"id":"5d7769","tag":"Adventure"}]}]}}
        """
        let wrapper = try JSONDecoder().decode(PlexMediaContainerWrapper.self, from: Data(json.utf8))
        XCTAssertNil(wrapper.MediaContainer.librarySectionID)
        let meta = try XCTUnwrap(wrapper.MediaContainer.Metadata?.first)
        XCTAssertEqual(meta.title, "Dune")
        XCTAssertEqual(meta.contentRating, "PG-13")
        XCTAssertEqual(meta.Genre?.compactMap(\.tag), ["Science Fiction", "Adventure"])
        XCTAssertEqual(meta.Genre?.compactMap(\._id), [])
    }

    /// A server's numbers still read as numbers, including one sent as text.
    func test_serverMetadata_keepsNumericIDs() throws {
        let json = """
        {"MediaContainer":{"size":1,"librarySectionID":3,"Metadata":[
          {"ratingKey":"101","type":"movie","title":"Heat","Genre":[{"id":17,"tag":"Crime"},{"id":"18","tag":"Drama"}]}]}}
        """
        let wrapper = try JSONDecoder().decode(PlexMediaContainerWrapper.self, from: Data(json.utf8))
        XCTAssertEqual(wrapper.MediaContainer.librarySectionID, 3)
        XCTAssertEqual(wrapper.MediaContainer.Metadata?.first?.Genre?.compactMap(\._id), [17, 18])
        XCTAssertEqual(wrapper.MediaContainer.Metadata?.first?.Genre?.first?.idString, "17")
    }
}
