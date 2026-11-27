import XCTest
@testable import Rivulet

final class AnimeScoresTests: XCTestCase {

    // Inline, not Bundle.main: the test host is the app, which may carry the real file.
    private static let fixture = """
    {"format":1,"built":"2026-01-01","source":"Test data",
     "tvdb":{"100:1":854,"100:2":891,"200:1":0,"201:1":1001},
     "tmdbShow":{"300:1":777},"tmdbMovie":{"100":866},"imdbMovie":{"tt0000001":912}}
    """

    private var table: AnimeScoreTable!
    private var savedEnabled: Any?

    override func setUp() {
        super.setUp()
        savedEnabled = UserDefaults.standard.object(forKey: AnimeScores.enabledKey)
        UserDefaults.standard.removeObject(forKey: AnimeScores.enabledKey)
        table = AnimeScoreTable(data: Data(Self.fixture.utf8))
        AnimeScores.install(table)
    }

    override func tearDown() {
        AnimeScores.install(nil)
        UserDefaults.standard.set(savedEnabled, forKey: AnimeScores.enabledKey)
        super.tearDown()
    }

    // MARK: Reading the file

    func test_decode_fixtureAndRejects() {
        XCTAssertNotNil(table)
        XCTAssertEqual(table.built, "2026-01-01")
        XCTAssertNil(AnimeScoreTable(data: Data(#"{"format":2,"built":"2026-01-01"}"#.utf8)))
        XCTAssertNil(AnimeScoreTable(data: Data("not json".utf8)))
    }

    // MARK: Shows

    func test_show_byTVDBAndSeason() {
        XCTAssertEqual(table.showScore(ids: ["tvdb": "100"], season: 2), 8.91)
        XCTAssertEqual(table.showScore(ids: ["tvdb": "100"], season: nil), 8.54)
        XCTAssertNil(table.showScore(ids: ["tvdb": "100"], season: 0))
        XCTAssertNil(table.showScore(ids: ["tvdb": "100"], season: 3))
        XCTAssertNil(table.showScore(ids: ["tvdb": "999"], season: 1))
    }

    func test_show_fallsBackToTMDB() {
        XCTAssertEqual(table.showScore(ids: ["tmdb": "300"], season: 1), 7.77)
        XCTAssertEqual(table.showScore(ids: ["tvdb": "999", "tmdb": "300"], season: 1), 7.77)
    }

    func test_show_outOfRangeValuesAreNoScore() {
        XCTAssertNil(table.showScore(ids: ["tvdb": "200"], season: 1))
        XCTAssertNil(table.showScore(ids: ["tvdb": "201"], season: 1))
    }

    // MARK: Films

    func test_movie_neverReadsTheShowMaps() {
        // TMDB film 100 and TVDB show 100 share a number.
        XCTAssertEqual(table.movieScore(ids: ["tmdb": "100"]), 8.66)
        XCTAssertNil(table.movieScore(ids: ["tmdb": "300"]))
    }

    func test_movie_imdbFallback() {
        XCTAssertEqual(table.movieScore(ids: ["imdb": "tt0000001"]), 9.12)
        XCTAssertEqual(table.movieScore(ids: ["imdb": "TT0000001"]), 9.12)
        XCTAssertNil(table.movieScore(ids: ["imdb": "tt9999999"]))
    }

    // MARK: What a page shows

    func test_score_byKind() {
        XCTAssertEqual(AnimeScores.score(kind: .show, ids: ["tvdb": "100"], season: 2), 8.54)
        XCTAssertEqual(AnimeScores.score(kind: .season, ids: ["tvdb": "100"], season: 2), 8.91)
        XCTAssertEqual(AnimeScores.score(kind: .episode, ids: ["tvdb": "100"], season: 2), 8.91)
        XCTAssertEqual(AnimeScores.score(kind: .movie, ids: ["tmdb": "100"], season: nil), 8.66)
        XCTAssertNil(AnimeScores.score(kind: .collection, ids: ["tvdb": "100"], season: 1))
        XCTAssertNil(AnimeScores.score(kind: .show, ids: [:], season: nil))
    }

    func test_score_offOrNoTable() {
        AnimeScores.isEnabled = false
        XCTAssertNil(AnimeScores.score(kind: .show, ids: ["tvdb": "100"], season: nil))
        AnimeScores.isEnabled = true
        AnimeScores.install(nil)
        XCTAssertNil(AnimeScores.score(kind: .show, ids: ["tvdb": "100"], season: nil))
    }
}
