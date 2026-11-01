// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Home hero overlay: HeroSlideView, HeroButtonRowView and paging dots. Paging is the Apple TV app's:
// new metadata fades in over the last 0.42 s of a 1 s slide, auto-advancing every 5 s while focused
// or at the top. The backdrop is a sibling `HeroBackdropView`, driven by `onIndexChanged`.

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
    /// False while something covers Home (a player, a preview): the timer
    /// then waits for the next interval instead of paging unseen.
    var autoAdvanceGate: (() -> Bool)?

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

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // Stable identifier for focus diagnostics / UI automation.
        accessibilityIdentifier = "home.hero.overlay.9f27c1"
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
        // Back from the MediaItem path (Home after Jellyfin signs out): this
        // same cell was showing the MediaItem overlay over hidden Plex views.
        let switchingRows = buttonRow.isHidden
        slideView.isHidden = false
        buttonRow.isHidden = false
        mediaItemOverlay?.isHidden = true
        renderSlide(animated: false)
        updateButtonStateForCurrentItem()
        renderPagingDots()
        prefetchNextBackdrop()
        updateAutoAdvanceTimer()
        if switchingRows { moveFocusToVisibleRow() }
    }

    // MARK: - Scroll

    /// Apple's showcase transition: as the page scrolls from the hero (`p` 1)
    /// to the shelves (`p` 0), the text and dots rise faster than the content.
    func applyShowcase(_ p: CGFloat) {
        let lift = CGAffineTransform(translationX: 0, y: -(1 - p) * Self.showcaseTextLift)
        slideView.transform = lift
        buttonRow.transform = lift
        pagingDotsBackground.transform = lift
        mediaItemOverlay?.applyShowcase(p)
        let wasAtTop = showcasePercentage == 1
        showcasePercentage = p
        if wasAtTop != (p == 1) { updateAutoAdvanceTimer() }
    }

    /// Apple lifts 120 from a stack resting ~30 pt lower than ours; 80 puts the
    /// buttons where Apple's sit on the first shelf (y ~120).
    static let showcaseTextLift: CGFloat = 80

    // MARK: - Auto-advance

    private var focusInHero = false
    private var showcasePercentage: CGFloat = 1
    private var autoAdvanceTimer: Timer?

    /// Longer than Apple's image-only 5 s: Apple's hero usually plays a trailer
    /// first, and ours is image-only, so 5 s read as rushed.
    static let autoAdvanceInterval: TimeInterval = 8

    private var pageCount: Int {
        if let mediaItemOverlay, !mediaItemOverlay.isHidden { return mediaItemOverlay.pageCount }
        return items.count
    }

    /// Restarted on every page change and every focus move inside the hero.
    /// Runs while focus is in the hero or the page sits at the top; focus on a
    /// shelf stops it. The active page dot fills with it.
    fileprivate func updateAutoAdvanceTimer() {
        autoAdvanceTimer?.invalidate()
        autoAdvanceTimer = nil
        let running = pageCount > 1 && (focusInHero || showcasePercentage == 1)
        let duration = running ? Self.autoAdvanceInterval : nil
        pagingDots.setProgress(duration: duration)
        mediaItemOverlay?.setDotProgress(duration: duration)
        guard running else { return }
        autoAdvanceTimer = Timer.scheduledTimer(withTimeInterval: Self.autoAdvanceInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoAdvance() }
        }
    }

    private func autoAdvance() {
        guard window != nil, autoAdvanceGate?() ?? true else {
            updateAutoAdvanceTimer()
            return
        }
        if let mediaItemOverlay, !mediaItemOverlay.isHidden { mediaItemOverlay.advance() } else { advance() }
    }

    private func prefetchNextBackdrop() {
        guard items.count > 1 else { return }
        let next = items[(currentIndex + 1) % items.count]
        let request = next.heroBackdropRequest(serverURL: serverURL, authToken: authToken)
        if let url = request.backdropURL ?? request.thumbnailURL {
            Task { await ImageCacheManager.shared.prefetch(urls: [url], quality: .full) }
        }
    }

    // MARK: - Focus

    override var canBecomeFocused: Bool { false }

    /// Forward focus into the visible button row so the focus engine can
    /// find `play` as the default landing target.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let mediaItemOverlay, !mediaItemOverlay.isHidden { return [mediaItemOverlay] }
        return [buttonRow]
    }

    /// The cell flips between the Plex and MediaItem overlays when Home's hero
    /// source changes (a second server's rows arrive). Hiding a row does not
    /// move focus off its Play, which then takes no presses and draws as
    /// unfocused, so re-ask while focus is still inside. No forced update:
    /// this runs inside a cell configure, mid snapshot apply.
    private func moveFocusToVisibleRow() {
        setNeedsFocusUpdate()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let nextInside = context.nextFocusedView?.isDescendant(of: self) == true
        let prevInside = context.previouslyFocusedView?.isDescendant(of: self) == true
        if nextInside, !prevInside {
            onFocusEntered?()
        }
        if nextInside || nextInside != focusInHero {
            focusInHero = nextInside
            updateAutoAdvanceTimer()
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

    private func renderPagingDots() {
        pagingDotsBackground.isHidden = items.count <= 1
        // Dots track the PRESS index (currentIndex), not the lagged metadata
        // (displayedIndex), so they advance with the backdrop image on the
        // click rather than 600ms later when the metadata swaps in.
        pagingDots.update(count: items.count, activeIndex: currentIndex)
    }

    // MARK: - Paging (button -> currentIndex -> backdrop -> delayed slide swap)

    private func advance() {
        guard items.count > 1 else { return }
        let next = (currentIndex + 1) % items.count
        setCurrentIndex(next)
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
        prefetchNextBackdrop()
        updateAutoAdvanceTimer()

        // The old metadata leaves with its page.
        HeroPageMotion.slideOut(slideView, in: self)

        // The new metadata fades in over the slide's last 0.42 s. renderSlide is
        // animated:false here (the old is already gone); we hold alpha at 0 and
        // drive the fade-in ourselves.
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
                UIView.animate(withDuration: HeroPageMotion.metadataFade, delay: 0, options: [.curveEaseOut]) {
                    self.slideView.alpha = 1
                }
            }
        }
        displayedSwapWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + HeroPageMotion.metadataDelay, execute: work)
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

    // MARK: - MediaItem path

    /// Installs the MediaItem overlay (a lazily created `MediaItemHeroOverlayView` pinned to our
    /// edges) and wires its callbacks.
    func configure(
        mediaItems: [MediaItem],
        initialIndex: Int,
        onIndexChanged: @escaping (Int, MediaItem) -> Void,
        onPlay: @escaping (MediaItem) -> Void,
        onInfo: @escaping (MediaItem) -> Void,
        onToggleWatchlist: ((MediaItem) -> Void)? = nil,
        badge: ((MediaItem) -> String?)? = nil
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
        let switchingRows = !buttonRow.isHidden
        slideView.isHidden = true
        buttonRow.isHidden = true
        pagingDotsBackground.isHidden = true

        mediaItemOverlay?.isHidden = false
        mediaItemOverlay?.onPaged = { [weak self] in self?.updateAutoAdvanceTimer() }
        mediaItemOverlay?.onToggleWatchlist = onToggleWatchlist
        mediaItemOverlay?.badge = badge
        mediaItemOverlay?.configure(
            items: mediaItems,
            initialIndex: initialIndex,
            onIndexChanged: onIndexChanged,
            onPlay: onPlay,
            onInfo: onInfo
        )
        updateAutoAdvanceTimer()
        if switchingRows { moveFocusToVisibleRow() }
    }

    /// Forward per-item primary-action state to the MediaItem overlay
    /// (no-op in PlexMetadata mode).
    func setMediaItemPrimaryAction(matchedInLibrary: Bool, isOnWatchlist: Bool, canWatchlist: Bool = true) {
        mediaItemOverlay?.setPrimaryAction(matchedInLibrary: matchedInLibrary, isOnWatchlist: isOnWatchlist,
                                           canWatchlist: canWatchlist)
    }

    private var mediaItemOverlay: MediaItemHeroOverlayView?
}

// MARK: - MediaItemHeroOverlayView

/// Hero overlay for MediaItem data, laid out like HeroOverlayView with the same HeroButtonRowView.
/// Play calls `onPlay` directly, without HeroPlaySession resolution.
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
    /// nil hides the watchlist circle: only Discover has a watchlist to
    /// toggle from the hero.
    var onToggleWatchlist: ((MediaItem) -> Void)? {
        didSet { syncWatchlistCircle() }
    }
    var badge: ((MediaItem) -> String?)?
    /// Every page change, so the parent restarts its auto-advance timer.
    var onPaged: (() -> Void)?

    var pageCount: Int { items.count }

    func setDotProgress(duration: TimeInterval?) { pagingDots.setProgress(duration: duration) }

    // MARK: - Subviews (layout mirrors HeroOverlayView)

    private let slideView = MediaItemSlideView()
    private let buttonRow = HeroButtonRowView()
    private let pagingDotsBackground = UIView()
    private let pagingDots = HeroPagingDotsView()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // Stable identifier for focus diagnostics / UI automation.
        accessibilityIdentifier = "detail.hero.overlay.9f27c1"
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
        prefetchNextBackdrop()
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

    // MARK: - Scroll

    /// Same showcase lift as `HeroOverlayView.applyShowcase`.
    func applyShowcase(_ p: CGFloat) {
        let lift = CGAffineTransform(translationX: 0, y: -(1 - p) * HeroOverlayView.showcaseTextLift)
        slideView.transform = lift
        buttonRow.transform = lift
        pagingDotsBackground.transform = lift
    }

    /// Per-item primary action (Discover): library-matched items get the
    /// Play pill; metadata-only items get the Watchlist pill (which also
    /// hides the redundant watchlist circle). `isOnWatchlist` drives both
    /// the pill's title/icon and the circle's icon. `canWatchlist` is false
    /// for a slide whose server keeps no watchlist (Jellyfin on a mixed Home).
    func setPrimaryAction(matchedInLibrary: Bool, isOnWatchlist: Bool, canWatchlist: Bool = true) {
        buttonRow.primaryAction = matchedInLibrary ? .play : .watchlist
        buttonRow.isOnWatchlist = isOnWatchlist
        self.canWatchlist = canWatchlist
        syncWatchlistCircle()
    }

    private var canWatchlist = true

    /// Nothing to toggle hides the circle; otherwise it follows the pill as
    /// `HeroButtonRowView.renderPrimaryAction` does (the `.watchlist` pill
    /// makes it redundant), so Discover is unchanged.
    private func syncWatchlistCircle() {
        buttonRow.watchlistButton.isHidden = onToggleWatchlist == nil || !canWatchlist
            || buttonRow.primaryAction == .watchlist
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
        slideView.configure(item: item, badge: badge?(item), onReady: onReady)
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
        prefetchNextBackdrop()
        onPaged?()

        HeroPageMotion.slideOut(slideView, in: self)

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
                UIView.animate(withDuration: HeroPageMotion.metadataFade, delay: 0, options: [.curveEaseOut]) {
                    self.slideView.alpha = 1
                }
            }
        }
        displayedSwapWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + HeroPageMotion.metadataDelay, execute: work)
    }

    func advance() {
        guard items.count > 1 else { return }
        setCurrentIndex((currentIndex + 1) % items.count)
    }

    private func prefetchNextBackdrop() {
        guard items.count > 1 else { return }
        let next = items[(currentIndex + 1) % items.count].heroBackdropRequest()
        if let url = next.backdropURL ?? next.thumbnailURL {
            Task { await ImageCacheManager.shared.prefetch(urls: [url], quality: .full) }
        }
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
        buttonRow.onNext = { [weak self] in self?.advance() }
        buttonRow.onWatchlist = { [weak self] in
            guard let self, let item = self.currentItem else { return }
            self.onToggleWatchlist?(item)
        }
        buttonRow.isOnWatchlist = false
    }
}

// MARK: - Page motion

/// The Apple TV app's hero page change (VideosUI, tvOS 26.5).
@MainActor
enum HeroPageMotion {
    /// The new metadata fades in over the last 0.42 s of the 1 s slide.
    static let metadataFade: TimeInterval = 0.42
    static let metadataDelay: TimeInterval = 1.0 - metadataFade

    /// Slides a snapshot of `view` off the leading edge with the backdrop's
    /// page spring, and hides the live view for the swap.
    static func slideOut(_ view: UIView, in container: UIView) {
        defer { view.alpha = 0 }
        guard view.alpha > 0, let snapshot = view.snapshotView(afterScreenUpdates: false) else { return }
        snapshot.frame = view.frame
        snapshot.isUserInteractionEnabled = false
        container.insertSubview(snapshot, aboveSubview: view)
        let animator = HeroBackdropView.pageAnimator()
        animator.addAnimations {
            snapshot.transform = CGAffineTransform(translationX: -container.bounds.width, y: 0)
        }
        animator.addCompletion { _ in snapshot.removeFromSuperview() }
        animator.startAnimation()
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
    private let sourceBadge = SourceBadgeView(style: .inline)
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

        // Apple's genres row: Caption1 (25) medium at full white, 6 pt to the badge.
        metadataLabel.font = .systemFont(ofSize: 25, weight: .medium)
        metadataLabel.textColor = .white
        metadataLabel.numberOfLines = 1

        metadataRow.axis = .horizontal
        metadataRow.spacing = 6
        metadataRow.alignment = .center
        metadataRow.addArrangedSubview(sourceBadge)
        metadataRow.addArrangedSubview(metadataLabel)
        metadataRow.addArrangedSubview(ratingBadge)
        ratingBadge.isHidden = true

        taglineLabel.font = .systemFont(ofSize: 22, weight: .regular)
        taglineLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        taglineLabel.numberOfLines = 2

        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(logoImageView)
        stack.addArrangedSubview(fallbackTitleLabel)
        stack.addArrangedSubview(metadataRow)
        stack.addArrangedSubview(taglineLabel)

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

    func configure(item: MediaItem?, badge: String? = nil, onReady: (() -> Void)? = nil) {
        sourceBadge.text = badge
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

        // An episode's slide is its show's: the show's logo and name.
        let title = item.kind == .episode ? (item.seriesTitle ?? item.title) : item.title
        let logo = item.grandparentArtwork?.logo ?? item.artwork.logo

        // Logo / fallback title. TMDB-mapped items carry no logo URL in
        // their artwork (the list endpoints don't include images) — resolve
        // one from the TMDB images API via the shared cache, then load.
        if logo == nil, let tmdbID = item.tmdbID {
            // Prepare the fallback (hidden behind the caller's alpha hold)
            // but don't signal ready until the resolve completes — the hero
            // fades the whole slide in only once the logo outcome is known.
            loadLogo(from: nil, fallbackTitle: title)
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
                        self.loadLogo(from: url, fallbackTitle: title, onReady: onReady)
                    } else {
                        onReady?()  // no logo exists — fallback title is final
                    }
                }
            }
        } else {
            logoResolveTask?.cancel()
            currentResolveItemID = nil
            loadLogo(from: logo, fallbackTitle: title, onReady: onReady)
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

    /// Same labels as the Plex hero (`HeroSlideView`): a season or episode
    /// slide is the show's, so it reads "TV Show", without the episode's year.
    /// An episode adds which one it is.
    private func metaLine(for item: MediaItem) -> String? {
        var parts: [String] = []
        if let kindLabel = typeLabel(for: item.kind) { parts.append(kindLabel) }
        if item.kind != .season, item.kind != .episode, let year = item.year { parts.append(String(year)) }
        if item.kind == .episode {
            if let s = item.seasonNumber, let e = item.episodeNumber { parts.append("S\(s), E\(e)") }
            if item.seriesTitle != nil { parts.append(item.title) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func typeLabel(for kind: MediaKind) -> String? {
        switch kind {
        case .movie: return "Movie"
        case .show, .season, .episode: return "TV Show"
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
