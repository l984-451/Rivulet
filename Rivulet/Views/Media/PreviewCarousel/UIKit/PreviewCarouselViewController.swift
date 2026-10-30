// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  The preview carousel modal: a paging card carousel over `PreviewCarouselLayout`
//  that expands into the full detail. Entry and dismiss morph the source row's
//  tile snapshots (or one `morphSnapshot`) to and from the card frames.

import Combine
import Sentry
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
    /// The source row's tiles as they are now, for the exit after paging.
    var freshEntrySnapshots: ((PreviewSourceTarget?) -> [PreviewEntrySnapshot])?
    /// Runs once however the carousel goes away: the presenter un-hides its tiles.
    var onTeardown: (() -> Void)?

    // MARK: - State

    private(set) var state = PreviewStateMachine()
    private var hasRunEntryMorph = false
    private var hasPreparedEntrySnapshots = false
    private var didStandaloneExpand = false

    /// Clipping windows around each entry snapshot; the morph animates these.
    /// Parallel to `entrySnapshots`, not keyed by index, so repeated indices each keep a window.
    private var entryMorphWindows: [(window: EntryMorphWindowView, itemIndex: Int, sourceFrame: CGRect)] = []

    /// Display-link paging state. A property animator on contentOffset skips per-frame
    /// layout invalidation, which breaks parallax and off-screen cell allocation.
    private struct PagingAnimation {
        let startOffset: CGFloat
        let endOffset: CGFloat
        let startTime: CFTimeInterval
        let duration: CFTimeInterval
        let targetIndex: Int
        /// Ease-in control point; raised on a retarget so the glide keeps its speed.
        var p1y: CGFloat = 0.02
    }
    private var pagingAnimation: PagingAnimation?
    private var displayLink: CADisplayLink?

    /// Held so the gesture delegate can tell them from the horizontal paging swipes.
    private var verticalSwipeRecognizers: [UISwipeGestureRecognizer] = []
    /// Whether focus rested on the details' top row when the current touch began.
    /// A long swipe from a lower row walks focus up to it mid-gesture, and must not
    /// then also collapse the details when the swipe completes.
    private var touchBeganOnDetailsTopRow = false

    // MARK: - Subviews

    private let backdrop = UIView()
    private let layout = PreviewCarouselLayout()
    private let expandedLayout = PreviewExpandedLayout()
    private var morphController: CarouselMorphController!
    private var collectionView: PinnableCollectionView!

    /// The one owner of artwork, behind the collection view; cells are transparent windows.
    private let backdropPlane = BackdropPlaneView()

    /// Invisible focus target. tvOS delivers presses to the focused view, and no
    /// carousel cell is focusable, so without this Menu never reaches our chain
    /// and the system dismisses the modal (UIKIT_FOUNDATIONS §2).
    private let focusAnchor = PreviewFocusAnchorView()

    /// Single card used for the entry and dismiss morph when there are no row snapshots.
    private let morphSnapshot = PreviewCardView(frame: .zero)

    /// Holds the presenting row's tile snapshots while they morph to the card frames.
    private let entrySnapshotContainer = UIView()

    /// Below-fold detail, above the collection view. Inert until the expand morph
    /// ends; reports `onScrollProgress` so the VC fades the blur and the cell chrome.
    private let expandedDetail = ExpandedDetailContainerView()
    private var themeOwnerID: String?
    private var themeTask: Task<Void, Never>?

    private func activateVisibleTheme() {
        guard isViewLoaded, view.window != nil, presentedViewController == nil,
              items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) as? SiloProvider,
              SiloSession.account?.providerID == provider.id,
              SiloSession.authorityRevision == provider.authorityRevision else { stopVisibleTheme(); return }
        if themeOwnerID == item.ref.itemID { return }
        stopVisibleTheme()
        themeOwnerID = item.ref.itemID
        themeTask = Task { [weak self] in
            await SiloThemeMusicController.shared.refresh(provider: provider)
            guard let self, !Task.isCancelled, self.themeOwnerID == item.ref.itemID,
                  self.view.window != nil, self.presentedViewController == nil,
                  self.items.indices.contains(self.selectedIndex),
                  self.items[self.selectedIndex].ref == item.ref else { return }
            await SiloThemeMusicController.shared.activate(ownerID: item.ref.itemID, provider: provider)
        }
    }

    private func stopVisibleTheme() {
        themeTask?.cancel()
        themeTask = nil
        themeOwnerID = nil
        SiloThemeMusicController.shared.stop()
    }

    /// Blur under the chrome, scrubbed by a paused animator's `fractionComplete`.
    /// Not by alpha: alpha on an effect view artifacts.
    private let blurOverlay = UIVisualEffectView(effect: nil)
    /// Paused animator whose `fractionComplete` is the blur intensity; built on first arm.
    private var blurAnimator: UIViewPropertyAnimator?

    deinit {
        // A property animator released while .active throws. `blurAnimator` stays
        // paused (.active) for the VC's life, so stop it or dismiss aborts the app.
        if blurAnimator?.state == .active { blurAnimator?.stopAnimation(true) }
        onTeardown?()
    }

    private func teardown() {
        stopVisibleTheme()
        onTeardown?()
        onTeardown = nil
    }

    /// True in `.expandingHero`, `.expandedHero` and `.detailsStable`: the centered
    /// card is full screen. The cell keeps one `chromeView`; only its insets and radius animate.
    private(set) var isExpanded: Bool = false

    /// True while a Down/Up below-fold scroll animation is in flight. Guards
    /// against overlapping scroll commands.
    private var isDetailScrolling = false

    /// Watch-state refresh subscription (issue #228) — same signal Home uses.
    private var refreshObservers = Set<AnyCancellable>()
    /// Bumped per refresh so a slow fetch from an earlier notification can't
    /// overwrite a newer one (or land after the user paged away).
    private var watchRefreshToken: UInt64 = 0

    // MARK: - Lifecycle

    /// One item, opened already expanded with no paging, blur-faded in and out;
    /// Menu dismisses it. The detail for a drill-in such as a Related poster.
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
        // Over full screen keeps Home visible for the row morphs; `backdrop` owns the
        // surround. Presentation style has no say over Menu (UIKIT_FOUNDATIONS §3).
        self.modalPresentationStyle = .overFullScreen
        self.restoresFocusAfterTransition = false
        // The entry morph is the transition: callers present with animated: false.
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
        // Apple's surround grey; shows in the top strip and the gaps between cards.
        backdrop.backgroundColor = UIColor(white: 0.16, alpha: 1)
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

        // Above the artwork, below the chrome; hidden until the scroll arms it.
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

        // Above the chrome, inert until the expand morph completes.
        expandedDetail.translatesAutoresizingMaskIntoConstraints = false
        expandedDetail.isHidden = true
        view.addSubview(expandedDetail)
        NSLayoutConstraint.activate([
            expandedDetail.topAnchor.constraint(equalTo: view.topAnchor),
            expandedDetail.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            expandedDetail.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            expandedDetail.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        // Below-fold scroll progress (0 to 1 over reserveDistance) drives blur and chrome fade.
        expandedDetail.onScrollProgress = { [weak self] progress in
            self?.driveHeroLayers(progress)
        }
        expandedDetail.onSelectSynopsis = { [weak self] detail in
            guard let self else { return }
            let content = InfoPopupContent.description(
                title: detail.item.title,
                subtitle: detail.genres.prefix(3).joined(separator: ", "),
                body: detail.item.overview,
                overviewIsMachineTranslated: detail.item.overviewIsMachineTranslated == true)
            let size = InfoPopupViewController.descriptionSize
            self.present(InfoPopupViewController(content: content, width: size.width, height: size.height), animated: true)
        }
        expandedDetail.onSelectAdvisory = { [weak self] advisory in
            let content = InfoPopupContent.advisory(advisory)
            self?.present(InfoPopupViewController(content: content, width: 720, scrollable: true), animated: true)
        }
        // Episode thumb Select → play the episode.
        expandedDetail.onPlayEpisode = { [weak self] episode in
            self?.playMediaItem(episode)
        }
        // Trailer / extra Select → play that video. Routed on the
        // extra's playbackKey, NOT its id: IVA extras have no library ratingKey.
        expandedDetail.onPlayTrailer = { [weak self] trailer in
            self?.presentExtraPlayer(trailer)
        }
        // Episode description Select → the episode's detail page.
        expandedDetail.onShowEpisodeDetails = { [weak self] episode in
            self?.presentEpisodePage(episode)
        }
        // Held Select on an episode → Home's tile menu, less the Go to entries.
        expandedDetail.onEpisodeMenu = { [weak self] episode, thumbFrame in
            guard let self else { return }
            EpisodeMenu.present(for: episode, from: self, sourceFrame: thumbFrame,
                                play: { [weak self] sourceID, fromBeginning in
                                    self?.playMediaItem(episode, sourceID: sourceID, fromBeginning: fromBeginning)
                                },
                                moreInfo: { [weak self] in self?.presentEpisodePage(episode) })
        }

        // Related poster Select → the item's full standalone detail, not the episode page.
        expandedDetail.onShowRelatedDetails = { [weak self] item in
            self?.presentStandaloneDetail(item)
        }

        // Season pill Select → the season's detail page (focus already switched the
        // rail). A standalone carousel here would stack one per season click.
        expandedDetail.onOpenSeason = { [weak self] season in
            guard let self else { return }
            let show = self.items.indices.contains(self.selectedIndex) ? self.items[self.selectedIndex] : nil
            self.present(SeasonDetailViewController(season: season,
                                                    showTitle: show?.kind == .show ? show?.title : nil),
                         animated: true)
        }
        // Cast / crew cell Select → person detail page (full-screen).
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.view.window != nil, self.presentedViewController == nil else { return }
                SiloThemeMusicController.shared.resume()
                self.themeOwnerID = nil
                self.activateVisibleTheme()
            }
            .store(in: &refreshObservers)

        expandedDetail.onSelectPerson = { [weak self] person in
            guard let self else { return }
            let provider = self.items.indices.contains(self.selectedIndex)
                ? MediaProviderRegistry.shared.provider(for: self.items[self.selectedIndex].ref.providerID) as? SiloProvider
                : nil
            let page: PersonDetailViewController
            if let provider {
                let libraries = ServerDataStore.shared.visibleLibraries
                    .filter { $0.providerID == provider.id }.map(\.id)
                guard let native = try? PersonDetailViewController.silo(
                    cast: person, provider: provider, inLibraries: libraries) else { return }
                page = native
            } else {
                page = PersonDetailViewController(person: person)
            }
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

        // Menu goes through a recognizer, not presses* overrides: the modal's dismiss
        // path runs alongside the responder chain, so absorbing the press there still
        // dismisses (UIKIT_FOUNDATIONS §2).
        let menuRecognizer = UITapGestureRecognizer(target: self, action: #selector(menuGestureFired))
        menuRecognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        view.addGestureRecognizer(menuRecognizer)

        // Touch-surface paging: the focusless carousel gets no arrow presses from a swipe.
        // Gated in `gestureRecognizerShouldBegin`, since a begun recognizer would cancel
        // the focus move between the expanded chrome's buttons.
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleCarouselSwipe(_:)))
            swipe.direction = direction
            swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            // On tvOS a swipe recognizer otherwise waits for a .select press.
            swipe.allowedPressTypes = []
            swipe.delegate = self
            view.addGestureRecognizer(swipe)
        }

        // Touch twin of the vertical arrow choreography in `pressesBegan`. Begins only
        // for hand-offs the engine cannot make; the below-fold rows need the rest.
        for direction in [UISwipeGestureRecognizer.Direction.up, .down] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleVerticalSwipe(_:)))
            swipe.direction = direction
            swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            swipe.allowedPressTypes = []
            swipe.delegate = self
            view.addGestureRecognizer(swipe)
            verticalSwipeRecognizers.append(swipe)
        }

        // Zero-size; see `focusAnchor`.
        focusAnchor.frame = .zero
        view.addSubview(focusAnchor)

        // Refetch watch state after playback (#228). The player posts this once its
        // stopped report has committed; the player's dismiss is about 2 s too early.
        NotificationCenter.default.publisher(for: .plexDataNeedsRefresh)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshWatchState()
            }
            .store(in: &refreshObservers)

        previewCarouselLog.info("[PCV] viewDidLoad items=\(self.items.count, privacy: .public) selected=\(self.selectedIndex, privacy: .public)")
        // Do not force a collection layout here: `view` is still zero-sized, and cells
        // dequeued against it keep collapsed chrome. viewDidLayoutSubviews lays out.
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Skip the transitional zero-bounds pass: setting contentOffset there dequeues
        // cells with zero-width chrome for good, and the carousel morphs in black.
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }

        // Recenter every pass, since content size follows bounds. Not mid-page:
        // selectedIndex is still the outgoing item and the glide would snap back.
        if pagingAnimation == nil {
            collectionView.contentOffset = layout.contentOffsetCentered(index: selectedIndex)
        }

        if !isExpanded {
            syncCards()
        }

        // Before entry, park the morph snapshot on the source frame.
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
                morphSnapshot.item = items.indices.contains(selectedIndex)
                    ? items[selectedIndex]
                    : nil
            } else {
                morphSnapshot.isHidden = true
                prepareEntrySnapshotsIfNeeded()
            }
        }

        // Standalone detail opens expanded once bounds are valid, with no card morph.
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
        // Details: the below-fold collection. Otherwise the anchor, so Menu reaches us.
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
        activateVisibleTheme()
        // Focus, not first responder, is what routes presses here on tvOS.
        becomeFirstResponder()
        // Re-arm a shelf row (Related) on its tile before the update resolves:
        // the host cell cannot be preferred directly. No-op otherwise.
        expandedDetail.restoreShelfRowFocusIfNeeded()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        // One-shot: consumed by the update above, so it can't capture a later one.
        expandedDetail.clearArmedShelfRestore()
        guard !hasRunEntryMorph else { return }
        hasRunEntryMorph = true

        if !entrySnapshots.isEmpty {
            runRowEntryMorph()
            return
        }

        if initialSourceFrame == .zero {
            // No source to morph from: reveal at once.
            morphSnapshot.isHidden = true
            backdrop.alpha = 1
            collectionView.alpha = 1
            backdropPlane.alpha = 1
            state.completeEntryMorph()
            updateCurrentCellChrome(animated: false)
            return
        }

        let targetFrame = centeredFrameInWindow()

        let morpher = Self.makeShelfTransitionAnimator()
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

    /// Bumped per reveal, so a held reveal from an earlier page never fires.
    private var chromeRevealToken = 0

    /// Gives the centred cell its chrome (faded in over 0.5 s when animated) and leaves the peeks bare.
    /// An animated reveal waits for the chrome's logo and details, so nothing swaps in after
    /// the fade; a slow server holds it at most 1 s.
    private func updateCurrentCellChrome(animated: Bool) {
        chromeRevealToken &+= 1
        guard animated,
              let card = collectionView.cellForItem(at: IndexPath(item: selectedIndex, section: 0)) as? PreviewCardView,
              !card.isChromeReady
        else {
            revealCurrentCellChrome(animated: animated)
            return
        }
        let token = chromeRevealToken
        let reveal = { [weak self] in
            guard let self, self.chromeRevealToken == token,
                  self.pagingAnimation == nil, !self.isExpanded else { return }
            self.chromeRevealToken &+= 1
            self.revealCurrentCellChrome(animated: true)
        }
        card.whenChromeReady(reveal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: reveal)
    }

    private func revealCurrentCellChrome(animated: Bool) {
        for cell in collectionView.visibleCells {
            guard let card = cell as? PreviewCardView else { continue }
            guard let indexPath = collectionView.indexPath(for: cell) else { continue }
            let shouldBeCurrent = indexPath.item == selectedIndex
            card.setIsCurrent(shouldBeCurrent, animated: animated && shouldBeCurrent)
        }
        // The below-fold peek is live in the carousel too and cascades with the chrome.
        expandedDetail.isHidden = false
        if items.indices.contains(selectedIndex) {
            expandedDetail.item = items[selectedIndex]
        }
        expandedDetail.setCurrent(true, animated: animated)
    }

    // MARK: - Geometry helpers

    /// Places the row snapshots at their source frames, which are in window coordinates.
    /// Re-run on every pre-entry layout pass, since the first may come before `view.window` exists.
    private func prepareEntrySnapshotsIfNeeded() {
        guard view.window != nil else { return }
        entrySnapshotContainer.isHidden = false
        entrySnapshotContainer.alpha = 1

        if !hasPreparedEntrySnapshots {
            hasPreparedEntrySnapshots = true
            for entry in entrySnapshots.sorted(by: { $0.itemIndex < $1.itemIndex }) {
                let window = EntryMorphWindowView(
                    content: entry.snapshotView,
                    sourceSize: entry.sourceFrame.size,
                    backdrop: items.indices.contains(entry.itemIndex) ? flightBackdrop(for: entry.itemIndex) : nil
                )
                window.layer.cornerRadius = entry.cornerRadius
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

    /// The card's artwork for a flying window, placed as the backdrop plane
    /// places it so the swap to the live carousel shows nothing.
    private func flightBackdrop(for index: Int) -> EntryMorphWindowView.Backdrop {
        let imageView = UIImageView(image: backdropPlane.image(for: index))
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .black
        if imageView.image == nil, let url = items[index].artwork.backdrop ?? items[index].artwork.poster {
            Task { [weak imageView] in
                imageView?.image = await ImageCacheManager.shared.image(for: url, quality: .full)
            }
        }
        let card = carouselFrameInView(for: index)
        return EntryMorphWindowView.Backdrop(
            imageView: imageView,
            cardSize: card.size,
            artInCard: CGRect(
                x: (card.width - view.bounds.width) / 2 + layout.parallaxOffset(for: index),
                y: -card.minY,
                width: view.bounds.width,
                height: view.bounds.height))
    }

    private func flightDim(for index: Int) -> CGFloat {
        PreviewCarouselGeometry.neighbourDimAlpha * abs(layout.normalizedPosition(for: index))
    }

    /// Windows for the cards with no tile to fly from or to (the two peeks, and the
    /// centre when its tile had no artwork): they hold the card's frame and only fade.
    private func tilelessPeekWindows(flying: Set<Int>) -> [EntryMorphWindowView] {
        [selectedIndex - 1, selectedIndex, selectedIndex + 1]
            .filter { items.indices.contains($0) && !flying.contains($0) }
            .map { index in
                let card = carouselFrameInView(for: index)
                let window = EntryMorphWindowView(
                    content: UIView(), sourceSize: card.size, backdrop: flightBackdrop(for: index))
                window.layer.cornerRadius = PreviewCarouselGeometry.cornerRadius
                window.setWindow(card)
                window.dimAlpha = flightDim(for: index)
                entrySnapshotContainer.addSubview(window)
                return window
            }
    }

    private func runRowEntryMorph() {
        prepareEntrySnapshotsIfNeeded()

        // Ensure the live carousel is in its final first-frame position behind
        // the source snapshots before it fades in.
        collectionView.layoutIfNeeded()
        collectionView.contentOffset = layout.contentOffsetCentered(index: selectedIndex)
        syncCards()
        backdrop.alpha = 0
        backdropPlane.alpha = 0
        collectionView.alpha = 0
        entrySnapshotContainer.alpha = 1

        let peeks = tilelessPeekWindows(flying: Set(entryMorphWindows.map(\.itemIndex)))
        peeks.forEach { $0.alpha = 0 }

        // One spring moves and fades everything; the live carousel is swapped
        // in under the settled windows at the end.
        let morpher = Self.makeShelfTransitionAnimator()
        morpher.addAnimations { [weak self] in
            guard let self else { return }
            for entry in self.entryMorphWindows {
                guard self.items.indices.contains(entry.itemIndex) else {
                    entry.window.alpha = 0
                    continue
                }
                entry.window.setWindow(self.carouselFrameInView(for: entry.itemIndex))
                entry.window.layer.cornerRadius = PreviewCarouselGeometry.cornerRadius
                entry.window.tileAlpha = 0
                entry.window.dimAlpha = self.flightDim(for: entry.itemIndex)
            }
            peeks.forEach { $0.alpha = 1 }
            self.backdrop.alpha = 1
        }
        morpher.addCompletion { [weak self] _ in
            guard let self else { return }
            self.backdropPlane.alpha = 1
            self.collectionView.alpha = 1
            for entry in self.entryMorphWindows {
                entry.window.removeFromSuperview()
            }
            peeks.forEach { $0.removeFromSuperview() }
            self.entryMorphWindows.removeAll()
            self.entrySnapshotContainer.isHidden = true
            self.state.completeEntryMorph()
            self.updateCurrentCellChrome(animated: true)
        }
        morpher.startAnimation()
    }

    /// Apple's shelf-tile transition spring (damping ratio 1.22, no overshoot),
    /// shared by entry and exit. UIKit ignores the duration for a physical
    /// spring and runs it for its settling time, about 0.75s.
    private static func makeShelfTransitionAnimator() -> UIViewPropertyAnimator {
        UIViewPropertyAnimator(
            duration: 0,
            timingParameters: UISpringTimingParameters(
                mass: 1, stiffness: 150, damping: 30, initialVelocity: .zero))
    }

    /// Place the artwork panels and set each card's hairline for the current offset.
    private func syncCards() {
        backdropPlane.sync(to: layout, offset: collectionView.contentOffset)
        for case let card as PreviewCardView in collectionView.visibleCells {
            guard let index = collectionView.indexPath(for: card)?.item else { continue }
            card.setHairline(position: layout.normalizedPosition(for: index))
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

    override var canBecomeFirstResponder: Bool { return true }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopVisibleTheme()
        previewCarouselLog.info("[Lifecycle] viewWillDisappear isExpanded=\(self.isExpanded) presentingVC=\(self.presentingViewController != nil)")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Torn down from outside (deep link, profile switch): no dismiss ran.
        // Covered by a player, the carousel is still presented and stays as is.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentingViewController == nil else { return }
            self.teardown()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // A presented VC's next responder is its presenter, so a press the
        // Watched prompt or the episode page declines bubbles up to here. It
        // belongs to them, not to the carousel underneath.
        guard presentedViewController == nil else {
            super.pressesBegan(presses, with: event)
            return
        }
        for press in presses {
            switch press.type {
            // .menu is owned by the menu gesture recognizer (see viewDidLoad).
            case .rightArrow:
                // From an episode description, Left/Right goes to the adjacent episode's
                // thumb, which sits above it where the engine cannot reach.
                if state.phase == .detailsStable, expandedDetail.episodeDescriptionFocused,
                   expandedDetail.armAdjacentEpisodeThumb(forward: true) {
                    setNeedsFocusUpdate(); updateFocusIfNeeded()
                    expandedDetail.clearArmedEpisodeFocus()
                    return
                }
                // Expanded, the focus engine needs Left/Right for the rows.
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
                // Select or Play/Pause on the centered card expands it.
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
    // Shared by arrow presses and the vertical swipes. True means consumed; false
    // passes the press to the focus engine and keeps the swipe from beginning.

    /// Down: carousel → hero → below-fold details, and pills → episodes.
    @discardableResult
    private func handleDownNavigation() -> Bool {
        if state.isCarouselInputEnabled {
            expandCurrentCard()
            return true
        }
        if state.phase == .expandedHero {
            enterBelowFold()
            return true
        }
        // Pills → the selected season's first episode. The engine still remembers
        // season 1's episode 0, so arm the target across this update.
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
        // Only the top of the details is ours; from a lower row the engine moves up one row.
        if state.phase == .detailsStable {
            if expandedDetail.focusIsOnPills {
                returnToHeroFromBelowFold()
                return true
            }
            if expandedDetail.focusIsOnEpisodes {
                // If the engine moved focus onto the primary row on this same press,
                // stay there; only an Up from a resting primary row lifts further.
                if expandedDetail.episodeThumbJustTookFocus
                    || expandedDetail.episodesJustTookFocus { return true }
                if expandedDetail.hasSeasonPills {
                    // The pills are unfocusable from here; the target enables them.
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
        // Up from the hero is Menu's collapse. Standalone has no carousel, so Up does nothing.
        if state.phase == .expandedHero {
            if standaloneDetail { return true }
            handleMenuPress()
            return true
        }
        return false
    }

    // MARK: - Watch-state refresh (issue #228)

    /// Re-reads the centered item's watch state and repaints the hero and episode rail in place.
    /// The normal setters rebuild the action row, which usually holds focus after playback.
    private func refreshWatchState() {
        // Runs while covered too: one GET, and right when the user comes back.
        guard isViewLoaded, items.indices.contains(selectedIndex) else { return }
        let index = selectedIndex
        let item = items[index]
        guard !item.isMetadataOnly,
              let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID)
        else { return }

        watchRefreshToken &+= 1
        let token = watchRefreshToken

        // The rail has its own fetch and token.
        expandedDetail.refreshWatchState()

        // `fullDetail` is one uncached GET, so it carries the committed state.
        Task { [weak self] in
            guard let detail = try? await provider.fullDetail(for: item.ref) else { return }
            await MainActor.run {
                guard let self,
                      self.watchRefreshToken == token,
                      self.items.indices.contains(index),
                      self.items[index].ref == detail.item.ref
                else { return }
                if provider.kind == .silo {
                    self.backdropPlane.updateArtwork(detail.item.artwork, for: detail.item.ref)
                }
                let refreshed = detail.item
                guard refreshed != self.items[index] else { return }
                self.items[index] = refreshed
                self.expandedDetail.updateItemInPlace(refreshed)
                let path = IndexPath(item: index, section: 0)
                (self.collectionView.cellForItem(at: path) as? PreviewCardView)?
                    .refreshWatchState(from: refreshed)
            }
        }
    }

    // MARK: - Playback

    /// Presents an item's full detail with this VC in `standaloneDetail` mode (Related drill-ins).
    private func presentStandaloneDetail(_ item: MediaItem) {
        // Collection tile: arm the row's restore while the tile exists, since the engine
        // may resolve before onDismiss runs. No focus request: it would spend the one-shot index now.
        if item.kind == .collection || item.kind == .playlist {
            expandedDetail.restoreShelfRowFocusIfNeeded(requestingFocus: false)
            let restore: () -> Void = { [weak self] in self?.restoreBelowFoldFocusAfterReturn() }
            _ = PlexHomeViewController.openCollectionIfNeeded(item, from: self, onDismiss: restore)
                || PlexHomeViewController.openPlaylistIfNeeded(item, from: self, onDismiss: restore)
            return
        }
        // Over full screen, so viewDidAppear never fires on return; restore from onDismiss.
        let detail = PreviewCarouselViewController(
            items: [item],
            selectedIndex: 0,
            sourceFrame: .zero,
            sourceTarget: nil,
            standaloneDetail: true,
            onDismiss: { [weak self] _ in self?.restoreBelowFoldFocusAfterReturn() })
        var top: UIViewController = self
        while let presented = top.presentedViewController { top = presented }
        top.present(detail, animated: true)
    }

    /// "Go to Show" from an episode: the SHOW's own detail, so its Watched
    /// button acts on the whole show. `show` skips the fetch when the caller
    /// already has it. From a page this show's detail presented, goes back to
    /// that detail instead of stacking a second one.
    static func openShowDetail(_ showRef: MediaItemRef, show: MediaItem? = nil, from presenter: UIViewController) {
        if let below = presenter.presentingViewController as? PreviewCarouselViewController,
           below.items.indices.contains(below.selectedIndex),
           below.items[below.selectedIndex].ref == showRef {
            presenter.dismiss(animated: true)
            return
        }
        Task { @MainActor [weak presenter] in
            var resolved = show
            if resolved == nil, let provider = MediaProviderRegistry.shared.provider(for: showRef.providerID) {
                resolved = try? await provider.fullDetail(for: showRef).item
            }
            guard var top = presenter, let resolved else { return }
            while let presented = top.presentedViewController { top = presented }
            top.present(PreviewCarouselViewController(
                items: [resolved], selectedIndex: 0, sourceFrame: .zero, sourceTarget: nil,
                standaloneDetail: true, onDismiss: { _ in }), animated: true)
        }
    }

    /// Restores below-fold focus after a standalone detail, from its dismiss callback
    /// (`.overFullScreen` skips this VC's appearance methods).
    func restoreBelowFoldFocusAfterReturn() {
        guard state.phase == .detailsStable else { return }
        expandedDetail.restoreShelfRowFocusIfNeeded()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        expandedDetail.clearArmedShelfRestore()
    }

    /// Filmography poster Select; metadata-only items take the same path.
    private func presentPersonFilmographyItem(_ item: MediaItem) {
        presentStandaloneDetail(item)
    }

    /// Info button → structured info popup (scrollable), styled like our other
    /// popups but with Information / Languages / Accessibility sections.
    private func presentInfoPopup(_ detail: MediaItemDetail) {
        // The popup's ratings row wants the Worker's scores too; the detail page has usually cached them.
        Task { [weak self] in
            var detail = detail
            let extra = await RatingsClient.shared.ratings(for: detail, within: 1)
            if !extra.isEmpty { detail.ratings = MediaRating.ordered(detail.ratings + extra) }
            self?.showInfoPopup(detail)
        }
    }

    private func showInfoPopup(_ detail: MediaItemDetail) {
        let content = InfoPopupContent.fullInfo(detail: detail)
        // Fixed size: the scroll-content measurement under-reports.
        let popup = InfoPopupViewController(content: content, width: InfoPopupViewController.infoWidth, height: 900, scrollable: true)
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

    private func playMediaItem(_ item: MediaItem, sourceID: String? = nil, fromBeginning: Bool = false) {
        // presentPlayer resolves a Plex ratingKey; any other item plays through
        // its own provider.
        if !item.ref.isPlex {
            ProviderPlayer.play(item, fromBeginning: fromBeginning, sourceID: sourceID, from: self, onDismiss: nil)
            return
        }
        // 0, not nil: nil means ask the server for its resume point.
        let offsetSec = item.userState.viewOffset
        let resume: Double? = fromBeginning ? 0 : (offsetSec > 0 ? offsetSec : nil)
        presentPlayer(ratingKey: item.ref.itemID, resumeOffset: resume, mediaID: sourceID)
    }

    private func presentEpisodePage(_ episode: MediaItem) {
        // No seriesTitle: the page reads the show from the episode's metadata,
        // and the carousel's selected item is not reliably the show.
        let page = MediaItemDetailPageViewController(
            item: episode,
            seriesTitle: nil,
            onPlay: { [weak self] ep, sourceID in self?.playMediaItem(ep, sourceID: sourceID) })
        present(page, animated: true)
    }

    /// The Plex server the item on screen lives on, which may not be the selected one (#87).
    private var shownItemServer: PlexServerAddress? {
        MediaProviderRegistry.shared.plexServer(for: expandedDetail.item?.ref.providerID)
    }

    /// Fetches a Plex ratingKey's metadata and presents the player. A nil `resumeOffset`
    /// means ask the server: the only place an extra's resume point appears (#303).
    private func presentPlayer(ratingKey: String, resumeOffset: Double?, mediaID: String? = nil) {
        let server = shownItemServer
        Task { [weak self] in
            guard let serverURL = server?.address, let token = server?.token else {
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
            // `viewOffset` is ms, gated on the shared resume policy rather than `> 0`.
            let serverResume = playItem.isInProgress
                ? playItem.viewOffset.map { Double($0) / 1000 }
                : nil
            await MainActor.run {
                self?.present(playItem: playItem, serverURL: serverURL, token: token,
                              resumeOffset: resumeOffset ?? serverResume, mediaID: mediaID)
            }
        }
    }

    /// Plays a trailer or extra. A user-added extra has a library ratingKey. A Plex IVA
    /// extra has none, only `key`, an absolute part path (`/services/iva/assets/...`) that
    /// 404s under `/library/metadata` (#255); it plays directly through a synthetic PlexMetadata.
    private func presentExtraPlayer(_ trailer: BelowFoldTrailer) {
        if let url = trailer.externalURL {
            guard let provider = MediaProviderRegistry.shared.provider(for: trailer.providerID),
                  MediaProviderRegistry.shared.isCurrentAuthority(provider) else { return }
            openRemoteVideo(url)
            return
        }
        let key = trailer.playbackKey ?? trailer.id
        // Off Plex an extra is a library item of its own provider.
        if let provider = MediaProviderRegistry.shared.provider(for: trailer.providerID), provider.kind != .plex {
            playProviderExtra(MediaItemRef(providerID: trailer.providerID, itemID: key), provider: provider)
            return
        }
        let route = ExtraPlaybackKey.route(for: key)

        // Context for the request's own Sentry capture, whose endpoint tag cannot group IVA paths.
        let crumb = Breadcrumb(level: .info, category: "playback.extra")
        crumb.message = "Playing extra"
        crumb.data = [
            "route": route.telemetryName,
            "subtype": trailer.subtype.displayName,
            "key_shape": ExtraPlaybackKey.keyShape(key),
            "had_playback_key": trailer.playbackKey != nil
        ]
        SentryBridge.addBreadcrumb(crumb)

        switch route {
        case .libraryMetadata(let ratingKey):
            // nil = resume from whatever the server has for this extra.
            presentPlayer(ratingKey: ratingKey, resumeOffset: nil)

        case .directPartPath(let path):
            // IVA extras aren't library items, so /:/timeline never recorded a
            // position for them — there is nothing to resume from.
            guard let serverURL = shownItemServer?.address, let token = shownItemServer?.token else {
                previewCarouselLog.error("[PCV] extra play: no server/token")
                return
            }
            previewCarouselLog.info("[PCV] extra play: direct part path (non-library extra)")
            present(
                playItem: Self.syntheticMetadata(forPartKey: path, trailer: trailer),
                serverURL: serverURL,
                token: token,
                resumeOffset: nil
            )
        }
    }

    /// Remote metadata videos are watch pages, not Aether inputs. Apple TV has
    /// no web view; YouTube's TV app accepts its app-scheme watch destination.
    private func openRemoteVideo(_ url: URL) {
        var destination = url
        if url.host == "www.youtube.com", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = "youtube"
            destination = components.url ?? url
        }
        let options: [UIApplication.OpenExternalURLOptionsKey: Any] = destination.scheme == "https"
            ? [.universalLinksOnly: true] : [:]
        UIApplication.shared.open(destination, options: options) { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let message = url.host == "www.youtube.com"
                    ? "Install or update YouTube on this Apple TV, then try again. Silo provides a YouTube link, not a video stream Rivulet can play."
                    : "No installed Apple TV app can open this Vimeo video. Open it in Vimeo on another device."
                let popup = ConfirmationPopupViewController(
                    title: "Couldn't Open Video", message: message,
                    confirmTitle: "OK", cancelTitle: nil, onConfirm: {})
                self.present(popup, animated: true)
            }
        }
    }

    private func playProviderExtra(_ ref: MediaItemRef, provider: any MediaProvider) {
        Task { [weak self] in
            do {
                let detail = try await provider.fullDetail(for: ref)
                guard let self else { return }
                ProviderPlayer.play(detail.item, fromBeginning: false, from: self, onDismiss: nil)
            } catch {
                previewCarouselLog.error("[PCV] extra play: \(error.localizedDescription, privacy: .public)")
                guard let self else { return }
                let popup = ConfirmationPopupViewController(
                    title: "Couldn't Play", message: ProviderPlayer.errorMessage(for: error),
                    confirmTitle: "OK", cancelTitle: nil, onConfirm: {})
                self.present(popup, animated: true)
            }
        }
    }

    /// Minimal PlexMetadata standing in for a non-library extra, carrying the
    /// part path ContentRouter needs to build a direct-play URL.
    private static func syntheticMetadata(forPartKey key: String, trailer: BelowFoldTrailer) -> PlexMetadata {
        let part = PlexPart(id: 0, key: key, duration: nil, file: nil, size: nil, container: nil, Stream: nil)
        let media = PlexMedia(
            id: 0, duration: nil, bitrate: nil, width: nil, height: nil, aspectRatio: nil,
            audioChannels: nil, audioCodec: nil, videoCodec: nil, videoResolution: nil,
            container: nil, videoFrameRate: nil, Part: [part]
        )
        return PlexMetadata(
            ratingKey: trailer.id,
            key: key,
            type: "clip",
            title: trailer.title,
            Media: [media]
        )
    }

    private func present(playItem: PlexMetadata, serverURL: String, token: String, resumeOffset: Double?,
                         mediaID: String? = nil) {
        let viewModel = UniversalPlayerViewModel(
            metadata: playItem,
            serverURL: serverURL,
            authToken: token,
            startOffset: resumeOffset,
            preferredMediaID: mediaID
        )
        // From the topmost VC, so Play also works from the episode page over the carousel.
        PlayerPresenter.present(viewModel: viewModel, from: self)
    }

    // Menu belongs to the recognizer alone. Do not also handle it in pressesEnded or
    // pressesCancelled: the two race, the press arrives cancelled and the modal dismisses.

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

    /// Touch twin of an up or down arrow; begins only when `verticalSwipeWouldNavigate` agrees.
    @objc private func handleVerticalSwipe(_ gesture: UISwipeGestureRecognizer) {
        switch gesture.direction {
        case .down: handleDownNavigation()
        case .up:   handleUpNavigation()
        default:    break
        }
    }

    /// True only for the boundary hand-offs the engine cannot make. Claiming any other
    /// swipe in the details would cancel the engine's row-to-row moves.
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
                return touchBeganOnDetailsTopRow
                    && (expandedDetail.focusIsOnPills || expandedDetail.focusIsOnEpisodes)
            }
            return false
        default:
            return false
        }
    }

    /// A press mid-glide pages on from where the glide is headed.
    private var pagingTargetIndex: Int { pagingAnimation?.targetIndex ?? selectedIndex }

    private func pageForward() {
        guard state.isCarouselInputEnabled else { return }
        guard pagingTargetIndex < items.count - 1 else { return }
        animatePage(toIndex: pagingTargetIndex + 1)
    }

    private func pageBackward() {
        guard state.isCarouselInputEnabled else { return }
        guard pagingTargetIndex > 0 else { return }
        animatePage(toIndex: pagingTargetIndex - 1)
    }

    /// Pages over 0.78 s on a display link, so layout invalidates every frame (see `PagingAnimation`).
    /// Called mid-glide, it retargets from the current offset and speed.
    private func animatePage(toIndex newIndex: Int) {
        state.beginPaging()
        chromeRevealToken &+= 1
        // Release the expand offset-pin so paging can move the carousel.
        collectionView.pinnedOffsetX = nil

        // Prefetch the far-edge card's artwork, or the glide stalls halfway waiting on it,
        // and its logo, or the chrome shows the title as text until the logo lands.
        let direction = newIndex > pagingTargetIndex ? 1 : -1
        let prefetchIndex = newIndex + direction * 2
        if items.indices.contains(prefetchIndex) {
            let item = items[prefetchIndex]
            for url in [item.artwork.backdrop ?? item.artwork.poster, item.artwork.logo].compactMap({ $0 }) {
                Task { _ = await ImageCacheManager.shared.image(for: url) }
            }
        }

        let now = CACurrentMediaTime()
        let start = collectionView.contentOffset.x
        let end = layout.contentOffsetCentered(index: newIndex).x
        var next = PagingAnimation(
            startOffset: start,
            endOffset: end,
            startTime: now,
            duration: 0.78,
            targetIndex: newIndex
        )
        // Match the curve's starting slope (p1y / p1x) to the current speed; a reversal starts from rest.
        if let current = pagingAnimation, end != start {
            let frame: CFTimeInterval = 1.0 / 60
            let velocity = (pagingOffset(current, at: now) - pagingOffset(current, at: now - frame)) / frame
            let slope = velocity * next.duration / (end - start)
            next.p1y = min(1, max(next.p1y, slope * 0.40))
        }
        pagingAnimation = next

        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tickPagingAnimation))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func pagingOffset(_ anim: PagingAnimation, at time: CFTimeInterval) -> CGFloat {
        let t = min(1.0, max(0.0, (time - anim.startTime) / anim.duration))
        let eased = cubicBezier(t: CGFloat(t), p1x: 0.40, p1y: anim.p1y, p2x: 0.18, p2y: 1.0)
        return anim.startOffset + (anim.endOffset - anim.startOffset) * eased
    }

    @objc private func tickPagingAnimation(_ link: CADisplayLink) {
        guard let anim = pagingAnimation else {
            link.invalidate()
            displayLink = nil
            return
        }

        let now = CACurrentMediaTime()
        let t = min(1.0, max(0.0, (now - anim.startTime) / anim.duration))
        // The layout invalidates on bounds change, recomputing parallax per frame.
        collectionView.setContentOffset(CGPoint(x: pagingOffset(anim, at: now), y: 0), animated: false)
        syncCards()

        // The outgoing card's chrome and the below-fold peek fade against its
        // travel, gone well before the card leaves.
        let outgoingCell = collectionView.cellForItem(at: IndexPath(item: selectedIndex, section: 0)) as? PreviewCardView
        let fade = max(0, 1 - abs(layout.normalizedPosition(for: selectedIndex)) / PreviewCarouselGeometry.contentFadeDistance)
        outgoingCell?.setPagingFade(fade)
        expandedDetail.alpha = fade

        if t >= 1.0 {
            link.invalidate()
            displayLink = nil
            // Paged away and back: the card kept its chrome, so just restore the fade.
            if anim.targetIndex == selectedIndex {
                outgoingCell?.setPagingFade(1)
                expandedDetail.alpha = 1
                pagingAnimation = nil
                state.finishPaging()
                // Left before its held reveal fired: reveal it now.
                if outgoingCell?.isCurrent == false { updateCurrentCellChrome(animated: true) }
                return
            }
            // Hand the fade back: both are at 0 by now, and the new centre
            // fades in from updateCurrentCellChrome.
            outgoingCell?.setIsCurrent(false, animated: false)
            outgoingCell?.setPagingFade(1)
            expandedDetail.setCurrent(false, animated: false)
            expandedDetail.alpha = 1
            stopVisibleTheme()
            selectedIndex = anim.targetIndex
            dismissSourceTarget = makeSourceTarget(for: selectedIndex)
            pagingAnimation = nil
            state.finishPaging()
            activateVisibleTheme()
            // Cascade chrome on the new center cell.
            updateCurrentCellChrome(animated: true)
        }
    }

    /// CSS-style cubic Bezier ease with endpoints (0,0) and (1,1): solves x(u) = t by
    /// Newton-Raphson (10 steps, clamped) and returns y(u).
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
        // Menu goes up one level: details to hero, like Up from the pills.
        if state.phase == .detailsStable {
            returnToHeroFromBelowFold()
            return
        }
        // The entry flight is not interruptible.
        if state.phase == .entryMorph { return }
        let action = state.exitAction(standaloneDetail: standaloneDetail)
        previewCarouselLog.info("[Menu] action=\(String(describing: action), privacy: .public)")
        switch action {
        case .dismissOverlay:
            // Standalone: the transitioning delegate blur-fades back to the previous detail.
            if standaloneDetail { dismiss(animated: true) }
            else { performDismissMorph() }
        case .collapseToCarousel:
            // `exitAction` already moved the phase to `.carouselStable`.
            collapseExpandedCard()
        }
    }

    // MARK: - Expand / Collapse

    /// Expands the centered card to full screen (`.expandingHero` → `.expandedHero`) on
    /// the morph controller's one animator. The same cell and chrome views tween; nothing is reparented.
    private func expandCurrentCard() {
        guard !isExpanded else { return }
        // A page in flight still owns selectedIndex and the outgoing card's chrome.
        guard pagingAnimation == nil else { return }
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]

        previewCarouselLog.info("[Expand] BEGIN idx=\(self.selectedIndex) ref=\(item.ref.itemID, privacy: .public)")

        state.beginExpand()
        isExpanded = true

        let cell = collectionView.cellForItem(at: IndexPath(item: selectedIndex, section: 0)) as? PreviewCardView
        // Finish the chrome cascade first, so a paged-to card's metadata is not
        // still fading in while the backdrop grows.
        cell?.setIsCurrent(true, animated: false)
        expandedDetail.setCurrent(true, animated: false)
        // Pin the offset until collapse: the layout swap's deferred offset reset would
        // throw a non-first expanded cell off the right edge.
        collectionView.pinnedOffsetX = collectionView.contentOffset.x
        morphController.expand(centeredIndex: selectedIndex, in: view.bounds, cell: cell) { [weak self] in
            guard let self else { return }
            self.state.finishExpand()
            // Reveal the real focus-driven below-fold (post-morph, §6).
            self.expandedDetail.revealBelowFoldCollection()
            self.setNeedsFocusUpdate()
        }
    }

    /// Down from the expanded hero: slides into the below-fold details, then hands focus in.
    private func enterBelowFold() {
        guard state.phase == .expandedHero else { return }
        state.markDetailsStable()
        // Always enter on the episodes, never stale on the pills.
        expandedDetail.detailsFocusTarget = .episodes
        expandedDetail.setBelowFoldScrollActive(true)
        // Focusable only after the slide: the engine's own scroll fights it and
        // overshoots to Cast.
        expandedDetail.belowFoldCollection.slideToDetailsTop(animated: true) { [weak self] in
            guard let self else { return }
            self.expandedDetail.setBelowFoldInteractive(true)
            // Lay out first: a preferred index path whose cell is not realized
            // throws NSInternalInconsistencyException.
            self.expandedDetail.belowFoldCollection.layoutIfNeeded()
            self.setNeedsFocusUpdate()
            self.updateFocusIfNeeded()
            // So Up from the primary row cannot escape into the faded chrome buttons.
            (self.collectionView.cellForItem(at: IndexPath(item: self.selectedIndex, section: 0)) as? PreviewCardView)?
                .setChromeActionRowFocusable(false)
        }
    }

    /// Up from the top of the below-fold: focus back to the hero, collection back to its peek.
    private func returnToHeroFromBelowFold() {
        guard state.phase == .detailsStable else { return }
        state.returnToExpandedHero()
        // Before the focus update, so focus can land on the hero Play button.
        (collectionView.cellForItem(at: IndexPath(item: selectedIndex, section: 0)) as? PreviewCardView)?
            .setChromeActionRowFocusable(true)
        // The scroll coupling stays live until the slide ends, so the slide drives the hero fade-in.
        expandedDetail.setBelowFoldInteractive(false)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        expandedDetail.belowFoldCollection.slideToHeroRest(animated: true) { [weak self] in
            guard let self else { return }
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

        // Metadata is gone by p ≈ 0.4, before the top logo starts fading in.
        let chromeAlpha = 1 - min(1, p * 2.6)
        (collectionView.cellForItem(at: IndexPath(item: selectedIndex, section: 0)) as? PreviewCardView)?
            .setHeroChromeAlpha(chromeAlpha)
    }

    /// Lazily build the paused blur animator. `fractionComplete` is the blur
    /// intensity (Apple's way to scrub a UIVisualEffectView — not alpha).
    private func blurAnimatorIfNeeded() -> UIViewPropertyAnimator {
        if let a = blurAnimator { return a }
        let a = UIViewPropertyAnimator(duration: 1, curve: .linear) { [weak self] in
            // Pinned dark like Apple's detail backdrop: `.regular` follows
            // the system appearance and turns into a white frost under Light.
            self?.blurOverlay.effect = UIBlurEffect(style: .dark)
        }
        a.pausesOnCompletion = true
        a.startAnimation()
        a.pauseAnimation()
        blurAnimator = a
        return a
    }

    /// Reverse of `expandCurrentCard`, on the same curve.
    private func collapseExpandedCard() {
        guard isExpanded else { return }
        previewCarouselLog.info("[Collapse] BEGIN idx=\(self.selectedIndex)")

        isExpanded = false

        // Back to the placeholder peek, at rest, before the collapse morph.
        expandedDetail.hideBelowFoldCollection()
        expandedDetail.reset()

        let cell = collectionView.cellForItem(at: IndexPath(item: selectedIndex, section: 0)) as? PreviewCardView
        morphController.collapse(centeredIndex: selectedIndex, cell: cell) { [weak self] in
            guard let self else { return }
            // Restore carousel-mode backdrop panels after collapse.
            self.syncCards()
            // After the morph, so a focus animation never overlaps its curve.
            self.setNeedsFocusUpdate()
        }
    }

    /// Flies the cards back to their row tiles when the centred card has one on screen;
    /// otherwise fades every layer out on one animator, since artwork and chrome live apart.
    private func performDismissMorph() {
        guard state.phase != .exiting else { return }
        // The exit flight starts from settled geometry: not mid-page, not mid-collapse.
        guard pagingAnimation == nil, !morphController.isAnimating else { return }
        state.beginExit()
        onPrepareDismiss(dismissSourceTarget)
        // Fly only when the centred card has a tile on screen to land on.
        if !entrySnapshots.isEmpty {
            let tiles = freshEntrySnapshots?(dismissSourceTarget) ?? []
            if tiles.contains(where: { $0.itemIndex == selectedIndex }) {
                runRowExitMorph(to: tiles)
                return
            }
        }
        teardown()
        // Rivulet's own fade (Apple always has a tile to return to), so it
        // keeps its timing instead of following the expand morph.
        let animator = UIViewPropertyAnimator(duration: 0.35, curve: .easeInOut)
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

    /// Reverse of `runRowEntryMorph()`: each card flies to its tile's current
    /// frame as a window of its artwork, the tile fading in above it. The
    /// chrome is gone from the first frame; everything rides one spring.
    private func runRowExitMorph(to tiles: [PreviewEntrySnapshot]) {
        entrySnapshotContainer.isHidden = false
        entrySnapshotContainer.alpha = 1

        var windows: [(window: EntryMorphWindowView, tile: PreviewEntrySnapshot)] = []
        for tile in tiles where items.indices.contains(tile.itemIndex) {
            let window = EntryMorphWindowView(
                content: tile.snapshotView,
                sourceSize: tile.sourceFrame.size,
                backdrop: flightBackdrop(for: tile.itemIndex))
            window.layer.cornerRadius = PreviewCarouselGeometry.cornerRadius
            window.layer.zPosition = tile.itemIndex == selectedIndex
                ? 100
                : CGFloat(50 - abs(tile.itemIndex - selectedIndex))
            window.setWindow(carouselFrameInView(for: tile.itemIndex))
            window.tileAlpha = 0
            window.dimAlpha = flightDim(for: tile.itemIndex)
            entrySnapshotContainer.addSubview(window)
            windows.append((window, tile))
        }
        let peeks = tilelessPeekWindows(flying: Set(windows.map(\.tile.itemIndex)))

        backdropPlane.alpha = 0
        collectionView.alpha = 0
        expandedDetail.alpha = 0

        let morpher = Self.makeShelfTransitionAnimator()
        morpher.addAnimations { [weak self] in
            guard let self else { return }
            for (window, tile) in windows {
                window.setWindow(self.view.convert(tile.sourceFrame, from: nil))
                window.layer.cornerRadius = tile.cornerRadius
                window.tileAlpha = 1
                window.dimAlpha = 0
            }
            peeks.forEach { $0.alpha = 0 }
            self.backdrop.alpha = 0
        }
        morpher.addCompletion { [weak self] _ in
            guard let self else { return }
            // The real tiles take over from the snapshots resting on them.
            self.teardown()
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

    /// A begun recognizer cancels the engine's focus move, so decline here, never in the
    /// handler. Vertical: `verticalSwipeWouldNavigate`. Horizontal: only while the carousel owns input.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === verticalSwipeRecognizers.first {
            touchBeganOnDetailsTopRow = state.phase == .detailsStable
                && (expandedDetail.focusIsOnPills || expandedDetail.focusIsOnEpisodes)
        }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let swipe = gestureRecognizer as? UISwipeGestureRecognizer else { return true }
        // Touch twin of the pressesBegan guard: nothing pages or scrolls under a prompt.
        guard presentedViewController == nil else { return false }
        if verticalSwipeRecognizers.contains(where: { $0 === swipe }) {
            return verticalSwipeWouldNavigate(swipe.direction)
        }
        return state.isCarouselInputEnabled
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
        cell.onDetailArtwork = { [weak self] ref, artwork in
            guard let self,
                  MediaProviderRegistry.shared.provider(for: ref.providerID)?.kind == .silo else { return }
            self.backdropPlane.updateArtwork(artwork, for: ref)
        }
        if items.indices.contains(indexPath.item) {
            cell.item = items[indexPath.item]
        }
        cell.onPlay = { [weak self] item in self?.playHeroItem(item) }
        cell.onPlayVersion = { [weak self] item, sourceID in self?.playMediaItem(item, sourceID: sourceID) }
        cell.onShowInfo = { [weak self] detail in self?.presentInfoPopup(detail) }
        // Entry or paging completion marks the current cell via updateCurrentCellChrome.
        cell.setIsCurrent(indexPath.item == selectedIndex && hasRunEntryMorph,
                          animated: false)
        cell.setHairline(position: layout.normalizedPosition(for: indexPath.item))
        return cell
    }

    // animatePage drives the scroll, not the focus engine.
    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        // Never: a focusable cell is a leaf, and a directional search skips its
        // preferred-focus redirect, which kills Left/Right between the action buttons.
        return false
    }
}

/// Zero-size focus target that lets Menu presses reach the carousel's responder chain.
final class PreviewFocusAnchorView: UIView {
    override var canBecomeFocused: Bool { true }
}
