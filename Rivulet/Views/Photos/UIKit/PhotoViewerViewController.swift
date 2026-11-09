// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PhotoViewerViewController.swift
//  Rivulet
//
//  One photo full screen. Left and Right page, Select or Play/Pause runs a
//  slideshow, Select on a clip plays it, Menu closes.
//

import UIKit

@MainActor
final class PhotoViewerViewController: UIViewController {
    /// Seconds each slide stays up.
    static let slideInterval: TimeInterval = 4
    private static let stepDissolve: TimeInterval = 0.2
    private static let slideDissolve: TimeInterval = 0.5
    private static let overlayLinger: TimeInterval = 3

    /// Called with the index on screen just before the viewer closes, then once it has.
    var onClose: ((Int) -> Void)?
    var onDismissed: (() -> Void)?

    private let listing: PhotoListing
    private var index: Int
    private let imageView = UIImageView()
    private let clipGlyph = UIImageView(image: UIImage(systemName: "play.circle.fill"))
    private let slideGlyph = UIImageView()
    private let caption = UILabel()
    /// The only focus target: presses reach a focused view, and the viewer has no other.
    private let anchor = PreviewFocusAnchorView()
    private var input: DirectionalInputBinding?
    private var loadTask: Task<Void, Never>?
    private var slideTimer: Timer?
    private var overlayHide: DispatchWorkItem?
    /// Set only while this viewer is what turned the idle timer off.
    private var holdsDisplayAwake = false

    init(listing: PhotoListing, index: Int) {
        self.listing = listing
        self.index = index
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

        // The swipes stand down while a clip's player is up over the viewer.
        input = DirectionalInputBinding(
            view: view, directions: [.left, .right],
            onTap: { [weak self] in self?.step($0 == .right ? 1 : -1) },
            swipeGate: { [weak self] _ in self?.presentedViewController == nil })
        for (press, action) in [(UIPress.PressType.select, #selector(selectPressed)),
                                (.playPause, #selector(toggleSlideshow)),
                                (.menu, #selector(close))] {
            let tap = UITapGestureRecognizer(target: self, action: action)
            tap.allowedPressTypes = [NSNumber(value: press.rawValue)]
            view.addGestureRecognizer(tap)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(stopSlideshow),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        show(index, dissolve: 0)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSlideshow()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [anchor] }

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
        guard slideTimer == nil else { caption.alpha = 0; return }
        UIView.animate(withDuration: Self.stepDissolve) { self.caption.alpha = 1 }
        let hide = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.5) { self?.caption.alpha = 0 }
        }
        overlayHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.overlayLinger, execute: hide)
    }

    // MARK: - Input

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

    // MARK: - Slideshow

    @objc private func toggleSlideshow() {
        if slideTimer != nil { return stopSlideshow() }
        slideTimer = Timer.scheduledTimer(withTimeInterval: Self.slideInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceSlide() }
        }
        holdsDisplayAwake = !UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        overlayHide?.cancel()
        caption.alpha = 0
        flash("play.fill")
    }

    @objc private func stopSlideshow() {
        guard let slideTimer else { return }
        slideTimer.invalidate()
        self.slideTimer = nil
        if holdsDisplayAwake { UIApplication.shared.isIdleTimerDisabled = false }
        holdsDisplayAwake = false
        flash("pause.fill")
    }

    /// Clips are skipped. The last photo wraps to the first once every page is in.
    private func advanceSlide() {
        let media = listing.media
        guard let next = PhotoViewerIndex.step(from: index, by: 1, count: media.count, wraps: !listing.hasMore,
                                               skipping: { media[$0].kind == .clip }) else {
            // A failed page ends the show; otherwise ask again and wait for the next tick.
            if !listing.hasMore || listing.error != nil { stopSlideshow() } else { listing.loadMore() }
            return
        }
        show(next, dissolve: Self.slideDissolve)
    }

    /// The only sign a slideshow started or stopped, since the caption hides for it.
    private func flash(_ symbol: String) {
        slideGlyph.image = UIImage(systemName: symbol)
        slideGlyph.alpha = 1
        UIView.animate(withDuration: 0.4, delay: 0.6) { self.slideGlyph.alpha = 0 }
    }
}
