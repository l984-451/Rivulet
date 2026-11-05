// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexMusicMapper.swift
//  Rivulet
//
//  Maps PlexMetadata -> agnostic music types. Stateless pure functions.
//  Mirrors PlexMediaMapper's conventions.
//

import Foundation

enum PlexMusicMapper {

    // MARK: - User state

    static func userState(_ meta: PlexMetadata) -> MusicUserState {
        // Plex userRating is 0-10; normalize to 0.0-5.0 for the music layer.
        let rating: Double? = meta.userRating.map { $0 / 2.0 }
        return MusicUserState(
            isFavorite: PlexUserRating.isFavorite(meta.userRating),
            userRating: rating,
            playCount: meta.viewCount ?? 0,
            lastPlayedAt: meta.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    // MARK: - Artwork

    private static func artwork(_ meta: PlexMetadata, serverURL: String, authToken: String) -> MediaArtwork {
        MediaArtwork(
            poster: PlexMediaMapper.artworkURL(meta.thumb ?? meta.bestThumb, serverURL: serverURL, authToken: authToken),
            backdrop: PlexMediaMapper.artworkURL(meta.bestArt, serverURL: serverURL, authToken: authToken),
            thumbnail: PlexMediaMapper.artworkURL(meta.thumb, serverURL: serverURL, authToken: authToken),
            logo: nil
        )
    }

    // MARK: - Artist

    static func artist(
        _ meta: PlexMetadata,
        providerID: String,
        serverURL: String,
        authToken: String
    ) -> MusicArtist {
        MusicArtist(
            ref: MediaItemRef(providerID: providerID, itemID: meta.ratingKey ?? ""),
            name: meta.title ?? "",
            sortName: nil,
            artwork: artwork(meta, serverURL: serverURL, authToken: authToken),
            genres: meta.Genre?.compactMap(\.tag) ?? [],
            yearRange: nil,
            userState: userState(meta)
        )
    }

    // MARK: - Album

    static func album(
        _ meta: PlexMetadata,
        providerID: String,
        serverURL: String,
        authToken: String
    ) -> MusicAlbum {
        let artistRef: MediaItemRef? = meta.parentRatingKey.map {
            MediaItemRef(providerID: providerID, itemID: $0)
        }
        return MusicAlbum(
            ref: MediaItemRef(providerID: providerID, itemID: meta.ratingKey ?? ""),
            title: meta.title ?? "",
            sortTitle: nil,
            artistRef: artistRef,
            artistName: meta.parentTitle,
            year: meta.year,
            artwork: artwork(meta, serverURL: serverURL, authToken: authToken),
            trackCount: meta.leafCount,
            totalDuration: meta.duration.map { TimeInterval($0) / 1000 },
            genres: meta.Genre?.compactMap(\.tag) ?? [],
            userState: userState(meta)
        )
    }

    // MARK: - Track

    static func track(
        _ meta: PlexMetadata,
        providerID: String,
        serverURL: String,
        authToken: String
    ) -> MusicTrack {
        let albumRef: MediaItemRef? = meta.parentRatingKey.map {
            MediaItemRef(providerID: providerID, itemID: $0)
        }
        let artistRef: MediaItemRef? = meta.grandparentRatingKey.map {
            MediaItemRef(providerID: providerID, itemID: $0)
        }
        let durationMs = meta.duration ?? 0
        // The first audio stream's codec and bitrate; a list response has no streams, only the media's.
        let media = (meta.Media ?? []).first
        let firstAudio: PlexStream? = media?.Part?.first?.Stream?.first(where: { $0.streamType == 2 })
        return MusicTrack(
            ref: MediaItemRef(providerID: providerID, itemID: meta.ratingKey ?? ""),
            title: meta.title ?? "",
            albumRef: albumRef,
            albumTitle: meta.parentTitle,
            artistRef: artistRef,
            // originalTitle is the track's own artist; it differs from the
            // album artist on compilations and cast recordings.
            artistName: meta.originalTitle.flatMap { $0.isEmpty ? nil : $0 } ?? meta.grandparentTitle,
            trackNumber: meta.index,
            discNumber: meta.parentIndex,
            duration: TimeInterval(durationMs) / 1000,
            audioCodec: firstAudio?.codec ?? media?.audioCodec,
            bitrate: firstAudio?.bitrate ?? media?.bitrate,
            sampleRate: firstAudio?.samplingRate,
            artwork: artwork(meta, serverURL: serverURL, authToken: authToken),
            userState: userState(meta)
        )
    }

    // MARK: - Playlist

    static func playlist(
        _ playlist: PlexPlaylist,
        providerID: String,
        serverURL: String,
        authToken: String
    ) -> MusicPlaylist {
        MusicPlaylist(
            ref: MediaItemRef(providerID: providerID, itemID: playlist.ratingKey),
            title: playlist.title ?? "",
            artworkURL: PlexMediaMapper.artworkURL(playlist.composite, serverURL: serverURL, authToken: authToken),
            trackCount: playlist.leafCount ?? 0,
            duration: TimeInterval(playlist.duration ?? 0) / 1000,
            isSmart: playlist.smart ?? false
        )
    }

    // MARK: - Lyrics

    /// Keys of a track's synced lyric streams (type 4, LRC). Needs full metadata.
    static func lyricStreamKeys(_ meta: PlexMetadata) -> [String] {
        (meta.Media?.first?.Part?.first?.Stream ?? [])
            .filter { $0.streamType == 4 && $0.codec == "lrc" }
            .compactMap(\.key)
    }

    /// Time-synced lines only: nil when the lyrics are untimed or empty.
    static func lyricLines(_ lyrics: PlexLyrics) -> [MusicLyricLine]? {
        let lines: [MusicLyricLine] = (lyrics.Line ?? []).compactMap { line in
            guard let startMs = line.startOffset else { return nil }
            // Sidecar LRC files with CRLF endings leave a stray \r on each line.
            let text = (line.Span ?? []).compactMap(\.text).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : MusicLyricLine(start: TimeInterval(startMs) / 1000, text: text)
        }
        return lines.isEmpty ? nil : lines
    }

    // MARK: - Dispatch

    /// Routes a generic PlexMetadata to the appropriate MusicItem case.
    /// Returns nil for non-music types so callers can filter mixed lists.
    static func item(
        _ meta: PlexMetadata,
        providerID: String,
        serverURL: String,
        authToken: String
    ) -> MusicItem? {
        switch meta.type {
        case "artist":
            return .artist(artist(meta, providerID: providerID, serverURL: serverURL, authToken: authToken))
        case "album":
            return .album(album(meta, providerID: providerID, serverURL: serverURL, authToken: authToken))
        case "track":
            return .track(track(meta, providerID: providerID, serverURL: serverURL, authToken: authToken))
        default:
            return nil
        }
    }

    // MARK: - Details

    static func artistDetail(
        _ meta: PlexMetadata,
        albums: [PlexMetadata],
        similarArtists: [PlexMetadata],
        providerID: String,
        serverURL: String,
        authToken: String
    ) -> MusicArtistDetail {
        MusicArtistDetail(
            artist: artist(meta, providerID: providerID, serverURL: serverURL, authToken: authToken),
            bio: meta.summary,
            genres: meta.Genre?.compactMap(\.tag) ?? [],
            albums: albums.map {
                album($0, providerID: providerID, serverURL: serverURL, authToken: authToken)
            },
            similarArtists: similarArtists.map {
                artist($0, providerID: providerID, serverURL: serverURL, authToken: authToken)
            }
        )
    }

    static func albumDetail(
        _ meta: PlexMetadata,
        tracks tracksList: [PlexMetadata],
        providerID: String,
        serverURL: String,
        authToken: String
    ) -> MusicAlbumDetail {
        let contributors: [MediaPerson] = (meta.Role ?? []).map { role in
            MediaPerson(
                id: role.id,
                name: role.tag ?? "",
                role: role.role,
                imageURL: PlexMediaMapper.artworkURL(role.thumb, serverURL: serverURL, authToken: authToken)
            )
        }
        return MusicAlbumDetail(
            album: album(meta, providerID: providerID, serverURL: serverURL, authToken: authToken),
            tracks: tracksList.map {
                track($0, providerID: providerID, serverURL: serverURL, authToken: authToken)
            },
            genres: meta.Genre?.compactMap(\.tag) ?? [],
            contributors: contributors
        )
    }
}
