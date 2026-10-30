// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerContainerViewController.swift
//  Rivulet
//
//  UIViewController wrapper for video player that intercepts Menu button on tvOS.
//  This bypasses SwiftUI's fullScreenCover gesture handling to give us full control.
//

import SwiftUI
import UIKit
import Combine


/// Container view controller that hosts the SwiftUI player view and intercepts button presses.
/// This allows us to handle Menu button presses before SwiftUI dismisses the player.
class PlayerContainerViewController: UIViewController {

    // MARK: - Properties

    private var hostingController: UIHostingController<AnyView>?
    private var rail: PlayerRailView?
    private var progressBar: PlayerProgressBarView?
    private var scrubberProxy: ScrubberFocusProxyView?
    private var skipPill: SkipPillButton?
    private var pausedDimView: UIView?
    private var chromeScrim = ChromeScrimView()
    private var ambientScrim: BottomScrimView?
    private var captionOverlay: CaptionOverlayView?
    private var cancellables = Set<AnyCancellable>()
    /// The one floating panel shared by CC, audio, info and Up Next.
    private var activeRailPanel: PlayerRailPanelView?
    private weak var siloBufferingPopup: ConfirmationPopupViewController?
    /// Closes an untouched info pane, as AVKit does after 8s, playing or paused (#411).
    private var paneIdleTimer: Timer?
    /// The open subtitle menu, and the speech model's download shown on its generated row.
    private weak var subtitleList: CardTrackListView?
    private var generatedSubtitleProgress: AnyCancellable?
    private var subtitleSearchTask: Task<Void, Never>?
    private var subtitleOperationProgress: AnyCancellable?
    private var subtitleSyncProgress: AnyCancellable?

    /// Previous `railVisible`, so `applyChromeVisibility()` can spot the rail
    /// APPEARING and start every appearance on the scrubber.
    private var railWasVisible = false
    /// Last `$upNextEpisodes` emission, read by the Up Next panel and the rail button.
    private var upNextEpisodesCache: [PlexMetadata] = []

    /// The end-of-episode Up Next page. Built on first use and added above
    /// every other chrome layer while `postVideoState != .hidden`; removed
    /// (not just hidden) when it goes away so its buttons cannot hold focus.
    private var postVideoOverlay: PostVideoOverlayView?
    /// Darkens the video behind the Up Next card, as `chromeScrim` does behind the rail.
    private var postVideoScrim: SideScrimView?
    /// Snapshot of the last `$insightsCast` emission, read when the rail's
    /// Insights panel is presented.
    private var insightsCastCache: [MediaPerson] = []
    /// Snapshot of the last `$insightsTrivia`/`$suppressedTriviaIDs` emission,
    /// read when the rail's Insights panel is presented (P2a).
    private var insightsTriviaCache: TitleTrivia?
    private var suppressedTriviaIDsCache: Set<String> = []
    private var panGestureRecognizer: UIPanGestureRecognizer?
    private var touchSurfaceTapGesture: UITapGestureRecognizer?

    /// Opaque black plate that covers the whole player while it fades out on
    /// exit. Created lazily on the first exit and never removed, since the
    /// controller is being torn down anyway.
    private var exitFadeView: UIView?
    /// Strong reference to the exit fade's animator. A `UIViewPropertyAnimator`
    /// is not retained by the run loop until it starts, and a paused one aborts
    /// outright if it is released, so it has to be owned here for the duration.
    private var exitFadeAnimator: UIViewPropertyAnimator?
    /// True from the moment the exit fade starts until the dismissal is handed
    /// to `super`. The dismiss override can be re-entered (the system's Menu
    /// gesture echoes one in, and `$shouldDismiss` can fire alongside it), and
    /// without this a second call would restart the fade from black or strand
    /// the player behind a fully opaque plate.
    private var isFadingOut = false

    /// Focus stop for the content state (see `ContentFocusAnchorView`).
    private var contentAnchor: ContentFocusAnchorView?
    /// Touch twin for the content state's Up/Down (see `setupContentAnchor`).
    private var contentSwipeBinding: DirectionalInputBinding?
    /// Tap-vs-hold for a content-state Left/Right press, the same detector the
    /// scrubber proxy uses, so both focus regimes behave identically.
    private let contentPressDetector = DirectionalPressDetector()
    /// The press type that began the detector's current press, so only that
    /// press's release ends it.
    private var contentDirectionalPressType: UIPress.PressType?
    /// A content-state Select is waiting for its release (it acts on the UP,
    /// like the SwiftUI tap gesture it replaces).
    private var contentSelectPending = false
    /// Set once an arrow press arrives with the clickpad physically down: this
    /// remote reports its edge clicks as arrows, so a `.select` is never an
    /// edge click (see `edgeClickDirection`). Static because the remote
    /// outlives any one player.
    private static var clickpadRingSeen = false

    private let inputCoordinator: PlaybackInputCoordinator

    /// Reference to the player view model for handling Menu button logic
    weak var viewModel: UniversalPlayerViewModel?

    /// Callback when player is dismissed (to update SwiftUI state)
    var onDismiss: (() -> Void)?

    // MARK: - Initialization

    init<Content: View>(
        rootView: Content,
        viewModel: UniversalPlayerViewModel? = nil,
        inputCoordinator: PlaybackInputCoordinator
    ) {
        self.viewModel = viewModel
        self.inputCoordinator = inputCoordinator
        super.init(nibName: nil, bundle: nil)

        self.modalPresentationStyle = .fullScreen
        // State the transition explicitly, like every other modal in the app
        // (InfoPopup, ConfirmationPopup, PreviewCarousel, TextEntry), instead of
        // inheriting the UIKit default. Housekeeping, NOT a visual change: on
        // tvOS this renders indistinguishably from the default, so do not credit
        // any transition polish to this line or reach for it as one. The only
        // exit that looks different is the display-handshake one, and that is the
        // fade below.
        self.modalTransitionStyle = .crossDissolve

        let hosting = UIHostingController(rootView: AnyView(rootView))
        hosting.view.backgroundColor = .black
        self.hostingController = hosting
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        viewModel?.onSiloBufferingOffer = { [weak self] answer in
            guard let self, self.view.window != nil else { answer(false); return }
            let popup = ConfirmationPopupViewController(
                title: "Reduce Quality?",
                message: "Playback is buffering. Let Silo lower quality for this video?",
                confirmTitle: "Reduce Quality", cancelTitle: "Keep Quality",
                onConfirm: { answer(true) }, onCancel: { answer(false) })
            self.siloBufferingPopup = popup
            self.present(popup, animated: true)
        }
        viewModel?.onSiloBufferingCancel = { [weak self] in
            self?.siloBufferingPopup?.dismiss(animated: true)
            self?.siloBufferingPopup = nil
        }

        if let hosting = hostingController {
            addChild(hosting)
            view.addSubview(hosting.view)
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
                hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            ])
            hosting.didMove(toParent: self)
        }

        #if DEBUG
        Self.debugCurrent = self
        #endif

        // Created here so it exists before any chrome binding runs; restacked
        // just below the rail once the chrome is built (see below).
        setupContentAnchor()

        // Captions sit directly above the video and BELOW every chrome layer
        // added afterwards, so the rail can never be drawn behind them. A plain
        // subview rather than a hosting controller, which matters beyond tidiness:
        // a hosting controller applies the tvOS ~60pt title-safe inset to its
        // content, which would shrink the box every caption margin is measured
        // against.
        if let vm = viewModel {
            let overlay = CaptionOverlayView(
                model: vm.aetherSubtitleModel,
                style: CaptionAppearance.current(),
                videoSize: vm.videoSize,
                heightUnits: vm.subtitleHeightUnits
            )
            overlay.frame = view.bounds
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.assTrack = vm.assTrack
            overlay.sourceClock = { [weak vm] hostTime in vm?.subtitleSourceTime(atHostTime: hostTime) }
            view.addSubview(overlay)
            captionOverlay = overlay
        }

        if let vm = viewModel {
            chromeScrim.isUserInteractionEnabled = false

            // Full-frame pause dim sits just above the video, below every
            // other chrome layer (z-order bottom-up: scrim, dim, rail,
            // progress bar, skip pill, loading label).
            let dim = UIView()
            dim.backgroundColor = UIColor.black.withAlphaComponent(0.28)
            dim.alpha = 0
            dim.isUserInteractionEnabled = false

            let ambientBottomScrim = BottomScrimView()
            ambientBottomScrim.alpha = 0
            let railView = PlayerRailView()
            let bar = PlayerProgressBarView()
            let proxy = ScrubberFocusProxyView()
            let pill = SkipPillButton()
            // Alpha-driven visibility (see applyChromeVisibility): alpha 0 also
            // makes the pill non-focusable, so it can't steal focus while hidden.
            pill.alpha = 0
            pill.onSelect = { [weak self] in
                Task { await self?.viewModel?.skipActiveMarker() }
            }
            // Up/Down while the pill owns focus (chrome hidden) surfaces the
            // controls; while the chrome is up, let the engine move focus back
            // to the rail on Down (return false → not consumed).
            pill.onDirectionalPress = { [weak self] _ in
                guard let vm = self?.viewModel else { return false }
                if vm.showControls { return false }
                vm.showControlsTemporarily()
                return true
            }

            [chromeScrim, dim, ambientBottomScrim, railView, bar, proxy, pill].forEach {
                view.addSubview($0)
                $0.translatesAutoresizingMaskIntoConstraints = false
            }
            // Z-order bottom-up, explicit (subview-add order above already
            // matches, but state this is intentional, not incidental).
            view.bringSubviewToFront(chromeScrim)
            view.bringSubviewToFront(dim)
            // Ambient bottom scrim sits above the dim/chrome scrim but below
            // the scrubber, so during ambient pause the scrubber reads over it.
            view.bringSubviewToFront(ambientBottomScrim)
            view.bringSubviewToFront(railView)
            view.bringSubviewToFront(bar)
            view.bringSubviewToFront(proxy)
            view.bringSubviewToFront(pill)

            NSLayoutConstraint.activate([
                chromeScrim.topAnchor.constraint(equalTo: view.topAnchor),
                chromeScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                chromeScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                chromeScrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),

                dim.topAnchor.constraint(equalTo: view.topAnchor),
                dim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                dim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                dim.bottomAnchor.constraint(equalTo: view.bottomAnchor),

                // Ambient bottom scrim: full-width, pinned to the bottom, tall
                // enough to sit behind the scrubber (which is ~118pt off the
                // bottom) during ambient pause.
                ambientBottomScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                ambientBottomScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                ambientBottomScrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                ambientBottomScrim.heightAnchor.constraint(equalToConstant: 320),

                // Rail: the screen's bottom band, edge to edge (AVKit's layout).
                railView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                railView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                railView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                railView.heightAnchor.constraint(equalToConstant: PlayerRailView.railHeight),

                // Scrubber: a sibling laid over the rail where AVKit puts its
                // bar. It never moves, scrubbing or not.
                bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: PlayerRailView.sideInset),
                bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -PlayerRailView.sideInset),
                bar.topAnchor.constraint(equalTo: railView.topAnchor, constant: PlayerRailView.barTop),

                // Invisible focus proxy: geometrically below the button
                // cluster (leading/trailing match the bar's; top/bottom pad
                // 8pt around it) so the focus engine's downward search from
                // ANY cluster button lands here rather than settling on a
                // same-row cone candidate (the bug this proxy fixes). The
                // bar itself is the visible indicator — this view draws
                // nothing.
                proxy.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                proxy.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                // Track and time labels only: the bar view reserves space below
                // for the ring-jog label drop, and a proxy reaching into the pill
                // row would leave Down with no pill "below" it.
                proxy.topAnchor.constraint(equalTo: bar.topAnchor, constant: -8),
                proxy.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: 56),

                // Skip pill: AVKit's contextual-action spot, bottom right. Like
                // AVKit's it shows only while the controls are hidden.
                pill.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -11),
                pill.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -56),
            ])
            // The proxy is a sibling of the rail, so the rail can't reach it
            // through the view tree — hand it over so its preferredFocus can
            // make the scrubber the first landing.
            railView.scrubberFocusProxy = proxy
            railView.installPillEntryGuide(on: bar)

            // The content anchor sits above the video, captions and full-frame
            // scrims and below every control. Nothing full-screen may sit over
            // a focus item (the engine's occlusion test is geometric), and the
            // anchor must not sit over any control for the same reason.
            if let contentAnchor {
                view.insertSubview(contentAnchor, belowSubview: railView)
            }

            rail = railView
            progressBar = bar
            scrubberProxy = proxy
            skipPill = pill
            ambientScrim = ambientBottomScrim
            pausedDimView = dim

            bindChrome(to: vm)
        }

        // Every press is handled in pressesBegan/Ended (see "Content-state
        // presses"), not by gesture recognizers: a recognizer on this view did
        // not reliably see arrow presses while SwiftUI held focus, and once a
        // UIKit view holds focus it races that view's own press handling.

        // Pan gesture for swipe-to-scrub on Siri Remote touchpad
        setupPanGesture()

        // Bare-tap on the Siri Remote touch surface surfaces the timeline
        // overlay briefly (matches Plex's tvOS client behavior).
        setupTouchSurfaceTapGesture()

        // Observe viewModel's shouldDismiss property for programmatic dismissal
        viewModel?.$shouldDismiss
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shouldDismiss in
                if shouldDismiss {
                    self?.dismissPlayer()
                }
            }
            .store(in: &cancellables)

    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        viewModel?.beginDescriptionTranslation()
        // Fallback press target for when NOTHING holds focus. Presses go to
        // the focused view and bubble up the responder chain; the first
        // responder only receives them directly in the focusless case.
        becomeFirstResponder()
    }

    override var canBecomeFirstResponder: Bool {
        return true
    }

    /// Focus routing for the UIKit transport layer. Controls-focus mode
    /// prefers the rail (its own preferred-focus handles which button
    /// lands, remembering the last-focused control).
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // Post-video owns the screen while it is up, so it owns focus. Without
        // this the engine kept resolving into the chrome (or nowhere) and the
        // page rendered with no button focused.
        if let overlay = postVideoOverlay, overlay.superview != nil {
            return [overlay]
        }
        if let descriptionOverlay { return [descriptionOverlay] }
        if let panel = activeRailPanel, panel.window != nil {
            // A pane leaves focus on its pill, as AVKit's tabs do; Down enters it.
            if panel.isPane, let rail { return [rail] }
            return [panel]
        }
        // The SwiftUI error overlay (its own default focus picks the button).
        if viewModel?.playbackState.isFailed == true, let hostingController {
            return [hostingController]
        }
        // Chrome hidden + a skip marker up: the pill is the lone affordance, so
        // it owns focus and a single Select jumps forward. (Ownership is false
        // whenever the rail/panel is up, so this never fights the checks above.)
        if viewModel?.skipPillOwnsFocus == true, let skipPill {
            return [skipPill]
        }
        if viewModel?.controlsFocusActive == true, let rail {
            return [rail]
        }
        // Everything else is the content state. Falls through to the hosting
        // view only when the anchor is gated off, i.e. the error overlay.
        if let contentAnchor, contentAnchor.canBecomeFocused {
            return [contentAnchor]
        }
        return super.preferredFocusEnvironments
    }

    /// Override dismiss to intercept system-triggered dismissals (e.g., from Menu button)
    /// and only allow dismissal when we've explicitly decided to dismiss.
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        // Already fading out: this is a re-entrant call (the system's Menu
        // gesture echo, or `$shouldDismiss` firing alongside a press we already
        // acted on). Swallow it so the fade runs once and its completion stays
        // the sole owner of the actual dismissal.
        if isFadingOut { return }

        // If we just handled a menu action that closed something, block this dismiss
        if blockNextDismiss {
            blockNextDismiss = false
            return
        }

        // Check if we have something to close before allowing dismiss
        if let vm = viewModel {
            // Cancel auto-skip countdown if active
            if vm.skipCountdownSeconds > 0 {
                vm.cancelSkipCountdown()
                return
            }
            // Back closes the Up Next page and puts the video back at full
            // size; it does NOT leave the player. Every other layer here
            // (scrub, rail panel, ambient pause) already unwinds one step per
            // press, and post-video was the odd one out — it took the whole
            // player down with it, so a user who only wanted the credits back
            // had to restart the episode. A second press then exits, through
            // the checks below.
            if vm.postVideoState != .hidden {
                vm.dismissPostVideo()
                return
            }
            if vm.isScrubbing {
                vm.cancelScrub()
                return
            }
            if let panel = activeRailPanel {
                panel.dismissPanel()
                return
            }
            // Ambient pause backdrop: back returns to the paused frame, it
            // does not exit the player.
            if vm.showPausedPoster {
                vm.hidePausedPoster()
                return
            }
            // Back from the transport buttons closes the whole chrome in one
            // press (not first de-focusing onto the scrubber). Hiding
            // showControls cascades to clear controlsFocusActive via its didSet.
            if vm.controlsFocusActive || vm.showControls {
                withAnimation(.easeOut(duration: 0.25)) {
                    vm.showControls = false
                }
                return
            }
        }
        // Nothing to close, allow normal dismiss
        fadeOutThenDismiss(animated: flag, completion: completion)
    }

    // MARK: - Exit Fade

    /// Exit fade to black. It masks the HDMI renegotiation Match Content triggers
    /// when display criteria go back to nil, which blacks many TVs out for about a
    /// second (#249). Under ~0.3s reads as a stutter, over ~0.5s feels unresponsive.
    private static let exitFadeDuration: TimeInterval = 0.4

    /// Fade the player to black, then hand the dismissal to `super`. Cuts straight
    /// out when no HDMI handshake is coming.
    private func fadeOutThenDismiss(animated flag: Bool, completion: (() -> Void)?) {
        isFadingOut = true

        // Reset display criteria at the start of the fade so the HDMI handshake
        // runs behind it. Without this the engine drops them in `engine.stop()`,
        // after the dismissal, and the fade masks nothing. Do not gate it.
        let handshakeIncoming = DisplayCriteriaManager.shared.reset()

        // No criteria were set (Match Content off, or the panel was never
        // programmed), so there is nothing to mask. The simulator always lands here.
        guard handshakeIncoming else {
            performSuperDismiss(animated: flag, completion: completion)
            return
        }

        let cover = exitFadeView ?? makeExitFadeView()
        cover.alpha = 0
        view.bringSubviewToFront(cover)

        // One clock. The whole exit is this single animator's alpha ramp; there
        // is no second CA animation and no other layer moving alongside it.
        let animator = UIViewPropertyAnimator(duration: Self.exitFadeDuration, curve: .easeOut) {
            cover.alpha = 1
        }
        animator.addCompletion { [weak self] _ in
            guard let self else { return }
            self.exitFadeAnimator = nil
            self.performSuperDismiss(animated: flag, completion: completion)
        }
        exitFadeAnimator = animator
        animator.startAnimation()
    }

    /// Lets the fade's weak-self closure reach `super.dismiss`.
    private func performSuperDismiss(animated flag: Bool, completion: (() -> Void)?) {
        super.dismiss(animated: flag, completion: completion)
    }

    /// Full-bleed opaque black plate for the exit fade. Non-interactive and
    /// non-focusable so it cannot pull focus off the chrome while the fade runs
    /// (the player is on its way out, and a focus move here would be visible as
    /// a chrome state change under the fade).
    private func makeExitFadeView() -> UIView {
        let cover = UIView()
        cover.backgroundColor = .black
        cover.isUserInteractionEnabled = false
        cover.isOpaque = true
        cover.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cover)
        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: view.topAnchor),
            cover.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            cover.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        // Lay the plate out now so its first animated frame is already
        // full-bleed rather than zero-sized.
        view.layoutIfNeeded()
        exitFadeView = cover
        return cover
    }

    deinit {
        // A running UIViewPropertyAnimator aborts on release, so stop it first.
        if let animator = exitFadeAnimator, animator.state != .inactive {
            animator.stopAnimation(true)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        viewModel?.endDescriptionTranslation()
        blockDismissResetWorkItem?.cancel()
        blockDismissResetWorkItem = nil

        // Notify when dismissed
        if isBeingDismissed || isMovingFromParent {
            onDismiss?()
        }
    }

    // MARK: - Button Interception
    // Menu, Play/Pause, and the content state's arrows and Select. See
    // "Content-state presses" below.

    /// Track if we're currently consuming presses
    private var isHandlingMenuPress = false
    private var isHandlingSelectPress = false
    private var isHandlingPlayPausePress = false
    /// False until the first `.playing` of the current load; gates the
    /// paused presentation so a transient startup `.paused` never flashes
    /// "Paused" chrome before playback has begun.
    private var hasPlayedSinceLoad = false

    /// Last-seen value of `viewModel.skipPillOwnsFocus`, so a change can
    /// trigger a focus re-resolution toward/away from the pill exactly once.
    private var lastSkipPillOwnsFocus = false

    /// Flag to block dismiss calls that occur immediately after we handled a menu action
    /// This prevents the double-handling issue where handleMenuButton() closes something,
    /// then SwiftUI's responder chain also calls dismiss().
    private var blockNextDismiss = false
    private var blockDismissResetWorkItem: DispatchWorkItem?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        restartPaneIdleTimer()
        for press in presses {
            if press.type == .menu {
                isHandlingMenuPress = true
                handleMenuButton()
                return
            }
            if press.type == .select {
                if let vm = viewModel, vm.isScrubbing {
                    isHandlingSelectPress = true
                    // A 1st-gen Siri Remote edge click while shuttling bumps the
                    // speed, as an arrow press does on later remotes; a centre
                    // click commits.
                    if vm.scrubSpeed != 0, contentOwnsPress(.select), let forward = edgeClickDirection() {
                        inputCoordinator.handle(action: .scrubNudge(forward: forward), source: .irPress)
                    } else {
                        inputCoordinator.handle(action: .scrubCommit, source: .irPress)
                    }
                    return
                }
                if contentOwnsPress(.select) {
                    beginContentSelect()
                }
                return
            }
            if press.type == .playPause {
                // Always honored, whatever holds focus — rail buttons, the
                // scrubber stop, the content anchor, or an open panel. Commits
                // an active scrub, else toggles.
                isHandlingPlayPausePress = true
                inputCoordinator.handle(action: .playPause, source: .irPress)
                return
            }
            if Self.isArrow(press.type) {
                if RemoteInputHandler.isClickpadDown { Self.clickpadRingSeen = true }
                if contentOwnsPress(press.type) {
                    beginContentArrow(press.type)
                }
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.type == .menu {
                // Menu is always handled at the began phase, either by a
                // popup or by handleMenuButton. If focus moved mid-press
                // (a popup closed itself), the ended phase arrives on a
                // responder chain that never saw the began - letting it
                // bubble triggers the system's default dismiss and peels
                // an extra unwind layer (focus "goes to nil").
                isHandlingMenuPress = false
                return
            }
            if press.type == .select && isHandlingSelectPress {
                isHandlingSelectPress = false
                return
            }
            if press.type == .playPause && isHandlingPlayPausePress {
                isHandlingPlayPausePress = false
                return
            }
            if press.type == .select || Self.isArrow(press.type) {
                endContentPress(press.type)
                return
            }
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.type == .menu && isHandlingMenuPress {
                isHandlingMenuPress = false
                return
            }
            if press.type == .select && isHandlingSelectPress {
                isHandlingSelectPress = false
                return
            }
            if press.type == .playPause && isHandlingPlayPausePress {
                isHandlingPlayPausePress = false
                return
            }
            if press.type == .select || Self.isArrow(press.type) {
                cancelContentPress(press.type)
                return
            }
        }
        super.pressesCancelled(presses, with: event)
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Same types, same rule as the other phases: arrows and Select stop here.
        if presses.contains(where: { $0.type == .select || Self.isArrow($0.type) }) { return }
        super.pressesChanged(presses, with: event)
    }

    // MARK: - Content-state presses
    //
    // The one handler for directional and Select presses when no chrome control
    // owns them: focus on the content anchor, the skip pill, or nowhere. Do not
    // move these back to a focused SwiftUI layer or GameController (#212, #232, #305).
    // Arrow and Select presses never travel past this controller, so the
    // presenter behind the player cannot react to them.

    private static func isArrow(_ type: UIPress.PressType) -> Bool {
        switch type {
        case .upArrow, .downArrow, .leftArrow, .rightArrow: return true
        default: return false
        }
    }

    /// Whether a directional or Select press that reached this controller
    /// belongs to the content-state grammar.
    private func contentOwnsPress(_ type: UIPress.PressType) -> Bool {
        guard let vm = viewModel,
              vm.postVideoState == .hidden,
              !vm.playbackState.isFailed
        else { return false }
        // A presented rail panel owns its own content's presses.
        if let panel = activeRailPanel, panel.window != nil { return false }
        guard let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem else { return true }
        // Rail buttons and the scrubber proxy: the focus engine (or the proxy's
        // own press handling) already acted on this press.
        guard let focusedView = focused as? UIView else { return false }
        if focusedView === contentAnchor { return true }
        if focusedView === skipPill {
            // Only Left/Right seek behind the pill. An Up here is usually the
            // press that just moved focus onto it, so claiming it bounces focus back.
            return type == .leftArrow || type == .rightArrow
        }
        return false
    }

    private func setupContentAnchor() {
        let anchor = ContentFocusAnchorView()
        // The player opens in the content state; enabled before the first focus
        // pass so it is the initial landing (applyChromeVisibility owns it after).
        anchor.isFocusEnabled = true
        anchor.frame = view.bounds
        anchor.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if let hostingView = hostingController?.view {
            view.insertSubview(anchor, aboveSubview: hostingView)
        } else {
            view.addSubview(anchor)
        }
        contentAnchor = anchor

        // Up/Down's touch twin (the iPhone Remote sends no arrow presses).
        // Not while the clickpad is down: a click jolts the touch into a fake swipe.
        contentSwipeBinding = DirectionalInputBinding(
            gatedSwipesOn: anchor,
            directions: [.up, .down],
            shouldHandle: { [weak self] direction in
                guard let self, !RemoteInputHandler.isClickpadDown else { return false }
                return self.contentOwnsPress(direction == .up ? .upArrow : .downArrow)
            },
            onSwipe: { [weak self] direction in self?.handleContentVertical(up: direction == .up) }
        )

        contentPressDetector.onTap = { [weak self] forward in
            // Shift+arrow on a keyboard jumps, as it did on the GameController path.
            let action: PlaybackInputAction = RemoteInputHandler.isShiftHeld
                ? .jumpSeek(forward: forward) : .stepSeek(forward: forward)
            self?.inputCoordinator.handle(action: action, source: .irPress)
        }
        contentPressDetector.onHold = { [weak self] forward in
            self?.inputCoordinator.handle(action: .scrubNudge(forward: forward), source: .irPress)
        }
    }

    private func beginContentArrow(_ type: UIPress.PressType) {
        switch type {
        case .upArrow:
            handleContentVertical(up: true)
        case .downArrow:
            handleContentVertical(up: false)
        case .leftArrow, .rightArrow:
            beginContentDirectional(forward: type == .rightArrow, pressType: type)
        default:
            break
        }
    }

    /// Left/Right: a quick release skips (`tapSeekSeconds`), a hold starts the
    /// FF/RW shuttle, and any press while already shuttling bumps or redirects
    /// it at once (ShuttleGrammar) with no tap-vs-hold wait.
    private func beginContentDirectional(forward: Bool, pressType: UIPress.PressType) {
        guard let vm = viewModel else { return }
        if vm.isScrubbing && vm.scrubSpeed != 0 {
            inputCoordinator.handle(action: .scrubNudge(forward: forward), source: .irPress)
            return
        }
        contentDirectionalPressType = pressType
        contentPressDetector.begin(forward: forward)
    }

    /// Up/Down: while scrubbing, Up snaps to the next chapter in the direction
    /// of travel and Down cancels. Otherwise they surface the controls as AVKit
    /// does: Up lands on the first tool button, Down opens the Info pane.
    private func handleContentVertical(up: Bool) {
        guard let vm = viewModel else { return }
        vm.hidePausedPoster()
        if vm.isScrubbing {
            if up {
                vm.chapterSnap()
            } else {
                inputCoordinator.handle(action: .scrubCancel, source: .irPress)
            }
            return
        }
        if !vm.showControls {
            vm.showControlsTemporarily()
        }
        // The chrome sink runs a pass later; the rail must be up now for the
        // landing and the pane.
        applyChromeVisibility()
        if up {
            if let tool = rail?.firstToolButton { rail?.setFocusLanding(tool) }
            vm.enterControlsFocus()
        } else {
            if let info = rail?.infoButton { rail?.setFocusLanding(info) }
            vm.enterControlsFocus()
            presentPane(.info)
        }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    /// Select acts on its release, like the tap gesture it replaces: acting on
    /// the down can move focus mid-press (hiding the chrome hands focus to the
    /// skip pill when a marker is up), and the release would then land on
    /// whatever took focus.
    private func beginContentSelect() {
        if let forward = edgeClickDirection() {
            contentDirectionalPressType = .select
            contentPressDetector.begin(forward: forward)
        } else {
            contentSelectPending = true
        }
    }

    /// A 1st-generation Siri Remote reports EVERY click as `.select`, so its
    /// "click the right edge to skip" can only be recovered from where the
    /// finger rested before the click (tracked by RemoteInputHandler). Later
    /// remotes report edge clicks as arrow presses, which is authoritative;
    /// once one has been seen, a `.select` is only ever a centre click. The
    /// clickpad must be physically down, so a Select from anything else (IR,
    /// CEC, a keyboard's Return, a gamepad's A) never reads a stale touch.
    private func edgeClickDirection() -> Bool? {
        guard !Self.clickpadRingSeen, RemoteInputHandler.isClickpadDown else { return nil }
        return RemoteInputHandler.active?.clickpadEdge
    }

    private func endContentPress(_ type: UIPress.PressType) {
        if type == .select, contentSelectPending {
            contentSelectPending = false
            selectFromContent()
            return
        }
        if type == contentDirectionalPressType {
            contentDirectionalPressType = nil
            contentPressDetector.end()
        }
    }

    private func cancelContentPress(_ type: UIPress.PressType) {
        if type == .select { contentSelectPending = false }
        if type == contentDirectionalPressType {
            contentDirectionalPressType = nil
            contentPressDetector.cancel()
        }
    }

    /// Select with nothing else focused brings the controls up on the scrubber,
    /// where the next Select toggles playback (#410). With the controls already
    /// on screen it toggles playback at once.
    private func selectFromContent() {
        guard let vm = viewModel, !vm.playbackState.isFailed else { return }
        let chromeUp = vm.showControls && !vm.showPausedPoster
        withAnimation(.easeInOut(duration: 0.25)) {
            if chromeUp {
                inputCoordinator.handle(action: .playPause, source: .irPress)
            } else {
                vm.showControlsTemporarily()
            }
        }
        // The chrome sink runs a pass later; the proxy must be focusable now.
        applyChromeVisibility()
        guard scrubberProxy?.isFocusEnabled == true else { return }
        rail?.resetFocusMemory()
        vm.enterControlsFocus()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    /// Handle Menu button press with priority:
    /// 1. Cancel auto-skip countdown if active
    /// 2. Dismiss post-video overlay if showing
    /// 3. Cancel scrubbing if active
    /// 4. Close an open pill popup (Subtitles/Audio/Info) if any
    /// 5. Hide controls if visible
    /// 6. Dismiss player if nothing else to close
    private func handleMenuButton() {
        guard let vm = viewModel else {
            print("🎮 [MENU] No viewModel - dismissing player")
            dismissPlayer()
            return
        }

        if descriptionOverlay != nil {
            dismissDescription()
            blockDismissTemporarily()
            return
        }

        // Cancel auto-skip countdown if active (highest priority)
        if vm.skipCountdownSeconds > 0 {
            vm.cancelSkipCountdown()
            blockDismissTemporarily()
            return
        }

        // An open popup or pane closes first, even with focus outside it
        // (on a pane's pills). Inside it, its own pressesBegan got there first.
        if let panel = activeRailPanel, panel.window != nil {
            if !panel.contentHandlesMenuPress() {
                panel.dismissPanel()
            }
            blockDismissTemporarily()
            return
        }

        if inputCoordinator.target == nil {
            if vm.postVideoState != .hidden {
                // Return to the still-playing fullscreen video rather than
                // exiting the player (see handleInputAction(.back)). This is
                // the target-less fallback; the primary path routes .back
                // through the coordinator to the same behavior.
                vm.dismissPostVideo()
            } else if vm.isScrubbing {
                vm.cancelScrub()
            } else if let panel = activeRailPanel {
                // Edge case only: while focus is inside the panel, Menu is
                // consumed by PlayerRailPanelView.pressesBegan (presses go
                // to the focused view and bubble up — they reach the panel
                // before this VC). This branch covers a Menu press arriving
                // with focus OUTSIDE the panel; same content-first-refusal
                // contract, see RailPanelMenuHandling.
                if !panel.contentHandlesMenuPress() {
                    panel.dismissPanel()
                }
            } else if vm.showPausedPoster {
                vm.hidePausedPoster()
            } else if vm.controlsFocusActive {
                vm.exitControlsFocus()
            } else if vm.showControls {
                withAnimation(.easeOut(duration: 0.25)) {
                    vm.showControls = false
                }
            } else {
                dismissPlayer()
            }
            return
        }

        // If we're consuming this menu press in-app (not dismissing), block SwiftUI fallback dismiss briefly.
        // showPausedPoster counts: the coordinator's .back consumes the press by
        // returning to the paused frame, and by the time the fallback dismiss
        // fires the poster flag is already cleared — without this term the
        // fallback would exit the player anyway.
        let shouldBlockDismiss = vm.postVideoState == .hidden
            && (vm.isScrubbing || vm.showControls || vm.showPausedPoster)
        if shouldBlockDismiss {
            blockDismissTemporarily()
        }

        inputCoordinator.handle(action: .back, source: .irPress)
    }

    // MARK: - Swipe-to-Scrub Gesture

    private func setupPanGesture() {
        let panRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        // Only recognize indirect touches (Siri Remote touchpad, not direct screen touches)
        panRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        // A pan that begins cancels the focus engine's move, so the delegate
        // lets it begin only on a clearly horizontal, actionable swipe.
        panRecognizer.delegate = self
        view.addGestureRecognizer(panRecognizer)
        panGestureRecognizer = panRecognizer
    }

    /// True when a touch-surface swipe should drive the scrubber. Mirrors the
    /// bail conditions in `handlePanGesture`, since beginning steals the gesture
    /// from the focus engine. Only focus on a transport button blocks it.
    private var panCanDriveScrub: Bool {
        guard let vm = viewModel else { return false }
        return !vm.playbackState.isFailed
            && vm.postVideoState == .hidden
            && descriptionOverlay == nil
            && !focusIsOnTransportButton
    }

    /// Focus is parked on a transport button rather than the scrubber. While
    /// `controlsFocusActive`, the scrubber proxy is the only focusable element
    /// that wants swipes (see `updateScrubberFocusEnabled`); anything else in
    /// the rail needs left/right to move focus, not to seek.
    private var focusIsOnTransportButton: Bool {
        guard viewModel?.controlsFocusActive == true else { return false }
        return scrubberProxy?.isFocused != true
    }

    // MARK: - Touch-Surface Tap (timeline overlay)

    /// Bare-tap on the Siri Remote touch surface (no force/click). Fires
    /// only on `.indirect` touches — the touchpad — and not on `.select`
    /// presses (those are the click and are routed to play/pause via the
    /// micro-gamepad buttonA handler). Coexists with the pan recognizer:
    /// if the user starts moving, pan takes over and tap doesn't fire.
    private func setupTouchSurfaceTapGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTouchSurfaceTap))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        // On tvOS, UITapGestureRecognizer defaults allowedPressTypes to
        // [.select], so without this it would silently wait for a click
        // rather than a bare finger tap.
        tap.allowedPressTypes = []
        view.addGestureRecognizer(tap)
        touchSurfaceTapGesture = tap
    }

    @objc private func handleTouchSurfaceTap() {
        guard let vm = viewModel else { return }
        guard !vm.isScrubbing,
              vm.postVideoState == .hidden,
              !vm.playbackState.isFailed,
              descriptionOverlay == nil
        else { return }

        // With the controls up, a bare tap (not a click) cycles the bar
        // between play time and the clock.
        let clicked = RemoteInputHandler.isClickpadDown
            || CACurrentMediaTime() - RemoteInputHandler.lastClickpadDownAt < 0.6
        if vm.showControls, !clicked, let bar = progressBar {
            bar.setShowsClockTimes(!bar.showsClockTimes)
            SettingsStore.setBool(Self.clockTimesKey, bar.showsClockTimes)
        }
        vm.showControlsTemporarily()
    }

    private static let clockTimesKey = "playerShowsClockTimes"

    @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        // Kept in sync with `panCanDriveScrub`, which stops the recognizer from
        // beginning (and thus stealing the gesture) in these same states.
        guard panCanDriveScrub else { return }
        // A touch that turned into a ring jog belongs to the jog from then on.
        guard !RemoteInputHandler.isRingJogging else { return }

        // Swipe-to-scrub works whether playing or paused.

        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)

        switch gesture.state {
        case .began:
            inputCoordinator.handle(action: .scrubRelative(seconds: 0), source: .irPress)

        case .changed:
            // Proportional scrubbing: horizontal translation maps to seek time
            // Sensitivity: ~1 second per 2 points of horizontal movement
            // Positive translation.x = swipe right = forward
            let seekDelta = translation.x * 0.5
            inputCoordinator.handle(action: .scrubRelative(seconds: seekDelta), source: .irPress)
            gesture.setTranslation(.zero, in: view)

        case .ended, .cancelled:
            // If significant horizontal velocity, apply a final "flick" adjustment
            if abs(velocity.x) > 500 {
                let flickSeekDelta = velocity.x * 0.02  // Small multiplier for flick
                inputCoordinator.handle(action: .scrubRelative(seconds: flickSeekDelta), source: .irPress)
            }
            // Don't auto-commit - wait for user to press play/select to confirm position

        default:
            break
        }
    }

    private func dismissPlayer() {
        // This is the decided exit: the override's "is there a panel to close
        // first" checks have already been made by the caller, so route straight
        // to the fade, which ends in super.dismiss and bypasses them.
        guard !isFadingOut else { return }
        fadeOutThenDismiss(animated: true) { [weak self] in
            self?.onDismiss?()
        }
    }

    private func blockDismissTemporarily() {
        blockNextDismiss = true
        blockDismissResetWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.blockNextDismiss = false
            self?.blockDismissResetWorkItem = nil
        }
        blockDismissResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + InputConfig.blockDismissTimeout, execute: workItem)
    }

    // MARK: - Chrome Bindings

    private func bindChrome(to vm: UniversalPlayerViewModel) {
        guard let rail, let bar = progressBar else { return }
        bar.setShowsClockTimes(SettingsStore.bool(Self.clockTimesKey, default: false))
        vm.descriptionTranslationController.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateDescriptionSurfaces() }
            .store(in: &cancellables)

        // Static metadata (re-applied on episode advance via itemGeneration).
        applyRailMetadata(vm: vm)

        // Scrubber focus proxy: an invisible view below the rail's buttons, so a
        // Down from any of them lands here. It owns tap-vs-hold detection.
        // Controls-focus mode stays active so the GameController seek path stays
        // swallowed and no press seeks twice.
        scrubberProxy?.isScrubbingProvider = { [weak vm] in vm?.isScrubbing ?? false }
        scrubberProxy?.onSkip = { [weak self, weak vm] forward in
            guard let vm else { return }
            self?.inputCoordinator.handle(action: .stepSeek(forward: forward), source: .irPress)
            vm.showControlsTemporarily()
        }
        scrubberProxy?.onShuttle = { [weak vm] forward in
            guard let vm else { return }
            vm.scrubInDirection(forward: forward)
            vm.showControlsTemporarily()
        }
        scrubberProxy?.onSelect = { [weak self, weak vm] in
            guard let vm else { return }
            // Center commits an active scrub; otherwise it toggles play/pause,
            // matching Apple's system player and the touch-remote flow.
            if vm.isScrubbing {
                self?.inputCoordinator.handle(action: .scrubCommit, source: .irPress)
            } else if !vm.showControls {
                // The proxy KEEPS focus after the rail auto-hides (see the
                // `proxyHasFocus` term on its focus gate), so a Select with the
                // chrome down arrives here rather than at the content layer's
                // tap handler. That press means "bring the rail back", not
                // "toggle playback" — reopen at whatever the current play state
                // is and leave the transport alone.
                vm.showControlsTemporarily()
            } else if let forward = self?.edgeClickDirection() {
                // A 1st-gen Siri Remote edge click skips here too, as it does from the content state.
                self?.inputCoordinator.handle(action: .stepSeek(forward: forward), source: .irPress)
                vm.showControlsTemporarily()
            } else {
                self?.inputCoordinator.handle(action: .playPause, source: .irPress)
            }
        }

        vm.$itemGeneration
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak vm] _ in
                self?.progressBar?.resetFilmstrip()
                if let vm { self?.applyRailMetadata(vm: vm) }
                // An open Playlist pane marks the old position; it rebuilds on the next open.
                if vm?.playQueue != nil, self?.openPaneTab == .upNext { self?.activeRailPanel?.dismissPanel() }
            }
            .store(in: &cancellables)

        vm.$currentTime
            .combineLatest(vm.$duration, vm.$isScrubbing, vm.$scrubTime)
            .combineLatest(vm.$wheelScrubbing.removeDuplicates())
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak vm] combined, isWheelScrubbing in
                let (currentTime, duration, isScrubbing, scrubTime) = combined
                guard let self, let vm else { return }
                self.progressBar?.setRingFinger(RemoteInputHandler.ringFingerPosition)
                self.progressBar?.update(
                    currentTime: currentTime, duration: duration,
                    isScrubbing: isScrubbing, scrubTime: scrubTime,
                    scanLevel: vm.scrubSpeed,
                    scrubThumbnail: vm.scrubThumbnail,
                    markers: vm.metadata.allMarkers,
                    chapters: vm.metadata.Chapter ?? [],
                    isWheelScrubbing: isWheelScrubbing
                )
                // Scrubbing hides the rail and skip pill; scrubber and
                // scrim stay (design mock state 2). The bar itself keeps
                // its rest geometry — no inset swap.
                self.applyChromeVisibility()
            }
            .store(in: &cancellables)

        vm.$showControls
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyChromeVisibility() }
            .store(in: &cancellables)

        // Every skip shows AVKit's glyph beside the time, on the full chrome or the bar alone.
        vm.$seekIndicator
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] indicator in self?.progressBar?.showSkipIndicator(indicator) }
            .store(in: &cancellables)
        vm.$showsSkipBar
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyChromeVisibility() }
            .store(in: &cancellables)

        // Caption inputs. The overlay measures against the picture, so a new
        // aspect ratio has to reach it; the height stepper is per-title and can
        // change mid-playback.
        vm.$videoSize
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in self?.captionOverlay?.videoSize = size }
            .store(in: &cancellables)

        vm.$subtitleHeightUnits
            .receive(on: DispatchQueue.main)
            .sink { [weak self] units in self?.captionOverlay?.heightUnits = units }
            .store(in: &cancellables)

        // ASS/SSA track script for the overlay's libass layer.
        vm.$assTrack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in self?.captionOverlay?.assTrack = track }
            .store(in: &cancellables)

        // A track the content filter reads unseen draws nothing: subtitles are Off or generated.
        vm.$silentSubtitleTrackId
            .combineLatest(vm.$currentSubtitleTrackId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] silent, shown in
                self?.captionOverlay?.isHidden = silent != nil && shown != UniversalPlayerViewModel.generatedSubtitleId
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: CaptionAppearance.changedNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.captionOverlay?.style = CaptionAppearance.current() }
            .store(in: &cancellables)

        // Ambient pause: the whole chrome yields to the clean backdrop.
        vm.$pausePresentation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyChromeVisibility() }
            .store(in: &cancellables)

        vm.$playbackState
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak vm] state in
                guard let self, let vm else { return }
                let loading = state == .loading || state == .idle
                // Startup can pass through a split-second .paused before
                // the first .playing; the paused presentation (indicator,
                // dims) must not flash for it. Only a pause AFTER playback
                // has actually begun counts; a new load resets the gate.
                if state == .playing {
                    self.hasPlayedSinceLoad = true
                } else if loading {
                    self.hasPlayedSinceLoad = false
                }
                self.rail?.setLoading(loading)
                self.progressBar?.setSkeleton(loading)
                self.progressBar?.setPausedDim(state == .paused && self.hasPlayedSinceLoad)

                self.applyChromeVisibility()
            }
            .store(in: &cancellables)

        // Pill title + visibility + focus-ownership all react to the skip
        // button toggling and to the live countdown ticking.
        vm.$showSkipButton
            .combineLatest(vm.$skipCountdownSeconds)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshSkipPill() }
            .store(in: &cancellables)

        // Post-video takes its own focus layer and hides the pill; keep the
        // pill's visibility/ownership in sync when it appears or dismisses.
        vm.$postVideoState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                // Order follows focus: mount the page BEFORE the chrome gives up
                // focus, and restore the chrome (re-enabling the content anchor)
                // BEFORE the page is removed, so each focus update runs while its
                // target can take focus.
                if state != .hidden {
                    self?.applyPostVideoState(state)
                    self?.applyChromeVisibility()
                } else {
                    self?.applyChromeVisibility()
                    self?.applyPostVideoState(state)
                }
            }
            .store(in: &cancellables)

        // The page's live parts: the countdown ring and the Play Next / Play
        // Now title both key off the countdown.
        vm.$countdownSeconds
            .combineLatest(vm.$isCountdownPaused, vm.$nextEpisode, vm.$nextEpisodeError)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPostVideoContent() }
            .store(in: &cancellables)

        vm.$subtitleTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak rail, weak vm] tracks in
                // Port of the old card binding: same enabled-look, applied
                // to the rail's subtitles button now.
                rail?.subtitlesButton.alpha = tracks.isEmpty && !(vm?.offersGeneratedSubtitles ?? false) ? 0.4 : 1
            }
            .store(in: &cancellables)

        vm.$upNextEpisodes
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak vm] episodes in
                guard let self, let vm else { return }
                self.upNextEpisodesCache = episodes
                if let queue = vm.playQueue {
                    // A playlist of any type gets the pane, titled for what it lists.
                    self.rail?.upNextButton.setTitle("Playlist")
                    self.rail?.setUpNextAvailable(queue.entries.count > 1)
                } else {
                    self.rail?.setUpNextAvailable(!episodes.isEmpty && vm.metadata.type == "episode")
                }
                // The open Up Next panel is reading a snapshot of the old
                // list — a fresh instance is built per presentation, so
                // there's no way to refresh it in place. Dismiss rather
                // than leave a stale list on screen; doesn't touch the
                // CC/audio/info panels, which don't key off this publisher.
                if self.openPaneTab == .upNext {
                    self.activeRailPanel?.dismissPanel()
                }
            }
            .store(in: &cancellables)

        vm.$insightsCast
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cast in
                guard let self else { return }
                self.insightsCastCache = cast
                self.updateInsightsAvailability()
            }
            .store(in: &cancellables)

        vm.$insightsTrivia
            .combineLatest(vm.$suppressedTriviaIDs)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] trivia, suppressed in
                guard let self else { return }
                self.insightsTriviaCache = trivia
                self.suppressedTriviaIDsCache = suppressed
                self.updateInsightsAvailability()
            }
            .store(in: &cancellables)

        // Kick the cast + trivia loads per item. @Published replays the
        // current value on subscribe, so this also fires once at bind time
        // for the first item.
        vm.$itemGeneration
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak vm] _ in
                Task { await vm?.loadInsightsCast() }
                Task { await vm?.loadInsightsTrivia() }
            }
            .store(in: &cancellables)

        vm.$controlsFocusActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                guard let self else { return }
                // The scrubber proxy is the rail's FIRST landing, and its
                // `canBecomeFocused` is gated on `controlsFocusActive` — which
                // has only just flipped. Refresh that gate BEFORE resolving
                // focus, or the engine polls a still-unfocusable proxy and the
                // rail falls through to the subtitles button.
                self.applyChromeVisibility()
                // Leaving controls-focus ends this visit to the rail, so the
                // next one starts on the scrubber again rather than on whatever
                // button happened to be focused when the user backed out.
                if !active { self.rail?.resetFocusMemory() }
                self.setNeedsFocusUpdate()
                self.updateFocusIfNeeded()
            }
            .store(in: &cancellables)

        // Rail actions. (No play/pause control, no skip-back — the remote owns seeking.)
        rail.onSubtitles = { [weak self] in
            guard let vm = self?.viewModel else { return }
            Task { [weak self, weak vm] in
                guard let vm else { return }
                await vm.refreshSubtitleActions()
                guard let self, self.viewModel === vm, self.activeRailPanel == nil else { return }
                self.presentSubtitleMenu(vm)
            }
        }
        rail.onSubtitlesHold = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            if vm.currentSubtitleTrackId != nil {
                vm.selectSubtitleTrack(id: nil)
                self.rail?.showNote("Subtitles off")
            } else if let id = vm.subtitleOnTrackId,
                      // A hold never starts the generated model's download.
                      id != UniversalPlayerViewModel.generatedSubtitleId || SpeechModelStore.shared.state == .ready {
                vm.selectSubtitleTrack(id: id)
                self.rail?.showNote("Subtitles on")
            }
        }
        rail.onAudio = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            self.presentRailPanel(
                content: CardTrackListView.audioMenu(
                    tracks: vm.audioTracks, selectedTrackId: vm.currentAudioTrackId,
                    onSelect: { [weak vm, weak self] id in
                        if let id { vm?.selectAudioTrack(id: id) }
                        self?.activeRailPanel?.dismissPanel()
                    }),
                width: CardTrackListView.menuWidth, from: rail.audioButton)
        }
        // The pills below the bar open AVKit's info pane; moving across them
        // while it is open switches the tab.
        rail.onInfo = { [weak self] in self?.presentPane(.info) }
        rail.onChapters = { [weak self] in self?.presentPane(.chapters) }
        rail.onUpNext = { [weak self] in self?.presentPane(.upNext) }
        rail.onInsights = { [weak self] in self?.presentPane(.insights) }
        rail.onDetails = { [weak self] in self?.presentPane(.details) }
        rail.onPillFocused = { [weak self] pill in
            guard let self, self.activeRailPanel?.isPane == true,
                  let tab = self.paneTab(for: pill), tab != self.openPaneTab else { return }
            self.presentPane(tab)
        }
        rail.setChaptersAvailable(!(vm.metadata.Chapter ?? []).isEmpty)
        rail.setDetailsAvailable(true)

        // Content filter: present only while filtering is on in Settings, so
        // nobody who doesn't use it pays a rail slot for it. Its menu pauses it
        // for this title (the next one is filtered again); the glyph is filled
        // while filtering and outlined while paused or with nothing to act on.
        rail.onFilter = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            let filter = vm.contentFilter
            self.presentRailPanel(
                content: CardTrackListView(header: "Content Filter", rows: [
                    .init(title: "Filtering On", subtitle: vm.contentFilterNotice, trackId: 0, isSelected: !filter.isPaused),
                    .init(title: "Pause for This Title", subtitle: nil, trackId: 1, isSelected: filter.isPaused),
                ], onSelect: { [weak self, weak filter] choice in
                    filter?.setPaused(choice == 1)
                    self?.activeRailPanel?.dismissPanel()
                }),
                width: CardTrackListView.menuWidth, from: rail.filterButton)
        }
        // Quality: every choice, the session's pick checked; Auto says what it is playing.
        rail.setQualityAvailable(!vm.source.isSilo || vm.siloQualityChoices != nil)
        rail.onQuality = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            if vm.source.isSilo, vm.siloQualityChoices == nil { return }
            if let qualities = vm.siloQualityChoices {
                let choices: [MediaQualityPreference] = [.automatic] + qualities.map { .offered(id: $0.id) }
                let activeLabel = vm.siloActiveQualityID.map { id in
                    qualities.first(where: { $0.id == id })?.displayName ?? id
                }
                let rows = choices.enumerated().map { index, choice in
                    CardTrackListView.Row(
                        title: index == 0 ? "Auto" : qualities[index - 1].displayName ?? qualities[index - 1].id,
                        subtitle: index == 0 ? activeLabel.map { "Playing \($0)" } : nil,
                        trackId: index, isSelected: choice == vm.siloSelectedQuality)
                }
                var menuRows = rows
                if vm.canRestoreSiloQuality {
                    menuRows.append(.init(title: "Restore quality", subtitle: "Clear learned connection limit",
                                          trackId: choices.count, isSelected: false))
                }
                self.presentRailPanel(content: CardTrackListView(header: "Quality", rows: menuRows,
                    onSelect: { [weak vm, weak self] index in
                        if let index, choices.indices.contains(index) { vm?.selectSiloQuality(choices[index]) }
                        else if index == choices.count { vm?.restoreSiloQuality() }
                        self?.activeRailPanel?.dismissPanel()
                    }), width: CardTrackListView.menuWidth, from: rail.qualityButton)
                return
            }
            let choices = StreamingQuality.allChoices
            let playing = "Playing " + (vm.activeStreamPlan.step?.label ?? "Original")
            let rows = choices.enumerated().map { index, choice in
                CardTrackListView.Row(
                    title: choice.label,
                    subtitle: choice == .auto && vm.qualityChoice == .auto ? playing : nil,
                    trackId: index,
                    isSelected: choice == vm.qualityChoice)
            }
            self.presentRailPanel(
                content: CardTrackListView(header: "Quality", rows: rows, onSelect: { [weak vm, weak self] index in
                    if let index, choices.indices.contains(index) { vm?.selectQuality(choices[index]) }
                    self?.activeRailPanel?.dismissPanel()
                }),
                width: CardTrackListView.menuWidth, from: rail.qualityButton)
        }
        vm.contentFilter.$isEnabled
            .combineLatest(vm.contentFilter.$isPaused, vm.$contentFilterNotice, vm.contentFilter.$hasSceneSkips)
            .receive(on: DispatchQueue.main)
            .sink { [weak rail] enabled, paused, notice, skips in
                // A restricted profile cannot pause the filter its owner set.
                rail?.setFilterAvailable(enabled && !PlexUserProfileManager.shared.isRestrictedProfile)
                rail?.setFilterActive(!paused && (notice == nil || skips))
            }
            .store(in: &cancellables)
    }

    /// Whether the Insights panel has anything to show: a non-empty cast
    /// list, or at least one trivia fact left after the suppression filter. Either section alone is enough to surface the
    /// rail button; both empty means fully graceful-absent (no button).
    private var insightsButtonShouldBeAvailable: Bool {
        if !insightsCastCache.isEmpty { return true }
        guard let trivia = insightsTriviaCache else { return false }
        return !trivia.visibleFacts(suppressed: suppressedTriviaIDsCache).isEmpty
    }

    /// Re-derives the rail's Insights button visibility from the current
    /// cast + trivia snapshots. Called from both the `$insightsCast` and
    /// `$insightsTrivia` sinks since either can flip the combined
    /// availability independently of the other.
    private func updateInsightsAvailability() {
        rail?.setInsightsAvailable(insightsButtonShouldBeAvailable)
    }

    /// Shared presenter for the rail panels; presenting one dismisses the last.
    /// Refuses while the rail is hidden or mid-scrub. Returns whether it presented.
    @discardableResult
    private func presentRailPanel(content: UIView, width: CGFloat, from button: UIView) -> Bool {
        guard let rail, rail.alpha > 0.5, viewModel?.isScrubbing != true else { return false }
        activeRailPanel?.dismissPanel()
        let panel = PlayerRailPanelView.present(content: content, width: width,
                                                in: view, aboveRail: rail, towards: button)
        adoptRailPanel(panel)
        return true
    }

    private func presentSubtitleMenu(_ vm: UniversalPlayerViewModel) {
        var actions: [CardActionConfig] = []
        if vm.isSiloPlayback {
            actions.append(CardActionConfig(title: "Silo Subtitles", subtitle: "Search, AI and audio sync",
                                            showsChevron: true) { [weak self] _ in
                self?.presentSiloSubtitleMenu()
            })
        } else if vm.canSearchSubtitles {
            actions.append(CardActionConfig(title: "Search for Subtitles") { [weak self] row in
                self?.searchSubtitles(from: row)
            })
        }
        let list = CardTrackListView.subtitleMenu(
            tracks: vm.subtitleMenuTracks,
            selectedTrackId: vm.currentSubtitleTrackId, onTrackId: vm.subtitleOnTrackId, actions: actions,
            steppers: [
                CardStepperConfig(title: "Delay",
                    value: { [weak vm] in SubtitleAdjustments.formattedDelay(vm?.subtitleDelaySeconds ?? 0) },
                    onStep: { [weak vm] step in vm?.adjustSubtitleDelay(bySteps: step) }),
                CardStepperConfig(title: "Height",
                    value: { [weak vm] in SubtitleAdjustments.formattedHeight(vm?.subtitleHeightUnits ?? 0) },
                    onStep: { [weak vm] step in vm?.adjustSubtitleHeight(bySteps: step) }),
            ],
            onSelect: { [weak vm, weak self] id in
                vm?.selectSubtitleTrack(id: id)
                if id == UniversalPlayerViewModel.generatedSubtitleId, SpeechModelStore.shared.state != .ready {
                    self?.subtitleList?.checkTrack(id)
                } else {
                    self?.activeRailPanel?.dismissPanel()
                }
            })
        subtitleList = list
        generatedSubtitleProgress = SpeechModelStore.shared.$state
            .dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak list] _ in
                list?.updateTrack(UniversalPlayerViewModel.generatedSubtitleId,
                                  subtitle: UniversalPlayerViewModel.generatedSubtitleStatus)
            }
        presentRailPanel(content: list, width: CardTrackListView.menuWidth, from: rail?.subtitlesButton ?? view)
    }

    private func presentSiloSubtitleMenu() {
        guard let vm = viewModel, vm.isSiloPlayback else { return }
        var actions: [CardActionConfig] = []
        if vm.canSearchSubtitles {
            actions.append(CardActionConfig(title: "Search Subtitles", subtitle: vm.subtitleSearchLanguageName) {
                [weak self] row in self?.searchSubtitles(from: row)
            })
        }
        if vm.siloSubtitleSyncStatus?.isAvailable == true {
            actions.append(CardActionConfig(title: "Sync with Audio",
                subtitle: vm.siloSubtitleSyncState?.label ?? "Downloaded subtitles and sidecar files",
                showsChevron: true) { [weak self] _ in self?.presentSiloSubtitleSync() })
        }
        let options = vm.siloSubtitleGenerationOptions
        if options.contains(where: { $0.kind != .translate }) {
            actions.append(CardActionConfig(title: "Generate from Audio", subtitle: "Silo AI transcription",
                                            showsChevron: true) { [weak self] _ in
                self?.presentSiloSubtitleGeneration(translation: false)
            })
        }
        if options.contains(where: { $0.kind == .translate }) {
            actions.append(CardActionConfig(title: "Translate a Subtitle",
                subtitle: "To \(vm.subtitleSearchLanguageName) · Silo AI", showsChevron: true) { [weak self] _ in
                self?.presentSiloSubtitleGeneration(translation: true)
            })
        }
        if !vm.siloSubtitleJobs.isEmpty || vm.subtitleOperation.isBusy {
            actions.append(CardActionConfig(title: "Subtitle Jobs", subtitle: "Progress and results",
                                            showsChevron: true) { [weak self] _ in self?.presentSiloSubtitleJobs() })
        }
        let rows = actions.isEmpty ? [
            CardTrackListView.Row(title: "No Server Actions Available",
                subtitle: "Check subtitle features and permissions on Silo.", trackId: nil,
                isSelected: false, isEnabled: false, wrapsSubtitle: true)
        ] : []
        actions.append(CardActionConfig(title: "Refresh Availability") { [weak self, weak vm] row in
            guard let self, let vm else { return }
            let origin = self.activeRailPanel
            row.setTitle("Checking Silo…")
            Task { [weak self, weak vm] in
                guard let vm else { return }
                await vm.refreshSubtitleActions()
                guard let self, self.viewModel === vm, self.activeRailPanel === origin else { return }
                self.presentSiloSubtitleMenu()
            }
        })
        let list = CardTrackListView(header: "Silo Subtitles", rows: rows, actions: actions,
            onBack: { [weak self] in
                guard let self, let vm = self.viewModel else { return }
                self.presentSubtitleMenu(vm)
            }, onSelect: { _ in })
        presentRailPanel(content: list, width: CardTrackListView.menuWidth, from: rail?.subtitlesButton ?? view)
    }

    private func presentSiloSubtitleGeneration(translation: Bool) {
        guard let vm = viewModel else { return }
        if vm.subtitleOperation.isBusy { presentSubtitleOperation(); return }
        let options = vm.siloSubtitleGenerationOptions.filter { ($0.kind == .translate) == translation }
        let rows = options.enumerated().map {
            CardTrackListView.Row(title: $0.element.title, subtitle: $0.element.detail,
                                 trackId: $0.offset, isSelected: false)
        }
        let header = translation ? "Translate to \(vm.subtitleSearchLanguageName)" : "Generate from Audio"
        let list = CardTrackListView(header: header, rows: rows,
            onBack: { [weak self] in self?.presentSiloSubtitleMenu() },
            onSelect: { [weak self, weak vm] index in
                guard let index, options.indices.contains(index), let vm else { return }
                vm.generateSiloSubtitles(options[index])
                self?.presentSubtitleOperation()
            })
        presentRailPanel(content: list, width: CardTrackListView.menuWidth, from: rail?.subtitlesButton ?? view)
    }

    private func presentSiloSubtitleJobs() {
        guard let vm = viewModel else { return }
        if vm.subtitleOperation.isBusy { presentSubtitleOperation(); return }
        let jobs = vm.siloSubtitleJobs
        let rows = jobs.enumerated().map {
            CardTrackListView.Row(title: $0.element.menuTitle, subtitle: $0.element.statusText,
                                 trackId: $0.offset, isSelected: false)
        }
        let list = CardTrackListView(header: "Subtitle Jobs", rows: rows,
            onBack: { [weak self] in self?.presentSiloSubtitleMenu() },
            onSelect: { [weak self, weak vm] index in
                guard let index, jobs.indices.contains(index), let vm else { return }
                vm.followSiloSubtitleJob(jobs[index])
                self?.presentSubtitleOperation()
            })
        presentRailPanel(content: list, width: CardTrackListView.menuWidth, from: rail?.subtitlesButton ?? view)
    }

    private func presentSubtitleOperation() {
        guard let vm = viewModel else { return }
        let list = CardTrackListView(header: "Silo Subtitle Job", rows: [
            CardTrackListView.Row(title: vm.subtitleOperation.title, subtitle: vm.subtitleOperation.detail,
                                 trackId: 0, isSelected: false, isEnabled: false, wrapsSubtitle: true)
        ], actions: [
            CardActionConfig(title: "Cancel Job", isEnabled: { [weak vm] in
                vm?.subtitleOperation.cancellableJobID != nil
            }) { [weak vm] _ in Task { await vm?.cancelSiloSubtitleJob() } },
            CardActionConfig(title: "Back to Silo Subtitles", showsChevron: true) { [weak self] _ in
                self?.presentSiloSubtitleMenu()
            }
        ], onBack: { [weak self] in self?.presentSiloSubtitleMenu() }, onSelect: { _ in })
        subtitleOperationProgress = vm.$subtitleOperation.receive(on: DispatchQueue.main).sink { [weak list] state in
            list?.updateTrack(0, title: state.title, subtitle: state.detail)
            list?.refreshActionAvailability()
        }
        presentRailPanel(content: list, width: CardTrackListView.menuWidth, from: rail?.subtitlesButton ?? view)
    }

    private func presentSiloSubtitleSync() {
        guard let vm = viewModel else { return }
        let list = CardTrackListView(header: "Sync with Audio", rows: [
            CardTrackListView.Row(title: vm.siloSubtitleSyncState?.label ?? "Selected Subtitle",
                subtitle: vm.siloSubtitleSyncDetail, trackId: 0, isSelected: false, isEnabled: false, wrapsSubtitle: true),
            CardTrackListView.Row(title: "Automatic Sync",
                subtitle: vm.siloSubtitleSyncStatus?.autoSync == true ? "Enabled on Silo" : "Manual sync only",
                trackId: nil, isSelected: false, isEnabled: false)
        ], actions: [
            CardActionConfig(title: "Sync with Audio", subtitle: "Align this subtitle on Silo",
                isEnabled: { [weak vm] in vm?.canStartSiloSubtitleSync == true }) { [weak vm] _ in
                    vm?.startSiloSubtitleSync()
                },
            CardActionConfig(title: "Reset Server Timing", subtitle: "Keeps your local delay",
                isEnabled: { [weak vm] in vm?.canResetSiloSubtitleTiming == true }) { [weak vm] _ in
                    vm?.resetSiloSubtitleTiming()
                },
            CardActionConfig(title: "Check Status") { [weak vm] _ in
                Task { await vm?.refreshSubtitleActions() }
            }
        ], onBack: { [weak self] in self?.presentSiloSubtitleMenu() }, onSelect: { _ in })
        subtitleSyncProgress = vm.$siloSubtitleSyncState
            .combineLatest(vm.$siloSubtitleSyncError, vm.$siloSubtitleSyncUpdating)
            .receive(on: DispatchQueue.main).sink { [weak list, weak vm] _ in
                guard let vm else { return }
                list?.updateTrack(0, title: vm.siloSubtitleSyncState?.label ?? "Selected Subtitle",
                                  subtitle: vm.siloSubtitleSyncDetail)
                list?.refreshActionAvailability()
            }
        presentRailPanel(content: list, width: CardTrackListView.menuWidth, from: rail?.subtitlesButton ?? view)
    }

    // MARK: - Subtitle search

    /// Searches while the Subtitles menu stays up, then swaps in the results,
    /// unless that menu was closed meanwhile.
    private func searchSubtitles(from row: CardTrackRowButton) {
        guard let vm = viewModel, subtitleSearchTask == nil else { return }
        let origin = activeRailPanel
        row.setTitle("Searching…")
        subtitleSearchTask = Task { [weak self, weak vm, weak row] in
            let results: [PlayerSubtitleSearchResult]?
            let failure: String?
            do { results = try await vm?.searchSubtitles(); failure = nil }
            catch { results = nil; failure = error.localizedDescription }
            guard let self else { return }
            self.subtitleSearchTask = nil
            if let row { row.setTitle(row.row.title) }
            guard let vm, let origin, self.activeRailPanel === origin else { return }
            let found = results ?? []
            var rows = found.isEmpty
                ? [CardTrackListView.Row(title: results == nil ? "Search Failed" : "No Subtitles Found",
                    subtitle: failure ?? vm.subtitleSearchLanguageName, trackId: nil,
                    isSelected: false, isEnabled: false, wrapsSubtitle: true)]
                : found.enumerated().map { index, result in
                    CardTrackListView.Row(title: result.title, subtitle: result.detail,
                                          trackId: index, isSelected: false)
                }
            if let warning = vm.subtitleSearchWarning {
                rows.insert(CardTrackListView.Row(title: "Some Providers Unavailable", subtitle: warning,
                    trackId: nil, isSelected: false, isEnabled: false, wrapsSubtitle: true), at: 0)
            }
            _ = self.presentRailPanel(
                content: CardTrackListView(header: "Results · \(vm.subtitleSearchLanguageName)", rows: rows,
                    actions: [CardActionConfig(title: "Search Again") { [weak self] row in
                        self?.searchSubtitles(from: row)
                    }], onBack: { [weak self, weak vm] in
                        guard let self, let vm else { return }
                        if vm.isSiloPlayback { self.presentSiloSubtitleMenu() }
                        else { self.presentSubtitleMenu(vm) }
                    }, onSelect: { [weak vm, weak self] index in
                        guard let index, let vm, found.indices.contains(index) else { return }
                        self?.activeRailPanel?.dismissPanel()
                        Task { await vm.installSubtitle(found[index]) }
                        if case .silo = found[index] { self?.presentSubtitleOperation() }
                    }),
                width: CardTrackListView.menuWidth, from: self.rail?.subtitlesButton ?? self.view)
        }
    }

    // MARK: - Full description

    private var descriptionOverlay: PlayerDescriptionOverlayView?
    private weak var descriptionInfoCard: PlayerInfoCardView?

    private func updateDescriptionSurfaces() {
        guard let vm = viewModel else { return }
        let translation = vm.descriptionTranslationController
        descriptionInfoCard?.updateDescription(text: vm.descriptionText, isTranslating: translation.isTranslating,
                                              isMachineTranslated: vm.descriptionOverviewIsMachineTranslated)
        descriptionOverlay?.updateDescription(
            text: vm.descriptionText, isTranslating: translation.isTranslating,
            isMachineTranslated: vm.descriptionOverviewIsMachineTranslated,
            canTranslate: translation.canTranslate, errorMessage: translation.errorMessage,
            onTranslate: { [weak vm] in vm?.descriptionTranslationController.translate() })
    }

    /// AVKit puts the controls away and shows the whole summary over a dim.
    private func presentDescription(_ text: String) {
        guard let vm = viewModel, descriptionOverlay == nil else { return }
        let translation = vm.descriptionTranslationController
        let overlay = PlayerDescriptionOverlayView(
            text: text, isTranslating: translation.isTranslating,
            isMachineTranslated: vm.descriptionOverviewIsMachineTranslated,
            canTranslate: translation.canTranslate, errorMessage: translation.errorMessage,
            onTranslate: { [weak vm] in vm?.descriptionTranslationController.translate() })
        overlay.frame = view.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(overlay)
        descriptionOverlay = overlay
        // Holds the paused poster and the remote's seek path, as a panel does.
        vm.isRailPanelOpen = true
        vm.showControls = false
        overlay.fadeIn()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func dismissDescription() {
        guard let overlay = descriptionOverlay else { return }
        descriptionOverlay = nil
        viewModel?.isRailPanelOpen = activeRailPanel != nil
        overlay.fadeOut { [weak self] in
            overlay.removeFromSuperview()
            self?.setNeedsFocusUpdate()
            self?.updateFocusIfNeeded()
        }
    }

    // MARK: - Info pane

    enum PaneTab: String { case info, chapters, upNext, insights, details }

    #if DEBUG
    /// The live player, for DEBUG launch hooks (RIVULET_AUTOPLAY_PANE).
    static weak var debugCurrent: PlayerContainerViewController?

    func debugMenu() { handleMenuButton() }
    func debugHideChrome() { viewModel?.showControls = false }
    func debugResume() { viewModel?.resume() }
    func debugContentVertical(up: Bool) { handleContentVertical(up: up) }

    func debugPresentPane(_ name: String) {
        guard let tab = PaneTab(rawValue: name) else { return }
        presentPane(tab)
        if let pill = pill(for: tab) { rail?.setFocusLanding(pill) }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }
    #endif

    /// The tab the open pane shows, nil when no pane is open.
    private var openPaneTab: PaneTab?

    private func paneTab(for pill: PlayerInfoPillButton) -> PaneTab? {
        guard let rail else { return nil }
        switch pill {
        case rail.infoButton: return .info
        case rail.chaptersButton: return .chapters
        case rail.upNextButton: return .upNext
        case rail.insightsButton: return .insights
        case rail.detailsButton: return .details
        default: return nil
        }
    }

    private func pill(for tab: PaneTab) -> PlayerInfoPillButton? {
        switch tab {
        case .info: return rail?.infoButton
        case .chapters: return rail?.chaptersButton
        case .upNext: return rail?.upNextButton
        case .insights: return rail?.insightsButton
        case .details: return rail?.detailsButton
        }
    }

    /// Opens AVKit's info pane on `tab`, or switches an open one to it.
    private func presentPane(_ tab: PaneTab) {
        guard let rail, let vm = viewModel, let content = paneContent(tab, vm: vm) else { return }
        let openPane = activeRailPanel?.isPane == true ? activeRailPanel : nil
        if openPane == nil {
            guard rail.alpha > 0.5, !vm.isScrubbing else { return }
            activeRailPanel?.dismissPanel()
        }
        guard let tabPill = pill(for: tab) else { return }
        // Insights' sub-tabs go on the pill row; Up from its content returns to the shown one.
        let insights = content.view as? InsightsPanelContainerView
        let subTabs = insights.map { $0.availableTabs.count > 1 ? $0.availableTabs : [] } ?? []
        let selectedSubTab = insights.flatMap { $0.availableTabs.firstIndex(of: $0.currentTab) } ?? 0
        weak var panelRef: PlayerRailPanelView?
        rail.setInsightsTabs(subTabs.map(\.title), selected: selectedSubTab) { [weak insights, weak rail] index in
            guard let insights, insights.availableTabs.indices.contains(index) else { return }
            insights.select(insights.availableTabs[index])
            if let tab = rail?.insightsTab(at: index) { panelRef?.setReturnTarget(tab) }
        }
        let panel = PlayerRailPanelView.presentPane(
            content: content.view, cardWidth: content.cardWidth, in: view, rail: rail,
            pill: rail.insightsTab(at: selectedSubTab) ?? tabPill,
            riders: [progressBar].compactMap { $0 }, replacing: openPane)
        panelRef = panel
        openPaneTab = tab
        rail.setSelectedPill(tabPill)
        (content.view as? PlayerCardRowView)?.scrollToCurrent()
        adoptRailPanel(panel)
    }

    private func paneContent(_ tab: PaneTab, vm: UniversalPlayerViewModel) -> (view: UIView, cardWidth: CGFloat?)? {
        switch tab {
        case .info:
            let meta = vm.metadata
            var badges: [String] = []
            if let rating = meta.displayContentRating { badges.append(rating) }
            if let resolution = meta.Media?.first?.videoResolution?.lowercased() {
                badges.append(resolution == "4k" ? "4K" : (["1080", "720"].contains(resolution) ? "HD" : "SD"))
            }
            if meta.hasDolbyVision { badges.append("Dolby Vision") } else if meta.hasHDR { badges.append("HDR") }
            if !vm.subtitleTracks.isEmpty { badges.append("CC") }
            let card = PlayerInfoCardView(content: .init(
                posterURL: vm.nowPlayingArtworkURL,
                title: meta.type == "episode" ? (meta.grandparentTitle ?? vm.title) : vm.title,
                summary: vm.descriptionText,
                genre: meta.Genre?.first?.tag,
                runtimeMinutes: meta.duration.map { $0 / 60000 },
                badges: badges,
                isDescriptionTranslating: vm.descriptionTranslationController.isTranslating,
                overviewIsMachineTranslated: vm.descriptionOverviewIsMachineTranslated))
            descriptionInfoCard = card
            card.onFromBeginning = { [weak self, weak vm] in
                self?.activeRailPanel?.dismissPanel()
                Task {
                    await vm?.seek(to: 0)
                    vm?.resume()
                }
            }
            card.onExpandSummary = { [weak self, weak vm] _ in
                guard let vm else { return }
                self?.presentDescription(vm.descriptionText ?? "")
            }
            return (card, nil)

        case .chapters:
            let chapters = vm.metadata.Chapter ?? []
            guard !chapters.isEmpty else { return nil }
            let now = vm.currentTime
            let cards = chapters.enumerated().map { index, chapter -> PlayerCardRowView.Card in
                let start = TimeInterval(chapter.startTimeOffset ?? 0) / 1000
                let end = chapter.endTimeOffset.map { TimeInterval($0) / 1000 } ?? .infinity
                let watching = now >= start && now < end
                return PlayerCardRowView.Card(
                    imageURL: vm.chapterThumbnailURL(chapter),
                    stillLoader: { [weak vm] in await vm?.chapterStill(at: start) },
                    eyebrow: watching ? "Watching" : nil,
                    title: chapter.tag ?? "Chapter \(index + 1)",
                    isCurrent: watching,
                    onSelect: { [weak self, weak vm] in
                        self?.activeRailPanel?.dismissPanel()
                        Task { await vm?.seek(to: start) }
                    })
            }
            let row = PlayerCardRowView(cards: cards)
            return (row, nil)

        case .upNext:
            if let queue = vm.playQueue { return (playlistRow(queue, vm: vm), nil) }
            guard !upNextEpisodesCache.isEmpty else { return nil }
            let currentKey = vm.metadata.ratingKey
            let episodes = upNextEpisodesCache
            let cards = episodes.map { episode -> PlayerCardRowView.Card in
                let state = UpNextRowState.state(for: episode, in: episodes, currentRatingKey: currentKey)
                let isCurrent = state == .nowPlaying
                let eyebrow: String? = switch state {
                case .nowPlaying: "Watching"
                case .upNext: "Up Next"
                case .watched: "Watched"
                case .future: episode.index.map { "Episode \($0)" }
                }
                let thumb = vm.providerThumbnailURL(for: episode) ?? episode.thumb.flatMap {
                    PlexNetworkManager.shared.buildThumbnailURL(
                        serverURL: vm.serverURL, authToken: vm.authToken, thumbPath: $0, width: 640, height: 360)
                }
                return PlayerCardRowView.Card(
                    imageURL: thumb,
                    eyebrow: eyebrow,
                    title: episode.title ?? "Episode",
                    isCurrent: isCurrent,
                    onSelect: { [weak self, weak vm] in
                        self?.activeRailPanel?.dismissPanel()
                        guard !isCurrent else { return }
                        vm?.exitControlsFocus()
                        Task { await vm?.playEpisode(episode) }
                    })
            }
            return (PlayerCardRowView(cards: cards), nil)

        case .insights:
            guard insightsButtonShouldBeAvailable else { return nil }
            return (InsightsPanelContainerView(
                cast: insightsCastCache,
                trivia: insightsTriviaCache,
                suppressedTriviaIDs: suppressedTriviaIDsCache), nil)

        case .details:
            // Live stats exist only on the aether route (an AetherPlayer is present).
            let statsProvider: (() -> AetherAdvancedStats?)? =
                vm.aetherPlayer != nil ? { [weak vm] in vm?.aetherPlayer?.advancedStats() } : nil
            var media = PlayerDetailsPaneView.mediaSections(metadata: vm.metadata, modes: vm.streamingModeInfo,
                dolbyVision: vm.aetherPlayer?.dolbyVisionPlayback,
                enhancementLayer: vm.aetherPlayer?.dolbyVisionEnhancementLayer,
                enhanceDialogue: SystemAudioAdjustment.dialogueSummary)
            if let negotiated = vm.siloNegotiatedDetails { media.insert(negotiated, at: 0) }
            let details = PlayerDetailsPaneView(
                media: media,
                statsProvider: statsProvider)
            return (details, nil)
        }
    }

    /// The Playlist pane: a window of queue entries around the current one, indexed by queue position.
    private func playlistRow(_ queue: PlayQueue<PlaylistEntry>, vm: UniversalPlayerViewModel) -> PlayerCardRowView {
        let window = UpNextRowState.queueWindow(count: queue.entries.count, currentIndex: queue.index)
        let cards = window.map { index -> PlayerCardRowView.Card in
            let item = queue.entries[index].item
            let isCurrent = UpNextRowState.queueState(at: index, currentIndex: queue.index) == .nowPlaying
            let eyebrow: String? = if isCurrent {
                "Watching"
            } else if item.kind == .movie {
                "Movie"
            } else if item.kind == .episode, let season = item.seasonNumber, let episode = item.episodeNumber {
                "S\(season) E\(episode)"
            } else {
                nil
            }
            return PlayerCardRowView.Card(
                imageURL: UniversalPlayerViewModel.queueThumbnailURL(for: item),
                eyebrow: eyebrow,
                title: item.title,
                isCurrent: isCurrent,
                onSelect: { [weak self, weak vm] in
                    self?.activeRailPanel?.dismissPanel()
                    guard !isCurrent else { return }
                    vm?.exitControlsFocus()
                    Task { await vm?.playQueueEntry(at: index) }
                })
        }
        return PlayerCardRowView(cards: cards)
    }

    /// Shared by popups and panes: Menu echo guard, dismissal bookkeeping,
    /// auto-hide suspension and focus.
    private func adoptRailPanel(_ panel: PlayerRailPanelView) {
        if !panel.isPane {
            openPaneTab = nil
            rail?.setSelectedPill(nil)
            rail?.setInsightsTabs([], selected: 0, onFocus: nil)
        }
        // The system's Menu gesture recognizer races the panel's own
        // responder-chain consumption and calls dismiss(animated:) on this
        // VC afterwards — arm the block so that echo is swallowed instead
        // of force-dismissing a panel that just handled Menu internally.
        panel.onMenuHandled = { [weak self] in self?.blockDismissTemporarily() }
        panel.onDismiss = { [weak self, weak panel] in
            guard let self else { return }
            // Identity guard: a superseding presentation can make this
            // completion fire after `activeRailPanel` describes a newer panel.
            if self.activeRailPanel === panel {
                self.activeRailPanel = nil
                self.openPaneTab = nil
                // AVKit returns focus to the bar when a pane closes.
                if panel?.isPane == true { self.rail?.resetFocusMemory() }
                self.rail?.setSelectedPill(nil)
                self.rail?.setInsightsTabs([], selected: 0, onFocus: nil)
                // Re-arm the container's Left/Right recognizers. An ENABLED
                // recognizer on an ancestor intercepts a press even when its
                // handler no-ops, so `isEnabled` has to track panel presence,
                // not just `controlsFocusActive`.
                self.applyChromeVisibility()
                self.viewModel?.isRailPanelOpen = self.descriptionOverlay != nil
            }
            self.setNeedsFocusUpdate(); self.updateFocusIfNeeded()
        }
        activeRailPanel = panel
        restartPaneIdleTimer()
        // Disarm them for the panel that just came up (see above).
        applyChromeVisibility()
        // A rail panel is a full-screen-adjacent overlay the ambient-pause
        // backdrop must not show through/around — see
        // UniversalPlayerViewModel.isRailPanelOpen.
        viewModel?.isRailPanelOpen = true
        view.setNeedsFocusUpdate(); view.updateFocusIfNeeded()
    }

    /// The TV app's title block: an episode reads "S1, E1 • Pilot" over the show,
    /// a movie its year over the title. Runtime, rating and audio live in the Info tab.
    private func applyRailMetadata(vm: UniversalPlayerViewModel) {
        let meta = vm.metadata
        guard meta.type == "episode", let show = meta.grandparentTitle else {
            rail?.setTitle(vm.title, eyebrow: vm.subtitle)
            return
        }
        let number = [meta.parentIndex.map { "S\($0)" }, meta.index.map { "E\($0)" }]
            .compactMap { $0 }.joined(separator: ", ")
        let eyebrow = [number, meta.title ?? ""].filter { !$0.isEmpty }.joined(separator: " • ")
        rail?.setTitle(show, eyebrow: eyebrow.isEmpty ? nil : eyebrow)
    }

    // MARK: - Post-video (Up Next)

    /// Mount or unmount the Up Next page and hand it focus. The focus update is
    /// required: `preferredFocusEnvironments` alone changes nothing.
    private func applyPostVideoState(_ state: PostVideoState) {
        if state != .hidden {
            let overlay = postVideoOverlay ?? makePostVideoOverlay()
            if overlay.superview == nil {
                let scrim = SideScrimView()
                scrim.alpha = 0
                view.addSubview(scrim)
                scrim.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    scrim.topAnchor.constraint(equalTo: view.topAnchor),
                    scrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                    scrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    scrim.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.6),
                ])
                postVideoScrim = scrim
                UIView.animate(withDuration: 0.5) { scrim.alpha = 1 }
                view.addSubview(overlay)
                overlay.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -PlayerRailView.sideInset),
                    overlay.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                ])
            }
            refreshPostVideoContent()
        } else if let overlay = postVideoOverlay {
            // A departing card is not the focus owner; the next presentation builds a new one.
            postVideoOverlay = nil
            let scrim = postVideoScrim
            postVideoScrim = nil
            UIView.animate(withDuration: 0.35, animations: { scrim?.alpha = 0 },
                           completion: { _ in scrim?.removeFromSuperview() })
            overlay.slideOut { [weak self] in
                self?.setNeedsFocusUpdate()
                self?.updateFocusIfNeeded()
            }
        }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func makePostVideoOverlay() -> PostVideoOverlayView {
        let overlay = PostVideoOverlayView()
        overlay.onPlayNext = { [weak self] in
            guard let vm = self?.viewModel else { return }
            Task { await vm.playNextEpisode() }
        }
        overlay.onDismiss = { [weak self] in
            guard let vm = self?.viewModel else { return }
            // Mid-countdown the button stops the countdown and leaves the page
            // up; with no countdown it returns to fullscreen video.
            if vm.countdownSeconds > 0 && !vm.isCountdownPaused {
                vm.cancelCountdown()
            } else {
                vm.dismissPostVideo()
            }
        }
        overlay.onUserFocusMove = { [weak self] in
            guard let vm = self?.viewModel else { return }
            if vm.countdownSeconds > 0 && !vm.isCountdownPaused { vm.cancelCountdown() }
        }
        postVideoOverlay = overlay
        return overlay
    }

    private func refreshPostVideoContent() {
        guard let vm = viewModel, let overlay = postVideoOverlay, overlay.superview != nil else { return }
        overlay.setLoading(vm.postVideoState == .loading)
        overlay.configure(
            nextEpisode: vm.nextEpisode,
            serverURL: vm.serverURL,
            authToken: vm.authToken,
            thumbnailURL: vm.nextEpisode.flatMap(vm.providerThumbnailURL(for:)),
            errorMessage: vm.nextEpisodeError
        )
        overlay.setCountdown(
            remaining: vm.countdownSeconds,
            total: vm.countdownTotalSeconds,
            isPaused: vm.isCountdownPaused
        )
    }

    /// Single writer for every chrome alpha and focus gate, so no two sinks fight
    /// over one view. Runs on every clock tick; the change guards keep that free.
    private func applyChromeVisibility() {
        guard let vm = viewModel else { return }
        let ambient = vm.pausePresentation != .frame
        let isLoading = vm.playbackState == .loading || vm.playbackState == .idle
        // The Up Next card sits over the video alone.
        let chromeVisible = (vm.showControls || vm.isScrubbing || vm.showsSkipBar)
            && !ambient && vm.postVideoState == .hidden
        // A skip with the controls hidden shows the bar alone, as AVKit does.
        let railVisible = chromeVisible && vm.showControls && !vm.isScrubbing
        if !chromeVisible { progressBar?.clearSkipIndicator() }

        // Every appearance of the rail starts on the scrubber; focus memory
        // lasts one visit (an open panel still counts as in the rail).
        if railVisible && !railWasVisible { rail?.resetFocusMemory() }
        railWasVisible = railVisible
        let paused = vm.playbackState == .paused && !ambient && hasPlayedSinceLoad
        // Ambient pause keeps the scrubber up as a read-only position indicator.
        let scrubberVisible = chromeVisible || (ambient && !isLoading)
        // For an episode the rail stays at alpha 1 during ambient so its title
        // holds; `setAmbient` fades the rest.
        let keepRailTitle = ambient && vm.metadata.type == "episode"
        let railAlpha: CGFloat = keepRailTitle ? 1 : (railVisible ? 1 : 0)

        // The proxy is the rail's first focus landing, focusable as soon as the
        // chrome is up. `proxyHasFocus` keeps it focusable through a scrub it
        // started, which clears `railVisible`.
        let proxyHasFocus = scrubberProxy?.isFocused == true
        // AVKit's info pane takes the bar's place while it is open.
        let paneOpen = activeRailPanel.map { $0.isPane && $0.window != nil } ?? false
        scrubberProxy?.isFocusEnabled = !paneOpen
            && ((railVisible && !isLoading) || (proxyHasFocus && !isLoading && !ambient))

        // The content anchor holds focus whenever nothing else should. In the
        // error state it is hidden so it cannot occlude the error buttons.
        let failed = vm.playbackState.isFailed
        let anchorEnabled = vm.postVideoState == .hidden
            && !failed
            && !vm.controlsFocusActive
            && !vm.skipPillOwnsFocus
        // Requested after the alpha writes below: the pill and rail accept focus
        // only once their model alpha is 1.
        var anchorNeedsFocusUpdate = false
        if failed {
            // Handed off one beat later, once SwiftUI has mounted the overlay
            // (see `handOffFocusToErrorOverlay`); until then the anchor keeps
            // focus, so the request is made from an environment that holds it.
            scheduleErrorOverlayHandoff()
        } else {
            anchorNeedsFocusUpdate = (contentAnchor?.isFocused == true && !anchorEnabled)
                || contentAnchor?.isHidden == true
            contentAnchor?.isFocusEnabled = anchorEnabled
            contentAnchor?.isHidden = false
        }
        if vm.postVideoState != .hidden || failed {
            // Drop a press in flight. Keyed on these states, not `anchorEnabled`,
            // because the skip pill takes content presses while the anchor is off.
            contentPressDetector.cancel()
            contentDirectionalPressType = nil
            contentSelectPending = false
        }

        // The skip pill shows whenever a marker is active, independent of the rail.
        let skipVisible = vm.showSkipButton && !isLoading && !ambient && vm.postVideoState == .hidden
            && !chromeVisible

        // Whether the pill owns focus. Re-resolved after the alpha write below.
        let ownsFocus = vm.skipPillOwnsFocus
        let ownershipChanged = ownsFocus != lastSkipPillOwnsFocus
        lastSkipPillOwnsFocus = ownsFocus

        // The panel anchors to the rail, so it goes when the rail does.
        if !railVisible {
            activeRailPanel?.dismissPanel()
        }

        let targets: [(UIView?, CGFloat)] = [
            (chromeScrim, chromeVisible ? 1 : 0),
            (progressBar, scrubberVisible && !paneOpen ? 1 : 0),
            (ambientScrim, (ambient && !isLoading) ? 1 : 0),
            (rail, railAlpha),
            (skipPill, skipVisible ? 1 : 0),
            (pausedDimView, paused ? 1 : 0),
            // The pause backdrop replaces the frame the captions belong to (#428).
            (captionOverlay, ambient ? 0 : 1),
        ]
        // `setAmbient` drives the rail's sub-view alphas, which `targets` cannot see.
        let railAmbientChanged = rail.map { $0.ambientState != (ambient, keepRailTitle) } ?? false
        let targetsChanged = targets.contains(where: { view, alpha in
            view.map { abs($0.alpha - alpha) > 0.01 } == true
        })
        // Captions lift on the same animation block as the rail. Set before the
        // guard so the state stays correct on the early-out path.
        let captionLiftChanged = captionOverlay.map { $0.controlsVisible != chromeVisible || $0.paneOpen != paneOpen } ?? false
        captionOverlay?.controlsVisible = chromeVisible
        captionOverlay?.paneOpen = paneOpen
        guard targetsChanged || railAmbientChanged || ownershipChanged
                || captionLiftChanged else {
            if anchorNeedsFocusUpdate {
                setNeedsFocusUpdate()
                updateFocusIfNeeded()
            }
            return
        }
        UIView.animate(withDuration: 0.25) {
            for (view, alpha) in targets { view?.alpha = alpha }
            self.rail?.setAmbient(ambient, keepTitle: keepRailTitle)
            if captionLiftChanged { self.captionOverlay?.layoutIfNeeded() }
        }
        // Model alpha is now 1 for a visible pill, so the engine will accept it
        // as a focus target. Re-resolve toward/away from the pill (or off the
        // anchor) exactly once.
        if ownershipChanged || anchorNeedsFocusUpdate {
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
    }

    /// Set while a handoff to the error overlay is waiting to run.
    private var errorOverlayHandoffPending = false

    private func scheduleErrorOverlayHandoff() {
        guard let contentAnchor, !contentAnchor.isHidden, !errorOverlayHandoffPending else { return }
        errorOverlayHandoffPending = true
        // The overlay makes its own focus claim 0.05s after it appears for the
        // same reason (the engine takes a beat to register a new SwiftUI focus
        // container); this runs just after it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.handOffFocusToErrorOverlay()
        }
    }

    /// Hide the anchor and move focus into the SwiftUI hierarchy, where the
    /// error overlay's default focus picks its button. Done while the anchor
    /// still holds focus, because a request from an environment that does not
    /// contain focus is ignored, and SwiftUI's own claim cannot pull focus out
    /// of a UIKit view outside its hosting view.
    private func handOffFocusToErrorOverlay() {
        errorOverlayHandoffPending = false
        guard viewModel?.playbackState.isFailed == true, let contentAnchor else { return }
        contentAnchor.isFocusEnabled = false
        contentAnchor.isHidden = true
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    /// Sync the pill's title, drive the auto-skip fill sweep, and re-evaluate
    /// visibility and focus ownership. A mid-countdown re-show fills from the
    /// remaining seconds so the sweep still ends with the skip.
    private func refreshSkipPill() {
        skipPill?.setTitle(viewModel?.skipButtonDisplayLabel, for: .normal)
        // Apply visibility BEFORE measuring for the fill: beginFill reads the
        // pill's laid-out width, which is only correct once it's on screen.
        applyChromeVisibility()
        let seconds = viewModel?.skipCountdownSeconds ?? 0
        if seconds > 0 {
            if skipPill?.isFillRunning == false {
                skipPill?.beginFill(duration: TimeInterval(seconds))
            }
        } else {
            skipPill?.cancelFill()
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)

        // `controlsFocusActive` ("the rail owns focus") gates all seek input, so
        // drive it from where focus lands. Skip a transient nil destination: a
        // panel dismiss passes through one and would reset the rail's focus memory.
        if let vm = viewModel, context.nextFocusedItem != nil {
            vm.scrubberOwnsFocus = context.nextFocusedView.map { $0 === scrubberProxy } ?? false
            let elsewhereInRail = context.nextFocusedView.map { $0 !== scrubberProxy && railOwnsFocus($0) } ?? false
            progressBar?.setFocusDimmed(elsewhereInRail, coordinator: coordinator)
            if railOwnsFocus(context.nextFocusedView) {
                vm.enterControlsFocus()
            } else {
                vm.exitControlsFocus()
            }
            // A user's move (not a re-resolution) counts as input for the paused poster.
            if !context.focusHeading.isEmpty { vm.hidePausedPoster() }
        }
        restartPaneIdleTimer()
    }

    private func restartPaneIdleTimer() {
        paneIdleTimer?.invalidate()
        paneIdleTimer = nil
        guard let pane = activeRailPanel, pane.isPane else { return }
        // Measured in AVKit: 8s with focus on the pills, 20s inside the pane's content.
        let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView
        let delay: TimeInterval = focused?.isDescendant(of: pane) == true ? 20 : 8
        paneIdleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                // The full summary is its own screen; closing it moves focus and re-arms.
                guard let self, let vm = self.viewModel, let pane = self.activeRailPanel, pane.isPane,
                      self.descriptionOverlay == nil, !vm.isScrubbing else { return }
                pane.dismissPanel()
                // AVKit takes the chrome with the pane; paused keeps Rivulet's own rule.
                if vm.playbackState == .playing { vm.showControls = false }
            }
        }
    }

    /// The scrubber proxy is a SIBLING of the rail, not a descendant (see the
    /// setup comment at `railView.scrubberFocusProxy = proxy`), so "focus is in
    /// the rail" needs both roots.
    private func railOwnsFocus(_ view: UIView?) -> Bool {
        guard let view else { return false }
        if let proxy = scrubberProxy, view === proxy { return true }
        if let rail, view.isDescendant(of: rail) { return true }
        // A presented panel counts as the rail, or its dismiss loses the button
        // that opened it.
        if let panel = activeRailPanel, panel.window != nil, view.isDescendant(of: panel) { return true }
        return false
    }
}

/// Invisible, full-screen focus stop for the content state. Presses bubble to
/// the container's "Content-state presses". Full screen so the engine never
/// finds a move from it; above video and scrims, below every control.
private final class ContentFocusAnchorView: UIView {

    /// Focus gate, set by `PlayerContainerViewController.applyChromeVisibility()`.
    var isFocusEnabled = false

    override var canBecomeFocused: Bool { isFocusEnabled }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// AVKit's control dimming, measured from its pixels: clear down to y 384 of
/// 1080, darkening linearly to black 0.55 at y 985, flat below.
final class ChromeScrimView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        let gradient = layer as! CAGradientLayer
        gradient.colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(0.55).cgColor,
            UIColor.black.withAlphaComponent(0.55).cgColor,
        ]
        gradient.locations = [0.356, 0.912, 1]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Right-side legibility gradient behind the Up Next card: `ChromeScrimView`'s
/// stops, turned to run left to right.
final class SideScrimView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let gradient = layer as! CAGradientLayer
        gradient.colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(0.55).cgColor,
            UIColor.black.withAlphaComponent(0.55).cgColor,
        ]
        gradient.locations = [0, 0.6, 1]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Bottom-anchored legibility gradient for the ambient-pause scrubber. The
/// glass rail normally grounds the scrubber; during ambient the rail is gone,
/// so this thin transparent→black gradient keeps the scrubber readable over
/// bright backdrops.
final class BottomScrimView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let gradient = layer as! CAGradientLayer
        gradient.colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(0.55).cgColor,
        ]
        gradient.locations = [0, 1]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}


// MARK: - UIGestureRecognizerDelegate

extension PlayerContainerViewController: UIGestureRecognizerDelegate {

    /// Only let the swipe-to-scrub pan claim a clearly horizontal gesture it will
    /// act on. Refusing here, not in the action, leaves vertical swipes to the engine.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
              pan === panGestureRecognizer
        else { return true }

        guard panCanDriveScrub else { return false }

        // Never while the clickpad is down: a click jolts the touch into a fake swipe.
        guard !RemoteInputHandler.isClickpadDown, !RemoteInputHandler.isRingJogging else { return false }

        // Decide on velocity: translation is still near zero at this point.
        // A 2:1 horizontal bias leaves diagonal drift to the focus engine.
        let velocity = pan.velocity(in: view)
        guard velocity != .zero else { return false }
        return abs(velocity.x) > abs(velocity.y) * 2
    }
}
