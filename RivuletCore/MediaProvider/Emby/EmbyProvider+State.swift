// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyProvider+State.swift
//  Rivulet
//
//  Watch state, Continue Watching removal, metadata refresh and deletion.
//

import Foundation

extension EmbyProvider {

    // MARK: - Watch state

    /// Sets `Played`, resets the position and counts one play. A series or season id works natively
    /// (measured): every episode under it turns played, with no play count, so there is no fan-out.
    func markPlayed(_ itemRef: MediaItemRef) async throws {
        try await client.post("Users/\(userID)/PlayedItems/\(itemRef.itemID)")
    }

    /// Clears `Played`, the position, the play count and the last played date in one call, a
    /// series or season included.
    func markUnplayed(_ itemRef: MediaItemRef) async throws {
        try await client.delete("Users/\(userID)/PlayedItems/\(itemRef.itemID)")
    }

    /// Saves a resume point. The route has no thresholds of its own (1%, 200% and 0.0001% were all
    /// stored), so `WatchProgressPolicy` decides here. It writes `Played` and the position together:
    /// an omitted one is stored as false or 0.
    func updateProgress(_ itemRef: MediaItemRef, position: TimeInterval) async throws {
        let item: EmbyItem = try await client.get("\(itemsPath)/\(itemRef.itemID)")
        guard let update = Self.progressUpdate(position: position, runtime: EmbyTicks.seconds(item.runTimeTicks)) else { return }
        try await client.post("\(itemsPath)/\(itemRef.itemID)/UserData", body: update)
    }

    /// Nil when there is nothing to store: no position, or one under the 2% floor (the server's
    /// own `Stopped` stores nothing there either). Past 90% the item is finished: played, no
    /// resume point. Otherwise it is a resume point and the item is not played.
    nonisolated static func progressUpdate(position: TimeInterval, runtime: TimeInterval?) -> EmbyUserDataUpdate? {
        guard position > 0 else { return nil }
        guard let fraction = WatchProgressPolicy.progress(offsetSeconds: position, runtimeSeconds: runtime) else {
            return EmbyUserDataUpdate(playbackPositionTicks: EmbyTicks.ticks(position), played: false)
        }
        if fraction >= WatchProgressPolicy.completionThreshold {
            return EmbyUserDataUpdate(playbackPositionTicks: 0, played: true)
        }
        guard fraction > WatchProgressPolicy.startedThreshold else { return nil }
        return EmbyUserDataUpdate(playbackPositionTicks: EmbyTicks.ticks(position), played: false)
    }

    // MARK: - Continue Watching

    /// `HideFromResume` on the Resume entry's own id. A position of 0 is not a way out: it marks
    /// the item unplayed. Hiding a next-up episode hides the whole show; the next playback report
    /// brings it back.
    func removeFromContinueWatching(_ item: MediaItem) async throws {
        try await client.post("\(itemsPath)/\(item.ref.itemID)/HideFromResume", query: [URLQueryItem(name: "Hide", value: "true")])
    }

    /// An episode is a next-up entry, and hiding it is the only removal Emby has.
    func canRemoveFromContinueWatching(_ item: MediaItem) -> Bool { true }

    // MARK: - Admin

    /// The server accepts a refresh from any user without checking, so the gate is here.
    func canRefreshMetadata() async -> Bool {
        await currentPolicy().isAdministrator
    }

    func refreshMetadata(_ itemRef: MediaItemRef) async throws {
        guard await canRefreshMetadata() else { throw MediaProviderError.unauthorized }
        try await client.post("Items/\(itemRef.itemID)/Refresh", query: [
            URLQueryItem(name: "Recursive", value: "false"),
            URLQueryItem(name: "MetadataRefreshMode", value: "FullRefresh"),
            URLQueryItem(name: "ImageRefreshMode", value: "FullRefresh"),
            URLQueryItem(name: "ReplaceAllMetadata", value: "false"),
            URLQueryItem(name: "ReplaceAllImages", value: "false")
        ])
    }

    /// Administrators, users with deletion on, or users with deletion on for some folders.
    /// Each item says for itself (`CanDelete`) whether this account may delete it.
    func canDeleteMedia() async -> Bool {
        let policy = await currentPolicy()
        return policy.isAdministrator || policy.enableContentDeletion || !policy.enableContentDeletionFromFolders.isEmpty
    }

    /// Administrators and users with downloading on. The server answers 403 to a download otherwise.
    func canDownloadMedia() async -> Bool {
        let policy = await currentPolicy()
        return policy.isAdministrator || policy.enableContentDownloading != false
    }

    /// The file itself: `Items/<id>/Download` with the key in the query, `MediaSourceId` for a version.
    /// It has no HEAD and honors Range.
    func downloadSource(for itemRef: MediaItemRef, sourceID: String?) async throws -> DownloadSource {
        let version = sourceID.map { [URLQueryItem(name: "MediaSourceId", value: $0)] } ?? []
        return DownloadSource(url: client.authenticatedURL("Items/\(itemRef.itemID)/Download", version), headers: [:])
    }

    private static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "avi", "mov", "ts", "m2ts", "wmv", "mpg", "mpeg", "iso", "webm", "flv", "vob", "3gp", "divx", "rmvb", "wtv", "ogv", "mts", "asf", "f4v"]

    /// Deleting a movie deletes its whole folder (`DeleteInfo.Paths`, a folder name; an episode's is
    /// its file), so a movie's confirmation names the folder. Anything else, or a failed read, keeps
    /// the standard text.
    func deleteConfirmation(for item: MediaItem) async -> String {
        guard item.kind == .movie,
              let info: EmbyDeleteInfo = try? await client.get("Items/\(item.ref.itemID)/DeleteInfo"),
              info.paths?.count == 1, let folder = info.paths?.first?.split(whereSeparator: { "/\\".contains($0) }).last,
              !Self.videoExtensions.contains(URL(fileURLWithPath: String(folder)).pathExtension.lowercased())
        else { return standardDeleteConfirmation(for: item) }
        return String(localized: "The folder \u{201C}\(String(folder))\u{201D} and everything in it will be deleted from \(displayName). This cannot be undone.")
    }

    func deleteMedia(_ itemRef: MediaItemRef) async throws {
        let item: EmbyItem = try await client.get("\(itemsPath)/\(itemRef.itemID)")
        guard item.canDelete == true else { throw MediaProviderError.unauthorized }
        try await client.delete("Items/\(itemRef.itemID)")
    }
}
