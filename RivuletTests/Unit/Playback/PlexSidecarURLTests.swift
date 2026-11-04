import XCTest
@testable import Rivulet

final class PlexSidecarURLTests: XCTestCase {
    func test_textCodecAsksForUTF8() {
        let url = PlexSidecarURL.url(serverURL: "http://h:32400", key: "/library/streams/9", token: "t", codec: "srt")
        XCTAssertEqual(url?.absoluteString, "http://h:32400/library/streams/9?encoding=utf-8&X-Plex-Token=t")
    }

    func test_imageCodecAndExistingEncodingUntouched() {
        let sup = PlexSidecarURL.url(serverURL: "http://h", key: "/library/streams/9", token: "t", codec: "pgs")
        XCTAssertEqual(sup?.absoluteString, "http://h/library/streams/9?X-Plex-Token=t")
        let set = PlexSidecarURL.url(serverURL: "http://h", key: "/s?encoding=utf-16", token: "t", codec: "SRT")
        XCTAssertEqual(set?.absoluteString, "http://h/s?encoding=utf-16&X-Plex-Token=t")
    }
}
