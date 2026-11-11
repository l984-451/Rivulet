import XCTest
@testable import Rivulet

final class ArtworkSizingTests: XCTestCase {
    private func fitted(_ string: String) -> String {
        ArtworkSizing.fitted(URL(string: string)!, maxPixel: 900).absoluteString
    }

    func test_plexPosterAndBackdropGoThroughTheTranscoder() {
        XCTAssertEqual(
            fitted("http://10.0.0.2:32400/library/metadata/123/thumb/1699?X-Plex-Token=abc"),
            "http://10.0.0.2:32400/photo/:/transcode?url=/library/metadata/123/thumb/1699&width=900&height=900&quality=95&X-Plex-Token=abc")
        XCTAssertEqual(
            fitted("https://1-2-3-4.hash.plex.direct:32400/library/metadata/9/art/5?X-Plex-Token=t"),
            "https://1-2-3-4.hash.plex.direct:32400/photo/:/transcode?url=/library/metadata/9/art/5&width=900&height=900&quality=95&X-Plex-Token=t")
        // No timestamp component.
        XCTAssertTrue(fitted("http://h:32400/library/metadata/9/thumb?X-Plex-Token=t").contains("/photo/:/transcode?url=/library/metadata/9/thumb&"))
    }

    func test_plexPathsThatAreNotPlainArtworkAreUnchanged() {
        for url in [
            "http://h:32400/library/metadata/123/clearLogo/1699?X-Plex-Token=abc",
            "http://h:32400/library/metadata/123/thumb/1699",                           // no token to carry
            "http://h:32400/library/metadata/123/thumb/1699?width=4&X-Plex-Token=abc",  // has its own query
            "http://h:32400/library/collections/5/composite/9?width=400&height=600&X-Plex-Token=abc",
            "http://h:32400/photo/:/transcode?url=/library/metadata/1/thumb/2&width=5&height=5&X-Plex-Token=abc",
            "http://h:32400/library/metadata/123/thumb/1699/extra?X-Plex-Token=abc",
            "https://metadata-static.plex.tv/0/people/abc.jpg",
            "https://image.tmdb.org/t/p/original/a.jpg"
        ] {
            XCTAssertEqual(fitted(url), url)
        }
    }

    func test_jellyfinAndEmbyGainASizeBox() {
        XCTAssertEqual(
            fitted("http://h:8096/Items/abc/Images/Primary?tag=t1"),
            "http://h:8096/Items/abc/Images/Primary?tag=t1&MaxWidth=900&MaxHeight=900&Quality=95")
        XCTAssertEqual(
            fitted("http://h:8097/emby/Items/7/Images/Backdrop/0?Tag=t2"),
            "http://h:8097/emby/Items/7/Images/Backdrop/0?Tag=t2&MaxWidth=900&MaxHeight=900&Quality=95")
        XCTAssertEqual(
            fitted("http://h:8096/Items/abc/Images/Thumb"),
            "http://h:8096/Items/abc/Images/Thumb?MaxWidth=900&MaxHeight=900&Quality=95")
    }

    func test_jellyfinLogosAndSizedRequestsAreUnchanged() {
        for url in [
            "http://h:8096/Items/abc/Images/Logo?tag=t1",
            "http://h:8096/Items/abc/Images/Primary?tag=t1&fillWidth=520&fillHeight=520",
            "http://h:8097/Items/7/Images/Primary?Tag=t&MaxWidth=3840&MaxHeight=2160",
            "http://h:8096/Users/abc/Images/Primary?tag=t1"
        ] {
            XCTAssertEqual(fitted(url), url)
        }
    }
}
