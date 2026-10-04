// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// RIVULET-18: PMS echoed a file path with a raw 0x82 byte and the whole
/// response failed to decode.
final class PlexInvalidUTF8DecodeTests: XCTestCase {

    private struct Part: Decodable { let file: String; let duration: Int }

    func test_decode_repairsInvalidUTF8InsteadOfFailingTheResponse() throws {
        var data = Data(#"{"file":"/media/Pok"#.utf8)
        data.append(0x82)
        data.append(contentsOf: Data(#"mon.mkv","duration":6269120}"#.utf8))
        XCTAssertThrowsError(try JSONDecoder().decode(Part.self, from: data))

        let part = try PlexNetworkManager.decodeRepairingUTF8(Part.self, from: data)

        XCTAssertEqual(part.file, "/media/Pok\u{FFFD}mon.mkv")
        XCTAssertEqual(part.duration, 6269120)
    }

    func test_decode_stillThrowsForValidUTF8ThatIsNotJSON() {
        XCTAssertThrowsError(try PlexNetworkManager.decodeRepairingUTF8(Part.self, from: Data("<html>".utf8)))
    }
}
