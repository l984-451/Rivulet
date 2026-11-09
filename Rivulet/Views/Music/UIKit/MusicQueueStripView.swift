// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicQueueStripView.swift
//  Rivulet
//
//  Now Playing's queue: one row of 524pt cards on a 564 pitch, history to the
//  left of the playing track and what is next to its right. The card that
//  matters rests at x 698: the focused one while focus is in the strip, the
//  playing one otherwise. Measured from Apple Music on tvOS 26.
//

import UIKit

@MainActor
final class MusicQueueStripView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    static let card: CGFloat = 524
    private static let pitch: CGFloat = 564
    /// Where the resting card's left edge sits on screen.
    private static let restX: CGFloat = 698

    /// Select on a card, as its distance from the playing track (negative is history).
    var onSelect: ((Int) -> Void)?

    private var tracks: [MusicTrack] = []
    private var currentIndex = 0
    private var isPlaying = false
    /// The card under focus; nil while focus is outside the strip.
    private var focusedIndex: Int?

    private let collectionView: UICollectionView
    private let registration = UICollectionView.CellRegistration<MusicQueueCardCell, Int> { _, _, _ in }

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = Self.pitch - Self.card
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        collectionView.frame = bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.clipsToBounds = false
        collectionView.contentInsetAdjustmentBehavior = .never
        // The engine's own focus scroll would rest a card on the screen edge; the offset is driven here.
        collectionView.isScrollEnabled = false
        collectionView.dataSource = self
        collectionView.delegate = self
        addSubview(collectionView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout,
              layout.itemSize.height != bounds.height else { return }
        layout.itemSize = CGSize(width: Self.card, height: bounds.height)
        layout.sectionInset = UIEdgeInsets(top: 0, left: Self.restX, bottom: 0,
                                           right: bounds.width - Self.restX - Self.card)
        settle(animated: false)
    }

    // MARK: - Content

    /// `tracks` is history, the playing track, then the queue. A track change keeps the list and
    /// moves `currentIndex`, so the cards stay put and only the marker and the offset move.
    func update(tracks newTracks: [MusicTrack], currentIndex newIndex: Int, isPlaying: Bool) {
        let sameList = newTracks.count == tracks.count && zip(newTracks, tracks).allSatisfy { $0.ref == $1.ref }
        tracks = newTracks
        currentIndex = newIndex
        self.isPlaying = isPlaying
        if sameList {
            for case let cell as MusicQueueCardCell in collectionView.visibleCells {
                if let item = collectionView.indexPath(for: cell)?.item { configure(cell, at: item) }
            }
        } else {
            if let focused = focusedIndex { focusedIndex = min(focused, max(0, tracks.count - 1)) }
            collectionView.reloadData()
        }
        // Focus owns the offset while it is in the strip: a track change must not move the focused card.
        if focusedIndex == nil { settle(animated: sameList && window != nil) }
    }

    private func configure(_ cell: MusicQueueCardCell, at item: Int) {
        guard tracks.indices.contains(item) else { return }
        cell.configure(track: tracks[item], isCurrent: item == currentIndex, isPlaying: isPlaying)
    }

    // MARK: - Collection

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        tracks.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: indexPath.item)
        configure(cell, at: indexPath.item)
        return cell
    }

    // A card prepared ahead of the scroll is not among `visibleCells` yet, so it missed any
    // change of the playing marker made since.
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        if let cell = cell as? MusicQueueCardCell { configure(cell, at: indexPath.item) }
    }

    // From outside, the strip is entered at the playing card and nowhere else.
    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        focusedIndex != nil || indexPath.item == currentIndex
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        tracks.isEmpty ? nil : IndexPath(item: focusedIndex ?? currentIndex, section: 0)
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        focusedIndex = context.nextFocusedIndexPath?.item
        settle(animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if indexPath.item != currentIndex { onSelect?(indexPath.item - currentIndex) }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [collectionView] }

    // MARK: - Offset

    private var offsetLink: CADisplayLink?
    private var animStartX: CGFloat = 0
    private var animTargetX: CGFloat = 0
    private var animStartTime: CFTimeInterval = 0

    /// Rests the focused card, or the playing one, at x 698. Same driven settle as the Home shelves.
    private func settle(animated: Bool) {
        let target = CGFloat(focusedIndex ?? currentIndex) * Self.pitch
        offsetLink?.invalidate()
        offsetLink = nil
        guard animated, !UIAccessibility.isReduceMotionEnabled,
              abs(target - collectionView.contentOffset.x) > 0.5 else {
            collectionView.contentOffset.x = target
            return
        }
        animStartX = collectionView.contentOffset.x
        animTargetX = target
        animStartTime = CACurrentMediaTime()
        // A weak proxy: the link retains its target.
        let link = CADisplayLink(target: LinkProxy(self), selector: #selector(LinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        offsetLink = link
    }

    fileprivate func stepOffset(_ link: CADisplayLink) {
        let t = min(1, (CACurrentMediaTime() - animStartTime) / FocusScrollMotion.settleDuration)
        collectionView.contentOffset.x = animStartX + (animTargetX - animStartX) * CGFloat(FocusScrollMotion.ease(t))
        if t >= 1 {
            link.invalidate()
            if offsetLink === link { offsetLink = nil }
        }
    }

    @MainActor
    private final class LinkProxy: NSObject {
        private weak var owner: MusicQueueStripView?
        init(_ owner: MusicQueueStripView) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.stepOffset(link)
        }
    }
}

// MARK: - Card

/// One queue card: the artwork over its title and artist. The playing card carries the bars.
@MainActor
final class MusicQueueCardCell: UICollectionViewCell {
    private let shadow = UIView()
    private let art = UIImageView()
    private let caption = MusicNowPlayingCaptionView()
    private var artworkTask: Task<Void, Never>?
    private var artworkURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = false
        let side = MusicQueueStripView.card
        shadow.frame = CGRect(x: 0, y: 0, width: side, height: side)
        shadow.layer.shadowColor = UIColor.black.cgColor
        shadow.layer.shadowRadius = 30
        shadow.layer.shadowOffset = CGSize(width: 0, height: 24)
        shadow.layer.shadowOpacity = 0
        shadow.layer.shadowPath = UIBezierPath(roundedRect: shadow.bounds, cornerRadius: 12).cgPath
        art.frame = shadow.bounds
        art.contentMode = .scaleAspectFill
        art.clipsToBounds = true
        art.layer.cornerRadius = 12
        art.layer.cornerCurve = .continuous
        shadow.addSubview(art)
        caption.frame = CGRect(x: 0, y: side, width: side, height: MusicNowPlayingCaptionView.height)
        [shadow, caption].forEach(contentView.addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(track: MusicTrack, isCurrent: Bool, isPlaying: Bool) {
        caption.configure(title: track.title, artist: track.artistName ?? track.albumTitle,
                          showsBars: isCurrent, isPlaying: isPlaying)
        let url = track.artwork.poster
        guard url == nil || url != artworkURL else { return }
        artworkURL = url
        art.image = MusicChrome.placeholder(side: MusicQueueStripView.card)
        artworkTask?.cancel()
        artworkTask = MusicChrome.loadArtwork(url, quality: .full) { [weak self] image in
            if let image { self?.art.image = image }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkTask?.cancel()
        artworkTask = nil
        artworkURL = nil
        art.image = nil
    }

    // Apple's focused card is in no capture: the art lifts as a Library tile does, by less,
    // because its neighbours are 40pt away.
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.animateFocusChange(gained: focused) {
            self.shadow.transform = focused ? CGAffineTransform(scaleX: 1.06, y: 1.06) : .identity
            self.shadow.layer.shadowOpacity = focused ? 0.4 : 0
            self.caption.transform = focused ? CGAffineTransform(translationX: 0, y: 16) : .identity
            self.caption.isEmphasized = focused
        }
    }
}

// MARK: - Caption

/// Title and artist under a 524pt artwork: Now Playing's own, and each queue card's. The title is
/// centred on the artwork; the bars hang to its left and are no part of the centred text.
@MainActor
final class MusicNowPlayingCaptionView: UIView {
    static let height: CGFloat = 96
    private static let barsGap: CGFloat = 8

    /// MediaCoreUI's marquee: a 3s wait, 30pt a second, 20pt between the copies, 8pt feathered edges.
    private enum Marquee {
        static let (delay, speed, gap, feather): (Double, Double, CGFloat, CGFloat) = (3, 30, 20, 8)
    }

    private let bars = MusicPlaybackBarsView(peak: 18, standsOnBaseline: true)
    private let title = MusicChrome.label(size: 29, weight: .medium)
    private let artist = MusicChrome.label(size: 29, weight: .medium, color: UIColor(white: 1, alpha: 0.5))
    /// Clips the title, with the second copy a scrolling title needs.
    private let titleBox = UIView()
    private let echo = MusicChrome.label(size: 29, weight: .medium)
    private let feather = GradientView()

    /// Now Playing's own title scrolls when it is wider than its box. A queue card's truncates.
    var marqueesTitle = false

    /// A focused queue card's text reads full white.
    var isEmphasized = false {
        didSet {
            title.textColor = UIColor(white: 1, alpha: isEmphasized ? 1 : 0.85)
            artist.textColor = UIColor(white: 1, alpha: isEmphasized ? 0.8 : 0.5)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        title.textColor = UIColor(white: 1, alpha: 0.85)
        artist.textAlignment = .center
        titleBox.clipsToBounds = true
        [title, echo].forEach(titleBox.addSubview)
        feather.gradientLayer.colors = [UIColor.clear, .white, .white, .clear].map(\.cgColor)
        (feather.gradientLayer.startPoint, feather.gradientLayer.endPoint) = (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5))
        [bars, titleBox, artist].forEach(addSubview)
        // Core Animation drops the scroll when the app leaves the foreground.
        NotificationCenter.default.addObserver(self, selector: #selector(setNeedsLayout),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, artist: String?, showsBars: Bool, isPlaying: Bool) {
        self.title.text = title
        self.artist.text = artist
        bars.isHidden = !showsBars
        bars.isPlaying = showsBars && isPlaying
        setNeedsLayout()
    }

    func setPlaying(_ playing: Bool) { bars.isPlaying = !bars.isHidden && playing }

    // Baselines 44 and 82 under the artwork (screen y 738 and 776).
    override func layoutSubviews() {
        super.layoutSubviews()
        let barsSize = bars.intrinsicContentSize
        // Room for the bars is kept on both sides, so a long title stays centred beside them.
        let limit = bars.isHidden ? bounds.width : bounds.width - 2 * (barsSize.width + Self.barsGap) + 2
        let natural = ceil(title.intrinsicContentSize.width)
        let width = min(natural, limit)
        let lineHeight = ceil(title.font.lineHeight)
        let left = (bounds.width - width) / 2
        bars.frame = CGRect(x: left - Self.barsGap - barsSize.width, y: 44 - barsSize.height,
                            width: barsSize.width, height: barsSize.height)
        artist.frame = CGRect(x: 0, y: 82 - artist.font.ascender, width: bounds.width, height: lineHeight)

        let scrolls = marqueesTitle && natural > limit && window != nil && !UIAccessibility.isReduceMotionEnabled
        // The feathered edges lie inside the box, clear of the bars; a title at rest starts past them, whole.
        let pad = scrolls ? Marquee.feather : 0
        titleBox.frame = CGRect(x: left, y: 44 - title.font.ascender, width: width, height: lineHeight)
        title.frame = CGRect(x: pad, y: 0, width: scrolls ? natural : width, height: lineHeight)
        titleBox.mask = scrolls ? feather : nil
        echo.isHidden = !scrolls
        [title, echo].forEach { $0.layer.removeAnimation(forKey: "marquee") }
        guard scrolls else { return }
        let travel = natural + Marquee.gap
        echo.text = title.text
        echo.textColor = title.textColor
        echo.frame = title.frame.offsetBy(dx: travel, dy: 0)
        feather.frame = titleBox.bounds
        let edge = Marquee.feather / titleBox.bounds.width
        feather.gradientLayer.locations = [0, edge, 1 - edge, 1].map { NSNumber(value: $0) }
        // One loop: wait, then the second copy slides to where the first began.
        let scroll = CAKeyframeAnimation(keyPath: "transform.translation.x")
        scroll.duration = Marquee.delay + travel / Marquee.speed
        scroll.values = [0, 0, -travel]
        scroll.keyTimes = [0, NSNumber(value: Marquee.delay / scroll.duration), 1]
        scroll.repeatCount = .infinity
        [title, echo].forEach { $0.layer.add(scroll, forKey: "marquee") }
    }

    // Core Animation drops the scroll when the layer leaves the window.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { setNeedsLayout() }
    }
}
