// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AVFoundation
import UIKit

/// Transparent over the existing artwork until the first video frame is ready.
/// It never owns audio focus, playback controls, or the title's watch progress.
@MainActor
final class ThemeVideoBackdropView: UIView {
    static let enabledKey = "enableThemeVideos"

    private let playerLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var readyObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var startupTask: Task<Void, Never>?
    private var visibilityTask: Task<Void, Never>?
    private var playbackGeneration = 0
    private weak var host: UIViewController?
    private var item: MediaItemRef?
    private var isActive = false
    private let session = ThemeVideoSession { ref in
        try await MediaProviderRegistry.shared.provider(for: ref.providerID)?.themeVideo(for: ref)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        clipsToBounds = true
        alpha = 0
        playerLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(playerLayer)
        session.onChange = { [weak self] video in self?.show(video) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        visibilityTask?.cancel()
        startupTask?.cancel()
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func configure(item: MediaItemRef, host: UIViewController) {
        self.item = item
        self.host = host
        updateEligibility()
    }

    func setActive(_ active: Bool) {
        isActive = active
        updateMonitoring()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateMonitoring()
    }

    private func updateMonitoring() {
        visibilityTask?.cancel()
        visibilityTask = nil
        updateEligibility()
        guard isActive, window != nil else { return }
        // overFullScreen presentations do not send disappearance callbacks to
        // their presenter. Check the host while active so nested details,
        // players, and popups cannot leave a second video running behind them.
        visibilityTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                self?.updateEligibility()
            }
        }
    }

    private func updateEligibility() {
        let eligible = isActive && window?.windowScene?.activationState == .foregroundActive
            && host != nil && host?.presentedViewController == nil && host?.isBeingDismissed == false
            && UserDefaults.standard.bool(forKey: Self.enabledKey) && !UIAccessibility.isReduceMotionEnabled
        session.update(for: eligible ? item : nil)
    }

    private func show(_ video: ThemeVideo?) {
        playbackGeneration += 1
        let generation = playbackGeneration
        startupTask?.cancel()
        readyObservation = nil
        itemObservation = nil
        statusObservation = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        layer.removeAllAnimations()
        alpha = 0
        player?.pause()
        playerLayer.player = nil
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()
        player = nil
        guard let video else { return }

        let player = AVQueuePlayer()
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.audiovisualBackgroundPlaybackPolicy = .pauses
        let template = AVPlayerItem(url: video.url)
        template.preferredForwardBufferDuration = 3
        self.player = player
        playerLayer.player = player
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            let ready = layer.isReadyForDisplay
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == generation, ready else { return }
                self.startupTask?.cancel()
                UIView.animate(withDuration: 0.35) { self.alpha = 1 }
            }
        }
        itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
            let item = player.currentItem
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == generation,
                      item === self.player?.currentItem else { return }
                self.statusObservation = item?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    let failed = item.status == .failed
                    Task { @MainActor [weak self] in
                        guard let self, self.playbackGeneration == generation, failed,
                              item === self.player?.currentItem else { return }
                        self.session.playbackFailed()
                    }
                }
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main
        ) { [weak self] notification in
            let failedItem = notification.object as? AVPlayerItem
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == generation,
                      let failedItem, failedItem === self.player?.currentItem else { return }
                self.session.playbackFailed()
            }
        }
        looper = AVPlayerLooper(player: player, templateItem: template)
        player.play()
        startupTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.playbackGeneration == generation else { return }
            self.session.playbackFailed()
        }
    }
}
