import XCTest
@testable import Rivulet

final class HeroTextlessBackdropTests: XCTestCase {
    private func decode(_ json: String) throws -> TMDBImagesResponse {
        try JSONDecoder().decode(TMDBImagesResponse.self, from: Data(json.utf8))
    }

    func test_picksBestVotedBackdropWithNoLanguage() throws {
        let response = try decode("""
        {"backdrops":[
          {"file_path":"/en.jpg","iso_639_1":"en","vote_average":9},
          {"file_path":"/low.jpg","iso_639_1":null,"vote_average":1},
          {"file_path":"/best.jpg","iso_639_1":null,"vote_average":5}
        ],"logos":[]}
        """)
        XCTAssertEqual(response.bestTextlessBackdropPath, "/best.jpg")
    }

    func test_noTextlessBackdropReturnsNil() throws {
        let response = try decode(#"{"backdrops":[{"file_path":"/en.jpg","iso_639_1":"en","vote_average":9}],"logos":[]}"#)
        XCTAssertNil(response.bestTextlessBackdropPath)
        XCTAssertNil(try decode(#"{"logos":[]}"#).bestTextlessBackdropPath)
    }

    func test_episodesAndSeasonsHaveNoHeroTMDBID() throws {
        func meta(_ type: String) throws -> PlexMetadata {
            try JSONDecoder().decode(PlexMetadata.self, from: Data(#"{"type":"\#(type)","guid":"tmdb://337170"}"#.utf8))
        }
        XCTAssertEqual(try meta("movie").heroTMDB?.id, 337170)
        XCTAssertNil(try meta("episode").heroTMDB)
    }
}
