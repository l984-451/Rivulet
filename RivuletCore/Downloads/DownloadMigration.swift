// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// What the Plex-only build (manifest version 1) wrote, read once and written back as version 2.
nonisolated struct LegacyDownloadRecord: Decodable {
    var id: String
    var serverID: String
    var profileID: String?
    var ratingKey: String
    var mediaID: Int
    var partID: Int?
    var quality: String
    var state: DownloadState
    var expectedBytes: Int64?
    var receivedBytes: Int64
    var etag: String?
    var cellularAllowed: Bool?
    var queueItemID: Int?
    var fileName: String?
    var posterFileName: String?
    var subtitleFiles: [DownloadRecord.SubtitleFile]
    var metadata: PlexMetadata
    var outputLabel: String?
    var createdAt: Date
    var completedAt: Date?

    /// Every field carries over. Only the list item is new, built from the metadata.
    var migrated: DownloadRecord {
        // A file the previous build rewrote carries another server's id as it was written (see `PreviousBuildRecord`).
        let otherServer = ["jellyfin:", "emby:"].contains { serverID.hasPrefix($0) }
        let providerID = otherServer ? serverID : DownloadIdentity.plexProviderID(machineID: serverID.isEmpty ? nil : serverID)
        var forItem = metadata
        if forItem.ratingKey == nil { forItem.ratingKey = ratingKey }
        let item = MediaItem.plexDownloadCopy(forItem, providerID: providerID)
        return DownloadRecord(
            id: id, providerID: providerID, profileID: profileID, itemID: ratingKey,
            sourceID: mediaID == 0 ? nil : String(mediaID), partID: partID, quality: quality, state: state,
            expectedBytes: expectedBytes, receivedBytes: receivedBytes, etag: etag, cellularAllowed: cellularAllowed,
            queueItemID: queueItemID, fileName: fileName, posterFileName: posterFileName, subtitleFiles: subtitleFiles,
            item: item, metadata: metadata, outputLabel: outputLabel, createdAt: createdAt, completedAt: completedAt)
    }
}

extension MediaItem {
    /// The list item for a Plex download, from its (full) metadata.
    static func plexDownloadCopy(_ meta: PlexMetadata, providerID: String) -> MediaItem {
        PlexMediaMapper.item(meta, providerID: providerID, serverURL: "", authToken: "")
            .storedForDownload(providerID: providerID)
    }

    /// The copy a download keeps: refs on the download's own server key, and no credential in any
    /// artwork URL. A Plex server's art is dropped whole (its URLs only mean something with a token and
    /// the current address); other servers keep theirs minus the key.
    func storedForDownload(providerID: String) -> MediaItem {
        let isPlex = providerID.hasPrefix("plex:")
        func ref(_ r: MediaItemRef?) -> MediaItemRef? { r.map { MediaItemRef(providerID: providerID, itemID: $0.itemID) } }
        func art(_ a: MediaArtwork?) -> MediaArtwork? {
            a.map { a in
                MediaArtwork(poster: Self.scrubbed(a.poster, drop: isPlex), backdrop: Self.scrubbed(a.backdrop, drop: isPlex),
                             thumbnail: Self.scrubbed(a.thumbnail, drop: isPlex), logo: Self.scrubbed(a.logo, drop: isPlex))
            }
        }
        return MediaItem(
            ref: ref(self.ref) ?? self.ref, kind: kind, title: title, sortTitle: sortTitle, overview: overview, year: year,
            releaseDate: releaseDate, contentRating: contentRating, runtime: runtime, isMusic: isMusic,
            parentRef: ref(parentRef), grandparentRef: ref(grandparentRef), seriesTitle: seriesTitle,
            episodeNumber: episodeNumber, seasonNumber: seasonNumber, childProgress: childProgress,
            userState: userState, artwork: art(artwork) ?? artwork, parentArtwork: art(parentArtwork),
            grandparentArtwork: art(grandparentArtwork), versionCount: versionCount, editionTitle: editionTitle,
            identity: identity, genres: genres, externalIDs: externalIDs, libraryID: libraryID)
    }

    private static let credentialNames: Set<String> = ["api_key", "apikey", "x-plex-token", "token"]

    private static func scrubbed(_ url: URL?, drop: Bool) -> URL? {
        guard !drop, let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let kept = parts.queryItems?.filter { !credentialNames.contains($0.name.lowercased()) }
        parts.queryItems = kept?.isEmpty == true ? nil : kept
        return parts.url
    }
}
