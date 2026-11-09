// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Fixtures are entries from a photo section on PMS 1.43.4, trimmed of file paths.
final class PlexPhotoMapperTests: XCTestCase {
    /// West of UTC, where a date parsed at UTC midnight shows as the day before. Passed in rather
    /// than set as the default zone: the date parser and `Calendar.current` don't both follow
    /// `NSTimeZone.default`, so that only held on a machine already in Chicago.
    private static let chicago = TimeZone(identifier: "America/Chicago")!
    private static var chicagoCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chicago
        return calendar
    }

    private func map(_ json: String) throws -> PhotoItem? {
        let meta = try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
        return PlexPhotoMapper.item(meta, providerID: "plex:abc", serverURL: "http://s:32400", authToken: "tok")
    }

    private func query(_ url: URL?) -> [String: String] {
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private static let album = #"""
    {"ratingKey":"242388","key":"/library/metadata/242388/children","parentRatingKey":"242383",
     "guid":"local://242388","type":"photo","title":"Day Two","parentKey":"/library/metadata/242383",
     "summary":"","index":1,"composite":"/library/metadata/242388/composite/1791946145",
     "thumb":"/library/metadata/242388/thumb/1791946145","art":"/library/metadata/242388/art/1791946145",
     "addedAt":1791946143,"updatedAt":1791946145}
    """#

    private static let photo = #"""
    {"ratingKey":"242382","key":"/library/metadata/242382","guid":"local://242382","type":"photo",
     "title":"photo-5","summary":"","index":1,"year":2024,"thumb":"/library/metadata/242382/thumb/1791946144",
     "originallyAvailableAt":"2024-03-02","addedAt":1709400000,"updatedAt":1791946144,
     "createdAtAccuracy":"epoch,local","createdAtTZOffset":"-3600",
     "Media":[{"id":270603,"width":4032,"height":3024,"aspectRatio":1.33,"container":"jpeg",
               "hasVoiceActivity":false,
               "Part":[{"id":272315,"key":"/library/parts/272315/1709400000/file.jpg","size":1700000,
                        "container":"jpeg","orientation":6}]}]}
    """#

    // `optimizedForStreaming` is a number on Media and a bool on Part, as the server sends it.
    private static let clip = #"""
    {"ratingKey":"242384","key":"/library/metadata/242384","parentRatingKey":"242383",
     "guid":"com.plexapp.agents.none://242384?lang=xn","type":"clip","title":"clip-1",
     "parentKey":"/library/metadata/242383","subtype":"photo","summary":"","index":1,"year":2024,
     "thumb":"/library/metadata/242384/thumb/1791946143","duration":9398,
     "originallyAvailableAt":"2024-06-01","addedAt":1717250000,"updatedAt":1791946143,
     "createdAtAccuracy":"epoch,local","createdAtTZOffset":"-3600",
     "Media":[{"id":270604,"duration":9398,"bitrate":2486,"width":1280,"height":720,"aspectRatio":1.78,
               "audioChannels":2,"audioCodec":"aac","videoCodec":"hevc","videoResolution":"720",
               "container":"mov","videoFrameRate":"NTSC","optimizedForStreaming":1,"audioProfile":"lc",
               "has64bitOffsets":false,"videoProfile":"main","hasVoiceActivity":false,
               "Part":[{"id":272316,"key":"/library/parts/272316/1717250000/file.mov","duration":9398,
                        "size":2900000,"audioProfile":"lc","container":"mov","has64bitOffsets":false,
                        "optimizedForStreaming":true,"videoProfile":"main"}]}]}
    """#

    func test_album_isToldByItsKey_notItsType() throws {
        let album = try XCTUnwrap(map(Self.album))
        XCTAssertEqual(album.kind, .folder)
        XCTAssertEqual(album.ref, MediaItemRef(providerID: "plex:abc", itemID: "242388"))
        XCTAssertEqual(album.title, "Day Two")
        XCTAssertNil(album.childCount, "the server sends no count for an album")
        XCTAssertEqual(query(album.thumbnail)["url"], "/library/metadata/242388/thumb/1791946145")
        XCTAssertNil(album.full, "a folder is never shown full screen")
        XCTAssertNil(album.playable)
    }

    func test_photo_datesAndSizedURLs() throws {
        let photo = try XCTUnwrap(map(Self.photo))
        XCTAssertEqual(photo.kind, .photo)
        XCTAssertNil(photo.childCount)
        XCTAssertNil(photo.playable)
        let taken = Calendar.current.dateComponents([.year, .month, .day], from: try XCTUnwrap(photo.date))
        XCTAssertEqual([taken.year, taken.month, taken.day], [2024, 3, 2], "the day taken, in the device's zone")
        let meta = try JSONDecoder().decode(PlexMetadata.self, from: Data(Self.photo.utf8))
        let west = Self.chicagoCalendar.dateComponents([.year, .month, .day],
                                                       from: try XCTUnwrap(PlexPhotoMapper.date(meta, in: Self.chicago)))
        XCTAssertEqual([west.year, west.month, west.day], [2024, 3, 2], "and west of UTC")

        let thumb = query(photo.thumbnail)
        XCTAssertEqual(photo.thumbnail?.path, "/photo/:/transcode")
        XCTAssertEqual(thumb["url"], "/library/metadata/242382/thumb/1791946144")
        XCTAssertEqual([thumb["width"], thumb["height"]], ["520", "520"])
        XCTAssertEqual(thumb["minSize"], "1", "a tile is a cover")
        XCTAssertEqual(thumb["upscale"], "0")
        XCTAssertEqual(thumb["X-Plex-Token"], "tok")

        let full = query(photo.full)
        XCTAssertEqual(full["url"], "/library/parts/272315/1709400000/file.jpg", "the file, through the transcoder")
        XCTAssertEqual([full["width"], full["height"]], ["3840", "2160"])
        XCTAssertNil(full["minSize"], "with minSize a portrait photo comes back larger than the screen")
        XCTAssertEqual(photo.full?.path, "/photo/:/transcode", "the original file is never requested directly")
    }

    func test_photo_withoutDateTaken_fallsBackToAddedAt_andThumb() throws {
        let photo = try XCTUnwrap(map(#"""
        {"ratingKey":"12","key":"/library/metadata/12","type":"photo","title":"scan",
         "thumb":"/library/metadata/12/thumb/1","addedAt":1700000000}
        """#))
        XCTAssertEqual(photo.date, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(query(photo.full)["url"], "/library/metadata/12/thumb/1")
    }

    func test_clip_carriesAPlayableItem_andAStillForItsImage() throws {
        let clip = try XCTUnwrap(map(Self.clip))
        XCTAssertEqual(clip.kind, .clip)
        XCTAssertEqual(clip.playable?.ref, clip.ref)
        XCTAssertEqual(query(clip.full)["url"], "/library/metadata/242384/thumb/1791946143", "never the video file")
    }

    // An item request's shape (EXIF on Media), with invented values.
    private static let detailedPhoto = #"""
    {"ratingKey":"31","key":"/library/metadata/31","type":"photo","title":"beach",
     "thumb":"/library/metadata/31/thumb/1","originallyAvailableAt":"2024-03-02","addedAt":1709400000,
     "userRating":10,"Geolocation":{"Coordinates":{"latitude":10.5,"longitude":-20.25}},
     "Media":[{"id":5,"width":4032,"height":3024,"aspectRatio":1.33,"container":"jpeg",
               "make":"Apple","model":"iPhone Air","lens":"","aperture":"f/1.6","exposure":"1/5","iso":"3200",
               "Part":[{"id":6,"key":"/library/parts/6/1/file.jpg","file":"/photos/trip/beach.jpg","size":100}]}]}
    """#

    func test_photo_mapsFavoriteCoordinateAndEXIF() throws {
        let photo = try XCTUnwrap(map(Self.detailedPhoto))
        XCTAssertTrue(photo.isFavorite, "a photo favorite is rating 10")
        XCTAssertEqual(photo.coordinate, PhotoCoordinate(latitude: 10.5, longitude: -20.25))
        let details = try XCTUnwrap(photo.details)
        XCTAssertEqual(details.make, "Apple")
        XCTAssertEqual(details.model, "iPhone Air")
        XCTAssertNil(details.lens, "an empty string is no lens")
        XCTAssertEqual(details.fNumber, 1.6)
        XCTAssertEqual(details.exposureSeconds, 0.2)
        XCTAssertEqual(details.iso, 3200)
        XCTAssertEqual([details.width, details.height], [4032, 3024])
        XCTAssertEqual(details.fileName, "beach.jpg")
        XCTAssertEqual(details.takenAt, photo.date)
    }

    func test_exifNumbers_decode_andAWrongShapeIsNil() throws {
        let numeric = Self.detailedPhoto.replacingOccurrences(of: #""iso":"3200""#, with: #""iso":3200"#)
        XCTAssertEqual(try XCTUnwrap(map(numeric)).details?.iso, 3200)
        let odd = Self.detailedPhoto.replacingOccurrences(of: #""iso":"3200""#, with: #""iso":{"x":1}"#)
        let photo = try XCTUnwrap(map(odd), "a wrong shape must not fail the item")
        XCTAssertNil(photo.details?.iso)
        XCTAssertEqual(photo.details?.make, "Apple")
    }

    func test_listEntry_isNotAFavorite_andHasNoCoordinate() throws {
        let photo = try XCTUnwrap(map(Self.photo))
        XCTAssertFalse(photo.isFavorite)
        XCTAssertNil(photo.coordinate)
        XCTAssertNil(photo.details?.make)
        XCTAssertEqual(photo.details?.width, 4032)
        XCTAssertNil(try map(Self.album)?.details, "an album has no details")
        let rated = try XCTUnwrap(map(Self.detailedPhoto.replacingOccurrences(of: #""userRating":10"#, with: #""userRating":6"#)))
        XCTAssertFalse(rated.isFavorite, "three stars is not a photo favorite")
    }

    func test_otherTypes_andItemsWithoutAKey_areDropped() throws {
        XCTAssertNil(try map(#"{"ratingKey":"14","key":"/library/metadata/14","type":"movie","title":"x"}"#))
        XCTAssertNil(try map(#"{"key":"/library/metadata/15","type":"photo","title":"x"}"#))
    }
}
