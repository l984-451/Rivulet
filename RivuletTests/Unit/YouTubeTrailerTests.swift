// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class YouTubeTrailerTests: XCTestCase {
    private func id(_ string: String) -> String? {
        URL(string: string).flatMap(YouTubeTrailer.videoID(from:))
    }

    func test_videoID_readsEveryYouTubeLinkShape() {
        XCTAssertEqual(id("https://www.youtube.com/watch?v=aqz-KE-bpKQ"), "aqz-KE-bpKQ")
        XCTAssertEqual(id("http://youtube.com/watch?feature=share&v=aqz-KE-bpKQ"), "aqz-KE-bpKQ")
        XCTAssertEqual(id("https://m.youtube.com/watch?v=aqz-KE-bpKQ"), "aqz-KE-bpKQ")
        XCTAssertEqual(id("https://youtu.be/aqz-KE-bpKQ"), "aqz-KE-bpKQ")
        XCTAssertEqual(id("https://www.youtube.com/embed/aqz-KE-bpKQ"), "aqz-KE-bpKQ")
    }

    func test_videoID_rejectsOtherHostsAndBadIDs() {
        XCTAssertNil(id("https://vimeo.com/watch?v=aqz-KE-bpKQ"))
        XCTAssertNil(id("https://www.youtube.com/watch?v=short"))
        XCTAssertNil(id("https://www.youtube.com/watch"))
        // A Plex trailer is a file on the server: no YouTube button.
        XCTAssertNil(id("http://192.168.1.2:32400/library/metadata/123"))
        XCTAssertNil(id("https://notyoutube.com/watch?v=aqz-KE-bpKQ"))
    }

    func test_firstLink_skipsNonYouTubeAndEmpty() {
        let link = YouTubeTrailer.firstLink([nil, "", "https://vimeo.com/1", "https://youtu.be/aqz-KE-bpKQ"])
        XCTAssertEqual(link?.absoluteString, "https://youtu.be/aqz-KE-bpKQ")
        XCTAssertNil(YouTubeTrailer.firstLink([]))
    }

    func test_appURL_opensTheYouTubeApp() {
        XCTAssertEqual(YouTubeTrailer.appURL(videoID: "aqz-KE-bpKQ")?.absoluteString, "youtube://watch/aqz-KE-bpKQ")
    }
}
