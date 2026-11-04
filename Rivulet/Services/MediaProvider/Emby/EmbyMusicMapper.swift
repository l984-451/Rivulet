// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyMusicMapper.swift
//  Rivulet
//
//  Emby DTOs -> music types. Albums and artists are virtual on Emby: no ParentId, no Path,
//  and an image only when the server names one, so every artwork URL is gated on a tag.
//

import Foundation

enum EmbyMusicMapper {
    /// Emby stores no star rating (a write is accepted and discarded), so none is read.
    static func userState(_ dto: EmbyItem) -> MusicUserState {
        let data = dto.userData
        return MusicUserState(
            isFavorite: data?.isFavorite ?? false,
            userRating: nil,
            playCount: data?.playCount ?? 0,
            lastPlayedAt: EmbyJSON.date(data?.lastPlayedDate)
        )
    }

    private static func ref(_ id: EmbyID?, _ providerID: String) -> MediaItemRef? {
        id.map { MediaItemRef(providerID: providerID, itemID: $0.value) }
    }

    private static func artwork(_ url: URL?) -> MediaArtwork {
        MediaArtwork(poster: url, backdrop: nil, thumbnail: url, logo: nil)
    }

    /// The item's own image, else the child's it points at, else none. An image route for an item
    /// with neither is a 404 (albums) or a 500 (tracks), so nothing is requested.
    private static func primary(_ dto: EmbyItem, _ baseURL: URL) -> URL? {
        EmbyMediaMapper.imageURL(baseURL, itemID: dto.id, type: "Primary", tag: dto.imageTags?["Primary"])
            ?? EmbyMediaMapper.imageURL(baseURL, itemID: dto.primaryImageItemId, type: "Primary", tag: dto.primaryImageTag)
    }

    static func artist(_ dto: EmbyItem, providerID: String, baseURL: URL) -> MusicArtist {
        let primary = primary(dto, baseURL)
        let backdrop = EmbyMediaMapper.imageURL(baseURL, itemID: dto.id, type: "Backdrop", tag: dto.backdropImageTags?.first)
        return MusicArtist(
            ref: MediaItemRef(providerID: providerID, itemID: dto.id.value),
            name: dto.name,
            sortName: dto.sortName,
            artwork: MediaArtwork(poster: primary, backdrop: backdrop, thumbnail: primary, logo: nil),
            genres: dto.genres ?? [],
            yearRange: nil,
            userState: userState(dto)
        )
    }

    /// The first album artist is the one the album files under.
    static func album(_ dto: EmbyItem, providerID: String, baseURL: URL) -> MusicAlbum {
        MusicAlbum(
            ref: MediaItemRef(providerID: providerID, itemID: dto.id.value),
            title: dto.name,
            sortTitle: dto.sortName,
            artistRef: ref(dto.albumArtists?.first?.id, providerID),
            artistName: dto.albumArtist ?? dto.albumArtists?.first?.name,
            year: dto.productionYear,
            artwork: artwork(primary(dto, baseURL)),
            trackCount: dto.childCount,
            totalDuration: EmbyTicks.seconds(dto.runTimeTicks),
            genres: dto.genres ?? [],
            userState: userState(dto)
        )
    }

    /// `artistRef` is the album artist, as on Plex; the name is the track's own artist, which differs
    /// on compilations and features. Codec and bitrate are nil on a list: it does not ask for streams.
    static func track(_ dto: EmbyItem, providerID: String, baseURL: URL) -> MusicTrack {
        let audio = dto.mediaSources?.first?.mediaStreams?.first { $0.type == "Audio" }
        let art = primary(dto, baseURL)
            ?? EmbyMediaMapper.imageURL(baseURL, itemID: dto.albumId, type: "Primary", tag: dto.albumPrimaryImageTag)
        return MusicTrack(
            ref: MediaItemRef(providerID: providerID, itemID: dto.id.value),
            title: dto.name,
            albumRef: ref(dto.albumId, providerID),
            albumTitle: dto.album,
            artistRef: ref(dto.albumArtists?.first?.id, providerID),
            artistName: dto.artistItems?.first?.name ?? dto.albumArtist,
            trackNumber: dto.indexNumber,
            discNumber: dto.parentIndexNumber,
            duration: EmbyTicks.seconds(dto.runTimeTicks) ?? 0,
            audioCodec: audio?.codec ?? dto.container,
            bitrate: audio?.bitRate.map { $0 / 1000 },
            sampleRate: audio?.sampleRate,
            artwork: artwork(art),
            userState: userState(dto)
        )
    }

    /// Emby playlists have no rules, so none is smart.
    static func playlist(_ dto: EmbyItem, providerID: String, baseURL: URL) -> MusicPlaylist {
        MusicPlaylist(
            ref: MediaItemRef(providerID: providerID, itemID: dto.id.value),
            title: dto.name,
            artworkURL: primary(dto, baseURL),
            trackCount: dto.childCount ?? 0,
            duration: EmbyTicks.seconds(dto.runTimeTicks) ?? 0,
            isSmart: false
        )
    }

    static func genre(_ dto: EmbyItem) -> MusicGenre {
        MusicGenre(id: dto.id.value, title: dto.name)
    }

    // MARK: - Lyrics

    /// The subtitle streams that can hold lyrics, a sidecar `.lrc` (timed) before an embedded tag
    /// (every cue at zero). The track's stream list needs the single-item route: lists leave it out.
    static func lyricStreams(_ source: EmbyMediaSource) -> [EmbyMediaStream] {
        let streams = (source.mediaStreams ?? []).filter { $0.type == "Subtitle" && $0.index != nil }
        return streams.filter { $0.isExternal == true } + streams.filter { $0.isExternal != true }
    }

    /// SRT text to lines; nil when it holds none or every cue starts at zero (an embedded tag,
    /// which has no timing), as for Plex and Jellyfin: untimed lyrics are not shown.
    static func lyricLines(fromSRT text: String) -> [MusicLyricLine]? {
        let blocks = text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        let lines = blocks.compactMap { block -> MusicLyricLine? in
            let rows = block.split(separator: "\n", omittingEmptySubsequences: false)
            guard let time = rows.firstIndex(where: { $0.contains("-->") }),
                  let start = seconds(String(rows[time].split(separator: "-->")[0]))
            else { return nil }
            let words = rows[(time + 1)...].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return MusicLyricLine(start: start, text: words)
        }
        return lines.contains { $0.start > 0 } ? lines : nil
    }

    /// `00:00:07,940`, with a dot as well.
    private static func seconds(_ stamp: String) -> TimeInterval? {
        let parts = stamp.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }
}
