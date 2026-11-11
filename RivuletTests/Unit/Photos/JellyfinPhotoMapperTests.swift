// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Fixtures are entries from a "homevideos" library on Jellyfin 12.1, trimmed
/// to the fields the app decodes, with ids, tags and dates replaced.
@MainActor
final class JellyfinPhotoMapperTests: XCTestCase {
    private let server = FakeJellyfinServer()
    private let library = MediaLibrary(id: "lib", providerID: "jellyfin:srv", title: "Photos", kind: .photos)
    /// West of UTC, where a wall-clock time read as UTC shows as the day before. Passed in rather
    /// than set as the default zone: the date parser and `Calendar.current` don't both follow
    /// `NSTimeZone.default`, so that only held on a machine already in Chicago.
    private static let chicago = TimeZone(identifier: "America/Chicago")!
    private static var chicagoCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chicago
        return calendar
    }

    // A sub-folder is a PhotoAlbum with no image; the library's own path is a Folder.
    private static let album = #"{"Name":"Trip","Id":"trip","DateCreated":"2001-07-17T18:31:23.0000000Z","IsFolder":true,"Type":"PhotoAlbum","RecursiveItemCount":6,"ImageTags":{},"MediaType":"Unknown"}"#
    private static let nestedAlbum = #"{"Name":"Day Two","Id":"day2","DateCreated":"2001-08-03T23:38:34.0000000Z","IsFolder":true,"Type":"PhotoAlbum","RecursiveItemCount":2,"ImageTags":{},"MediaType":"Unknown"}"#
    private static let libraryFolder = #"{"Name":"Rivulet Photo Test","Id":"path","IsFolder":true,"Type":"Folder","RecursiveItemCount":7,"ImageTags":{},"MediaType":"Unknown"}"#
    // With EXIF: both dates are the camera's wall clock stamped Z.
    private static let photo = #"{"Name":"day2-10","Id":"p10","PremiereDate":"2001-01-03T01:00:00.0000000Z","DateCreated":"2001-01-03T01:00:00.0000000Z","Type":"Photo","ImageTags":{"Primary":"tag10"},"MediaType":"Photo"}"#
    // Without EXIF: the file's date only.
    private static let photoWithoutEXIF = #"{"Name":"trip-6","Id":"p6","DateCreated":"2001-04-03T07:42:06.0000000Z","Type":"Photo","ImageTags":{"Primary":"tag6"},"MediaType":"Photo"}"#
    private static let clip = #"{"Name":"clip-1","Id":"v1","PremiereDate":"2001-01-17T06:07:11.0000000Z","DateCreated":"2001-02-03T11:14:22.0000000Z","RunTimeTicks":93983450,"IsFolder":false,"Type":"Video","VideoType":"VideoFile","ImageTags":{"Primary":"tagv"},"MediaType":"Video"}"#

    private func list(_ items: [String], total: Int? = nil) -> String {
        #"{"Items":[\#(items.joined(separator: ","))],"TotalRecordCount":\#(total ?? items.count),"StartIndex":0}"#
    }

    private func provider() -> JellyfinProvider {
        JellyfinProvider(serverID: "srv", displayName: "NAS", userID: "user-1",
                         client: JellyfinClient(baseURL: JellyfinFixtures.baseURL, token: "tok",
                                                transport: server.transport))
    }

    private func map(_ json: String) -> PhotoItem? {
        JellyfinPhotoMapper.item(JellyfinFixtures.decode(json), providerID: "jellyfin:srv",
                                 baseURL: JellyfinFixtures.baseURL)
    }

    private func query(_ url: URL?) -> [String: String] {
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private func sent(_ types: String) -> [String: String]? {
        server.requests.map { query($0.url) }.first { $0["includeItemTypes"] == types }
    }

    func test_kinds_andUnknownTypesDropped() {
        let album = map(Self.album)
        XCTAssertEqual(album?.kind, .folder)
        XCTAssertEqual(album?.childCount, 6, "leaves at any depth, sub-albums not counted")
        XCTAssertNil(album?.thumbnail, "an album has no image: the cell keeps its folder glyph")
        XCTAssertEqual(map(Self.libraryFolder)?.kind, .folder)
        XCTAssertEqual(map(Self.photo)?.kind, .photo)
        XCTAssertNil(map(#"{"Id":"d","Name":"Song","Type":"Audio"}"#))
        XCTAssertNil(map(#"{"Name":"no id","Type":"Photo"}"#))
    }

    func test_photo_sizedURLs() {
        let photo = map(Self.photo)
        XCTAssertEqual(photo?.thumbnail?.path, "/Items/p10/Images/Primary")
        let thumb = query(photo?.thumbnail)
        XCTAssertEqual([thumb["tag"], thumb["fillWidth"], thumb["fillHeight"]], ["tag10", "520", "520"])
        let full = query(photo?.full)
        XCTAssertEqual([full["maxWidth"], full["maxHeight"]], ["3840", "2160"])
        XCTAssertNil(full["fillWidth"], "full screen is a fit, not a cover")
        XCTAssertNil(photo?.playable)
    }

    func test_photoDate_isTheCamerasDay_inTheDeviceZone() {
        // 01:00 "Z" is 19:00 the day before in Chicago if read as an instant.
        let taken = map(Self.photo)?.date
        XCTAssertEqual(taken.map { Calendar.current.dateComponents([.year, .month, .day], from: $0) },
                       DateComponents(year: 2001, month: 1, day: 3))
        let west = JellyfinPhotoMapper.date(JellyfinFixtures.decode(Self.photo), kind: .photo, in: Self.chicago)
        XCTAssertEqual(west.map { Self.chicagoCalendar.dateComponents([.year, .month, .day], from: $0) },
                       DateComponents(year: 2001, month: 1, day: 3), "and west of UTC")
    }

    func test_takenClock_isTheCamerasWithEXIF_elseAnInstant() {
        XCTAssertEqual(map(Self.photo)?.details?.takenAtClock, .wallClock)
        XCTAssertEqual(map(Self.photoWithoutEXIF)?.details?.takenAtClock, .instant)
        XCTAssertEqual(map(Self.clip)?.details?.takenAtClock, .instant)
    }

    func test_date_withoutEXIF_andForAClip_isAnInstant() {
        XCTAssertEqual(map(Self.photoWithoutEXIF)?.date, JellyfinMediaMapper.parseDate("2001-04-03T07:42:06.0000000Z"))
        XCTAssertEqual(map(Self.clip)?.date, JellyfinMediaMapper.parseDate("2001-01-17T06:07:11.0000000Z"))
    }

    func test_video_isAClip_withAPlayableItem() {
        let clip = map(Self.clip)
        XCTAssertEqual(clip?.kind, .clip)
        XCTAssertEqual(clip?.playable?.ref, MediaItemRef(providerID: "jellyfin:srv", itemID: "v1"))
        XCTAssertEqual(query(clip?.thumbnail)["tag"], "tagv", "its still is an extracted frame")
    }

    // MARK: - Home videos rule

    private func libraryKinds(_ collectionType: String) async throws -> [MediaLibrary.LibraryKind] {
        server.respond("/UserViews", body: list([
            #"{"Name":"Rivulet Photo Test","Id":"lib","IsFolder":true,"Type":"CollectionFolder","CollectionType":"\#(collectionType)","ImageTags":{"Primary":"t"}}"#
        ]))
        return try await provider().libraries().map(\.kind)
    }

    func test_homeVideos_withPhotos_isAPhotoLibrary() async throws {
        server.respond("/Items", query: ["includeItemTypes": "Photo", "limit": "0"], body: list([], total: 6))
        server.respond("/Items", query: ["includeItemTypes": "Video", "limit": "0"], body: list([], total: 0))

        let kinds = try await libraryKinds("homevideos")

        XCTAssertEqual(kinds, [.photos])
        let probe = sent("Photo")
        XCTAssertEqual([probe?["parentId"], probe?["recursive"]], ["lib", "true"])
    }

    func test_homeVideos_videoOnly_staysAVideoLibrary() async throws {
        server.respond("/Items", query: ["includeItemTypes": "Photo", "limit": "0"], body: list([], total: 0))
        let kinds = try await libraryKinds("homevideos")
        XCTAssertEqual(kinds, [.mixed])
    }

    func test_homeVideos_probeFailure_throws() async {
        server.respond("/Items", query: ["includeItemTypes": "Photo", "limit": "0"], status: 500)
        do {
            _ = try await libraryKinds("homevideos")
            XCTFail("expected a throw")
        } catch {}
    }

    func test_photosType_isAPhotoLibrary_withoutAProbe() async throws {
        let kinds = try await libraryKinds("photos")
        XCTAssertEqual(kinds, [.photos])
        XCTAssertEqual(server.requests.count, 1)
    }

    // Invented values, in the list shape: EXIF and GPS come without `fields`.
    private static let detailedPhoto = #"{"Name":"beach","Id":"p20","DateCreated":"2001-01-03T01:00:00.0000000Z","PremiereDate":"2001-01-03T01:00:00.0000000Z","Type":"Photo","ImageTags":{"Primary":"t"},"MediaType":"Photo","CameraMake":"Apple","CameraModel":"iPhone Air","ExposureTime":0.0125,"FocalLength":5.96,"IsoSpeedRating":125,"Aperture":1.3561438531849228,"Latitude":10.5,"Longitude":-20.25,"Width":4032,"Height":3024,"Path":"/photos/trip/beach.jpg","UserData":{"IsFavorite":true}}"#

    func test_photo_mapsFavoriteCoordinateAndEXIF() throws {
        let photo = try XCTUnwrap(map(Self.detailedPhoto))
        XCTAssertTrue(photo.isFavorite)
        XCTAssertEqual(photo.coordinate, PhotoCoordinate(latitude: 10.5, longitude: -20.25))
        let details = try XCTUnwrap(photo.details)
        XCTAssertEqual(details.cameraLine, "Apple iPhone Air")
        XCTAssertEqual(details.fNumber, 1.6, "APEX aperture as an f-number")
        XCTAssertEqual(details.exposureSeconds, 0.0125)
        XCTAssertEqual(details.iso, 125)
        XCTAssertEqual(details.focalLength, 5.96)
        XCTAssertEqual([details.width, details.height], [4032, 3024])
        XCTAssertEqual(details.fileName, "beach.jpg")
        XCTAssertEqual(details.takenAt, JellyfinMediaMapper.parseDate("2001-01-03T01:00:00.0000000Z"))
        XCTAssertEqual(details.exposureLine, "f/1.6 · 1/80 s · ISO 125 · 6 mm")
    }

    func test_photoWithoutEXIF_hasNoCameraOrPlace() throws {
        let photo = try XCTUnwrap(map(Self.photoWithoutEXIF))
        XCTAssertFalse(photo.isFavorite)
        XCTAssertNil(photo.coordinate)
        XCTAssertNil(photo.details?.cameraLine)
        XCTAssertNil(map(Self.album)?.details)
    }

    // MARK: - Requests

    func test_root_asksItsOwnFoldersOnce_andEveryPhotoRecursively() async throws {
        // Without `recursive=false` the server adds the nested album and the library's own Folder.
        server.respond("/Items", query: ["includeItemTypes": "PhotoAlbum,Folder", "recursive": "false"],
                       body: list([Self.album]))
        server.respond("/Items", query: ["includeItemTypes": "PhotoAlbum,Folder"],
                       body: list([Self.nestedAlbum, Self.libraryFolder, Self.album]))
        server.respond("/Items", query: ["includeItemTypes": "Photo,Video"],
                       body: list([Self.photoWithoutEXIF, Self.clip, Self.photo], total: 450))

        let page = try await provider().photoPage(in: library, folder: nil, query: .default, page: Page(offset: 0, limit: 200))

        XCTAssertEqual(page.folders.map(\.title), ["Trip"])
        XCTAssertEqual(page.media.map(\.kind), [.photo, .clip, .photo])
        XCTAssertEqual(page.nextPage, Page(offset: 200, limit: 200))
        XCTAssertEqual(sent("PhotoAlbum,Folder")?["parentId"], "lib")
        let media = sent("Photo,Video")
        XCTAssertEqual(media?["parentId"], "lib")
        XCTAssertEqual(media?["recursive"], "true")
        XCTAssertEqual(media?["sortBy"], "DateCreated,SortName")
        XCTAssertEqual(media?["sortOrder"], "Descending")
        XCTAssertEqual([media?["startIndex"], media?["limit"]], ["0", "200"])
        XCTAssertEqual(media?["fields"], "DateCreated,RecursiveItemCount,Path,Width,Height",
                       "DateCreated, the path and the size arrive only when asked for")
    }

    func test_folder_listsItsSubAlbums_andItsOwnMedia() async throws {
        server.respond("/Items", query: ["includeItemTypes": "PhotoAlbum,Folder"], body: list([Self.nestedAlbum]))
        server.respond("/Items", query: ["includeItemTypes": "Photo,Video"], body: list([Self.photoWithoutEXIF, Self.clip]))

        let page = try await provider().photoPage(
            in: library, folder: MediaItemRef(providerID: "jellyfin:srv", itemID: "trip"), query: .default,
            page: Page(offset: 0, limit: 200))

        XCTAssertEqual(page.folders.map(\.title), ["Day Two"])
        XCTAssertEqual(page.folders.first?.childCount, 2)
        XCTAssertEqual(page.media.map(\.title), ["trip-6", "clip-1"])
        XCTAssertNil(page.nextPage)
    }

    func test_folder_laterPage_asksOnlyItsOwnMedia() async throws {
        server.respond("/Items", query: ["includeItemTypes": "Photo,Video"], body: list([Self.photo], total: 201))

        let page = try await provider().photoPage(
            in: library, folder: MediaItemRef(providerID: "jellyfin:srv", itemID: "trip"), query: .default,
            page: Page(offset: 200, limit: 200))

        XCTAssertNil(page.nextPage)
        XCTAssertEqual(server.requests.count, 1, "folders come with the first page only")
        let query = query(server.requests[0].url)
        XCTAssertEqual(query["parentId"], "trip")
        XCTAssertNil(query["recursive"], "a folder lists its own photos")
    }
}
