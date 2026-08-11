// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HeroBackdropSupport.swift
//  Rivulet
//
//  Shared hero/backdrop resolution and full-size crossfade rendering for
//  preview/detail/loading surfaces. Artwork URLs come from whatever type
//  the caller adapts into a `HeroBackdropRequest` — see the extensions
//  at the bottom of this file.
//

import SwiftUI
import UIKit

struct HeroBackdropRequest: Hashable {
    let cacheKey: String
    let backdropURL: URL?
    let thumbnailURL: URL?
    let logoURL: URL?
}

actor HeroBackdropResolver {
    static let shared = HeroBackdropResolver()

    func playerLoadingImages(for request: HeroBackdropRequest) async -> (UIImage?, UIImage?) {
        let backdropURL = request.backdropURL ?? request.thumbnailURL

        async let backdropTask: UIImage? = backdropURL != nil
            ? ImageCacheManager.shared.imageFullSize(for: backdropURL!)
            : nil
        async let thumbnailTask: UIImage? = request.thumbnailURL != nil
            ? ImageCacheManager.shared.image(for: request.thumbnailURL!)
            : nil

        return await (backdropTask, thumbnailTask)
    }
}

struct HeroBackdropImage<Placeholder: View>: View {
    let url: URL?
    var animationDuration: Double = 0.22
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var currentURL: URL?
    @State private var currentImage: UIImage?
    @State private var previousImage: UIImage?
    @State private var revealOpacity: Double = 1
    @State private var clearPreviousTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if let previousImage {
                imageView(previousImage)
                    .opacity(1 - revealOpacity)
            }

            if let currentImage {
                imageView(currentImage)
                    .opacity(revealOpacity)
            } else if previousImage == nil {
                placeholder()
            }
        }
        .task(id: url) {
            await loadImage(for: url)
        }
        .onDisappear {
            clearPreviousTask?.cancel()
        }
    }

    private func imageView(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
    }

    @MainActor
    private func loadImage(for url: URL?) async {
        guard url != currentURL else { return }

        clearPreviousTask?.cancel()

        guard let url else {
            currentURL = nil
            currentImage = nil
            previousImage = nil
            revealOpacity = 1
            return
        }

        let image = await ImageCacheManager.shared.imageFullSize(for: url)
        guard !Task.isCancelled, currentURL != url else { return }

        guard let image else {
            if currentImage == nil {
                currentURL = url
            }
            return
        }

        if let currentImage {
            previousImage = currentImage
        }

        currentURL = url
        currentImage = image
        revealOpacity = previousImage == nil ? 1 : 0

        guard previousImage != nil else { return }

        withAnimation(.easeInOut(duration: animationDuration)) {
            revealOpacity = 1
        }

        clearPreviousTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(animationDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                previousImage = nil
            }
        }
    }
}

extension PlexMetadata {
    /// Builds a `HeroBackdropRequest` from this item's Plex artwork.
    ///
    /// For episodes/seasons, the clearLogo isn't carried on the item itself —
    /// callers that want the show's logo should pass `logoPathOverride` after
    /// fetching the parent show's metadata.
    func heroBackdropRequest(
        serverURL: String,
        authToken: String,
        logoPathOverride: String? = nil
    ) -> HeroBackdropRequest {
        let backdropPath = bestArt
        let thumbnailPath = thumb ?? bestThumb
        let logoPath = logoPathOverride ?? clearLogoPath

        let backdropURL = backdropPath.flatMap {
            URL(string: "\(serverURL)\($0)?X-Plex-Token=\(authToken)")
        }
        let thumbnailURL = thumbnailPath.flatMap {
            URL(string: "\(serverURL)\($0)?X-Plex-Token=\(authToken)")
        }
        let logoURL = logoPath.flatMap {
            URL(string: "\(serverURL)\($0)?X-Plex-Token=\(authToken)")
        }

        return HeroBackdropRequest(
            cacheKey: ratingKey ?? "\(type ?? "item"):\(title ?? "unknown")",
            backdropURL: backdropURL,
            thumbnailURL: thumbnailURL,
            logoURL: logoURL
        )
    }
}

// MARK: - MediaItem adapter

extension MediaItem {
    /// Agnostic counterpart to `PlexMetadata.heroBackdropRequest(...)`. No
    /// server/auth inputs needed — `MediaItem.artwork.*` URLs are already
    /// fully qualified by the provider's mapper. Episodes/seasons fall
    /// back to their grandparent's backdrop when their own isn't set.
    func heroBackdropRequest() -> HeroBackdropRequest {
        let backdrop = artwork.backdrop ?? grandparentArtwork?.backdrop
        let thumbnail = artwork.thumbnail ?? artwork.poster
        return HeroBackdropRequest(
            cacheKey: ref.itemID,
            backdropURL: backdrop,
            thumbnailURL: thumbnail,
            logoURL: artwork.logo
        )
    }
}
