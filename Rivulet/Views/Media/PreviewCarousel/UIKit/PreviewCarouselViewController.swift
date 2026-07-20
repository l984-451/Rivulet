// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PreviewCarouselViewController.swift
//  Rivulet
//
//  UIKit replacement for `PreviewOverlayHost` + the surrounding
//  `PreviewContainerViewController` modal. Hosts a UICollectionView
//  with a custom `PreviewCarouselLayout` that gives every cell a
//  parallax-aware frame, then drives `contentOffset` directly via
//  `UIViewPropertyAnimator` for paging with the exact cubic timing
//  curve from the SwiftUI baseline.
//
//  Entry / dismiss morphs use a separate `morphSnapshot` view: a
//  PreviewCardView at the same size as the source poster tile,
//  morphed via spring to the centered carousel frame. The collection
//  view sits behind it and is revealed by a crossfade once the
//  morph completes.
//  UIKit home rows can also pass snapshots for every visible source tile.
//  Those snapshots animate into the carousel's visible card frames together,
//  so the row reads as enlarging into the carousel instead of a modal
//  appearing over it.
//
//  Visual goals:
//   - Smooth 60fps paging with parallax (artwork lags the card).
//   - No content swap mid-animation — every cell shows its item
//     throughout its visible lifetime.
//   - Entry + dismiss spring morphs match SwiftUI baseline timing.
//

import UIKit
import os.log

private let previewCarouselLog = Logger(
    subsystem: "com.rivulet.app",
    category: "PreviewCarouselUIKit"
)

final class PreviewCarouselViewController: UIViewController {
    // MARK: - Inputs

    private var items: [MediaItem]
    private(set) var selectedIndex: Int
    private let initialSourceFrame: CGRect
    private let entrySnapshots: [PreviewEntrySnapshot]
    private let sourceItemIDs: [String]?
    private let onPrepareDismiss: (PreviewSourceTarget?) -> Void
    private let onDismiss: (PreviewSourceTarget?) -> Void
    private var dismissSourceTarget: PreviewSourceTarget?

    // MARK: - State

    private(set) var state = PreviewStateMachine()
    private var hasRunEntryMorph = false
    private var hasPreparedEntrySnapshots = false
    private var didStandaloneExpand = false

    /// Clipping windows wrapping each entry snapshot. The morph animates
    /// these, not the snapshots (see EntryMorphWindowView). Parallel to
    /// `entrySnapshots` rather than keyed by item index, so repeated indices
    /// each keep their own window instead of one silently replacing another.
    private var entryMorphWindows: [(window: EntryMorphWindowView, itemIndex: Int, sourceFrame: CGRect)] = []

    /// CADisplayLink-driven paging state. Replaces UIViewPropertyAnimator
    /// because UIVPA's contentOffset interpolation doesn't trigger
    /// per-frame layout invalidation, which breaks parallax and
    /// off-screen cell pre-allocation.
    private struct PagingAnimation {
        let startOffset: CGFloat
        let endOffset: CGFloat
        let startTime: CFTimeInterval
        let duration: CFTimeInterval
        let targetIndex: Int
    }
    private var pagingAnimation: PagingAnimation?
    private var displayLink: CADisplayLink?

    /// Up/down swipe recognizers (touch surface). Held so the gesture delegate
    /// can tell them apart from the horizontal paging swipes, which are claimed
    /// unconditionally.
    private var verticalSwipeRecognizers: [UISwipeGestureRecognizer] = []

    // MARK: - Subviews

    private let backdrop = UIView()
    private let layout = PreviewCarouselLayout()
    private let expandedLayout = PreviewExpandedLayout()
    private var morphController: CarouselMorphController!
    private var collectionView: PinnableCollectionView!

    /// VC-owned backdrop plane — single source of truth for artwork.
    /// Sits behind the collection view; cells are transparent windows.
    private let backdropPlane = BackdropPlaneView()

    /// Invisible, always-focusable anchor. The carousel has no focusable
    /// cells (canFocusItemAt is false everywhere), and on tvOS PRESS EVENTS
    /// ARE DELIVERED TO THE FOCUSED VIEW and climb the responder chain from
    /// there — NOT to the first responder, and never to children of the
    /// focused view (WWDC 2016/210; UIKIT_FOUNDATIONS §2). With nothing
    /// focused inside this modal, Menu presses never enter our responder
    /// chain at all, so neither the .menu gesture recognizer nor presses*
    /// overrides ever fire — the presentation machinery handles Menu as a
    /// default modal-dismiss one layer up. This anchor gives the focus
    /// engine a target so the Menu press reaches our chain; the recognizer
    /// then "begins", emits pressesCancelled up the chain (which suppresses
    /// the system dismiss), and our handler runs collapse-vs-dismiss.
    private let focusAnchor = PreviewFocusAnchorView()

    /// Temporary card view used for the source-frame → centered-frame
    /// entry morph (and the reverse for dismiss). Sits on top of the
    /// collection view until the entry settles, then fades out as
    /// the real collection-view cell becomes visible underneath.
    private let morphSnapshot = PreviewCardView(frame: .zero)

    /// Source tile snapshots captured from the presenting row. These sit above
    /// the hidden live carousel during entry, animate to carousel card frames,
    /// then fade out as the real backdrop plane + cells fade in.
    private let entrySnapshotContainer = UIView()

    /// Below-fold detail surface. Sits ABOVE the collection view (which holds
    /// the hero chrome) and wakes up only after the expand morph completes.
    /// Hidden + non-interactive in carousel mode. Drives its own scroll
    /// choreography; calls back via `onScrollProgress` so the VC can fade the
    /// two layers it owns (the backdrop blur + the cell chrome).
    private let expandedDetail = ExpandedDetailContainerView()

    /// Backdrop blur that fades in as the user scrolls into the below-fold.
    /// Sits BELOW the chrome (blurs the artwork; chrome fades on top of it).
    /// Intensity is scrubbed via a paused property animator's
    /// `fractionComplete` (Iter 3) — NOT alpha (Apple: alpha on an effect
    /// view artifacts). `.regular` style matches HeroButtonRowView precedent.
    private let blurOverlay = UIVisualEffectView(effect: nil)
    /// Paused animator whose `fractionComplete` is the blur intensity. Built
    /// lazily when the blur is first armed (Iter 3).
    private var blurAnimator: UIViewPropertyAnimator?

    deinit {
        // A UIViewPropertyAnimator THROWS in dealloc if released while still in
        // the .active state. `blurAnimator` uses pausesOnCompletion = true, so it
        // sits in .active (paused) for the controller's whole life — it must be
        // stopped before the controller is torn down or the app aborts on dismiss.
        if blurAnimator?.state == .active { blurAnimator?.stopAnimation(true) }
    }

    /// Whether the centered card is currently in expanded layout.
    /// In `.expandingHero`/`.expandedHero`/`.detailsStable` this is
    /// true. Drives the custom layout (see `PreviewCarouselLayout`)
    /// to size the centered cell to fullscreen and hide side peeks.
    /// The cell's existing `chromeView` is the SAME view in both
    /// states — only its constraint constants animate (118→140 inset)
    /// and the contentView's corner radius animates (28→0). No
    /// reparenting, no second view tree, true visual continuity.
    private(set) var isExpanded: Bool = false

    /// True while a Down/Up below-fold scroll animation is in flight. Guards
    /// against overlapping scroll commands.
    private var isDetailScrolling = false

    // MARK: - Lifecycle

    /// Standalone "expanded detail" mode: seeded with a single item, opens
    /// already expanded (no carousel-stable browse, no paging), blur-fades in/out,
    /// and Menu dismisses the whole thing. Used to show a movie/show's full detail
    /// when drilled into (e.g. a Related poster) without building a second VC.
    private let standaloneDetail: Bool
    private let blurFade = BlurFadeTransitioningDelegate()

    init(
        items: [MediaItem],
        selectedIndex: Int,
        sourceFrame: CGRect,
        sourceTarget: PreviewSourceTarget?,
        entrySnapshots: [PreviewEntrySnapshot] = [],
        sourceItemIDs: [String]? = nil,
        standaloneDetail: Bool = false,
        onPrepareDismiss: @escaping (PreviewSourceTarget?) -> Void = { _ in },
        onDismiss: @escaping (PreviewSourceTarget?) -> Void
    ) {
        precondition(!items.isEmpty, "PreviewCarouselViewController requires at least one item")
        precondition(selectedIndex >= 0 && selectedIndex < items.count, "selectedIndex out of range")
        self.items = items
        self.selectedIndex = selectedIndex
        self.initialSourceFrame = sourceFrame
        self.entrySnapshots = entrySnapshots
        self.sourceItemIDs = sourceItemIDs?.count == items.count ? sourceItemIDs : nil
        self.onPrepareDismiss = onPrepareDismiss
        self.dismissSourceTarget = sourceTarget
        self.standaloneDetail = standaloneDetail
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
        if standaloneDetail {
            // Blur-fade in/out over whatever's behind (the previous detail), and
            // keep it visible — this is presented over another modal.
            self.modalPresentationStyle = .overFullScreen
            self.transitioningDelegate = blurFade
            return
        }
        // Keep the presenter alive behind us. The row-entry and row-exit
        // morphs need Home visible while source tile snapshots animate into
        // and out of the carousel. The explicit `backdrop` view below owns
        // the black surround and fades it in/out on the morph timeline.
        //
        // NOTE: presentation style does NOT control Menu dismissal. Menu flows
        // up the responder chain via pressesEnded reaching UIApplication
        // regardless of style. We own Menu by claiming first responder
        // (canBecomeFirstResponder + becomeFirstResponder in viewDidAppear) and
        // absorbing the press in our handler. See §2.
        self.modalPresentationStyle = .overFullScreen
        self.restoresFocusAfterTransition = false
        // No modal transition — the entry morph IS the transition.
        // The caller presents with animated: false so viewDidAppear
        // fires immediately for the spring animator.
        self.modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PreviewCarouselViewController is not Storyboard-backed")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.backgroundColor = .black
        backdrop.alpha = entrySnapshots.isEmpty ? 1 : 0

        view.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Backdrop plane sits behind the collection view (z-order:
        // backdrop-color -> plane -> collection view) so cells layer on top.
        backdropPlane.translatesAutoresizingMaskIntoConstraints = false
        backdropPlane.configure(items: items)
        view.addSubview(backdropPlane)
        NSLayoutConstraint.activate([
            backdropPlane.topAnchor.constraint(equalTo: view.topAnchor),
            backdropPlane.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropPlane.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdropPlane.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Backdrop blur sits above the plane (artwork), below the collection
        // view (chrome). Hidden until armed by the scroll choreography (Iter 3).
        blurOverlay.translatesAutoresizingMaskIntoConstraints = false
        blurOverlay.isUserInteractionEnabled = false
        blurOverlay.isHidden = true
        view.addSubview(blurOverlay)
        NSLayoutConstraint.activate([
            blurOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            blurOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            blurOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            blurOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        layout.itemCount = items.count
        collectionView = PinnableCollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.bounces = false
        collectionView.isScrollEnabled = false  // We drive offset manually.
        collectionView.remembersLastFocusedIndexPath = false
        collectionView.register(
            PreviewCardView.self,
            forCellWithReuseIdentifier: PreviewCardView.reuseIdentifier
        )
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        entrySnapshotContainer.translatesAutoresizingMaskIntoConstraints = false
        entrySnapshotContainer.isUserInteractionEnabled = false
        entrySnapshotContainer.isHidden = entrySnapshots.isEmpty
        view.addSubview(entrySnapshotContainer)
        NSLayoutConstraint.activate([
            entrySnapshotContainer.topAnchor.constraint(equalTo: view.topAnchor),
            entrySnapshotContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            entrySnapshotContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            entrySnapshotContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Below-fold detail surface above the collection view (chrome). Hidden
        // and inert until the expand morph completes. Full-screen; it manages
        // its own internal translation. onScrollProgress is wired in Iter 3 to
        // drive the blur + cell-chrome fade.
        expandedDetail.translatesAutoresizingMaskIntoConstraints = false
        expandedDetail.isHidden = true
        view.addSubview(expandedDetail)
        NSLayoutConstraint.activate([
            expandedDetail.topAnchor.constraint(equalTo: view.topAnchor),
            expandedDetail.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            expandedDetail.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            expandedDetail.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        // Scroll-into-details choreography the VC owns: backdrop blur + the
        // hero metadata (cell chrome) fade. Driven by the below-fold's scroll
        // progress (0→1 over reserveDistance).
        expandedDetail.onScrollProgress = { [weak self] progress in
            self?.driveHeroLayers(progress)
        }
        expandedDetail.onSelectSynopsis = { [weak self] detail in
            guard let self else { return }
            let content = InfoPopupContent.description(
                title: detail.item.title,
                subtitle: detail.genres.prefix(3).joined(separator: ", "),
                body: detail.item.overview)
            self.present(InfoPopupViewController(content: content, width: 840, scrollable: true), animated: true)
        }
        expandedDetail.onSelectAdvisory = { [weak self] advisory in
            let content = InfoPopupContent.advisory(advisory)
            self?.present(InfoPopupViewController(content: content, width: 720, scrollable: true), animated: true)
        }
        // Episode thumb Select → play the episode.
        expandedDetail.onPlayEpisode = { [weak self] episode in
            self?.playMediaItem(episode)
        }
        // Trailer / extra Select → play that video (by Plex ratingKey, no resume).
        expandedDetail.onPlayTrailer = { [weak self] trailer in
            self?.presentPlayer(ratingKey: trailer.id, resumeOffset: nil)
        }
        // Episode description Select → reusable detail page (blur-fade in Stage 3c).
        expandedDetail.onShowEpisodeDetails = { [weak self] episode in
            guard let self else { return }
            // seriesTitle nil for now — the show name comes from the episode's
            // fetched metadata (grandparentTitle) in Stage 3b, not the carousel's
            // selectedIndex item (which isn't reliably the show).
            let page = MediaItemDetailPageViewController(
                item: episode,
                seriesTitle: nil,
                onPlay: { [weak self] ep in self?.playMediaItem(ep) })
            self.present(page, animated: true)
        }

        // Related poster Select → the item's FULL expanded detail (movies/shows
        // always have trailers/extras/related below the fold), presented standalone
        // (no carousel) with a blur-fade. NOT the episode-only "just details" page.
        expandedDetail.onShowRelatedDetails = { [weak self] item in
            self?.presentStandaloneDetail(item)
        }
        // Cast / crew cell Select → person detail page (full-screen).
        expandedDetail.onSelectPerson = { [weak self] person in
            guard let self else { return }
            let page = PersonDetailViewController(person: person)
            page.onSelectItem = { [weak self] item in self?.presentPersonFilmographyItem(item) }
            self.present(page, animated: true)
        }

        expandedLayout.itemCount = items.count
        morphController = CarouselMorphController(
            collectionView: collectionView,
            backdropPlane: backdropPlane,
            carouselLayout: layout,
            expandedLayout: expandedLayout
        )
        // Let the below-fold peek's expand morph ride the morph animator.
        morphController.detailContainer = expandedDetail

        // Morph snapshot sits on top until entry settles.
        morphSnapshot.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(morphSnapshot)

        // Own the Menu button via a press gesture recognizer on our own
        // view. This is the reliable mechanism (see UIKIT_FOUNDATIONS §2):
        // a Menu press on a present()-ed modal otherwise reaches the
        // presentation controller's dismiss path IN PARALLEL to the press
        // responder chain — so absorbing it in pressesBegan/Ended/Cancelled
        // is not enough (the press arrives as pressesCancelled when our
        // collapse triggers a focus update mid-press, and the modal
        // dismisses anyway). A .menu tap recognizer on this view intercepts
        // the press first, letting handleMenuPress() decide collapse vs
        // dismiss.
        let menuRecognizer = UITapGestureRecognizer(target: self, action: #selector(menuGestureFired))
        menuRecognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        view.addGestureRecognizer(menuRecognizer)

        // Swipe-to-page. Paging previously keyed ONLY off .leftArrow/.rightArrow
        // presses, which a touch surface does not emit — a light swipe produces
        // indirect touches plus focus-engine moves, and arrow presses come from
        // directional CLICKS. Because the carousel is deliberately focusless
        // (`canFocusItemAt` is false in .carouselStable), a swipe also generated
        // no focus move, so it did nothing on any remote. These recognizers give
        // the swipe a home. Nothing to conflict with: with no focusable cells the
        // engine has no candidate to move to, so claiming the gesture steals
        // nothing.
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleCarouselSwipe(_:)))
            swipe.direction = direction
            swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            // On tvOS a swipe recognizer otherwise waits for a .select press.
            swipe.allowedPressTypes = []
            view.addGestureRecognizer(swipe)
        }

        // Swipe-up/down. The vertical choreography (carousel → hero → details,
        // pills → episodes, and every step back up) lived only in `pressesBegan`
        // under .upArrow/.downArrow, so a touch-surface swipe reached none of it
        // and the engine bonked with no candidate to move to.
        //
        // Unlike the horizontal case these CANNOT be claimed unconditionally:
        // inside the details the below-fold rows ARE focusable, and the engine
        // needs the swipe to walk between them. `gestureRecognizerShouldBegin`
        // therefore lets each recognizer begin only for the hand-off transitions
        // the engine cannot perform on its own.
        for direction in [UISwipeGestureRecognizer.Direction.up, .down] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleVerticalSwipe(_:)))
            swipe.direction = direction
            swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            swipe.allowedPressTypes = []
            swipe.delegate = self
            view.addGestureRecognizer(swipe)
            verticalSwipeRecognizers.append(swipe)
        }

        // Focus anchor: invisible, always-focusable, so the focus engine has
        // a target inside the modal and Menu presses enter our responder
        // chain (see the focusAnchor doc comment). Zero-size, behind
        // everything; it never shows and never steals visible focus.
        focusAnchor.frame = .zero
        view.addSubview(focusAnchor)

        previewCarouselLog.info("[PCV] viewDidLoad items=\(self.items.count, privacy: .public) selected=\(self.selectedIndex, privacy: .public)")
        // NOTE: do NOT force collectionView.layoutIfNeeded() here. `view`
        // has no real frame yet at viewDidLoad time (it's sized by the
        // presentation controller AFTER this runs) — forcing a layout pass
        // against a zero-width view collapses every cell's internal Auto
        // Layout (logged "UIView-Encapsulated-Layout-Width == 0" warnings)
        // and leaves PreviewCardView's chrome permanently mis-laid-out for
        // that dequeue, since the diffable/flow layout caches attributes
        // from this first (wrong) pass. The real, bounds-valid layout pass
        // happens in viewDidLayoutSubviews(); cellForItemAt still runs
        // synchronously there before the entry morph reads cell content.
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // `.fullScreen` presentation runs viewDidLayoutSubviews at least
        // once on a TRANSITIONAL pass before `view` has its real frame
        // (zero/garbage bounds). Writing `collectionView.contentOffset` in
        // that pass forces UICollectionView to lay out + dequeue cells
        // against those bad bounds, which collapses every PreviewCardView's
        // internal Auto Layout to zero width (logged as
        // "UIView-Encapsulated-Layout-Width == 0") and corrupts that
        // dequeue's chrome content for good — re-snapshotting it later
        // (entry/exit morphs) just captures the corrupted, zero-sized
        // content, which is why the carousel reads as black even though
        // entrySnapshots/backdropPlane/alpha timing are all correct.
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }

        // Center the carousel on `selectedIndex` so the first frame
        // shows the chosen item under the morph snapshot. We do this
        // every layout pass because `collectionViewContentSize`
        // depends on bounds and `bounds` can change (orientation,
        // focus shifts).
        let offset = layout.contentOffsetCentered(index: selectedIndex)
        collectionView.contentOffset = offset

        if !isExpanded {
            backdropPlane.sync(to: layout, offset: collectionView.contentOffset)
        }

        // Position the morph snapshot. Pre-entry: at the source
        // frame. Post-entry: hidden anyway.
        if !hasRunEntryMorph {
            backdrop.alpha = entrySnapshots.isEmpty ? 1 : 0
            backdropPlane.alpha = 0
            collectionView.alpha = 0
            if entrySnapshots.isEmpty {
                morphSnapshot.isHidden = false
                morphSnapshot.translatesAutoresizingMaskIntoConstraints = true
                morphSnapshot.frame = initialSourceFrame == .zero
                    ? centeredFrameInWindow()
                    : view.convert(initialSourceFrame, from: nil)
                // Show item[selectedIndex] in the snapshot so the morph
                // is visually meaningful.
                morphSnapshot.item = items.indices.contains(selectedIndex)
                    ? items[selectedIndex]
                    : nil
            } else {
                morphSnapshot.isHidden = true
                prepareEntrySnapshotsIfNeeded()
            }
        }

        // Standalone detail (e.g. a Related drill-in): open ALREADY expanded,
        // once, now that bounds are valid — the blur-fade presents the expanded
        // detail with no spring/card-grow morph.
        if standaloneDetail, !didStandaloneExpand, view.bounds.width > 0 {
            didStandaloneExpand = true
            hasRunEntryMorph = true
            enterStandaloneExpanded()
        }
    }

    /// Standalone entry: reveal (no spring) + apply the expanded end-state
    /// instantly, mirroring `expandCurrentCard` but with no animation.
    private func enterStandaloneExpanded() {
        guard !isExpanded, items.indices.contains(selectedIndex) else { return }
        // Reveal — mirror the `.zero`-source entry (no spring, no snapshot).
        morphSnapshot.isHidden = true
        backdrop.alpha = 1
        collectionView.alpha = 1
        backdropPlane.alpha = 1
        state.completeEntryMorph()                 // entryMorph → carouselStable
        updateCurrentCellChrome(animated: false)   // sets expandedDetail.item + chrome
        collectionView.layoutIfNeeded()
        // Expand instantly.
        let cell = collectionView.cellForItem(at: IndexPath(item: selectedIndex, section: 0)) as? PreviewCardView
        state.beginExpand()
        isExpanded = true
        cell?.setIsCurrent(true, animated: false)
        expandedDetail.setCurrent(true, animated: false)
        collectionView.pinnedOffsetX = collectionView.contentOffset.x
        morphController.expandInstantly(centeredIndex: selectedIndex, in: view.bounds, cell: cell) { [weak self] in
            guard let self else { return }
            self.state.finishExpand()
            self.expandedDetail.revealBelowFoldCollection()
            self.setNeedsFocusUpdate()
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // In the scrolled-in details state, focus lives in the real below-fold
        // collection (focus-driven nav + auto-scroll). Otherwise focus the
        // invisible anchor so Menu presses are delivered into our responder
        // chain (tvOS routes presses to the FOCUSED view; without a target the
        // modal would Menu-dismiss by default).
        if state.phase == .detailsStable, let env = expandedDetail.belowFoldFocusEnvironment {
            return [env]
        }
        // Expanded hero: focus the centered cell, which redirects into the Play
        // pill. Falls back to the anchor until the detail (action row) loads.
        if state.phase == .expandedHero,
           let cell = collectionView.cellForItem(at: IndexPath(item: selectedIndex, section: 0)) as? PreviewCardView,
           cell.actionFocusEnvironment != nil {
            return [cell]
        }
        return [focusAnchor]
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Drive focus to the anchor so the focus engine has a target inside
        // the modal. becomeFirstResponder is kept as belt-and-suspenders but
        // focus (not first-responder) is what makes presses reach us on tvOS.
        becomeFirstResponder()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        guard !hasRunEntryMorph else { return }
        hasRunEntryMorph = true

        if !entrySnapshots.isEmpty {
            runRowEntryMorph()
            return
        }

        if initialSourceFrame == .zero {
            // No source to morph from. Reveal the collection view
            // immediately and skip the spring.
            morphSnapshot.isHidden = true
            backdrop.alpha = 1
            collectionView.alpha = 1
            backdropPlane.alpha = 1
            state.completeEntryMorph()
            updateCurrentCellChrome(animated: false)
            return
        }

        let targetFrame = centeredFrameInWindow()

        // Spring: SwiftUI baseline (response 0.45, dampingRatio 0.88).
        // Translated to UISpringTimingParameters physics initializer
        // because tvOS lacks the dampingRatio:frequencyResponse:
        // convenience initializer (iOS 17+).
        //   mass = 1, ω = 2π/0.45 ≈ 13.96
        //   stiffness = ω² ≈ 195
        //   damping = 2 × 0.88 × √195 ≈ 24.58
        let timing = UISpringTimingParameters(
            mass: 1.0,
            stiffness: 195.0,
            damping: 24.58,
            initialVelocity: .zero
        )
        let morpher = UIViewPropertyAnimator(duration: 0.45, timingParameters: timing)
        morpher.addAnimations { [weak self] in
            guard let self else { return }
            self.morphSnapshot.frame = targetFrame
            self.backdrop.alpha = 1
            self.backdropPlane.alpha = 1
            self.collectionView.alpha = 1
        }
        morpher.addCompletion { [weak self] _ in
            guard let self else { return }
            self.morphSnapshot.isHidden = true
            self.state.completeEntryMorph()
            // Cascade in the chrome on the centered cell.
            self.updateCurrentCellChrome(animated: true)
        }
        morpher.startAnimation()
    }

    /// Refresh the `isCurrent` flag on every visible cell so the
    /// center one (at `selectedIndex`) gets its chrome cascade and
    /// the peeks stay bare.
    ///
    /// `animated: true` runs the page-cascade timing (140ms delay +
    /// 260ms easeOut for vignette, 210ms delay + 480ms easeOut for
    /// chrome). `animated: false` snaps the cell to invisible
    /// chrome — used on paging start to clear the outgoing center.
    private func updateCurrentCellChrome(animated: Bool) {
        for cell in collectionView.visibleCells {
            guard let card = cell as? PreviewCardView else { continue }
            guard let indexPath = collectionView.indexPath(for: cell) else { continue }
            let shouldBeCurrent = indexPath.item == selectedIndex
            card.setIsCurrent(shouldBeCurrent, animated: animated && shouldBeCurrent)
        }
        // Drive the below-fold peek for the centered card — it loads in WITH the
        // chrome cascade (P2: the peek is live in carousel-stable, not just
        // expanded). Item sync + cascade so paging snaps it out then re-cascades.
        expandedDetail.isHidden = false
        if items.indices.contains(selectedIndex) {
            expandedDetail.item = items[selectedIndex]
        }
        expandedDetail.setCurrent(true, animated: animated)
    }

    // MARK: - Geometry helpers

    /// Places (or re-places) the row snapshots at their source frames.
    /// `entry.sourceFrame` was captured in WINDOW coordinates by the
    /// presenter; converting it via `view.convert(_:from: nil)` only
    /// resolves correctly once `view.window` is non-nil. Called from
    /// `viewDidLayoutSubviews()`, which can fire before the view is attached
    /// to a window (pre-presentation layout) — so this re-syncs the frames
    /// on every pre-entry layout pass instead of computing them once and
    /// locking in a possibly-wrong (zero/garbage) result.
    private func prepareEntrySnapshotsIfNeeded() {
        guard view.window != nil else { return }
        entrySnapshotContainer.isHidden = false
        entrySnapshotContainer.alpha = 1

        if !hasPreparedEntrySnapshots {
            hasPreparedEntrySnapshots = true
            for entry in entrySnapshots.sorted(by: { $0.itemIndex < $1.itemIndex }) {
                let window = EntryMorphWindowView(
                    content: entry.snapshotView,
                    sourceSize: entry.sourceFrame.size
                )
                window.layer.cornerRadius = 16
                window.layer.zPosition = entry.itemIndex == selectedIndex
                    ? 100
                    : CGFloat(50 - abs(entry.itemIndex - selectedIndex))
                entryMorphWindows.append((window, entry.itemIndex, entry.sourceFrame))
                entrySnapshotContainer.addSubview(window)
            }
        }
        for entry in entryMorphWindows {
            entry.window.setWindow(view.convert(entry.sourceFrame, from: nil))
        }
    }

    private func runRowEntryMorph() {
        prepareEntrySnapshotsIfNeeded()

        // Ensure the live carousel is in its final first-frame position behind
        // the source snapshots before it fades in.
        collectionView.layoutIfNeeded()
        collectionView.contentOffset = layout.contentOffsetCentered(index: selectedIndex)
        backdropPlane.sync(to: layout, offset: collectionView.contentOffset)
        backdrop.alpha = 0
        backdropPlane.alpha = 0
        collectionView.alpha = 0
        entrySnapshotContainer.alpha = 1

        let timing = UISpringTimingParameters(
            mass: 1.0,
            stiffness: 195.0,
            damping: 24.58,
            initialVelocity: .zero
        )
        let morpher = UIViewPropertyAnimator(duration: 0.45, timingParameters: timing)
        morpher.addAnimations { [weak self] in
            guard let self else { return }
            for entry in self.entryMorphWindows {
                guard self.items.indices.contains(entry.itemIndex) else {
                    entry.window.alpha = 0
                    continue
                }
                entry.window.setWindow(self.carouselFrameInView(for: entry.itemIndex))
                entry.window.layer.cornerRadius = PreviewCarouselGeometry.cornerRadius
            }
        }
        morpher.addCompletion { [weak self] _ in
            guard let self else { return }
            for entry in self.entryMorphWindows {
                entry.window.removeFromSuperview()
            }
            self.entryMorphWindows.removeAll()
            self.entrySnapshotContainer.isHidden = true
            self.state.completeEntryMorph()
            self.updateCurrentCellChrome(animated: true)
        }
        morpher.startAnimation()

        UIView.animate(
            withDuration: 0.45,
            delay: 0,
            options: [.curveEaseInOut, .allowUserInteraction]
        ) { [weak self] in
            guard let self else { return }
            self.entrySnapshotContainer.alpha = 0
            self.backdrop.alpha = 1
            self.backdropPlane.alpha = 1
            self.collectionView.alpha = 1
        }
    }

    private func carouselFrameInView(for index: Int) -> CGRect {
        let geom = PreviewCarouselGeometry.self
        let centered = geom.centeredCardFrame(in: view.bounds)
        let stride = centered.width + geom.sideCardGap
        let selectedOffset = stride * CGFloat(selectedIndex)
        return centered.offsetBy(dx: stride * CGFloat(index) - selectedOffset, dy: 0)
    }

    /// Frame the centered cell occupies in the view's coordinate
    /// space. Used by the morph snapshot for its target frame.
    private func centeredFrameInWindow() -> CGRect {
        PreviewCarouselGeometry.centeredCardFrame(in: view.bounds)
    }

    // MARK: - Input handling

    // Must return true so this VC can become first responder and receive
    // pressesBegan. Without this, the collection view has no focusable
    // items (canFocusItemAt returns false) so UIKit never installs this VC
    // in the responder chain — Menu presses route to the presenter instead.
    override var canBecomeFirstResponder: Bool { return true }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        previewCarouselLog.info("[Lifecycle] viewWillDisappear isExpanded=\(self.isExpanded) presentingVC=\(self.presentingViewController != nil)")
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            // .menu is owned by the menu gesture recognizer (see viewDidLoad).
            case .rightArrow:
                // From an episode description, Left/Right jumps to the ADJACENT
                // episode's thumb (the description is a per-episode drill-down,
                // not a horizontal row). The engine can't reach the adjacent
                // thumb on its own (it sits fully above the description), so
                // redirect via a one-shot preferred-focus target.
                if state.phase == .detailsStable, expandedDetail.episodeDescriptionFocused,
                   expandedDetail.armAdjacentEpisodeThumb(forward: true) {
                    setNeedsFocusUpdate(); updateFocusIfNeeded()
                    expandedDetail.clearArmedEpisodeFocus()
                    return
                }
                // Only consume Left/Right to page the carousel. In the expanded
                // hero / details the focus engine must get them so the user can
                // move horizontally among season pills, episodes, cast, etc.
                if state.isCarouselInputEnabled { pageForward(); return }
            case .leftArrow:
                if state.phase == .detailsStable, expandedDetail.episodeDescriptionFocused,
                   expandedDetail.armAdjacentEpisodeThumb(forward: false) {
                    setNeedsFocusUpdate(); updateFocusIfNeeded()
                    expandedDetail.clearArmedEpisodeFocus()
                    return
                }
                if state.isCarouselInputEnabled { pageBackward(); return }
            case .select, .playPause:
                // Select OR Play/Pause on the centered card expands to
                // the fullscreen detail. Matches SwiftUI's
                // PreviewOverlayHost.swift:183-192 — both Tap and
                // Play/Pause call expandCurrentCard().
                if state.isCarouselInputEnabled {
                    expandCurrentCard()
                    return
                }
            case .downArrow:
                if handleDownNavigation() { return }
            case .upArrow:
                if handleUpNavigation() { return }
            default:
                break
            }
        }
        super.pressesBegan(presses, with: event)
    }

    // MARK: - Vertical navigation
    //
    // Shared by .upArrow/.downArrow PRESSES (d-pad / clickpad clicks) and by the
    // up/down SWIPE recognizers (touch surface, e.g. the iPhone remote), which
    // emit no arrow presses. Both call these, so the two input paths cannot
    // drift. Each returns true when it consumed the input; false means "not
    // ours" — the press falls through to the focus engine, and the swipe
    // recognizer refuses to begin so the engine sees the touches instead.

    /// Down: carousel → hero → below-fold details, and pills → episodes.
    @discardableResult
    private func handleDownNavigation() -> Bool {
        // Down from the carousel expands the centered card to the hero —
        // the mirror of Up (hero → carousel). Same action as Select, so
        // Down walks carousel → hero → details.
        if state.isCarouselInputEnabled {
            expandCurrentCard()
            return true
        }
        // Down from the expanded hero hands focus into the real
        // below-fold collection (focus-driven nav + auto-scroll, which
        // drives the hero choreography).
        if state.phase == .expandedHero {
            enterBelowFold()
            return true
        }
        // Down from the season pills drops focus into the episodes — at
        // the SELECTED season's first episode. The orthogonal rail was
        // scrolled there on pill-focus, but the focus engine still
        // remembers episode 0 / season 1; arm the preferred-focus target
        // across this update so it enters the current season instead.
        if state.phase == .detailsStable, expandedDetail.focusIsOnPills {
            expandedDetail.detailsFocusTarget = .episodes
            expandedDetail.armPillEntryFocus()
            setNeedsFocusUpdate(); updateFocusIfNeeded()
            expandedDetail.disarmPillEntryFocus()
            return true
        }
        return false
    }

    /// Up: episodes → pills → hero → carousel.
    @discardableResult
    private func handleUpNavigation() -> Bool {
        // Up choreography ONLY at the top of the details: pills → hero,
        // episodes → pills. From a LOWER section (Trailers/Related/Cast/
        // About/Info) we must NOT intercept — fall through to the focus
        // engine so it moves focus up ONE row. (The previous version
        // forced focus to the pills on every Up, so one Up from any lower
        // row jumped straight to the top.)
        if state.phase == .detailsStable {
            if expandedDetail.focusIsOnPills {
                // Already on the season pills → Up collapses to the hero.
                returnToHeroFromBelowFold()
                return true
            }
            if expandedDetail.focusIsOnEpisodes {
                // The primary row (episodes for shows, trailers/related for
                // movies) is the anchor: Up lands here first. If it JUST
                // took focus on THIS press (the engine moved focus up before
                // pressesBegan ran), stick on it — only a deliberate Up from
                // a RESTING primary row lifts to pills / collapses.
                //  - episodeThumbJustTookFocus: within-section description→thumb
                //    (no section change, so the section gate misses it).
                //  - episodesJustTookFocus: a lower row → primary section
                //    change (covers movies, where there's no episode thumb).
                if expandedDetail.episodeThumbJustTookFocus
                    || expandedDetail.episodesJustTookFocus { return true }
                if expandedDetail.hasSeasonPills {
                    // Episodes → lift to the pills. The pills are
                    // non-focusable while on the episodes, so the engine
                    // can't grab one; setting target=.pills enables them
                    // and drives focus to the SELECTED season's pill.
                    expandedDetail.detailsFocusTarget = .pills
                    setNeedsFocusUpdate(); updateFocusIfNeeded()
                } else {
                    returnToHeroFromBelowFold()   // no pills → straight to hero
                }
                return true
            }
            // Lower section: let the focus engine move up one row.
            return false
        }
        // Up from the expanded hero collapses to the carousel — the
        // mirror of Down (carousel → hero → details). Same path as Menu
        // from the hero, so Up and Back stay identical at every level.
        // In standalone detail the hero IS the top — Up does nothing; only
        // Back/Menu dismisses (there's no carousel to collapse to).
        if state.phase == .expandedHero {
            if standaloneDetail { return true }
            handleMenuPress()
            return true
        }
        return false
    }

    // MARK: - Playback

    /// Launch playback for a MediaItem (episode thumb Select): resolve the
    /// provider-agnostic MediaItem → a concrete `PlexMetadata` (with full Stream
    /// data for DV/HDR), build the player, and present it over the carousel.
    /// Returns to the detail when the player dismisses. No edit to the off-limits
    /// PlexHomeViewController — the carousel presents the player itself.
    /// Hero Play. For a show, play its on-deck episode (Plex OnDeck); a movie /
    /// episode plays directly.
    /// Present an item's FULL expanded detail standalone (no carousel) — reuses
    /// this same VC in `standaloneDetail` mode. Used for Related drill-ins.
    private func presentStandaloneDetail(_ item: MediaItem) {
        let detail = PreviewCarouselViewController(
            items: [item],
            selectedIndex: 0,
            sourceFrame: .zero,
            sourceTarget: nil,
            standaloneDetail: true,
            onDismiss: { _ in })
        var top: UIViewController = self
        while let presented = top.presentedViewController { top = presented }
        top.present(detail, animated: true)
    }

    /// Person filmography poster Select → open the item's full expanded detail.
    /// Server-backed and metadata-only items both go through `presentStandaloneDetail`:
    /// the carousel handles `isMetadataOnly` items already (Watchlist-primary chrome),
    /// so a single path covers both cases.
    private func presentPersonFilmographyItem(_ item: MediaItem) {
        presentStandaloneDetail(item)
    }

    /// Info button → structured info popup (scrollable), styled like our other
    /// popups but with Information / Languages / Accessibility sections.
    private func presentInfoPopup(_ detail: MediaItemDetail) {
        let content = InfoPopupContent.fullInfo(detail: detail)
        // Force the card size (skip the scroll-content measurement, which
        // under-reports and left the card small) — same fix as the Settings
        // Licenses popup.
        let popup = InfoPopupViewController(content: content, width: 900, height: 900, scrollable: true)
        var top: UIViewController = self
        while let presented = top.presentedViewController { top = presented }
        top.present(popup, animated: true)
    }

    /// Play on a show or a season has to resolve to an actual episode — neither
    /// has playable media of its own, and handing Plex a season ratingKey makes
    /// the transcode start hang until it times out.
    private func playHeroItem(_ item: MediaItem) {
        guard item.kind == .show || item.kind == .season else { playMediaItem(item); return }
        Task { [weak self] in
            guard let self,
                  let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID)
            else { return }
            let target = await EpisodePicker.resolvePlayTarget(for: item, provider: provider)
            await MainActor.run { self.playMediaItem(target ?? item) }
        }
    }

    private func playMediaItem(_ item: MediaItem) {
        let offsetSec = item.userState.viewOffset
        presentPlayer(ratingKey: item.ref.itemID, resumeOffset: offsetSec > 0 ? offsetSec : nil)
    }

    /// Resolve a Plex ratingKey → metadata → present the player. Used for the
    /// hero/episode play AND trailer/extra playback (resumeOffset nil for those).
    private func presentPlayer(ratingKey: String, resumeOffset: Double?) {
        Task { [weak self] in
            guard let serverURL = PlexAuthManager.shared.selectedServerURL,
                  let token = PlexAuthManager.shared.selectedServerToken else {
                previewCarouselLog.error("[PCV] play handoff: no server/token")
                return
            }
            let network = PlexNetworkManager.shared
            let playItem: PlexMetadata
            do {
                playItem = try await network.getFullMetadata(
                    serverURL: serverURL, authToken: token, ratingKey: ratingKey)
            } catch {
                do {
                    playItem = try await network.getMetadata(
                        serverURL: serverURL, authToken: token, ratingKey: ratingKey)
                } catch {
                    previewCarouselLog.error("[PCV] play handoff fetch failed: \(String(describing: error), privacy: .public)")
                    return
                }
            }
            await MainActor.run {
                guard let self else { return }
                let viewModel = UniversalPlayerViewModel(
                    metadata: playItem,
                    serverURL: serverURL,
                    authToken: token,
                    startOffset: resumeOffset
                )
                let playerVC = PlayerPresenter.makeViewController(viewModel: viewModel)
                // Present from the topmost VC so Play works both directly on the
                // carousel AND from the episode detail page presented over it.
                var top: UIViewController = self
                while let presented = top.presentedViewController { top = presented }
                top.present(playerVC, animated: true)
            }
        }
    }

    // NOTE: Menu is owned SOLELY by the .menu UITapGestureRecognizer
    // installed in viewDidLoad (see UIKIT_FOUNDATIONS §2 + Apple Forums
    // thread 42630 / openradar 25428691). We deliberately do NOT also
    // intercept .menu in pressesEnded/pressesCancelled: doing both makes the
    // responder-chain absorb race the recognizer, the recognizer never
    // recognizes, the press arrives cancelled, and the presentation
    // controller dismisses the modal anyway. With the recognizer as the
    // single owner, it claims the press (preventing the system dismiss) and
    // its action drives collapse-vs-dismiss. No pressesEnded/Cancelled
    // overrides needed.

    // MARK: - Paging

    /// Swiping the finger LEFT drags the strip leftward, revealing the NEXT
    /// card — same direction convention as a right-arrow press.
    @objc private func handleCarouselSwipe(_ gesture: UISwipeGestureRecognizer) {
        guard state.isCarouselInputEnabled else { return }
        switch gesture.direction {
        case .left:  pageForward()
        case .right: pageBackward()
        default:     break
        }
    }

    /// Touch-surface equivalent of an .upArrow / .downArrow press. Only ever
    /// begins for transitions `verticalSwipeWouldNavigate` vouched for, so it
    /// can drive the same choreography the presses do.
    @objc private func handleVerticalSwipe(_ gesture: UISwipeGestureRecognizer) {
        switch gesture.direction {
        case .down: handleDownNavigation()
        case .up:   handleUpNavigation()
        default:    break
        }
    }

    /// Whether a vertical swipe in the CURRENT state is a hand-off the focus
    /// engine cannot make by itself, and so should be claimed by the recognizer.
    ///
    /// This must stay conservative. In `.detailsStable` the below-fold rows are
    /// focusable and the engine moves between them on its own; claiming the
    /// gesture there would cancel that and break scrolling through the details.
    /// So we claim only the boundary transitions:
    ///   - down: carousel → hero, hero → below-fold, pills → episodes
    ///   - up:   episodes → pills, pills → hero, hero → carousel
    /// Everything else (a lower details row moving one row at a time) is left to
    /// the engine, which mirrors what the arrow-press handlers already do by
    /// falling through to `super.pressesBegan`.
    private func verticalSwipeWouldNavigate(_ direction: UISwipeGestureRecognizer.Direction) -> Bool {
        switch direction {
        case .down:
            if state.isCarouselInputEnabled { return true }
            if state.phase == .expandedHero { return true }
            if state.phase == .detailsStable, expandedDetail.focusIsOnPills { return true }
            return false
        case .up:
            if state.phase == .expandedHero { return true }
            if state.phase == .detailsStable {
                return expandedDetail.focusIsOnPills || expandedDetail.focusIsOnEpisodes
            }
            return false
        default:
            return false
        }
    }

    private func pageForward() {
        guard state.isCarouselInputEnabled else { return }
        guard pagingAnimation == nil else { return }
        guard selectedIndex < items.count - 1 else { return }
        animatePage(toIndex: selectedIndex + 1)
    }

    private func pageBackward() {
        guard state.isCarouselInputEnabled else { return }
        guard pagingAnimation == nil else { return }
        guard selectedIndex > 0 else { return }
        animatePage(toIndex: selectedIndex - 1)
    }

    /// Drive `contentOffset` toward the new index across the SwiftUI
    /// baseline cubic curve over 0.78s. Uses CADisplayLink + manual
    /// cubic-Bezier evaluation so layout invalidation happens every
    /// frame — required for parallax tracking and off-screen cell
    /// pre-allocation. `UIViewPropertyAnimator` interpolating
    /// contentOffset does not trigger per-frame layout passes.
    private func animatePage(toIndex newIndex: Int) {
        state.beginPaging()
        // Release the expand offset-pin so paging can move the carousel.
        collectionView.pinnedOffsetX = nil

        // Snap the outgoing center cell's chrome to invisible — no
        // fade-out. Matches SwiftUI behavior (vignette + metadata
        // snap to alpha 0 the moment paging begins).
        if let oldCenterCell = collectionView.cellForItem(at: IndexPath(item: selectedIndex, section: 0))
            as? PreviewCardView {
            oldCenterCell.setIsCurrent(false, animated: false)
        }
        // Snap the below-fold peek out too; it re-cascades for the new centered
        // item on paging completion (updateCurrentCellChrome).
        expandedDetail.setCurrent(false, animated: false)

        // Pre-warm the image for the new far-edge cell so the display
        // link's per-frame layout pass doesn't have to wait on an
        // async fetch when the cell scrolls into view. Without this,
        // the animation pauses ~halfway through while the dequeued
        // cell loads its artwork.
        let direction = newIndex > selectedIndex ? 1 : -1
        let prefetchIndex = newIndex + direction * 2
        if items.indices.contains(prefetchIndex) {
            let item = items[prefetchIndex]
            if let url = item.artwork.backdrop ?? item.artwork.poster {
                Task { _ = await ImageCacheManager.shared.image(for: url) }
            }
        }

        let start = collectionView.contentOffset.x
        let end = layout.contentOffsetCentered(index: newIndex).x
        pagingAnimation = PagingAnimation(
            startOffset: start,
            endOffset: end,
            startTime: CACurrentMediaTime(),
            duration: 0.78,
            targetIndex: newIndex
        )

        let link = CADisplayLink(target: self, selector: #selector(tickPagingAnimation))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tickPagingAnimation(_ link: CADisplayLink) {
        guard let anim = pagingAnimation else {
            link.invalidate()
            displayLink = nil
            return
        }

        let elapsed = CACurrentMediaTime() - anim.startTime
        let t = min(1.0, max(0.0, elapsed / anim.duration))
        // SwiftUI baseline cubic curve: control points (0.40, 0.02)
        // and (0.18, 1.0).
        let eased = cubicBezier(t: CGFloat(t), p1x: 0.40, p1y: 0.02, p2x: 0.18, p2y: 1.0)
        let x = anim.startOffset + (anim.endOffset - anim.startOffset) * eased
        // setContentOffset with animated: false issues a non-animated
        // scroll. UICollectionView responds by invalidating layout
        // (because shouldInvalidateLayout(forBoundsChange:) returns
        // true), which recomputes parallax + alpha for every visible
        // cell and queries layoutAttributesForElements with the new
        // viewport.
        collectionView.setContentOffset(CGPoint(x: x, y: 0), animated: false)
        backdropPlane.sync(to: layout, offset: collectionView.contentOffset)

        if t >= 1.0 {
            link.invalidate()
            displayLink = nil
            selectedIndex = anim.targetIndex
            dismissSourceTarget = makeSourceTarget(for: selectedIndex)
            pagingAnimation = nil
            state.finishPaging()
            // Cascade chrome on the new center cell.
            updateCurrentCellChrome(animated: true)
        }
    }

    /// Evaluate a 1-D cubic Bezier ease for x → y given control
    /// points (p1x, p1y) and (p2x, p2y) (with endpoints fixed at
    /// (0,0) and (1,1)).
    ///
    /// We solve for parameter `u` such that the x-coordinate of the
    /// cubic equals `t`, then return the y-coordinate at that u.
    /// Newton-Raphson + bisection fallback (10 iterations is plenty
    /// for animation precision).
    private func cubicBezier(t: CGFloat, p1x: CGFloat, p1y: CGFloat, p2x: CGFloat, p2y: CGFloat) -> CGFloat {
        // Coefficients for x(u) = ((1-u)^3 * 0) + 3 * (1-u)^2 * u * p1x + 3 * (1-u) * u^2 * p2x + u^3 * 1
        //        = (3 p1x - 3 p2x + 1) u^3 + (-6 p1x + 3 p2x) u^2 + (3 p1x) u
        let cx = 3 * p1x
        let bx = 3 * (p2x - p1x) - cx
        let ax = 1 - cx - bx

        let cy = 3 * p1y
        let by = 3 * (p2y - p1y) - cy
        let ay = 1 - cy - by

        // Find u such that x(u) == t. Newton-Raphson.
        var u = t
        for _ in 0..<10 {
            let x = ((ax * u + bx) * u + cx) * u
            let dx = (3 * ax * u + 2 * bx) * u + cx
            if abs(dx) < 1e-6 { break }
            let nextU = u - (x - t) / dx
            u = max(0, min(1, nextU))
        }

        return ((ay * u + by) * u + cy) * u
    }

    // MARK: - Menu + dismiss

    @objc private func menuGestureFired() {
        handleMenuPress()
    }

    private func handleMenuPress() {
        previewCarouselLog.info("[Menu] phase=\(String(describing: self.state.phase), privacy: .public) isExpanded=\(self.isExpanded)")
        // Menu/Back goes up ONE level. From the scrolled-in details that's the
        // expanded hero (NOT all the way to the carousel) — identical to Up from
        // the season pills, so the two controls behave the same.
        if state.phase == .detailsStable {
            returnToHeroFromBelowFold()
            return
        }
        let action = state.exitAction(standaloneDetail: standaloneDetail)
        previewCarouselLog.info("[Menu] action=\(String(describing: action), privacy: .public)")
        switch action {
        case .dismissOverlay:
            // Standalone detail has no carousel behind it — blur-fade dismiss
            // (the transitioningDelegate handles it) back to the previous detail.
            if standaloneDetail { dismiss(animated: true) }
            else { performDismissMorph() }
        case .collapseToCarousel:
            // Phase already transitioned to `.carouselStable` inside
            // `state.exitAction()`. Tear down the child VC. Iter C
            // adds the animated collapse cascade (frame shrink +
            // chrome cross-fade); Iter B is an instant teardown.
            collapseExpandedCard()
        }
    }

    // MARK: - Expand / Collapse

    /// Expand the centered card to fullscreen. State machine
    /// transitions through `.expandingHero` → `.expandedHero`. The
    /// custom layout reshapes the centered cell's frame to the
    /// collection view's full bounds; the cell's chromeView mutates
    /// its constraint constants (inset 118 → 140); the cell's
    /// `contentView.layer.cornerRadius` snaps 28 → 0. All happen
    /// inside one `UIView.animate(duration: 0.35, .curveEaseInOut)`.
    ///
    /// Critical: the cell view and the chrome view are the SAME
    /// instances throughout — no second view tree, no reparenting,
    /// no re-render. The animation is a constraint+frame tween on
    /// existing views. This is what gives true visual continuity
    /// matching SwiftUI's persistent-view-tree model.
    ///
    /// Iter B (this commit): instant (duration: 0). Iter C will add
    /// the 0.35s ease-in-out curve + 4-step cascade.
    private func expandCurrentCard() {
        guard !isExpanded else { return }
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]

        previewCarouselLog.info("[Expand] BEGIN idx=\(self.selectedIndex) ref=\(item.ref.itemID, privacy: .public)")

        state.beginExpand()
        isExpanded = true

        // Single-animator morph (CarouselMorphController): the cell window
        // (layout swap to PreviewExpandedLayout), the backdrop panel
        // container grow to fullscreen, the chrome insets 118->140, and the
        // corner-radius lerp 28->0 ALL run on one UIViewPropertyAnimator
        // curve. Nothing can drift. See
        // docs/superpowers/specs/2026-05-31-two-layout-carousel-morph-design.md.
        let cell = collectionView.cellForItem(at: IndexPath(item: selectedIndex, section: 0)) as? PreviewCardView
        // Complete the chrome cascade NOW so the metadata is fully present when
        // the morph starts. Entry items settle before you expand them; a
        // paged-to item expanded mid-cascade would have its metadata still
        // fading in while the backdrop just grows — the "metadata not aligning
        // with the background" artifact on non-first items. Snapping cancels the
        // in-flight fade and pins alpha 1 so only position morphs.
        cell?.setIsCurrent(true, animated: false)
        expandedDetail.setCurrent(true, animated: false)
        // Pin the carousel offset to the centered position for the WHOLE morph +
        // expanded state. The layout swap's deferred contentOffset zeroing would
        // otherwise throw the expanded cell (placed at content x = offset) off
        // the right edge for non-first items. Cleared on collapse.
        collectionView.pinnedOffsetX = collectionView.contentOffset.x
        morphController.expand(centeredIndex: selectedIndex, in: view.bounds, cell: cell) { [weak self] in
            guard let self else { return }
            self.state.finishExpand()
            // Reveal the real focus-driven below-fold (post-morph, §6).
            self.expandedDetail.revealBelowFoldCollection()
            self.setNeedsFocusUpdate()
        }
    }

    /// Down from the expanded hero: hand focus into the real below-fold
    /// collection. The focus engine moves to the first cell + auto-scrolls,
    /// which fires the collection's scroll → drives the hero choreography.
    private func enterBelowFold() {
        guard state.phase == .expandedHero else { return }
        state.markDetailsStable()
        // Always enter the details on the episodes (not stale on the pills from a
        // previous pills→hero→Down round-trip).
        expandedDetail.detailsFocusTarget = .episodes
        // The below-fold's scroll now drives the hero fade.
        expandedDetail.setBelowFoldScrollActive(true)
        // Slide the episodes up (timed) WITHOUT making the collection focusable
        // yet — otherwise the focus engine scrolls to its focused cell and
        // fights the slide (over-scrolling past the episodes, all the way to
        // Cast). The blur + metadata fade + logo ride this single movement.
        // Hand focus in only once the slide settles.
        expandedDetail.belowFoldCollection.slideToDetailsTop(animated: true) { [weak self] in
            guard let self else { return }
            self.expandedDetail.setBelowFoldInteractive(true)
            // Flush layout BEFORE asking for focus. The preferred-focus target
            // may be a deep episode in the orthogonal rail, and UIKit rejects a
            // preferred index path whose cell isn't realized yet (it throws
            // NSInternalInconsistencyException from _delegatePreferredIndexPath).
            // The rail positions itself in layoutSubviews, so run that first.
            self.expandedDetail.belowFoldCollection.layoutIfNeeded()
            self.setNeedsFocusUpdate()
            self.updateFocusIfNeeded()
            // Focus is now in the below-fold; make the faded chrome buttons
            // non-focusable so Up from the primary row can't escape into them
            // (which reads as "jumps back to the carousel").
            (self.collectionView.cellForItem(at: IndexPath(item: self.selectedIndex, section: 0)) as? PreviewCardView)?
                .setChromeActionRowFocusable(false)
        }
    }

    /// Up from the top of the below-fold: return focus to the hero, reset the
    /// collection to its peek position (→ scrollProgress 0, hero un-fades).
    private func returnToHeroFromBelowFold() {
        guard state.phase == .detailsStable else { return }
        state.returnToExpandedHero()
        // Re-enable the chrome buttons (disabled on enterBelowFold) BEFORE the
        // focus update, so focus can park back on the hero Play button.
        (collectionView.cellForItem(at: IndexPath(item: selectedIndex, section: 0)) as? PreviewCardView)?
            .setChromeActionRowFocusable(true)
        // Exact reverse of enterBelowFold: keep the below-fold scroll coupling LIVE
        // so the collection's slide back to the peek rest drives the hero fade-in
        // (blur out, chrome in, logo out, pills out) through the same single
        // chain — scrollViewDidScroll -> driveScrollProgress -> applyHeroProgress.
        // Make it non-focusable so focus parks on the hero anchor; the coupling is
        // torn down only once the slide completes.
        expandedDetail.setBelowFoldInteractive(false)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        expandedDetail.belowFoldCollection.slideToHeroRest(animated: true) { [weak self] in
            guard let self else { return }
            NSLog("RVCOLLAPSE slide-complete")
            self.expandedDetail.setBelowFoldScrollActive(false)
            self.setNeedsFocusUpdate()
            self.updateFocusIfNeeded()
        }
    }

    // MARK: - Hero layer choreography (backdrop blur + metadata fade)

    /// Drive the VC-owned hero layers from below-fold scroll progress (0→1):
    /// blur the backdrop in and fade the hero metadata (cell chrome) out.
    private func driveHeroLayers(_ progress: CGFloat) {
        let p = max(0, min(1, progress))
        blurOverlay.isHidden = p <= 0.01
        blurAnimatorIfNeeded().fractionComplete = min(0.999, max(0.001, p))

        // Metadata fades out faster than the blur fades in (gone by ~p=0.6).
        // Carousel metadata fades out FAST + early (gone by ~p=0.4) so it
        // clears before the top logo fades in (which starts later) — no overlap.
        let chromeAlpha = 1 - min(1, p * 2.6)
        (collectionView.cellForItem(at: IndexPath(item: selectedIndex, section: 0)) as? PreviewCardView)?
            .setHeroChromeAlpha(chromeAlpha)
    }

    /// Lazily build the paused blur animator. `fractionComplete` is the blur
    /// intensity (Apple's way to scrub a UIVisualEffectView — not alpha).
    private func blurAnimatorIfNeeded() -> UIViewPropertyAnimator {
        if let a = blurAnimator { return a }
        let a = UIViewPropertyAnimator(duration: 1, curve: .linear) { [weak self] in
            // ATV+ detail backdrop is a LIGHT frosted grey, not a dark blur.
            self?.blurOverlay.effect = UIBlurEffect(style: .regular)
        }
        a.pausesOnCompletion = true
        a.startAnimation()
        a.pauseAnimation()
        blurAnimator = a
        return a
    }

    /// Reverse of `expandCurrentCard`. Returns the centered cell to
    /// its carousel slot, restores chrome insets, restores corner
    /// radius — all on the same 0.35s ease-in-out curve.
    private func collapseExpandedCard() {
        guard isExpanded else { return }
        previewCarouselLog.info("[Collapse] BEGIN idx=\(self.selectedIndex)")

        isExpanded = false

        // Tear down the real below-fold collection (restore the placeholder
        // peek) before the collapse morph, and return the peek scroll to rest.
        expandedDetail.hideBelowFoldCollection()
        expandedDetail.reset()

        let cell = collectionView.cellForItem(at: IndexPath(item: selectedIndex, section: 0)) as? PreviewCardView
        morphController.collapse(centeredIndex: selectedIndex, cell: cell) { [weak self] in
            guard let self else { return }
            // Restore carousel-mode backdrop panels after collapse.
            self.backdropPlane.sync(to: self.layout, offset: self.collectionView.contentOffset)
            // Focus update AFTER the morph so a focus-driven animation never
            // runs concurrently with the morph curve.
            self.setNeedsFocusUpdate()
        }
    }

    /// Dismiss the overlay. If we entered via row snapshots, reverse that
    /// exact morph (`runRowExitMorph`) so exit mirrors entry. Otherwise the
    /// artwork lives in the VC-owned `backdropPlane` (not in the cell), so
    /// the old "fly a chrome-only PreviewCardView snapshot back to the
    /// source tile" reverse-entry morph desynced: the chrome snapshot flew
    /// off while the artwork plane sat orphaned ("metadata dismisses first,
    /// then the carousel"). In that case we fade ALL overlay layers
    /// together — backdrop plane (artwork), the collection view (chrome),
    /// and the black backdrop — on ONE animator, so everything leaves in
    /// lockstep.
    private func performDismissMorph() {
        onPrepareDismiss(dismissSourceTarget)
        if !entrySnapshots.isEmpty {
            runRowExitMorph()
            return
        }
        let animator = UIViewPropertyAnimator(
            duration: PreviewCarouselGeometry.expandAnimationDuration,
            curve: .easeInOut
        )
        animator.addAnimations { [weak self] in
            guard let self else { return }
            self.backdropPlane.alpha = 0
            self.collectionView.alpha = 0
            self.backdrop.alpha = 0
            self.expandedDetail.alpha = 0
        }
        animator.addCompletion { [weak self] _ in
            guard let self else { return }
            self.dismiss(animated: false) {
                self.onDismiss(self.dismissSourceTarget)
            }
        }
        animator.startAnimation()
    }

    /// Reverse of `runRowEntryMorph()`: re-snapshot the live carousel cards
    /// at their current carousel frames, then animate those snapshots back
    /// to their source row frames while the real backdrop/collection/detail
    /// layers fade out underneath — the exact inverse of the entry morph.
    private func runRowExitMorph() {
        entrySnapshotContainer.isHidden = false
        entrySnapshotContainer.alpha = 1

        // `PreviewCardView` is intentionally transparent — its artwork is
        // composited from the VC-owned `backdropPlane`, not drawn in the
        // cell itself (see PreviewCardView.swift). Snapshotting
        // `cellForItem(at:)` alone would capture chrome over nothing,
        // reading as empty/black. Render the full composited stack once
        // (backdrop + backdropPlane artwork + collection chrome) and crop
        // a piece per card instead.
        let compositeRenderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let composite = compositeRenderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }

        // Same clipping window as the entry morph, so shrinking back into a
        // portrait tile crops the composite instead of squashing it.
        var liveWindows: [(window: EntryMorphWindowView, sourceFrame: CGRect)] = []
        for entry in entrySnapshots {
            guard items.indices.contains(entry.itemIndex) else { continue }
            let cardFrame = carouselFrameInView(for: entry.itemIndex)
            guard cardFrame.width > 1, cardFrame.height > 1 else { continue }
            guard let cropped = composite.cgImage?.cropping(to: CGRect(
                x: cardFrame.minX * composite.scale,
                y: cardFrame.minY * composite.scale,
                width: cardFrame.width * composite.scale,
                height: cardFrame.height * composite.scale
            )) else { continue }
            let snapshot = UIImageView(image: UIImage(cgImage: cropped, scale: composite.scale, orientation: composite.imageOrientation))
            // Safe: the window keeps this box at the composite's aspect ratio.
            snapshot.contentMode = .scaleToFill
            let window = EntryMorphWindowView(content: snapshot, sourceSize: cardFrame.size)
            window.layer.cornerRadius = PreviewCarouselGeometry.cornerRadius
            window.layer.zPosition = entry.itemIndex == selectedIndex
                ? 100
                : CGFloat(50 - abs(entry.itemIndex - selectedIndex))
            window.setWindow(cardFrame)
            entrySnapshotContainer.addSubview(window)
            liveWindows.append((window, entry.sourceFrame))
        }

        backdropPlane.alpha = 0
        collectionView.alpha = 0
        expandedDetail.alpha = 0

        let timing = UISpringTimingParameters(
            mass: 1.0,
            stiffness: 195.0,
            damping: 24.58,
            initialVelocity: .zero
        )
        let morpher = UIViewPropertyAnimator(duration: 0.45, timingParameters: timing)
        morpher.addAnimations { [weak self] in
            guard let self else { return }
            for live in liveWindows {
                live.window.setWindow(self.view.convert(live.sourceFrame, from: nil))
                live.window.layer.cornerRadius = 16
                live.window.alpha = 0
            }
            self.backdrop.alpha = 0
        }
        morpher.addCompletion { [weak self] _ in
            guard let self else { return }
            self.dismiss(animated: false) {
                self.onDismiss(self.dismissSourceTarget)
            }
        }
        morpher.startAnimation()
    }

    private func makeSourceTarget(for index: Int) -> PreviewSourceTarget? {
        guard let existing = dismissSourceTarget,
              items.indices.contains(index) else { return dismissSourceTarget }
        if let sourceItemIDs, sourceItemIDs.indices.contains(index) {
            return PreviewSourceTarget(rowID: existing.rowID, itemID: sourceItemIDs[index])
        }
        let item = items[index]
        return PreviewSourceTarget(rowID: existing.rowID, itemID: item.ref.itemID)
    }
}

// MARK: - UIGestureRecognizerDelegate

extension PreviewCarouselViewController: UIGestureRecognizerDelegate {

    /// Gate the vertical swipes. On tvOS the focus engine reads the same
    /// indirect-touch stream a recognizer does, and a recognizer that reaches
    /// .began CANCELS the competing focus interaction. So a vertical swipe may
    /// only be claimed where the engine has nothing useful to do with it — the
    /// hand-off transitions in `verticalSwipeWouldNavigate`. Anywhere else
    /// (moving between the below-fold rows) we must decline and let the engine
    /// have the touches.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let swipe = gestureRecognizer as? UISwipeGestureRecognizer,
              verticalSwipeRecognizers.contains(where: { $0 === swipe })
        else { return true }
        return verticalSwipeWouldNavigate(swipe.direction)
    }
}

// MARK: - UICollectionViewDataSource / Delegate

extension PreviewCarouselViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: PreviewCardView.reuseIdentifier,
            for: indexPath
        ) as! PreviewCardView
        if items.indices.contains(indexPath.item) {
            cell.item = items[indexPath.item]
        }
        cell.onPlay = { [weak self] item in self?.playHeroItem(item) }
        cell.onShowInfo = { [weak self] detail in self?.presentInfoPopup(detail) }
        // Default to non-current; if this dequeued cell happens to be
        // at selectedIndex (e.g. on first viewport population), the
        // entry-morph completion or paging completion will flip it via
        // updateCurrentCellChrome.
        cell.setIsCurrent(indexPath.item == selectedIndex && hasRunEntryMorph,
                          animated: false)
        return cell
    }

    // Block the focus engine from auto-scrolling the collection view
    // — we drive scroll ourselves via animatePage so we can use the
    // exact cubic timing curve.
    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        // Carousel-stable is focusless (we drive paging ourselves, so the focus
        // engine must not auto-scroll). Only the EXPANDED HERO makes the centered
        // cell focusable so its action row (Play etc.) can take focus. In
        // detailsStable the cell must be UNFOCUSABLE: otherwise Up from the
        // episodes lets the focus engine jump back to this full-screen hero card
        // (it sits behind the below-fold) instead of reaching the season pills.
        return indexPath.item == selectedIndex && state.phase == .expandedHero
    }
}

/// Invisible, always-focusable anchor. Exists solely to give the tvOS focus
/// engine a target inside the focusless preview modal so Menu presses are
/// delivered into the VC's responder chain (presses go to the FOCUSED view
/// on tvOS, then climb the chain). It has zero size and draws nothing, so it
/// never shows and never competes with visible content for focus.
final class PreviewFocusAnchorView: UIView {
    override var canBecomeFocused: Bool { true }
}
