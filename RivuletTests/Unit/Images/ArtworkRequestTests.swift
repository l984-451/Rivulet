import XCTest
@testable import Rivulet

final class ArtworkRequestTests: XCTestCase {
    func test_tokenMovesToHeaderAndOtherItemsKeepOrder() {
        let url = URL(string: "https://h:32400/photo/:/transcode?width=240&X-Plex-Token=abc%2B1&url=%2Flibrary%2Fa&height=360")!
        let request = ArtworkRequest.request(for: url)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Token"), "abc+1")
        XCTAssertEqual(request.url?.absoluteString, "https://h:32400/photo/:/transcode?width=240&url=%2Flibrary%2Fa&height=360")
    }

    func test_onlyTokenLeavesNoQuery() {
        let request = ArtworkRequest.request(for: URL(string: "https://h/p?X-Plex-Token=t")!)
        XCTAssertEqual(request.url?.absoluteString, "https://h/p")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Token"), "t")
    }

    func test_urlWithoutTokenIsUnchanged() {
        let url = URL(string: "https://image.tmdb.org/t/p/w500/a.jpg?x=1&y=2")!
        let request = ArtworkRequest.request(for: url)
        XCTAssertEqual(request.url, url)
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Plex-Token"))
        let bare = URL(string: "https://jf/Items/1/Images/Primary")!
        XCTAssertEqual(ArtworkRequest.request(for: bare).url, bare)
    }
}
