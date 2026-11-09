// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PhotoViewerViewController.swift
//  Rivulet
//
//  One photo full screen. Left and Right page, Select or Play/Pause runs a
//  slideshow, Select on a clip plays it, Down opens the info pane, Menu closes.
//  The slideshow reads its interval, transition and clips from `PhotoPreferences`
//  at every slide.
//

import UIKit

@MainActor
final class PhotoViewerViewController: UIViewController {
    private static let stepDissolve: TimeInterval = 0.2
    private static let slideDissolve: TimeInterval = 0.5
    private static let overlayLinger: TimeInterval = 3

    /// Called with the index on screen just before the viewer closes, then once it has.
    var onClose: ((Int) -> Void)?
    var onDismissed: (() -> Void)?

    private let listing: PhotoListing
    private var index: Int
    private let imageView = UIImageView()
    /// The slide going away, fading out over the next one while it keeps its Pan and Zoom.
    private let outgoingView = UIImageView()
    /// Where the current slide's Pan and Zoom is heading.
    private var panTarget: CGAffineTransform?
    private let clipGlyph = UIImageView(image: UIImage(systemName: "play.circle.fill"))
    private let slideGlyph = UIImageView()
    private let caption = UILabel()
    /// The only focus target: presses reach a focused view, and the viewer has no other.
    private let anchor = PreviewFocusAnchorView()
    private var input: DirectionalInputBinding?
    private var loadTask: Task<Void, Never>?
    private var slideTimer: Timer?
    private var isRunning = false
    private let startsSlideshow: Bool
    /// A slideshow clip's player is up; the show goes on when it closes.
    private var playingShowClip = false
    private var overlayHide: DispatchWorkItem?
    /// Set only while this viewer is what turned the idle timer off.
    private var holdsDisplayAwake = false
    /// Over the bottom third while open; its Favorite button then holds focus.
    private let infoPane = PhotoInfoPaneView()
    private var paneOpen = false
    private var detailsTask: Task<Void, Never>?
    /// Select and Play/Pause stand down while the pane is open, so Select reaches its button.
    private var paneBlockedTaps: [UITapGestureRecognizer] = []

    init(listing: PhotoListing, index: Int, startsSlideshow: Bool = false) {
        self.listing = listing
        self.index = index
        self.startsSlideshow = startsSlideshow
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - View

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        imageView.frame = view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleAspectFit
        view.addSubview(imageView)
        outgoingView.frame = view.bounds
        outgoingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        outgoingView.contentMode = .scaleAspectFit
        outgoingView.alpha = 0
        view.addSubview(outgoingView)

        for glyph in [clipGlyph, slideGlyph] {
            glyph.tintColor = UIColor(white: 1, alpha: 0.85)
            glyph.contentMode = .scaleAspectFit
            glyph.frame = CGRect(x: 0, y: 0, width: 120, height: 120)
            glyph.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            glyph.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin,
                                      .flexibleTopMargin, .flexibleBottomMargin]
            view.addSubview(glyph)
        }
        slideGlyph.alpha = 0

        caption.numberOfLines = 2
        caption.layer.shadowOpacity = 0.8
        caption.layer.shadowRadius = 6
        caption.layer.shadowOffset = .zero
        caption.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(caption)
        let margin = MediaRowMetrics.rowLeading
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -margin),
            caption.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -margin)
        ])
        view.addSubview(anchor)

        infoPane.isHidden = true
        infoPane.alpha = 0
        infoPane.onFavorite = { [weak self] in self?.toggleFavorite() }
        infoPane.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(infoPane)
        NSLayoutConstraint.activate([
            infoPane.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            infoPane.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            infoPane.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            infoPane.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 1.0 / 3)
        ])

        // The swipes stand down while a clip's player is up over the viewer.
        input = DirectionalInputBinding(
            view: view, directions: [.left, .right, .up, .down],
            onTap: { [weak self] in self?.directionPressed($0) },
            swipeGate: { [weak self] _ in self?.presentedViewController == nil })
        for (press, action) in [(UIPress.PressType.select, #selector(selectPressed)),
                                (.playPause, #selector(toggleSlideshow)),
                                (.menu, #selector(menuPressed))] {
            let tap = UITapGestureRecognizer(target: self, action: action)
            tap.allowedPressTypes = [NSNumber(value: press.rawValue)]
            view.addGestureRecognizer(tap)
            if press != .menu { paneBlockedTaps.append(tap) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(stopSlideshow),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        show(index, dissolve: 0)
        if startsSlideshow { toggleSlideshow() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if !playingShowClip { stopSlideshow() }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        paneOpen ? [infoPane.favoriteButton] : [anchor]
    }

    // MARK: - Showing a photo

    private func show(_ newIndex: Int, dissolve: TimeInterval) {
        guard listing.media.indices.contains(newIndex) else { return }
        index = newIndex
        let item = listing.media[newIndex]
        let cache = ImageCacheManager.shared
        loadTask?.cancel()
        clipGlyph.isHidden = item.kind != .clip

        // The grid's thumbnail at once, then the screen-sized image when it arrives.
        let full = item.full.flatMap { cache.cachedImage(for: $0, quality: .full) }
        setImage(full ?? item.thumbnail.flatMap { cache.cachedImage(for: $0) }, dissolve: dissolve)
        if full == nil, let url = item.full {
            loadTask = Task { [weak self] in
                let image = await cache.image(for: url, quality: .full)
                guard let self, let image, !Task.isCancelled, self.index == newIndex else { return }
                self.setImage(image, dissolve: Self.stepDissolve)
            }
        }
        let neighbours = [newIndex - 1, newIndex + 1].filter(listing.media.indices.contains)
        let ahead = neighbours.compactMap { listing.media[$0].full }
        Task { await cache.prefetch(urls: ahead, quality: .full) }
        if newIndex >= listing.media.count - 5 { listing.loadMore() }
        updateCaption(item)
        if paneOpen { updatePane() }
    }

    private func setImage(_ image: UIImage?, dissolve: TimeInterval) {
        UIView.transition(with: imageView, duration: dissolve, options: .transitionCrossDissolve) {
            self.imageView.image = image
        }
    }

    /// Title and date, bottom leading; gone after a moment and for the whole of a slideshow.
    private func updateCaption(_ item: PhotoItem) {
        overlayHide?.cancel()
        let text = NSMutableAttributedString(string: item.title, attributes: [
            .font: UIFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: UIColor.white])
        if let date = item.date {
            text.append(NSAttributedString(
                string: "\n" + date.formatted(date: .abbreviated, time: .omitted),
                attributes: [.font: UIFont.systemFont(ofSize: 28),
                             .foregroundColor: UIColor(white: 1, alpha: 0.7)]))
        }
        caption.attributedText = text
        guard !isRunning, !paneOpen else { caption.alpha = 0; return }
        UIView.animate(withDuration: Self.stepDissolve) { self.caption.alpha = 1 }
        let hide = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.5) { self?.caption.alpha = 0 }
        }
        overlayHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.overlayLinger, execute: hide)
    }

    // MARK: - Input

    private func directionPressed(_ direction: DirectionalInputBinding.Direction) {
        switch direction {
        case .left: step(-1)
        case .right: step(1)
        case .down: openPane()
        case .up: closePane()
        }
    }

    @objc private func menuPressed() {
        paneOpen ? closePane() : close()
    }

    private func step(_ direction: Int) {
        guard let next = PhotoViewerIndex.step(from: index, by: direction, count: listing.media.count,
                                               wraps: false) else { return }
        stopSlideshow()
        show(next, dissolve: Self.stepDissolve)
    }

    @objc private func selectPressed() {
        guard listing.media.indices.contains(index), let clip = listing.media[index].playable else {
            return toggleSlideshow()
        }
        stopSlideshow()
        ProviderPlayer.play(clip, fromBeginning: false, from: self, onDismiss: nil)
    }

    @objc private func close() {
        stopSlideshow()
        onClose?(index)
        dismiss(animated: true) { [onDismissed] in onDismissed?() }
    }

    // MARK: - Info pane

    private func openPane() {
        guard !paneOpen, listing.media.indices.contains(index) else { return }
        stopSlideshow()
        paneOpen = true
        overlayHide?.cancel()
        paneBlockedTaps.forEach { $0.isEnabled = false }
        updatePane()
        infoPane.isHidden = false
        UIView.animate(withDuration: Self.stepDissolve) {
            self.infoPane.alpha = 1
            self.caption.alpha = 0
        }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        // Hidden, the anchor leaves the button with no neighbour, so every arrow reaches the binding.
        anchor.isHidden = true
    }

    private func closePane() {
        guard paneOpen else { return }
        paneOpen = false
        detailsTask?.cancel()
        paneBlockedTaps.forEach { $0.isEnabled = true }
        anchor.isHidden = false
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        UIView.animate(withDuration: Self.stepDissolve) {
            self.infoPane.alpha = 0
        } completion: { _ in
            if !self.paneOpen { self.infoPane.isHidden = true }
        }
    }

    /// The listed lines at once, then the server's full details when they arrive.
    private func updatePane() {
        guard listing.media.indices.contains(index) else { return }
        let shown = index, item = listing.media[shown]
        infoPane.show(PhotoDetailsCache.known(item))
        detailsTask?.cancel()
        guard let provider = listing.source()?.provider else { return }
        detailsTask = Task { [weak self] in
            _ = await PhotoDetailsCache.load(item, provider: provider)
            guard let self, !Task.isCancelled, paneOpen, index == shown,
                  listing.media.indices.contains(shown) else { return }
            infoPane.show(PhotoDetailsCache.known(listing.media[shown]))
        }
    }

    private func toggleFavorite() {
        guard listing.media.indices.contains(index) else { return }
        let task = listing.setFavorite(!listing.media[index].isFavorite, at: index)
        updatePane()
        // A refused write is put back once it settles.
        Task { [weak self] in
            await task?.value
            if let self, paneOpen { updatePane() }
        }
    }

    // MARK: - Slideshow

    @objc private func toggleSlideshow() {
        guard !playingShowClip else { return }
        if isRunning { return stopSlideshow() }
        isRunning = true
        holdsDisplayAwake = !UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        overlayHide?.cancel()
        caption.alpha = 0
        flash("play.fill")
        if listing.media.indices.contains(index), listing.media[index].kind == .clip,
           PhotoPreferences.playsClips, let clip = listing.media[index].playable {
            return playShowClip(clip)
        }
        startPan()
        scheduleSlide()
    }

    @objc private func stopSlideshow() {
        guard isRunning else { return }
        isRunning = false
        slideTimer?.invalidate()
        slideTimer = nil
        if holdsDisplayAwake { UIApplication.shared.isIdleTimerDisabled = false }
        holdsDisplayAwake = false
        resetPan(animated: true)
        flash("pause.fill")
    }

    private func scheduleSlide() {
        slideTimer?.invalidate()
        slideTimer = Timer.scheduledTimer(withTimeInterval: PhotoPreferences.slideInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceSlide() }
        }
    }

    /// Clips play when the setting allows, and are skipped otherwise.
    /// The last photo wraps to the first once every page is in.
    private func advanceSlide() {
        guard isRunning else { return }
        let media = listing.media, playsClips = PhotoPreferences.playsClips
        guard let next = PhotoViewerIndex.step(from: index, by: 1, count: media.count, wraps: !listing.hasMore,
                                               skipping: { !playsClips && media[$0].kind == .clip }) else {
            // A failed page ends the show; otherwise ask again and wait for the next tick.
            if !listing.hasMore || listing.error != nil { stopSlideshow() } else { listing.loadMore(); scheduleSlide() }
            return
        }
        if PhotoPreferences.transition == .panAndZoom || imageView.transform != .identity {
            handOffSlide()
            show(next, dissolve: 0)
        } else {
            show(next, dissolve: Self.slideDissolve)
        }
        if let clip = media[next].playable, media[next].kind == .clip {
            playShowClip(clip)
        } else {
            startPan()
            scheduleSlide()
        }
    }

    /// The player closes itself at the clip's end; the show resumes on the next item.
    private func playShowClip(_ clip: MediaItem) {
        playingShowClip = true
        ProviderPlayer.play(clip, fromBeginning: true, from: self) { [weak self] in
            guard let self else { return }
            playingShowClip = false
            guard isRunning else { return }
            // The player lets the display sleep again as it closes.
            UIApplication.shared.isIdleTimerDisabled = true
            advanceSlide()
        } onFailedToStart: { [weak self] in
            guard let self else { return }
            playingShowClip = false
            advanceSlide()
        }
    }

    /// Pan and Zoom: a slow push in with a small drift over the slide, the direction alternating.
    private func startPan() {
        guard isRunning, PhotoPreferences.transition == .panAndZoom else { return }
        let side: CGFloat = index.isMultiple(of: 2) ? 1 : -1
        let drift = CGAffineTransform(translationX: side * view.bounds.width * 0.02,
                                      y: -side * view.bounds.height * 0.01).scaledBy(x: 1.08, y: 1.08)
        panTarget = drift
        UIView.animate(withDuration: PhotoPreferences.slideInterval + Self.slideDissolve, delay: 0,
                       options: [.curveLinear, .beginFromCurrentState]) {
            self.imageView.transform = drift
        }
    }

    /// Moves the slide on screen to `outgoingView`, still zoomed and drifting, and fades it
    /// out over `imageView`, which starts the next slide from rest.
    private func handOffSlide() {
        let shown = imageView.layer.presentation().map { CATransform3DGetAffineTransform($0.transform) }
            ?? imageView.transform
        outgoingView.layer.removeAllAnimations()
        outgoingView.image = imageView.image
        outgoingView.transform = shown
        outgoingView.alpha = 1
        imageView.layer.removeAnimation(forKey: "transform")
        imageView.transform = .identity
        let target = panTarget ?? shown
        panTarget = nil
        UIView.animate(withDuration: Self.slideDissolve, delay: 0, options: .curveLinear) {
            self.outgoingView.alpha = 0
            self.outgoingView.transform = target
        }
    }

    private func resetPan(animated: Bool) {
        panTarget = nil
        guard imageView.transform != .identity else { return }
        // Hold where the push is now, then settle back from there.
        if let shown = imageView.layer.presentation() {
            imageView.transform = CATransform3DGetAffineTransform(shown.transform)
        }
        imageView.layer.removeAnimation(forKey: "transform")
        UIView.animate(withDuration: animated ? 0.3 : 0, delay: 0, options: .beginFromCurrentState) {
            self.imageView.transform = .identity
        }
    }

    /// The only sign a slideshow started or stopped, since the caption hides for it.
    private func flash(_ symbol: String) {
        slideGlyph.image = UIImage(systemName: symbol)
        slideGlyph.alpha = 1
        UIView.animate(withDuration: 0.4, delay: 0.6) { self.slideGlyph.alpha = 0 }
    }
}
