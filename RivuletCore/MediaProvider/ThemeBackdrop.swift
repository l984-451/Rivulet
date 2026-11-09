// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ThemeBackdrop.swift
//  Rivulet
//
//  The muted looping theme video behind a hero or detail page, for both apps. The
//  views only size `layer` and fade on `onDisplayChange`; whether, when and which
//  clip plays lives here. It touches no audio session, Now Playing or watch state.
//

import AVFoundation

/// One lookup per title, with late answers for a title that has since changed dropped.
@MainActor
final class ThemeVideoSession {
    typealias Resolver = @MainActor @Sendable (MediaItemRef) async throws -> URL?

    private let resolve: Resolver
    private var requested: MediaItemRef?
    private var generation = 0
    private var task: Task<Void, Never>?
    private(set) var url: URL?
    var onChange: ((URL?) -> Void)?

    init(resolve: @escaping Resolver) { self.resolve = resolve }

    deinit { task?.cancel() }

    /// Nil releases the clip. The same item again makes no new lookup.
    func update(for item: MediaItemRef?) {
        guard requested != item else { return }
        requested = item
        generation += 1
        task?.cancel()
        task = nil
        release()
        guard let item else { return }
        let generation = generation
        let resolve = resolve
        task = Task { [weak self] in
            // Theme media is optional: a failed lookup keeps the artwork.
            guard let url = try? await resolve(item), !Task.isCancelled,
                  let self, self.generation == generation else { return }
            self.url = url
            self.onChange?(url)
        }
    }

    /// A clip that fails stays on artwork for this visit instead of retrying.
    func playbackFailed() { release() }

    private func release() {
        guard url != nil else { return }
        url = nil
        onChange?(nil)
    }
}

@MainActor
final class ThemeBackdrop {
    /// The system's video-preview and Reduce Motion settings.
    static var systemAllowsVideo: Bool {
        HostPlatform.allowsVideoPreviews()
    }

    /// Which title should be playing, or nil. Every condition must hold.
    nonisolated static func wantedItem(
        _ item: MediaItemRef?, isActive: Bool, isSuspended: Bool, isCovered: Bool,
        isForeground: Bool, systemAllows: Bool
    ) -> MediaItemRef? {
        isActive && !isSuspended && !isCovered && isForeground && systemAllows ? item : nil
    }

    /// A random usable clip id, like Jellyfin's web client picks one per visit.
    nonisolated static func pickClip(from ids: [String?]) -> String? {
        ids.compactMap { $0 }.filter { !$0.isEmpty }.randomElement()
    }

    /// Add as a sublayer, sized by the view. Transparent (artwork shows) until the first frame is ready.
    let layer = AVPlayerLayer()
    /// Whether something is presented over the host page; polled while active, because an
    /// over-full-screen presentation sends the presenter no disappearance callbacks.
    var isCovered: (() -> Bool)?

    var item: MediaItemRef? { didSet { refresh() } }
    var isActive = false { didSet { if isActive != oldValue { activeChanged() } } }
    /// Scrolled away, hidden, or the artwork is mid-change.
    var isSuspended = false { didSet { refresh() } }

    private let session: ThemeVideoSession
    private let systemAllows: @MainActor () -> Bool
    private let isForeground: @MainActor () -> Bool
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var observers: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var startup: Task<Void, Never>?
    private var poll: Task<Void, Never>?
    private var generation = 0

    init(
        resolve: @escaping ThemeVideoSession.Resolver = { ref in
            try await MediaProviderRegistry.shared.provider(for: ref.providerID)?.themeVideoURL(for: ref)
        },
        systemAllows: @escaping @MainActor () -> Bool = { ThemeBackdrop.systemAllowsVideo },
        isForeground: @escaping @MainActor () -> Bool = { HostPlatform.isForeground() }
    ) {
        session = ThemeVideoSession(resolve: resolve)
        self.systemAllows = systemAllows
        self.isForeground = isForeground
        layer.videoGravity = .resizeAspectFill
        layer.opacity = 0
        session.onChange = { [weak self] in self?.play($0) }
        let center = NotificationCenter.default
        notifications = HostPlatform.appearanceChangeNotifications.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
    }

    deinit {
        poll?.cancel()
        startup?.cancel()
        notifications.forEach(NotificationCenter.default.removeObserver)
    }

    func refresh() {
        let wanted = Self.wantedItem(
            item, isActive: isActive, isSuspended: isSuspended, isCovered: isCovered?() ?? false,
            isForeground: isForeground(), systemAllows: systemAllows()
        )
        session.update(for: wanted)
    }

    private func activeChanged() {
        poll?.cancel()
        poll = nil
        refresh()
        guard isActive else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                self?.refresh()
            }
        }
    }

    private func play(_ url: URL?) {
        generation += 1
        let generation = generation
        startup?.cancel()
        observers = []
        looper?.disableLooping()
        looper = nil
        player?.pause()
        player?.removeAllItems()
        player = nil
        layer.player = nil
        layer.opacity = 0
        guard let url else { return }

        let player = AVQueuePlayer()
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.audiovisualBackgroundPlaybackPolicy = .pauses
        let template = AVPlayerItem(url: url)
        template.preferredForwardBufferDuration = 3
        self.player = player
        layer.player = player
        let looper = AVPlayerLooper(player: player, templateItem: template)
        self.looper = looper
        observers = [
            layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                let ready = layer.isReadyForDisplay
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation, ready else { return }
                    self.startup?.cancel()
                    self.layer.opacity = 1
                }
            },
            looper.observe(\.status, options: [.initial, .new]) { [weak self] looper, _ in
                let failed = looper.status == .failed
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation, failed else { return }
                    self.session.playbackFailed()
                }
            }
        ]
        player.play()
        startup = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.generation == generation else { return }
            self.session.playbackFailed()
        }
    }
}
