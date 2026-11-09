// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyPhotoFolderTests.swift
//  RivuletTests
//
//  Photo and folder browsing against FakeEmbyServer. Replies are trimmed 4.10.2 captures
//  (EmbyPhotoFixtures); the request assertions are the part the server's behavior depends on.
//

import XCTest
@testable import Rivulet

@MainActor
final class EmbyPhotoFolderTests: XCTestCase {
    private let server = FakeEmbyServer()
    private let uid = EmbyLiveFixtures.userID
    private let pid = "emby:srv"
    private typealias Fixtures = EmbyPhotoFixtures
    private let base = EmbyBrowseFixtures.baseURL
    private let photos = MediaLibrary(id: "9", providerID: "emby:srv", title: "Photos", kind: .photos)
    private let misc = MediaLibrary(id: "11", providerID: "emby:srv", title: "Misc Mixed", kind: .mixed)
    private var zone: TimeZone!

    // West of UTC, where a wall-clock time read as UTC shows as the day before.
    override func setUp() {
        zone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/Chicago")!
    }

    override func tearDown() async throws {
        NSTimeZone.default = zone
        XCTAssertEqual(server.headerProblems, [])
        try await super.tearDown()
    }

    private func provider() -> EmbyProvider {
        EmbyProvider(serverID: "srv", displayName: "Emby", userID: uid, policy: EmbySession.Policy(),
                     client: EmbyClient(baseURL: base, token: "tok", transport: server.transport))
    }

    private func items(_ json: String) throws -> [EmbyItem] { try EmbyTestJSON.items(json) }

    private func map(_ json: String, at index: Int = 0) throws -> PhotoItem? {
        EmbyPhotoMapper.item(try items(json)[index], providerID: pid, baseURL: base)
    }

    private func params(_ url: URL?) -> [String: String] {
        let pairs = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(pairs.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    private func query(_ request: URLRequest) -> [String: String] { params(request.url) }

    private func day(_ date: Date?) -> DateComponents? {
        date.map { Calendar.current.dateComponents([.year, .month, .day], from: $0) }
    }

    // MARK: - Photo mapper

    func test_kinds_andUnknownTypesDropped() throws {
        XCTAssertEqual(try map(Fixtures.libraryAlbums)?.kind, .folder)
        XCTAssertEqual(try map(Fixtures.libraryFolder)?.kind, .folder, "a recursive request adds the library's own Folder")
        XCTAssertEqual(try map(Fixtures.rootMedia)?.kind, .photo)
        XCTAssertEqual(try map(Fixtures.rootMedia, at: 3)?.kind, .clip)
        let audio = try EmbyTestJSON.decode(#"{"Id":"9","Name":"Song","Type":"Audio"}"#) as EmbyItem
        XCTAssertNil(EmbyPhotoMapper.item(audio, providerID: pid, baseURL: base))
    }

    /// `FillWidth` is ignored (the original comes back, 9 MB for a HEIC), so a tile is a `MaxWidth` fit.
    func test_photo_thumbnailAndViewerURLs() throws {
        let photo = try XCTUnwrap(try map(Fixtures.rootMedia))
        XCTAssertEqual(photo.thumbnail?.path, "/Items/1652/Images/Primary")
        let thumb = params(photo.thumbnail)
        XCTAssertEqual(thumb["Tag"], "bebea31b6dbc7458b604c699fa9c403a_639009169400000000")
        XCTAssertEqual([thumb["MaxWidth"], thumb["MaxHeight"], thumb["Quality"]], ["520", "520", "90"])
        XCTAssertNil(thumb["FillWidth"])
        XCTAssertNil(thumb["FillHeight"])
        XCTAssertNil(thumb["api_key"], "images are anonymous")
        let full = params(photo.full)
        XCTAssertEqual([full["MaxWidth"], full["MaxHeight"]], ["3840", "2160"])
        XCTAssertNil(full["Width"])
        XCTAssertNil(photo.playable)
    }

    func test_heic_isAPhotoLikeAnyOther() throws {
        let heic = try XCTUnwrap(try map(Fixtures.rootMedia, at: 1))
        XCTAssertEqual(heic.kind, .photo)
        XCTAssertEqual(heic.ref.itemID, "1649")
        XCTAssertNotNil(heic.thumbnail)
        XCTAssertNotNil(heic.full)
        let detail = try EmbyTestJSON.decode(Fixtures.heicDetail) as EmbyItem
        XCTAssertEqual(EmbyPhotoMapper.item(detail, providerID: pid, baseURL: base)?.kind, .photo)
    }

    func test_album_coverIsTheChildItPointsAt_andHasNoViewerImage() throws {
        let trip = try XCTUnwrap(try map(Fixtures.libraryAlbums))
        XCTAssertEqual(trip.title, "Trip")
        XCTAssertEqual(trip.thumbnail?.path, "/Items/1659/Images/Primary", "its own image route is a 404")
        XCTAssertEqual(params(trip.thumbnail)["Tag"], "08d7d27de01ced30c63c212935551959_638885700510000000")
        XCTAssertEqual(params(trip.thumbnail)["MaxWidth"], "520")
        XCTAssertNil(trip.full)
        XCTAssertEqual(trip.childCount, 6, "RecursiveItemCount: leaves at any depth")
    }

    func test_album_withoutAPointerKeepsTheGlyph() throws {
        let bare = try EmbyTestJSON.decode(#"{"Id":"5","Name":"Empty","Type":"PhotoAlbum","ImageTags":{}}"#) as EmbyItem
        XCTAssertNil(EmbyPhotoMapper.item(bare, providerID: pid, baseURL: base)?.thumbnail)
    }

    func test_clip_hasNoImageRequest_andIsPlayable() throws {
        let clip = try XCTUnwrap(try map(Fixtures.rootMedia, at: 3))
        XCTAssertEqual(clip.kind, .clip)
        XCTAssertNil(clip.thumbnail, "Images/Primary is a 500 for a clip")
        XCTAssertNil(clip.full)
        XCTAssertEqual(clip.playable?.ref, MediaItemRef(providerID: pid, itemID: "1657"))
        XCTAssertEqual(clip.playable?.kind, .movie)
    }

    // MARK: - Dates

    func test_photoDate_isTheCamerasDay_inTheDeviceZone() throws {
        // 15:18 "Z" would be 09:18 the same day in Chicago; 04:05 would roll back a day.
        let late = try EmbyTestJSON.decode(#"{"Id":"1","Name":"p","Type":"Photo","PremiereDate":"2025-01-03T01:00:00.0000000Z","DateCreated":"2025-01-03T01:00:00.0000000Z","ImageTags":{"Primary":"t"}}"#) as EmbyItem
        let photo = try XCTUnwrap(EmbyPhotoMapper.item(late, providerID: pid, baseURL: base))
        XCTAssertEqual(day(photo.date), DateComponents(year: 2025, month: 1, day: 3))
        XCTAssertEqual(day(try map(Fixtures.rootMedia)?.date), DateComponents(year: 2025, month: 12, day: 9))
    }

    func test_takenClock_isTheCamerasWithEXIF_elseAnInstant() throws {
        XCTAssertEqual(try map(Fixtures.rootMedia)?.details?.takenAtClock, .wallClock)
        XCTAssertEqual(try map(Fixtures.rootMedia, at: 2)?.details?.takenAtClock, .instant)
        XCTAssertEqual(try map(Fixtures.rootMedia, at: 3)?.details?.takenAtClock, .instant)
    }

    func test_dateWithoutEXIF_andForAClip_isAnInstant() throws {
        XCTAssertEqual(try map(Fixtures.rootMedia, at: 2)?.date, EmbyJSON.date("2025-12-05T16:53:00.0000000Z"))
        XCTAssertEqual(try map(Fixtures.rootMedia, at: 3)?.date, EmbyJSON.date("2025-07-16T06:46:37.0000000Z"))
    }

    func test_photo_detailsAreSizeAndFileOnly_andNoPlace() throws {
        let photo = try XCTUnwrap(try map(Fixtures.rootMedia))
        XCTAssertNil(photo.coordinate, "Emby sends no GPS")
        XCTAssertNil(photo.details?.cameraLine, "nor EXIF")
        XCTAssertNil(photo.details?.exposureLine)
        XCTAssertEqual([photo.details?.width, photo.details?.height], [4032, 3024])
        XCTAssertEqual(photo.details?.fileName, "photo-5.jpg")
        XCTAssertEqual(photo.details?.takenAt, EmbyJSON.date("2025-12-09T16:42:20.0000000Z"))
        XCTAssertFalse(photo.isFavorite)
        let favorite = Fixtures.rootMedia.replacingOccurrences(of: #""IsFavorite":false"#, with: #""IsFavorite":true"#)
        XCTAssertTrue(try XCTUnwrap(try map(favorite)).isFavorite)
        XCTAssertNil(try map(Fixtures.libraryAlbums)?.details)
    }

    func test_favorites_skipTheAlbums_andRecurse() async throws {
        server.respond("/Users/\(uid)/Items", body: Fixtures.rootMedia)
        let trip = MediaItemRef(providerID: pid, itemID: "1653")
        _ = try await provider().photoPage(in: photos, folder: trip, query: PhotoQuery(favoritesOnly: true),
                                           page: Page(offset: 0, limit: 100))
        XCTAssertEqual(server.requests.count, 1, "no album request")
        let sent = query(server.requests[0])
        XCTAssertEqual([sent["Filters"], sent["Recursive"]], ["IsFavorite", "true"])
    }

    // MARK: - photoPage

    func test_root_listsFoldersNonRecursively_andEveryPhotoRecursively() async throws {
        server.respond("/Users/\(uid)/Items", query: ["IncludeItemTypes": "PhotoAlbum,Folder"], body: Fixtures.libraryAlbums)
        server.respond("/Users/\(uid)/Items", query: ["IncludeItemTypes": "Photo,Video"], body: Fixtures.rootMedia)
        let result = try await provider().photoPage(in: photos, folder: nil, query: .default, page: Page(offset: 0, limit: 100))
        XCTAssertEqual(result.folders.map(\.title), ["Trip"])
        XCTAssertEqual(result.media.map(\.title), ["photo-5", "photo-2", "trip-6", "clip-1"])
        XCTAssertEqual(result.media.map(\.kind), [.photo, .photo, .photo, .clip])
        XCTAssertNil(result.nextPage)

        let folders = try XCTUnwrap(server.requests.map(query).first { $0["IncludeItemTypes"] == "PhotoAlbum,Folder" })
        XCTAssertEqual([folders["ParentId"], folders["Recursive"]], ["9", "false"], "omitted would also be false, but say so")
        XCTAssertEqual(folders["SortBy"], "SortName")
        XCTAssertTrue(folders["Fields"]?.contains("RecursiveItemCount") == true)
        let media = try XCTUnwrap(server.requests.map(query).first { $0["IncludeItemTypes"] == "Photo,Video" })
        XCTAssertEqual([media["ParentId"], media["Recursive"]], ["9", "true"])
        XCTAssertEqual([media["SortBy"], media["SortOrder"]], ["DateCreated,SortName", "Descending,Ascending"])
        XCTAssertTrue(media["Fields"]?.contains("PremiereDate") == true, "not a default field: without it every photo is an instant")
        XCTAssertEqual([media["StartIndex"], media["Limit"]], ["0", "100"])
    }

    func test_insideAFolder_bothRequestsAreNonRecursiveAndScopedToIt() async throws {
        server.respond("/Users/\(uid)/Items", query: ["IncludeItemTypes": "PhotoAlbum,Folder"], body: Fixtures.albumFolders)
        server.respond("/Users/\(uid)/Items", query: ["IncludeItemTypes": "Photo,Video"], body: Fixtures.albumMedia)
        let trip = MediaItemRef(providerID: pid, itemID: "1653")
        let result = try await provider().photoPage(in: photos, folder: trip, query: .default, page: Page(offset: 0, limit: 100))
        XCTAssertEqual(result.folders.map(\.title), ["Day Two"])
        XCTAssertEqual(result.media.map(\.kind), [.photo, .photo, .photo, .clip])
        for request in server.requests {
            let sent = query(request)
            XCTAssertEqual([sent["ParentId"], sent["Recursive"]], ["1653", "false"])
        }
    }

    func test_laterPages_skipTheFoldersAndPageAgainstTheTotal() async throws {
        server.respond("/Users/\(uid)/Items", body: Fixtures.rootMedia.replacingOccurrences(of: #""TotalRecordCount":4"#, with: #""TotalRecordCount":11"#))
        let result = try await provider().photoPage(in: photos, folder: nil, query: .default, page: Page(offset: 4, limit: 4))
        XCTAssertEqual(server.requests.count, 1, "folders are asked for once")
        XCTAssertTrue(result.folders.isEmpty)
        XCTAssertEqual(result.nextPage?.offset, 8)
        let last = try await provider().photoPage(in: photos, folder: nil, query: .default, page: Page(offset: 8, limit: 4))
        XCTAssertNil(last.nextPage)
    }

    // MARK: - Folders

    func test_folderEntries_mapEveryObservedType() throws {
        func entry(_ json: String, at index: Int = 0) throws -> FolderEntry? {
            EmbyFolderMapper.entry(try items(json)[index], providerID: pid, baseURL: base)
        }
        let series = try XCTUnwrap(try entry(Fixtures.miscRoot))
        XCTAssertEqual(series.title, "10 Minute Trainer")
        XCTAssertEqual(series.content, .folder(MediaItemRef(providerID: pid, itemID: "14"), childCount: 1))
        guard case .folder(_, let count) = try XCTUnwrap(try entry(Fixtures.miscRoot, at: 1)).content else { return XCTFail("a folder") }
        XCTAssertEqual(count, 5)
        guard case .video(let movie) = try XCTUnwrap(try entry(Fixtures.testFiles)).content else { return XCTFail("a video") }
        XCTAssertEqual(movie.title, "Dolby 5.1 Channel Check")
        XCTAssertEqual(movie.ref.itemID, "806")
        guard case .photo(let photo) = try XCTUnwrap(try entry(Fixtures.rootMedia)).content else { return XCTFail("a photo") }
        XCTAssertEqual(photo.kind, .photo)
        for type in ["PhotoAlbum", "Season", "BoxSet", "Folder", "Series"] {
            let dto = try EmbyTestJSON.decode(#"{"Id":"1","Name":"x","Type":"\#(type)"}"#) as EmbyItem
            guard case .folder = EmbyFolderMapper.entry(dto, providerID: pid, baseURL: base)?.content else { return XCTFail(type) }
        }
        for type in ["Movie", "Episode", "Video"] {
            let dto = try EmbyTestJSON.decode(#"{"Id":"1","Name":"x","Type":"\#(type)"}"#) as EmbyItem
            guard case .video = EmbyFolderMapper.entry(dto, providerID: pid, baseURL: base)?.content else { return XCTFail(type) }
        }
        let audio = try EmbyTestJSON.decode(#"{"Id":"1","Name":"x","Type":"Audio"}"#) as EmbyItem
        XCTAssertNil(EmbyFolderMapper.entry(audio, providerID: pid, baseURL: base))
    }

    /// Folders first is `IsFolder` ascending on Emby; the Jellyfin string would put them last.
    func test_folderPage_sortsFoldersFirst_withoutFilters() async throws {
        server.respond("/Users/\(uid)/Items", body: Fixtures.miscRoot.replacingOccurrences(of: #""TotalRecordCount":2"#, with: #""TotalRecordCount":26"#))
        let result = try await provider().folderPage(in: misc, folder: nil, page: Page(offset: 0, limit: 2))
        XCTAssertEqual(result.entries.map(\.title), ["10 Minute Trainer", "80 Day Sample"])
        XCTAssertEqual(result.nextPage?.offset, 2)
        let sent = query(server.requests[0])
        XCTAssertEqual(sent["ParentId"], "11")
        XCTAssertEqual(sent["SortBy"], "IsFolder,SortName")
        XCTAssertEqual(sent["SortOrder"], "Ascending,Ascending")
        XCTAssertNil(sent["Filters"], "Filters=IsFolder with IncludeItemTypes returned the whole library")
        XCTAssertNil(sent["IncludeItemTypes"])
        XCTAssertNil(sent["Recursive"])
        XCTAssertEqual([sent["StartIndex"], sent["Limit"]], ["0", "2"])
    }

    func test_folderPage_insideAFolder_listsItsChildren_andEndsAtTheTotal() async throws {
        server.respond("/Users/\(uid)/Items", body: Fixtures.testFiles.replacingOccurrences(of: #""TotalRecordCount":9"#, with: #""TotalRecordCount":2"#))
        let folder = MediaItemRef(providerID: pid, itemID: "37")
        let result = try await provider().folderPage(in: misc, folder: folder, page: Page(offset: 0, limit: 50))
        XCTAssertEqual(query(server.requests[0])["ParentId"], "37")
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertNil(result.nextPage)
    }

    func test_embyIsFoundThroughTheSeamsCasts() {
        let emby: any MediaProvider = provider()
        XCTAssertNotNil(emby as? any PhotoProvider)
        XCTAssertNotNil(emby as? any FolderProvider)
    }
}
