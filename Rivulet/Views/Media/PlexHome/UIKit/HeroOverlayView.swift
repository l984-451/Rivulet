//
//  HeroOverlayView.swift
//  Rivulet
//
//  Native UIKit hero overlay. Replaces the previous SwiftUI-hosted
//  `HeroOverlayCell` so the entire UIKit Home is one focus model.
//
//  Composition (bottom-up):
//    - HeroSlideView   — logo / metadata / tagline for the current slide
//    - HeroButtonRowView — Play / Watchlist / Info / Next
//    - paging dots     — pinned to the bottom of the overlay
//
//  The slide content lags the backdrop's `currentIndex` by 100ms so the
//  Apple TV "metadata follows the art" beat is preserved (matches
//  `HeroOverlayContent.slideSwapDelay`).
//
//  The view does NOT manage the backdrop image. The collection-view
//  controller hosts `HeroBackdropView` as a sibling and updates it
//  whenever this view emits `onIndexChanged`.
//

import UIKit
import Combine
import os.log

private let heroLog = Logger(subsystem: "com.rivulet.app", category: "HeroOverlayUIKit")

@MainActor
final class HeroOverlayView: UIView {

    // MARK: - Inputs

    private(set) var items: [PlexMetadata] = []
    private var serverURL: String = ""
    private var authToken: String = ""

    /// Index of the slide whose backdrop is currently visible. Drives
    /// `onIndexChanged` (which the controller wires to the backdrop view).
    private(set) var currentIndex: Int = 0

    /// Lags `currentIndex` by 100ms so the metadata column doesn't pop in
    /// before the backdrop crossfade has started. Mirrors
    /// `HeroOverlayContent.displayedIndex`.
    private var displayedIndex: Int = 0
    private var displayedSwapWorkItem: DispatchWorkItem?

    var onIndexChanged: ((Int, PlexMetadata) -> Void)?
    var onInfo: ((PlexMetadata) -> Void)?
    var onPlay: ((PlexMetadata) -> Void)?
    var onFocusEntered: (() -> Void)?

    // MARK: - Subviews

    private let slideView = HeroSlideView()
    private let buttonRow = HeroButtonRowView()
    private let pagingDots = HeroPagingDotsView()
    private let pagingDotsBackground = UIView()

    // MARK: - State

    private var resolvedPlayTargets: [String: PlexMetadata] = [:]
    private var resolvedForWatchlistCache: [String: PlexMetadata] = [:]
    private var isResolvingPlay = false

    private var watchlistObserver: AnyCancellable?

    // MARK: - Auto-advance

    /// Seconds each hero slide is shown before auto-advancing. The active
    /// paging dot fills over this duration as a countdown.
    private let heroCycleSeconds: TimeInterval = 9
    private var autoAdvanceTimer: Timer?
    private var isHeroFocused = false

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        setUpSubviews()
        wireButtonHandlers()
        observeWatchlist()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func setUpSubviews() {
        slideView.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        pagingDotsBackground.translatesAutoresizingMaskIntoConstraints = false
        pagingDots.translatesAutoresizingMaskIntoConstraints = false

        addSubview(slideView)
        addSubview(buttonRow)
        addSubview(pagingDotsBackground)
        pagingDotsBackground.addSubview(pagingDots)

        pagingDotsBackground.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        pagingDotsBackground.layer.cornerRadius = 12
        pagingDotsBackground.layer.cornerCurve = .continuous
        pagingDotsBackground.isHidden = true

        NSLayoutConstraint.activate([
            // Slide + buttons pinned bottom-left at 32pt, aligned with the home
            // rows' content-left margin. Held off the very bottom by 94pt (the
            // metadata stack sits ~50px lower than the old 144), dots below them.
            slideView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MediaRowMetrics.rowLeading),
            slideView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -120),

            buttonRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MediaRowMetrics.rowLeading),
            buttonRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -94),
            buttonRow.topAnchor.constraint(equalTo: slideView.bottomAnchor, constant: 28),
            buttonRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -120),

            pagingDotsBackground.centerXAnchor.constraint(equalTo: centerXAnchor),
            // Low at rest: ~50px above Continue Watching (10pt above the hero
            // bottom + the hero section's 40pt bottom gap to the first row).
            pagingDotsBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            pagingDots.topAnchor.constraint(equalTo: pagingDotsBackground.topAnchor, constant: 8),
            pagingDots.bottomAnchor.constraint(equalTo: pagingDotsBackground.bottomAnchor, constant: -8),
            pagingDots.leadingAnchor.constraint(equalTo: pagingDotsBackground.leadingAnchor, constant: 14),
            pagingDots.trailingAnchor.constraint(equalTo: pagingDotsBackground.trailingAnchor, constant: -14)
        ])
    }

    // MARK: - Configure

    func configure(items: [PlexMetadata],
                   serverURL: String,
                   authToken: String,
                   initialIndex: Int) {
        self.items = items
        self.serverURL = serverURL
        self.authToken = authToken
        // Clamp index against new items.
        self.currentIndex = max(0, min(initialIndex, max(0, items.count - 1)))
        self.displayedIndex = currentIndex
        renderSlide(animated: false)
        updateButtonStateForCurrentItem()
        renderPagingDots()
    }

    // MARK: - Scroll parallax

    /// Parallax the paging dots upward as the page scrolls below the hero so
    /// they don't sink too low. Driven by the home VC's `scrollViewDidScroll`.
    /// The dots otherwise ride the content at 1x while the backdrop recedes at
    /// 1.4x, so without this they fall too low relative to the hero image. At
    /// rest (offset 0) the transform is identity, so the rest position is
    /// unchanged.
    func applyScrollOffset(_ offset: CGFloat) {
        let lift = -max(0, offset) * Self.dotsParallaxFactor
        pagingDotsBackground.transform = CGAffineTransform(translationX: 0, y: lift)
        // In Discover mode our own dots are hidden and the live dots live in the
        // MediaItem overlay child — forward the lift so they parallax the same.
        mediaItemOverlay?.applyScrollOffset(offset)
    }

    /// Upward parallax rate for the dots (fraction of scroll). ~0.1 lifts them
    /// ~50px by the time Continue Watching is focused.
    private static let dotsParallaxFactor: CGFloat = 0.1

    // MARK: - Focus

    override var canBecomeFocused: Bool { false }

    /// Forward focus into the button row so the focus engine can find
    /// `play` as the default landing target.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        return [buttonRow]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let nextInside = context.nextFocusedView?.isDescendant(of: self) == true
        let prevInside = context.previouslyFocusedView?.isDescendant(of: self) == true
        if nextInside, !prevInside {
            isHeroFocused = true
            onFocusEntered?()
            startAutoAdvanceCycle()   // begin auto-cycling while the hero is focused
        } else if prevInside, !nextInside {
            isHeroFocused = false
            stopAutoAdvance()         // pause when focus leaves the hero
        }
        // Land-on-Play gate: secondary buttons are focus candidates only
        // while focus lives inside the hero (see
        // HeroButtonRowView.setSecondaryButtonsFocusable).
        buttonRow.setSecondaryButtonsFocusable(nextInside)
    }

    // MARK: - Slide rendering

    private var currentItem: PlexMetadata? {
        guard !items.isEmpty else { return nil }
        let clamped = max(0, min(currentIndex, items.count - 1))
        return items[clamped]
    }

    private var displayedItem: PlexMetadata? {
        guard !items.isEmpty else { return nil }
        let clamped = max(0, min(displayedIndex, items.count - 1))
        return items[clamped]
    }

    private func renderSlide(animated: Bool, manageAlpha: Bool = true, onReady: (() -> Void)? = nil) {
        guard let item = displayedItem else {
            slideView.configure(item: nil, serverURL: serverURL, authToken: authToken,
                                animated: false, manageAlpha: manageAlpha, onReady: onReady)
            return
        }
        slideView.configure(item: item, serverURL: serverURL, authToken: authToken,
                            animated: animated, manageAlpha: manageAlpha, onReady: onReady)
    }

    private func renderPagingDots(progressDuration: TimeInterval? = nil) {
        pagingDotsBackground.isHidden = items.count <= 1
        // Dots track the PRESS index (currentIndex), not the lagged metadata
        // (displayedIndex), so they advance with the backdrop image on the
        // click rather than 600ms later when the metadata swaps in.
        pagingDots.update(count: items.count, activeIndex: currentIndex,
                          progressDuration: progressDuration)
    }

    // MARK: - Auto-advance cycle

    /// Starts (or restarts) the auto-advance cycle: the active dot fills over
    /// `heroCycleSeconds`, then the hero advances to the next slide. Only runs
    /// while the hero is focused and there's more than one slide.
    private func startAutoAdvanceCycle() {
        autoAdvanceTimer?.invalidate()
        autoAdvanceTimer = nil
        guard isHeroFocused, items.count > 1 else {
            renderPagingDots()
            return
        }
        renderPagingDots(progressDuration: heroCycleSeconds)
        autoAdvanceTimer = Timer.scheduledTimer(withTimeInterval: heroCycleSeconds,
                                                repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advance()
            }
        }
    }

    private func stopAutoAdvance() {
        autoAdvanceTimer?.invalidate()
        autoAdvanceTimer = nil
        renderPagingDots()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { stopAutoAdvance() }
    }

    // MARK: - Paging (button -> currentIndex -> backdrop -> delayed slide swap)

    private func advance() {
        guard items.count > 1 else { return }
        let next = (currentIndex + 1) % items.count
        setCurrentIndex(next)
        // Reset the cycle so the dot countdown restarts from this slide, whether
        // the advance came from the timer or the Next button.
        if isHeroFocused { startAutoAdvanceCycle() }
    }

    private func setCurrentIndex(_ newIndex: Int) {
        guard newIndex != currentIndex else { return }
        currentIndex = newIndex
        // Pass the actual item (not just the index) so the controller drives the
        // backdrop off the SAME array the slide uses. The controller's heroItems
        // can be reordered (TMDB hero upgrade) after this view was configured, so
        // an index alone would point at a different item -> metadata/image drift.
        if let item = currentItem { onIndexChanged?(newIndex, item) }
        updateButtonStateForCurrentItem()
        // Advance the dots NOW, on the press (with the backdrop image), not in
        // the delayed metadata swap below.
        renderPagingDots()

        // Fade the OLD metadata out quickly on the click so it clears while the
        // backdrop changes (it would otherwise linger for the full 600ms lag).
        UIView.animate(withDuration: 0.15, delay: 0, options: [.curveEaseIn]) {
            self.slideView.alpha = 0
        }

        // Then, after a 600ms lag (so the new backdrop image has changed), swap
        // in the new metadata and fade it in SLOWLY. renderSlide is animated:false
        // here (no crossfade — the old is already gone); we hold alpha at 0 and
        // drive the slow fade-in ourselves.
        displayedSwapWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.displayedIndex = newIndex
            // Hold the slide hidden, set the new content + load its logo, and
            // fade in only once the logo is resolved (loaded or absent), so the
            // final logo/text shows from the first frame -- no fallback-text
            // flash that then jumps to the logo mid-fade.
            self.slideView.alpha = 0
            self.renderSlide(animated: false, manageAlpha: false) { [weak self] in
                guard let self else { return }
                UIView.animate(withDuration: 0.6, delay: 0, options: [.curveEaseOut]) {
                    self.slideView.alpha = 1
                }
            }
        }
        displayedSwapWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: - Buttons + handlers

    private func wireButtonHandlers() {
        buttonRow.onPlay = { [weak self] in self?.handlePlay() }
        buttonRow.onWatchlist = { [weak self] in
            guard let self, let item = self.currentItem else { return }
            Task { @MainActor in await self.toggleWatchlist(for: item) }
        }
        buttonRow.onInfo = { [weak self] in
            guard let self, let item = self.currentItem else { return }
            self.onInfo?(item)
        }
        buttonRow.onNext = { [weak self] in self?.advance() }
    }

    private func updateButtonStateForCurrentItem() {
        buttonRow.canAdvance = items.count > 1
        if let item = currentItem {
            let tmdb = resolvedTmdbId(for: item)
            let onList = tmdb.map { PlexWatchlistService.shared.contains(tmdbId: $0) } ?? false
            buttonRow.isOnWatchlist = onList
        } else {
            buttonRow.isOnWatchlist = false
        }
    }

    private func handlePlay() {
        guard !isResolvingPlay, let item = currentItem else { return }
        if let key = item.ratingKey, let cached = resolvedPlayTargets[key] {
            onPlay?(cached)
            return
        }
        if let type = item.type, type == "movie" || type == "episode" {
            onPlay?(item)
            return
        }
        // Re-entrancy guard only (no UI): resolving a show's next-up episode
        // is async, and a second Play press mid-resolve would double-fire.
        isResolvingPlay = true
        Task { @MainActor in
            let resolved = await HeroPlaySession.resolvePlaybackTarget(
                for: item,
                serverURL: serverURL,
                authToken: authToken
            )
            if let key = item.ratingKey {
                resolvedPlayTargets[key] = resolved
            }
            isResolvingPlay = false
            onPlay?(resolved)
        }
    }

    // MARK: - Watchlist

    private func observeWatchlist() {
        // When the watchlist changes (toggle from anywhere else in the
        // app), refresh our bookmark icon.
        watchlistObserver = PlexWatchlistService.shared.$watchlistGUIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateButtonStateForCurrentItem()
            }
    }

    private func toggleWatchlist(for item: PlexMetadata) async {
        let resolved = await resolvedForWatchlist(item)
        guard let tmdbId = resolved.tmdbId else {
            heroLog.warning("Watchlist toggle aborted: no tmdbId on \(resolved.ratingKey ?? "?", privacy: .public)")
            return
        }
        let guid = "tmdb://\(tmdbId)"
        let service = PlexWatchlistService.shared
        if service.contains(guid: guid) {
            await service.remove(guid: guid)
        } else {
            let watchType: PlexWatchlistItem.WatchlistType = (resolved.type == "show") ? .show : .movie
            let posterURL: URL? = {
                guard let thumbPath = resolved.thumb, !thumbPath.isEmpty else { return nil }
                return URL(string: "\(serverURL)\(thumbPath)?X-Plex-Token=\(authToken)")
            }()
            let watchlistItem = PlexWatchlistItem(
                id: guid,
                title: resolved.title ?? "",
                year: resolved.year,
                type: watchType,
                posterURL: posterURL,
                guids: [guid]
            )
            await service.add(guid: guid, item: watchlistItem)
        }
    }

    private func resolvedForWatchlist(_ item: PlexMetadata) async -> PlexMetadata {
        if item.tmdbId != nil { return item }
        if let ratingKey = item.ratingKey, let cached = resolvedForWatchlistCache[ratingKey] {
            return cached
        }
        guard let ratingKey = item.ratingKey else { return item }
        do {
            let full = try await PlexNetworkManager.shared.getMetadata(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: ratingKey
            )
            resolvedForWatchlistCache[ratingKey] = full
            return full
        } catch {
            return item
        }
    }

    private func resolvedTmdbId(for item: PlexMetadata) -> Int? {
        if let id = item.tmdbId { return id }
        if let key = item.ratingKey, let cached = resolvedForWatchlistCache[key] {
            return cached.tmdbId
        }
        return nil
    }

    // MARK: - MediaItem path (additive, for MediaLibraryViewController)

    /// Installs the MediaItem overlay and wires its callbacks. The PlexMetadata
    /// path (configure(items:serverURL:authToken:initialIndex:)) is UNTOUCHED.
    ///
    /// The overlay is a simple self-contained UIView (MediaItemHeroOverlayView)
    /// added as a subview pinned to self's edges. It is created lazily on first
    /// call and reused thereafter.
    func configure(
        mediaItems: [MediaItem],
        initialIndex: Int,
        onIndexChanged: @escaping (Int, MediaItem) -> Void,
        onPlay: @escaping (MediaItem) -> Void,
        onInfo: @escaping (MediaItem) -> Void,
        onToggleWatchlist: ((MediaItem) -> Void)? = nil
    ) {
        if mediaItemOverlay == nil {
            let v = MediaItemHeroOverlayView()
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: topAnchor),
                v.bottomAnchor.constraint(equalTo: bottomAnchor),
                v.leadingAnchor.constraint(equalTo: leadingAnchor),
                v.trailingAnchor.constraint(equalTo: trailingAnchor)
            ])
            mediaItemOverlay = v
        }

        // Hide the PlexMetadata subviews so they don't overlap.
        slideView.isHidden = true
        buttonRow.isHidden = true
        pagingDotsBackground.isHidden = true

        mediaItemOverlay?.onToggleWatchlist = onToggleWatchlist
        mediaItemOverlay?.configure(
            items: mediaItems,
            initialIndex: initialIndex,
            onIndexChanged: onIndexChanged,
            onPlay: onPlay,
            onInfo: onInfo
        )
    }

    /// Forward per-item primary-action state to the MediaItem overlay
    /// (no-op in PlexMetadata mode).
    func setMediaItemPrimaryAction(matchedInLibrary: Bool, isOnWatchlist: Bool) {
        mediaItemOverlay?.setPrimaryAction(matchedInLibrary: matchedInLibrary, isOnWatchlist: isOnWatchlist)
    }

    private var mediaItemOverlay: MediaItemHeroOverlayView?
}

// MARK: - MediaItemHeroOverlayView

/// Minimal hero overlay for MediaItem data. Matches the visual structure of
/// HeroOverlayView: title/logo + metadata row + tagline, Play/Info/Next
/// buttons, paging dots. Watchlist is a no-op stub (Task 12 wires actions).
///
/// Simplifications vs. the full PlexMetadata hero:
///   - No watchlist toggle (button hidden; Task 12).
///   - No HeroPlaySession on-demand resolution (calls onPlay immediately).
///   - No TMDB logo upgrade (uses item.artwork.logo as-is).
///   - No delayed metadata-swap work item (metadata updates are instant).
///   - Logo loaded via ImageCacheManager.shared.image(for:) (not imageFullSize).
///
/// Preserved from the PlexMetadata hero:
///   - 100ms slide-swap delay so art beat aligns with the backdrop crossfade.
///   - Paging dots, advance (Next) button.
///   - Focus forwarding to the Play button.
///   - Identical button layout/spacing (HeroButtonRowView reused directly).
@MainActor
final class MediaItemHeroOverlayView: UIView {

    // MARK: - State

    private var items: [MediaItem] = []
    private(set) var currentIndex: Int = 0
    private var displayedIndex: Int = 0
    private var displayedSwapWorkItem: DispatchWorkItem?

    // MARK: - Callbacks

    var onIndexChanged: ((Int, MediaItem) -> Void)?
    var onPlay: ((MediaItem) -> Void)?
    var onInfo: ((MediaItem) -> Void)?
    var onToggleWatchlist: ((MediaItem) -> Void)?

    // MARK: - Subviews (layout mirrors HeroOverlayView)

    private let slideView = MediaItemSlideView()
    private let buttonRow = HeroButtonRowView()
    private let pagingDotsBackground = UIView()
    private let pagingDots = HeroPagingDotsView()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        setUpSubviews()
        wireButtons()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUpSubviews() {
        slideView.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        pagingDotsBackground.translatesAutoresizingMaskIntoConstraints = false
        pagingDots.translatesAutoresizingMaskIntoConstraints = false

        addSubview(slideView)
        addSubview(buttonRow)
        addSubview(pagingDotsBackground)
        pagingDotsBackground.addSubview(pagingDots)

        pagingDotsBackground.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        pagingDotsBackground.layer.cornerRadius = 12
        pagingDotsBackground.layer.cornerCurve = .continuous
        pagingDotsBackground.isHidden = true

        NSLayoutConstraint.activate([
            slideView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MediaRowMetrics.rowLeading),
            slideView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -120),

            buttonRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MediaRowMetrics.rowLeading),
            buttonRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -94),
            buttonRow.topAnchor.constraint(equalTo: slideView.bottomAnchor, constant: 28),
            buttonRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -120),

            pagingDotsBackground.centerXAnchor.constraint(equalTo: centerXAnchor),
            pagingDotsBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            pagingDots.topAnchor.constraint(equalTo: pagingDotsBackground.topAnchor, constant: 8),
            pagingDots.bottomAnchor.constraint(equalTo: pagingDotsBackground.bottomAnchor, constant: -8),
            pagingDots.leadingAnchor.constraint(equalTo: pagingDotsBackground.leadingAnchor, constant: 14),
            pagingDots.trailingAnchor.constraint(equalTo: pagingDotsBackground.trailingAnchor, constant: -14)
        ])
    }

    // MARK: - Configure

    func configure(
        items: [MediaItem],
        initialIndex: Int,
        onIndexChanged: @escaping (Int, MediaItem) -> Void,
        onPlay: @escaping (MediaItem) -> Void,
        onInfo: @escaping (MediaItem) -> Void
    ) {
        self.items = items
        self.onIndexChanged = onIndexChanged
        self.onPlay = onPlay
        self.onInfo = onInfo
        self.currentIndex = max(0, min(initialIndex, max(0, items.count - 1)))
        self.displayedIndex = currentIndex
        // First render holds the slide hidden until the logo resolves, so
        // the cold-load hero doesn't show text-then-logo.
        slideView.alpha = 0
        renderSlide { [weak self] in
            guard let self else { return }
            UIView.animate(withDuration: 0.4, delay: 0, options: [.curveEaseOut]) {
                self.slideView.alpha = 1
            }
        }
        renderPagingDots()
        buttonRow.canAdvance = items.count > 1
    }

    // MARK: - Focus

    override var canBecomeFocused: Bool { false }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        return [buttonRow]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        // Land-on-Play gate: secondary buttons are focus candidates only
        // while focus lives inside the hero (see
        // HeroButtonRowView.setSecondaryButtonsFocusable).
        let nextInside = context.nextFocusedView?.isDescendant(of: self) == true
        buttonRow.setSecondaryButtonsFocusable(nextInside)
    }

    // MARK: - Scroll parallax

    /// Lifts the paging dots as the page scrolls below the hero so they don't
    /// sink behind the receding backdrop — same factor/behaviour as the Plex
    /// `HeroOverlayView`, which forwards its scroll offset here in Discover mode.
    static let dotsParallaxFactor: CGFloat = 0.1

    func applyScrollOffset(_ offset: CGFloat) {
        let lift = -max(0, offset) * Self.dotsParallaxFactor
        pagingDotsBackground.transform = CGAffineTransform(translationX: 0, y: lift)
    }

    /// Per-item primary action (Discover): library-matched items get the
    /// Play pill; metadata-only items get the Watchlist pill (which also
    /// hides the redundant watchlist circle). `isOnWatchlist` drives both
    /// the pill's title/icon and the circle's icon.
    func setPrimaryAction(matchedInLibrary: Bool, isOnWatchlist: Bool) {
        buttonRow.primaryAction = matchedInLibrary ? .play : .watchlist
        buttonRow.isOnWatchlist = isOnWatchlist
    }

    // MARK: - Rendering

    private var displayedItem: MediaItem? {
        guard !items.isEmpty else { return nil }
        return items[max(0, min(displayedIndex, items.count - 1))]
    }

    private var currentItem: MediaItem? {
        guard !items.isEmpty else { return nil }
        return items[max(0, min(currentIndex, items.count - 1))]
    }

    private func renderSlide(onReady: (() -> Void)? = nil) {
        guard let item = displayedItem else {
            slideView.configure(item: nil)
            onReady?()
            return
        }
        slideView.configure(item: item, onReady: onReady)
    }

    private func renderPagingDots() {
        pagingDotsBackground.isHidden = items.count <= 1
        // Track the PRESS index (currentIndex), not the lagged metadata
        // (displayedIndex) — dots advance with the backdrop image on the click.
        pagingDots.update(count: items.count, activeIndex: currentIndex)
    }

    // MARK: - Paging

    private func setCurrentIndex(_ newIndex: Int) {
        guard newIndex != currentIndex else { return }
        currentIndex = newIndex
        if let item = currentItem { onIndexChanged?(newIndex, item) }
        buttonRow.canAdvance = items.count > 1
        // Advance the dots NOW, on the press, with the backdrop image.
        renderPagingDots()

        UIView.animate(withDuration: 0.15, delay: 0, options: [.curveEaseIn]) {
            self.slideView.alpha = 0
        }

        displayedSwapWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.displayedIndex = newIndex
            // Hold the slide hidden and fade in only once the logo is
            // resolved (loaded or absent) — same beat as the PlexMetadata
            // hero, so metadata never pops in ahead of its logo.
            self.slideView.alpha = 0
            self.renderSlide { [weak self] in
                guard let self else { return }
                UIView.animate(withDuration: 0.6, delay: 0, options: [.curveEaseOut]) {
                    self.slideView.alpha = 1
                }
            }
        }
        displayedSwapWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: - Buttons

    private func wireButtons() {
        buttonRow.onPlay = { [weak self] in
            guard let self, let item = self.currentItem else { return }
            self.onPlay?(item)
        }
        buttonRow.onInfo = { [weak self] in
            guard let self, let item = self.currentItem else { return }
            self.onInfo?(item)
        }
        buttonRow.onNext = { [weak self] in
            guard let self, self.items.count > 1 else { return }
            self.setCurrentIndex((self.currentIndex + 1) % self.items.count)
        }
        buttonRow.onWatchlist = { [weak self] in
            guard let self, let item = self.currentItem else { return }
            self.onToggleWatchlist?(item)
        }
        buttonRow.isOnWatchlist = false
    }
}

// MARK: - MediaItemSlideView

/// Logo + fallback title + metadata row + tagline. Mirrors HeroSlideView
/// but reads from MediaItem (artwork.logo, title, kind, year, overview).
@MainActor
private final class MediaItemSlideView: UIView {

    private let logoImageView = UIImageView()
    private let fallbackTitleLabel = UILabel()
    private let metadataLabel = UILabel()
    private let ratingBadge = HeroRatingBadgeView()
    private let metadataRow = UIStackView()
    private let taglineLabel = UILabel()
    private let stack = UIStackView()

    private var currentLogoURL: URL?
    private var logoLoadTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        translatesAutoresizingMaskIntoConstraints = false
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        logoImageView.contentMode = .scaleAspectFit
        logoImageView.translatesAutoresizingMaskIntoConstraints = false
        logoImageView.setContentHuggingPriority(.required, for: .horizontal)

        let baseFont = UIFont.systemFont(ofSize: 72, weight: .heavy)
        if let serifDescriptor = baseFont.fontDescriptor.withDesign(.serif) {
            fallbackTitleLabel.font = UIFont(descriptor: serifDescriptor, size: 72)
        } else {
            fallbackTitleLabel.font = baseFont
        }
        fallbackTitleLabel.textColor = .white
        fallbackTitleLabel.numberOfLines = 2
        fallbackTitleLabel.shadowColor = UIColor.black.withAlphaComponent(0.5)
        fallbackTitleLabel.shadowOffset = CGSize(width: 0, height: 3)
        fallbackTitleLabel.isHidden = true

        metadataLabel.font = .systemFont(ofSize: 20, weight: .medium)
        metadataLabel.textColor = UIColor.white.withAlphaComponent(0.9)
        metadataLabel.numberOfLines = 1

        metadataRow.axis = .horizontal
        metadataRow.spacing = 12
        metadataRow.alignment = .center
        metadataRow.addArrangedSubview(metadataLabel)
        metadataRow.addArrangedSubview(ratingBadge)
        ratingBadge.isHidden = true

        taglineLabel.font = .systemFont(ofSize: 22, weight: .regular)
        taglineLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        taglineLabel.numberOfLines = 2

        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(logoImageView)
        stack.addArrangedSubview(fallbackTitleLabel)
        stack.addArrangedSubview(metadataRow)
        stack.addArrangedSubview(taglineLabel)
        stack.setCustomSpacing(18, after: metadataRow)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),

            logoImageView.heightAnchor.constraint(lessThanOrEqualToConstant: 180),
            logoImageView.widthAnchor.constraint(lessThanOrEqualToConstant: 520),

            taglineLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 720)
        ])
    }

    func configure(item: MediaItem?, onReady: (() -> Void)? = nil) {
        guard let item else {
            logoImageView.image = nil
            logoImageView.isHidden = true
            fallbackTitleLabel.text = nil
            fallbackTitleLabel.isHidden = true
            metadataLabel.text = nil
            ratingBadge.isHidden = true
            taglineLabel.text = nil
            onReady?()
            return
        }

        // Metadata row
        metadataLabel.text = metaLine(for: item)
        if let rating = item.contentRating, !rating.isEmpty {
            ratingBadge.text = rating
            ratingBadge.isHidden = false
        } else {
            ratingBadge.text = nil
            ratingBadge.isHidden = true
        }

        // Tagline: overview first sentence.
        taglineLabel.text = tagline(for: item)

        // Logo / fallback title. TMDB-mapped items carry no logo URL in
        // their artwork (the list endpoints don't include images) — resolve
        // one from the TMDB images API via the shared cache, then load.
        if item.artwork.logo == nil, let tmdbID = item.tmdbID {
            // Prepare the fallback (hidden behind the caller's alpha hold)
            // but don't signal ready until the resolve completes — the hero
            // fades the whole slide in only once the logo outcome is known.
            loadLogo(from: nil, fallbackTitle: item.title)
            let itemID = item.ref.itemID
            currentResolveItemID = itemID
            let type: TMDBMediaType = item.kind == .movie ? .movie : .tv
            logoResolveTask?.cancel()
            logoResolveTask = Task { [weak self] in
                let url = await TMDBLogoCache.shared.logoURL(tmdbId: tmdbID, type: type)
                guard !Task.isCancelled, let self else { return }
                await MainActor.run {
                    guard self.currentResolveItemID == itemID else { return }
                    if let url {
                        self.loadLogo(from: url, fallbackTitle: item.title, onReady: onReady)
                    } else {
                        onReady?()  // no logo exists — fallback title is final
                    }
                }
            }
        } else {
            logoResolveTask?.cancel()
            currentResolveItemID = nil
            loadLogo(from: item.artwork.logo, fallbackTitle: item.title, onReady: onReady)
        }
    }

    private var logoResolveTask: Task<Void, Never>?
    private var currentResolveItemID: String?

    // MARK: - Logo loader

    private func loadLogo(from url: URL?, fallbackTitle: String, onReady: (() -> Void)? = nil) {
        logoLoadTask?.cancel()

        if url == currentLogoURL && logoImageView.image != nil {
            fallbackTitleLabel.text = fallbackTitle
            fallbackTitleLabel.isHidden = true
            logoImageView.isHidden = false
            onReady?()
            return
        }
        currentLogoURL = url

        guard let url else {
            logoImageView.image = nil
            logoImageView.isHidden = true
            fallbackTitleLabel.text = fallbackTitle
            fallbackTitleLabel.isHidden = false
            onReady?()
            return
        }

        logoImageView.image = nil
        logoImageView.isHidden = true
        fallbackTitleLabel.text = fallbackTitle
        fallbackTitleLabel.isHidden = false

        logoLoadTask = Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                guard self.currentLogoURL == url else { return }
                defer { onReady?() }
                if let image {
                    self.logoImageView.image = image
                    self.logoImageView.isHidden = false
                    self.fallbackTitleLabel.isHidden = true
                    self.logoImageView.alpha = 0
                    UIView.animate(withDuration: 0.22) { self.logoImageView.alpha = 1 }
                }
            }
        }
    }

    // MARK: - Helpers

    private func metaLine(for item: MediaItem) -> String? {
        var parts: [String] = []
        if let kindLabel = typeLabel(for: item.kind) { parts.append(kindLabel) }
        if let year = item.year { parts.append(String(year)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func typeLabel(for kind: MediaKind) -> String? {
        switch kind {
        case .movie: return "Movie"
        case .show: return "TV Show"
        case .season: return "Season"
        case .episode: return "Episode"
        default: return nil
        }
    }

    private func tagline(for item: MediaItem) -> String? {
        guard let overview = item.overview, !overview.isEmpty else { return nil }
        if let endIdx = overview.firstIndex(where: { ".!?".contains($0) }) {
            return String(overview[..<overview.index(after: endIdx)])
        }
        return overview
    }
}
