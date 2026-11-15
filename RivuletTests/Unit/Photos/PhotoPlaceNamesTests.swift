// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
private final class FakeGeocoder: PlaceGeocoding {
    var calls: [PhotoCoordinate] = []
    private var pending: [CheckedContinuation<String?, Never>] = []

    func placeName(at coordinate: PhotoCoordinate) async -> String? {
        calls.append(coordinate)
        return await withCheckedContinuation { pending.append($0) }
    }

    func answer(_ name: String?) { pending.removeFirst().resume(returning: name) }
    var waiting: Int { pending.count }
}

@MainActor
final class PhotoPlaceNamesTests: XCTestCase {
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
    }

    func test_key_roundsToThreeDecimals() {
        let a = PhotoPlaceNames.Key(PhotoCoordinate(latitude: 45.52341, longitude: -122.67649))
        let b = PhotoPlaceNames.Key(PhotoCoordinate(latitude: 45.5229, longitude: -122.6762))
        let c = PhotoPlaceNames.Key(PhotoCoordinate(latitude: 45.5245, longitude: -122.6765))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.latitude, 45523)
        XCTAssertEqual(a.longitude, -122676)
        XCTAssertNotEqual(a, c)
    }

    func test_cachesByRoundedCoordinate_andFailureIsNoPlace() async {
        let fake = FakeGeocoder()
        let places = PhotoPlaceNames(geocoder: fake)
        let here = PhotoCoordinate(latitude: 45.52341, longitude: -122.67649)
        let first = Task { await places.name(for: here) }
        await until { fake.waiting == 1 }
        fake.answer("Portland, Oregon")
        let firstName = await first.value
        XCTAssertEqual(firstName, "Portland, Oregon")
        let nearbyName = await places.name(for: PhotoCoordinate(latitude: 45.5229, longitude: -122.6762))
        XCTAssertEqual(nearbyName, "Portland, Oregon")
        XCTAssertEqual(fake.calls.count, 1)

        let elsewhere = PhotoCoordinate(latitude: 1, longitude: 1)
        let failed = Task { await places.name(for: elsewhere) }
        await until { fake.waiting == 1 }
        fake.answer(nil)
        let failedName = await failed.value
        XCTAssertNil(failedName)
        XCTAssertNil(places.cachedName(for: elsewhere))
    }

    func test_oneInFlight_newestWaitingWins() async {
        let fake = FakeGeocoder()
        let places = PhotoPlaceNames(geocoder: fake)
        let a = PhotoCoordinate(latitude: 1, longitude: 1)
        let b = PhotoCoordinate(latitude: 2, longitude: 2)
        let c = PhotoCoordinate(latitude: 3, longitude: 3)
        let first = Task { await places.name(for: a) }
        await until { fake.waiting == 1 }
        let second = Task { await places.name(for: b) }
        await Task.yield()
        let third = Task { await places.name(for: c) }
        let secondName = await second.value
        XCTAssertNil(secondName, "a newer request sends the waiting one away")
        XCTAssertEqual(fake.calls, [a], "nothing starts while one is in flight")

        fake.answer("A")
        let firstName = await first.value
        XCTAssertEqual(firstName, "A")
        await until { fake.waiting == 1 }
        fake.answer("C")
        let thirdName = await third.value
        XCTAssertEqual(thirdName, "C")
        XCTAssertEqual(fake.calls, [a, c])
    }

    func test_queued_waitsInOrder_captionGoesFirst_andIsNeverSentAway() async {
        let fake = FakeGeocoder()
        let places = PhotoPlaceNames(geocoder: fake)
        let a = PhotoCoordinate(latitude: 1, longitude: 1)
        let b = PhotoCoordinate(latitude: 2, longitude: 2)
        let c = PhotoCoordinate(latitude: 3, longitude: 3)
        let caption = PhotoCoordinate(latitude: 4, longitude: 4)
        let first = Task { await places.queuedName(for: a) }
        await until { fake.waiting == 1 }
        let second = Task { await places.queuedName(for: b) }
        await Task.yield()
        let third = Task { await places.queuedName(for: c) }
        await Task.yield()
        let shown = Task { await places.name(for: caption) }
        await Task.yield()
        let alsoA = Task { await places.queuedName(for: a) }
        await Task.yield()

        fake.answer("A")
        let firstName = await first.value
        XCTAssertEqual(firstName, "A")
        await until { fake.waiting == 1 }
        XCTAssertEqual(fake.calls.last, caption, "the caption jumps the queue")
        fake.answer("Here")
        let shownName = await shown.value
        XCTAssertEqual(shownName, "Here")
        await until { fake.waiting == 1 }
        fake.answer("B")
        await until { fake.waiting == 1 }
        fake.answer("C")
        let names = await [second.value, third.value, alsoA.value]
        XCTAssertEqual(names, ["B", "C", "A"])
        XCTAssertEqual(fake.calls, [a, caption, b, c], "a queued place already named costs no lookup")
    }

    func test_format_areaAtHome_countryAbroad() {
        XCTAssertEqual(PhotoPlaceNames.format(city: "Portland", cityWithArea: "Portland, OR", country: "United States",
                                              countryCode: "US", homeRegion: "US"), "Portland, OR")
        XCTAssertEqual(PhotoPlaceNames.format(city: "Paris", cityWithArea: "Paris, Île-de-France", country: "France",
                                              countryCode: "FR", homeRegion: "US"), "Paris, France")
        XCTAssertEqual(PhotoPlaceNames.format(city: "Portland", cityWithArea: nil, country: nil,
                                              countryCode: nil, homeRegion: "US"), "Portland")
        XCTAssertNil(PhotoPlaceNames.format(city: nil, cityWithArea: nil, country: nil, countryCode: nil, homeRegion: "US"))
    }

    func test_caption_dateUnderPlace_placeAloneWithoutDate() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let both = PhotoInfoLines.caption(date: date, place: "Portland, Oregon")
        XCTAssertEqual(both.eyebrow, "Portland, Oregon")
        XCTAssertEqual(both.title, date.formatted(date: .long, time: .omitted))
        let placeOnly = PhotoInfoLines.caption(date: nil, place: "Portland, Oregon")
        XCTAssertNil(placeOnly.eyebrow)
        XCTAssertEqual(placeOnly.title, "Portland, Oregon")
        let neither = PhotoInfoLines.caption(date: nil, place: nil)
        XCTAssertNil(neither.eyebrow)
        XCTAssertNil(neither.title)
    }
}
