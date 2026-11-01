import XCTest
@testable import Rivulet

final class LiveJoinBackdropContentTests: XCTestCase {
    private func program(description: String?, art: URL?) -> UnifiedProgram {
        UnifiedProgram(id: "p", channelId: "c", title: "Show", description: description,
                       startTime: Date(), endTime: Date().addingTimeInterval(3600), landscapeURL: art)
    }

    func test_noProgram_isNil() {
        XCTAssertNil(LiveJoinBackdropContent.make(program: nil))
    }

    func test_usesLandscapeArtAndTrimmedSummary() {
        let url = URL(string: "https://example.com/a.jpg")
        let c = LiveJoinBackdropContent.make(program: program(description: "  Hello \n", art: url))
        XCTAssertEqual(c, LiveJoinBackdropContent(artworkURL: url, title: "Show", summary: "Hello"))
    }

    func test_withoutLandscape_usesTheGuideBackdropChain() {
        let icon = URL(string: "https://example.com/icon.jpg")
        let p = UnifiedProgram(id: "p", channelId: "c", title: "Show", startTime: Date(),
                               endTime: Date().addingTimeInterval(3600), iconURL: icon)
        XCTAssertEqual(LiveJoinBackdropContent.make(program: p)?.artworkURL, icon)
    }

    func test_blankSummary_becomesNil() {
        XCTAssertNil(LiveJoinBackdropContent.make(program: program(description: " ", art: nil))?.summary)
    }
}
