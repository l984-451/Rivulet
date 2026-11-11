import XCTest
@testable import Rivulet

final class PlayAlreadyCountedTests: XCTestCase {
    private func counted(offset: Int?, plays: Int?, before: Int) -> Bool {
        PlexNetworkManager.playAlreadyCounted(viewOffset: offset, viewCount: plays, playsBefore: before)
    }

    func test_serverCompletedThePlay() {
        // The timeline passed the server's threshold: one more play, resume point cleared.
        XCTAssertTrue(counted(offset: nil, plays: 1, before: 0))
        XCTAssertTrue(counted(offset: nil, plays: 4, before: 3))
        XCTAssertTrue(counted(offset: 0, plays: 1, before: 0))
    }

    func test_stillNeedsAScrobble() {
        // In progress: the server holds a resume point, whatever the count.
        XCTAssertFalse(counted(offset: 2_580_000, plays: 0, before: 0))
        XCTAssertFalse(counted(offset: 2_580_000, plays: 2, before: 1))
        // Nothing stored and no new play: a clip too short for the server to track.
        XCTAssertFalse(counted(offset: nil, plays: 0, before: 0))
        XCTAssertFalse(counted(offset: nil, plays: nil, before: 0))
        // A rewatch the server has not counted yet.
        XCTAssertFalse(counted(offset: nil, plays: 3, before: 3))
    }
}
