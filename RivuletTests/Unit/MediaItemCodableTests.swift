// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class MediaItemCodableTests: XCTestCase {
    func test_decodesJSONWrittenBeforeTheVersionFields() throws {
        let item = JellyfinFixtures.mediaItem("m1")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        json.removeValue(forKey: "versionCount")
        json.removeValue(forKey: "editionTitle")
        let decoded = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, item)
        XCTAssertNil(decoded.versionCount)
    }
}
