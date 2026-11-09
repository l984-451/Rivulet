// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TopShelfComposer.swift
//  Rivulet
//
//  Builds Apple TV+-style Top Shelf images in-app: resolves each item's
//  clearLogo, downloads backdrop + logo, composites them, and writes the
//  result to the App Group container. The extension only reads the files.
//  Never throws; any per-item failure falls back to the plain backdrop.
//

import UIKit

enum TopShelfComposer {

    /// Returns items with `logoImageURL` / `compositeFileName` populated where a
    /// composite was produced. Prunes composite files to the current set.
    @MainActor
    static func composite(items: [TopShelfItem], serverURL: String?, token: String?) async -> [TopShelfItem] {
        // One run at a time, in call order: a prune never sees another run's files.
        let previous = inFlight
        let task = Task { @MainActor in
            _ = await previous?.value
            return await run(items: items, serverURL: serverURL, token: token)
        }
        inFlight = task
        return await task.value
    }

    @MainActor private static var inFlight: Task<[TopShelfItem], Never>?

    @MainActor
    private static func run(items: [TopShelfItem], serverURL: String?, token: String?) async -> [TopShelfItem] {
        var result: [TopShelfItem] = []
        var keptFiles: Set<String> = []

        for item in items {
            var logoURLString = item.logoImageURL
            var compositeFileName: String? = nil

            // 1. Resolve clearLogo URL (via full/grandparent metadata, cached).
            //    fullMetadata() handles episode → grandparent (show) resolution.
            //    Plex items carry the server URL; other servers' items arrive with their logo.
            if let serverURL, let token, item.serverIdentifier == serverURL,
               let full = await fullMetadata(for: item.ratingKey, serverURL: serverURL, token: token) {
                logoURLString = TopShelfLogoResolver.logoURLString(from: full, serverURL: serverURL, token: token)
            }

            // 2. Compose only when we have both a backdrop and a logo, and only
            //    when this item's file is not already there. Off the main thread:
            //    the compositor analyses the backdrop.
            let backdropURLString = item.wideImageURL.isEmpty ? item.imageURL : item.wideImageURL
            if !logoURLString.isEmpty {
                let fileName = TopShelfImageCompositor.fileName(
                    ratingKey: item.ratingKey, backdropURL: backdropURLString, logoURL: logoURLString)
                if let url = TopShelfCache.shared.compositeFileURL(fileName: fileName),
                   FileManager.default.fileExists(atPath: url.path) {
                    compositeFileName = fileName
                } else if let backdropURL = URL(string: backdropURLString),
                          let logoURL = URL(string: logoURLString),
                          let backdrop = await ImageCacheManager.shared.image(for: backdropURL, quality: .full),
                          let logo = await ImageCacheManager.shared.image(for: logoURL, quality: .full),
                          let data = await Task.detached(priority: .utility, operation: {
                              TopShelfImageCompositor.compose(backdrop: backdrop, logo: logo)
                                  .jpegData(compressionQuality: 0.9)
                          }).value,
                          TopShelfCache.shared.writeComposite(data, fileName: fileName) {
                    compositeFileName = fileName
                }
                if let compositeFileName { keptFiles.insert(compositeFileName) }
            }

            result.append(TopShelfItem(
                ratingKey: item.ratingKey,
                title: item.title,
                subtitle: item.subtitle,
                imageURL: item.imageURL,
                wideImageURL: item.wideImageURL,
                logoImageURL: logoURLString,
                compositeFileName: compositeFileName,
                progress: item.progress,
                type: item.type,
                lastWatched: item.lastWatched,
                serverIdentifier: item.serverIdentifier
            ))
        }

        // 3. Prune any composite files not in the current set.
        TopShelfCache.shared.pruneComposites(keeping: keptFiles)
        return result
    }

    // MARK: - Helpers

    /// Full metadata carrying the clearLogo. `TopShelfItem` doesn't carry
    /// `grandparentRatingKey`, so for episodes we fetch the item's own metadata
    /// first (which carries the grandparent key), then resolve the grandparent
    /// (show) metadata where the show logo lives.
    private static func fullMetadata(for ratingKey: String, serverURL: String, token: String) async -> PlexMetadata? {
        if let cached = await MainActor.run(body: { PlexDataStore.shared.getCachedLogoMetadata(for: ratingKey) }) {
            // For episodes, the show logo lives on the grandparent — resolve that.
            if cached.type == "episode", let gp = cached.grandparentRatingKey {
                return await fetchAndCache(gp, serverURL: serverURL, token: token) ?? cached
            }
            return cached
        }
        guard let fetched = await fetchAndCache(ratingKey, serverURL: serverURL, token: token) else { return nil }
        if fetched.type == "episode", let gp = fetched.grandparentRatingKey {
            return await fetchAndCache(gp, serverURL: serverURL, token: token) ?? fetched
        }
        return fetched
    }

    private static func fetchAndCache(_ ratingKey: String, serverURL: String, token: String) async -> PlexMetadata? {
        if let cached = await MainActor.run(body: { PlexDataStore.shared.getCachedLogoMetadata(for: ratingKey) }) { return cached }
        do {
            // Plain metadata: `clearLogoPath` is all this path reads. See
            // `logoMetadataCache`.
            let m = try await PlexNetworkManager.shared.getMetadata(serverURL: serverURL, authToken: token, ratingKey: ratingKey)
            await MainActor.run { PlexDataStore.shared.cacheLogoMetadata(m, for: ratingKey) }
            return m
        } catch {
            return nil
        }
    }
}
