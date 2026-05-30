// RivuletTests/Unit/MusicProviderRegistryTests.swift
import XCTest
@testable import Rivulet

@MainActor
final class MusicProviderRegistryTests: XCTestCase {

    private final class StubMusicProvider: MusicProvider, @unchecked Sendable {
        nonisolated let id: String
        nonisolated let kind: MediaProviderKind = .plex
        nonisolated let displayName: String = "Stub"
        nonisolated var connectionState: ConnectionState { .connected }
        init(id: String) { self.id = id }

        func musicLibraries() async throws -> [MediaLibrary] { [] }
        func artists(in library: MediaLibrary, sort: SortOption, page: Page) async throws -> PagedResult<MusicArtist> {
            PagedResult(items: [], total: 0, nextPage: nil)
        }
        func albums(in library: MediaLibrary, sort: SortOption, page: Page) async throws -> PagedResult<MusicAlbum> {
            PagedResult(items: [], total: 0, nextPage: nil)
        }
        func search(_ query: String) async throws -> [MusicItem] { [] }
        func albums(for artistRef: MediaItemRef) async throws -> [MusicAlbum] { [] }
        func tracks(for albumRef: MediaItemRef) async throws -> [MusicTrack] { [] }
        func allTracks(for artistRef: MediaItemRef) async throws -> [MusicTrack] { [] }
        func artistDetail(for ref: MediaItemRef) async throws -> MusicArtistDetail {
            MusicArtistDetail(artist: MusicArtist(ref: ref, name: "", sortName: nil,
                                                  artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
                                                  genres: [], yearRange: nil, userState: .empty),
                              bio: nil, genres: [], albums: [], topTracks: [], similarArtists: [])
        }
        func albumDetail(for ref: MediaItemRef) async throws -> MusicAlbumDetail {
            MusicAlbumDetail(album: MusicAlbum(ref: ref, title: "", sortTitle: nil,
                                               artistRef: nil, artistName: nil, year: nil,
                                               artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
                                               trackCount: nil, totalDuration: nil, genres: [], userState: .empty),
                             tracks: [], genres: [], contributors: [])
        }
        func trackDetail(for ref: MediaItemRef) async throws -> MusicTrackDetail {
            MusicTrackDetail(track: MusicTrack(ref: ref, title: "", albumRef: nil, albumTitle: nil,
                                               artistRef: nil, artistName: nil, trackNumber: nil,
                                               discNumber: nil, duration: 0, audioCodec: nil, bitrate: nil,
                                               sampleRate: nil,
                                               artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
                                               userState: .empty),
                             lyrics: nil)
        }
        func recentlyAddedAlbums(limit: Int) async throws -> [MusicAlbum] { [] }
        func recentlyPlayed(limit: Int) async throws -> [MusicItem] { [] }
        func resolveStream(for trackRef: MediaItemRef) async throws -> StreamInfo {
            StreamInfo(source: MediaSource(id: "", container: nil, duration: 0, bitrate: nil,
                                           fileSize: nil, fileName: nil, videoResolution: nil,
                                           videoTracks: [], audioTracks: [],
                                           subtitleTracks: [], streamKind: .directPlay, streamURL: nil),
                       playSessionID: nil, trackInfoAvailable: false)
        }
        func setRating(_ rating: Double?, for ref: MediaItemRef) async throws {}
        func setFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws {}
    }

    func test_register_and_lookup() {
        let registry = MusicProviderRegistry()
        let provider = StubMusicProvider(id: "plex:abc")
        registry.register(provider)
        XCTAssertNotNil(registry.provider(for: "plex:abc"))
        XCTAssertEqual(registry.provider(for: "plex:abc")?.id, "plex:abc")
    }

    func test_register_dedupes_by_id() {
        let registry = MusicProviderRegistry()
        registry.register(StubMusicProvider(id: "plex:abc"))
        registry.register(StubMusicProvider(id: "plex:abc"))
        XCTAssertEqual(registry.enabledProviders().count, 1)
    }

    func test_unregister_removes() {
        let registry = MusicProviderRegistry()
        registry.register(StubMusicProvider(id: "plex:abc"))
        registry.unregister(providerID: "plex:abc")
        XCTAssertNil(registry.provider(for: "plex:abc"))
    }

    func test_missing_id_returns_nil() {
        let registry = MusicProviderRegistry()
        XCTAssertNil(registry.provider(for: "nope"))
    }
}
