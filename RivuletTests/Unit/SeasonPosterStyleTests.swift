import XCTest
@testable import Rivulet

final class SeasonPosterStyleTests: XCTestCase {

    private func ref(_ id: String) -> MediaItemRef { MediaItemRef(providerID: "plex:m1", itemID: id) }

    // MARK: When posters show

    func test_showsPosters() {
        XCTAssertFalse(SeasonPosterStyle.showsPosters(enabled: false, seasonCount: 3, pageKind: .show))
        XCTAssertFalse(SeasonPosterStyle.showsPosters(enabled: true, seasonCount: 1, pageKind: .show))
        XCTAssertTrue(SeasonPosterStyle.showsPosters(enabled: true, seasonCount: 2, pageKind: .show))
        // Season 1 plus Specials counts as two, as the pills count it.
        XCTAssertTrue(SeasonPosterStyle.showsPosters(enabled: true, seasonCount: 2, pageKind: .episode))
        XCTAssertFalse(SeasonPosterStyle.showsPosters(enabled: true, seasonCount: 4, pageKind: .season))
    }

    // MARK: Which season the row lands on

    func test_selectedIndex() {
        let seasons = [ref("s1"), ref("s2"), ref("s3")]
        XCTAssertEqual(SeasonPosterStyle.selectedIndex(seasons: seasons, holding: ref("s2")), 1)
        XCTAssertEqual(SeasonPosterStyle.selectedIndex(seasons: seasons, holding: nil), 0)
        XCTAssertEqual(SeasonPosterStyle.selectedIndex(seasons: seasons, holding: ref("gone")), 0)
    }

    func test_firstColumn() {
        XCTAssertEqual(SeasonPosterStyle.firstColumn(toShow: 0, count: 10, fullCount: 6), 0)
        XCTAssertEqual(SeasonPosterStyle.firstColumn(toShow: 7, count: 10, fullCount: 6), 2)
        XCTAssertEqual(SeasonPosterStyle.firstColumn(toShow: 9, count: 10, fullCount: 6), 4)
        XCTAssertEqual(SeasonPosterStyle.firstColumn(toShow: 3, count: 4, fullCount: 6), 0)
    }

    // MARK: The poster's corner

    func test_mark() {
        XCTAssertEqual(SeasonPosterStyle.mark(progress: ChildProgress(played: 2, total: 10), isPlayed: false),
                       .unwatched(8))
        XCTAssertEqual(SeasonPosterStyle.mark(progress: ChildProgress(played: 10, total: 10), isPlayed: false),
                       .watched)
        XCTAssertEqual(SeasonPosterStyle.mark(progress: nil, isPlayed: true), .watched)
        XCTAssertEqual(SeasonPosterStyle.mark(progress: nil, isPlayed: false), .hidden)
        XCTAssertEqual(SeasonPosterStyle.mark(progress: ChildProgress(played: 0, total: 0), isPlayed: false), .hidden)
    }

    // MARK: Setting

    func test_setting_defaultsToPosters() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: SeasonPosterStyle.enabledKey)
        defer { defaults.set(saved, forKey: SeasonPosterStyle.enabledKey) }
        defaults.removeObject(forKey: SeasonPosterStyle.enabledKey)
        XCTAssertTrue(SeasonPosterStyle.isEnabled)
        SeasonPosterStyle.isEnabled = false
        XCTAssertFalse(SeasonPosterStyle.isEnabled)
    }
}
