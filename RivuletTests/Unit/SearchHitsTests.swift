// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import XCTest
@testable import Rivulet

final class SearchRankTests: XCTestCase {
    func test_rank_order() {
        XCTAssertEqual(SearchRank.of("Christmas", query: "christmas"), .exact)
        XCTAssertEqual(SearchRank.of("The Christmas", query: "christmas"), .exact)
        XCTAssertEqual(SearchRank.of("Christmas Vacation", query: "christmas"), .prefix)
        XCTAssertEqual(SearchRank.of("A Christmas Story", query: "christmas"), .prefix)
        XCTAssertEqual(SearchRank.of("Four Christmases", query: "christmas"), .wordPrefix)
        XCTAssertEqual(SearchRank.of("Eloise at Christmastime", query: "christmas"), .wordPrefix)
        XCTAssertEqual(SearchRank.of("Nochristmas", query: "christmas"), .contains)
        XCTAssertEqual(SearchRank.of("Elf", query: "christmas"), .none)
    }

    func test_normalized_foldsCaseAccentsAndPunctuation() {
        XCTAssertEqual(SearchRank.normalized("Ocean's  Eleven"), "oceans eleven")
        XCTAssertEqual(SearchRank.normalized("Amélie"), "amelie")
        XCTAssertEqual(SearchRank.of("Spider-Man: No Way Home", query: "spider man"), .prefix)
    }

    func test_ranked_bestFirst_keepsServerOrderWithinRank_dropsUnnamedEpisodes() {
        func item(_ title: String, _ kind: MediaKind) -> MediaItem {
            JellyfinFixtures.mediaItem(title, kind: kind, providerID: "plex:a")  // title is the id
        }
        let titles = [item("Mickey's Christmas Carol", .movie), item("Christmas Vacation", .movie),
                      item("Blitz", .episode), item("Christmas Day", .episode), item("Red One", .movie)]
        XCTAssertEqual(SearchRank.ranked(titles, query: "christmas").map(\.title),
                       ["Christmas Vacation", "Christmas Day", "Mickey's Christmas Carol", "Red One"])
    }

    func test_matching_minimumAndLimit() {
        let names = ["Horror Movies", "Christmas", "Christmas Classics", "Nochristmas"]
        XCTAssertEqual(SearchRank.matching(names, query: "christmas", limit: 5) { $0 }, ["Christmas", "Christmas Classics"])
        XCTAssertEqual(SearchRank.matching(names, query: "christmas", limit: 1) { $0 }, ["Christmas"])
    }

    func test_interleaved() {
        XCTAssertEqual(SearchHits.interleaved([[1, 2, 3], [10], [20, 21]]), [1, 10, 20, 2, 21, 3])
    }
}

/// Shapes from `/hubs/search` on PMS 1.43.5 (2026-11-09), trimmed.
final class PlexHubSearchTests: XCTestCase {
    private static let json = """
    {"MediaContainer":{"size":7,"Hub":[
      {"type":"movie","hubIdentifier":"movie","size":3,"Metadata":[
        {"ratingKey":"14808","type":"movie","title":"Christmas Vacation","librarySectionID":1,"score":"0.73"},
        {"ratingKey":"52877","type":"movie","title":"Forrest Gump","librarySectionID":1,"reason":"actor","reasonTitle":"Tom Hanks","reasonID":139965},
        {"ratingKey":"231423","type":"movie","title":"1991 Christmas","librarySectionID":7}
      ]},
      {"type":"episode","hubIdentifier":"episode","size":2,"Metadata":[
        {"ratingKey":"219033","type":"episode","title":"Christmas Party","librarySectionID":2},
        {"ratingKey":"210742","type":"episode","title":"The Beginning","librarySectionID":2}
      ]},
      {"type":"album","hubIdentifier":"album","size":1,"Metadata":[
        {"ratingKey":"239291","type":"album","title":"Christmas","librarySectionID":3}
      ]},
      {"type":"genre","hubIdentifier":"genre","size":3,"Directory":[
        {"id":413860,"tag":"Christmas","librarySectionID":1,"type":"tag","reason":"section","count":1},
        {"id":413860,"tag":"Christmas","librarySectionID":2,"type":"tag","reason":"section","count":4},
        {"id":99,"tag":"Christian","librarySectionID":1,"type":"tag","count":2}
      ]},
      {"type":"collection","hubIdentifier":"collection","size":1,"Metadata":[
        {"ratingKey":"61366","type":"collection","title":"Christmas","librarySectionID":1,"childCount":6}
      ]},
      {"type":"director","hubIdentifier":"director","size":1,"Directory":[
        {"id":158774,"tag":"Christmas Smith","librarySectionID":1,"count":10,"tagKey":"abc","thumb":"https://metadata-static.plex.tv/p.jpg"}
      ]},
      {"type":"actor","hubIdentifier":"actor","size":3,"Directory":[
        {"id":174497,"tag":"Christmas Smith","librarySectionID":1,"count":1},
        {"id":5,"tag":"Mary Christmas","librarySectionID":1,"count":3},
        {"id":5,"tag":"Mary Christmas","librarySectionID":2,"count":3}
      ]}
    ]}}
    """

    private func hubs() throws -> [PlexHubSearch.Hub] {
        try JSONDecoder().decode(PlexHubSearch.Container.self, from: Data(Self.json.utf8)).MediaContainer.Hub ?? []
    }

    func test_parse_titlesSkipPeopleMatches_andMusicIsSeparate() throws {
        let parsed = PlexHubSearch.parse(try hubs(), query: "christmas", visibleSections: nil)
        XCTAssertEqual(parsed.titles.map(\.ratingKey), ["14808", "231423", "219033", "210742"])
        XCTAssertEqual(parsed.music.map(\.ratingKey), ["239291"])
    }

    func test_parse_hiddenLibrariesStayOut() throws {
        let parsed = PlexHubSearch.parse(try hubs(), query: "christmas", visibleSections: [1, 2])
        XCTAssertEqual(parsed.titles.map(\.ratingKey), ["14808", "219033", "210742"])
        XCTAssertTrue(parsed.music.isEmpty)
    }

    func test_parse_people_oncePerTagAndName_bestMatchFirst() throws {
        let parsed = PlexHubSearch.parse(try hubs(), query: "christmas", visibleSections: nil)
        // "Christmas Smith" is a director (10 titles) and an actor (1): the director entry stays.
        XCTAssertEqual(parsed.people.map { "\($0.tag.tag ?? "")/\($0.filter)" },
                       ["Christmas Smith/director", "Mary Christmas/actor"])
    }

    func test_parse_shelves_collectionThenGenreAcrossLibraries_onlyWordMatches() throws {
        let parsed = PlexHubSearch.parse(try hubs(), query: "christmas", visibleSections: nil)
        XCTAssertEqual(parsed.shelves.map(\.name), ["Christmas", "Christmas"])
        XCTAssertEqual(parsed.shelves[0].kind, .collection)
        XCTAssertEqual(parsed.shelves[0].collectionKey, "61366")
        XCTAssertEqual(parsed.shelves[1].kind, .genre)
        XCTAssertEqual(parsed.shelves[1].genreTags, [.init(section: 1, id: 413860), .init(section: 2, id: 413860)])
    }

    func test_person_mapsTagToPlexPerson() throws {
        let parsed = PlexHubSearch.parse(try hubs(), query: "christmas", visibleSections: nil)
        let person = PlexHubSearch.person(parsed.people[0], serverURL: "http://s", token: "t", providerID: "plex:m")
        XCTAssertEqual(person.originActorId, "158774")
        XCTAssertEqual(person.originFilter, "director")
        XCTAssertEqual(person.tagKey, "abc")
        XCTAssertEqual(person.providerID, "plex:m")
        XCTAssertEqual(person.imageURL?.absoluteString, "https://metadata-static.plex.tv/p.jpg")
    }
}
