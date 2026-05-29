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
import Combine

struct HeroBackdropRequest: Hashable {
    let cacheKey: String
    let backdropURL: URL?
    let thumbnailURL: URL?
    let logoURL: URL?
}

struct HeroBackdropResolution: Equatable {
    let displayedBackdropURL: URL?
    let pendingUpgradeURL: URL?
    let logoURL: URL?
    let thumbnailURL: URL?

    var canUpgradeAfterSettle: Bool {
        pendingUpgradeURL != nil && pendingUpgradeURL != displayedBackdropURL
    }
}

struct HeroBackdropSession: Equatable {
    var displayedBackdropURL: URL?
    var pendingUpgradeURL: URL?
    var logoURL: URL?
    var thumbnailURL: URL?
    private(set) var motionLocked = false
    private(set) var lastUnlockedAt: Date? = Date()

    init() {}

    init(seed request: HeroBackdropRequest) {
        displayedBackdropURL = request.backdropURL ?? request.thumbnailURL
        thumbnailURL = request.thumbnailURL
        logoURL = request.logoURL
    }

    var canUpgradeAfterSettle: Bool {
        pendingUpgradeURL != nil && pendingUpgradeURL != displayedBackdropURL
    }

    mutating func stage(_ resolution: HeroBackdropResolution) {
        logoURL = resolution.logoURL
        thumbnailURL = resolution.thumbnailURL

        if resolution.pendingUpgradeURL == nil {
            displayedBackdropURL = resolution.displayedBackdropURL
        } else if displayedBackdropURL == nil {
            displayedBackdropURL = resolution.displayedBackdropURL
        }

        pendingUpgradeURL = resolution.pendingUpgradeURL
    }

    mutating func setMotionLocked(_ locked: Bool, now: Date = Date()) {
        guard motionLocked != locked else { return }
        motionLocked = locked
        lastUnlockedAt = locked ? nil : now
    }

    @discardableResult
    mutating func applyPendingUpgradeIfReady(
        now: Date = Date(),
        minimumStableDuration: TimeInterval = 0.15
    ) -> Bool {
        guard !motionLocked,
              let pendingUpgradeURL,
              let lastUnlockedAt,
              now.timeIntervalSince(lastUnlockedAt) >= minimumStableDuration else {
            return false
        }

        displayedBackdropURL = pendingUpgradeURL
        self.pendingUpgradeURL = nil
        return true
    }
}

struct HeroBackdropLoadGate {
    private(set) var generation = 0

    @discardableResult
    mutating func begin() -> Int {
        generation += 1
        return generation
    }

    func isCurrent(_ token: Int) -> Bool {
        token == generation
    }
}

actor HeroBackdropResolver {
    static let shared = HeroBackdropResolver()

    func resolveAssets(for request: HeroBackdropRequest) async -> HeroBackdropResolution {
        HeroBackdropResolution(
            displayedBackdropURL: request.backdropURL ?? request.thumbnailURL,
            pendingUpgradeURL: nil,
            logoURL: request.logoURL,
            thumbnailURL: request.thumbnailURL
        )
    }

    func playerLoadingImages(for request: HeroBackdropRequest) async -> (UIImage?, UIImage?) {
        let resolution = await resolveAssets(for: request)
        let backdropURL = resolution.pendingUpgradeURL ?? resolution.displayedBackdropURL

        async let backdropTask: UIImage? = backdropURL != nil
            ? ImageCacheManager.shared.imageFullSize(for: backdropURL!)
            : nil
        async let thumbnailTask: UIImage? = resolution.thumbnailURL != nil
            ? ImageCacheManager.shared.image(for: resolution.thumbnailURL!)
            : nil

        return await (backdropTask, thumbnailTask)
    }
}

@MainActor
final class HeroBackdropCoordinator: ObservableObject {
    @Published private(set) var session = HeroBackdropSession()

    private var request: HeroBackdropRequest?
    private var loadGate = HeroBackdropLoadGate()
    private var loadTask: Task<Void, Never>?
    private var upgradeTask: Task<Void, Never>?

    deinit {
        loadTask?.cancel()
        upgradeTask?.cancel()
    }

    func load(request: HeroBackdropRequest?, motionLocked: Bool) {
        if request == self.request {
            setMotionLocked(motionLocked)
            return
        }

        self.request = request
        loadTask?.cancel()
        upgradeTask?.cancel()

        guard let request else {
            session = HeroBackdropSession()
            return
        }

        var seededSession = HeroBackdropSession(seed: request)
        seededSession.setMotionLocked(motionLocked)
        session = seededSession

        let token = loadGate.begin()
        loadTask = Task { [weak self] in
            let resolution = await HeroBackdropResolver.shared.resolveAssets(for: request)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self, self.loadGate.isCurrent(token), self.request == request else { return }

                var nextSession = self.session
                nextSession.stage(resolution)
                self.session = nextSession
                self.schedulePendingUpgradeIfNeeded()
            }
        }
    }

    func setMotionLocked(_ locked: Bool) {
        var nextSession = session
        nextSession.setMotionLocked(locked)
        session = nextSession
        schedulePendingUpgradeIfNeeded()
    }

    private func schedulePendingUpgradeIfNeeded() {
        upgradeTask?.cancel()
        guard session.canUpgradeAfterSettle, !session.motionLocked else { return }

        upgradeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }

                var nextSession = self.session
                guard nextSession.applyPendingUpgradeIfReady() else { return }
                self.session = nextSession
            }
        }
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
        // Fill the *container* and clip, rather than letting the image's own
        // dimensions drive layout. `.aspectRatio(.fill)` without a bounding
        // frame reports the scaled image size as this view's layout size, so a
        // source with extreme dimensions (e.g. a near-square poster used as a
        // backdrop) balloons to thousands of points tall and shoves the hero
        // off-screen. Anchoring to a flexible `Color.clear` pins the layout
        // size to whatever the parent proposes; the image fills it as an
        // overlay and the overflow is clipped.
        Color.clear
            .overlay(
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            )
            .clipped()
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
