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
    private var pauseIndicator: UIStackView?
    private var pauseTimeLabel: UILabel?
    private var loadingLabel: UILabel?
    private var chromeScrim = ChromeScrimView()
    private var ambientScrim: BottomScrimView?
    private var captionOverlay: CaptionOverlayView?
    private var cancellables = Set<AnyCancellable>()
    /// The one floating panel shared by CC/audio/info (Task 5) and Up
    /// Next (Task 6). Only one can be up at a time — presenting a new
    /// one dismisses whatever's showing first.
    private var activeRailPanel: PlayerRailPanelView?

    /// Previous `railVisible`, so `applyChromeVisibility()` can spot the rail
    /// APPEARING and start every appearance on the scrubber.
    private var railWasVisible = false
    /// Snapshot of the last `$upNextEpisodes` emission — Task 6's panel
    /// reads this when it comes online; Task 3 only derives the rail
    /// button's availability from it.
    private var upNextEpisodesCache: [PlexMetadata] = []

    /// The end-of-episode Up Next page. Built on first use and added above
    /// every other chrome layer while `postVideoState != .hidden`; removed
    /// (not just hidden) when it goes away so its buttons cannot hold focus.
    private var postVideoOverlay: PostVideoOverlayView?
    /// Snapshot of the last `$insightsCast` emission, read when the rail's
    /// Insights panel is presented.
    private var insightsCastCache: [MediaPerson] = []
    /// Snapshot of the last `$insightsTrivia`/`$suppressedTriviaIDs` emission,
    /// read when the rail's Insights panel is presented (P2a).
    private var insightsTriviaCache: TitleTrivia?
    private var suppressedTriviaIDsCache: Set<String> = []
    /// True while `activeRailPanel` is showing Up Next content, so the
    /// `$upNextEpisodes` sink can dismiss a now-stale list without
    /// touching the CC/audio/info panels, which don't go stale off that
    /// publisher.
    private var isShowingUpNextPanel = false
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
            view.addSubview(overlay)
            captionOverlay = overlay
        }

        if let vm = viewModel {
            chromeScrim.isUserInteractionEnabled = false

            // Full-frame pause dim sits just above the video, below every
            // other chrome layer (z-order bottom-up: scrim, dim, rail,
            // progress bar, skip pill, pause indicator, loading label).
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

            // Top-left pause indicator: two bars + "Paused · Xm left".
            let barsStack = UIStackView()
            barsStack.axis = .horizontal
            barsStack.spacing = 6
            barsStack.alignment = .center
            for _ in 0..<2 {
                let bar = UIView()
                bar.backgroundColor = .white
                bar.layer.cornerRadius = 2
                bar.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    bar.widthAnchor.constraint(equalToConstant: 7),
                    bar.heightAnchor.constraint(equalToConstant: 24),
                ])
                barsStack.addArrangedSubview(bar)
            }
            let timeLabel = UILabel()
            timeLabel.font = .systemFont(ofSize: 22, weight: .medium)
            timeLabel.textColor = UIColor.white.withAlphaComponent(0.6)

            let indicator = UIStackView(arrangedSubviews: [barsStack, timeLabel])
            indicator.axis = .horizontal
            indicator.spacing = 12
            indicator.alignment = .center
            indicator.alpha = 0

            // Top-left "Loading" label — same spot the paused indicator
            // occupies, styled like its time label. The progress bar's own
            // skeleton shimmer (see `PlayerProgressBarView.setSkeleton`) is
            // the primary loading visual; this is a quiet text-only cue,
            // no spinner.
            let loadingLabel = UILabel()
            loadingLabel.font = .systemFont(ofSize: 22, weight: .medium)
            loadingLabel.textColor = UIColor.white.withAlphaComponent(0.6)
            loadingLabel.text = "Loading"
            loadingLabel.isHidden = true

            [chromeScrim, dim, ambientBottomScrim, railView, bar, proxy, pill, indicator, loadingLabel].forEach {
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
            view.bringSubviewToFront(indicator)
            view.bringSubviewToFront(loadingLabel)

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

                // Rail: left/right 90, pinned to the bottom.
                railView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 90),
                railView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -90),
                railView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -84),
                railView.heightAnchor.constraint(equalToConstant: PlayerRailView.railHeight),

                // Scrubber lives in the rail's lower region — a container
                // sibling overlaid on the rail, not a rail child (its
                // morph/behavior layer is untouched by this task). Leading/
                // trailing inset stays 132 at rest AND while scrubbing —
                // the bar never moves (see PlayerProgressBarView).
                bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 132),
                bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -132),
                bar.bottomAnchor.constraint(equalTo: railView.bottomAnchor, constant: -34),

                // Invisible focus proxy: geometrically below the button
                // cluster (leading/trailing match the bar's; top/bottom pad
                // 8pt around it) so the focus engine's downward search from
                // ANY cluster button lands here rather than settling on a
                // same-row cone candidate (the bug this proxy fixes). The
                // bar itself is the visible indicator — this view draws
                // nothing.
                proxy.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                proxy.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                proxy.topAnchor.constraint(equalTo: bar.topAnchor, constant: -8),
                proxy.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),

                // Skip pill: right-aligned with the scrubber's right end. Its
                // vertical position is driven from applyChromeVisibility (see
                // skipPillBottomConstraint): just above the rail plate when the
                // chrome is up, dropped lower over the video when it's hidden.
                pill.trailingAnchor.constraint(equalTo: bar.trailingAnchor),

                // Pause indicator: top 44 / leading 64.
                indicator.topAnchor.constraint(equalTo: view.topAnchor, constant: 44),
                indicator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 64),

                // Loading label occupies the exact same spot as the pause
                // indicator (the two are disjoint states — never shown at
                // the same time — but kept as separate views).
                loadingLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 44),
                loadingLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 64),
            ])
            // Adjustable vertical position (constant retargeted in
            // applyChromeVisibility). Starts in the rail-hidden (lower) spot.
            let pillBottom = pill.bottomAnchor.constraint(
                equalTo: railView.topAnchor, constant: Self.skipPillLoweredOffset)
            pillBottom.isActive = true
            skipPillBottomConstraint = pillBottom

            // Focus bridge so an Up press from ANY rail button reaches the pill,
            // not just the buttons that happen to sit under it. Spans the rail
            // width in the gap between the button row and the pill; enabled only
            // while the pill is visible (see applyChromeVisibility).
            let skipGuide = UIFocusGuide()
            view.addLayoutGuide(skipGuide)
            skipGuide.preferredFocusEnvironments = [pill]
            skipGuide.isEnabled = false
            NSLayoutConstraint.activate([
                skipGuide.leadingAnchor.constraint(equalTo: railView.leadingAnchor),
                skipGuide.trailingAnchor.constraint(equalTo: railView.trailingAnchor),
                skipGuide.bottomAnchor.constraint(equalTo: railView.topAnchor),
                // Anchored to the RAIL at the raised offset, not to `pill.bottom`.
                // The pill's own bottom constraint is retargeted between the
                // raised (-20) and lowered (+200) offsets, and the guide's height
                // is the negation of whichever is active — so pinning the guide's
                // top to the pill made it exactly -200pt tall whenever the chrome
                // hid, which is unsatisfiable. Auto Layout logged the conflict and
                // broke this constraint on every play (the chrome starts hidden).
                // The guide is only ENABLED while `railVisible`, i.e. only while
                // the pill is raised, so the band above the rail is the only
                // geometry it ever needs. Same constant drives both, so they
                // cannot drift apart.
                skipGuide.topAnchor.constraint(
                    equalTo: railView.topAnchor, constant: Self.skipPillRaisedOffset),
            ])
            skipPillFocusGuide = skipGuide

            // The proxy is a sibling of the rail, so the rail can't reach it
            // through the view tree — hand it over so its preferredFocus can
            // make the scrubber the first landing.
            railView.scrubberFocusProxy = proxy

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
            pauseIndicator = indicator
            pauseTimeLabel = timeLabel
            self.loadingLabel = loadingLabel

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
        if let panel = activeRailPanel, panel.window != nil {
            return [panel]
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

    /// How long the player takes to fade to black on the way out.
    ///
    /// This is a functional mask, not decoration. tvOS "Match Content" makes the
    /// TV renegotiate HDMI when `preferredDisplayCriteria` goes back to nil, and
    /// many sets black the picture out for around a second while they do it. The
    /// fade puts the screen at black before that starts, so the blackout reads as
    /// part of the exit rather than as a flash on the freshly revealed home
    /// screen (issue #249).
    ///
    /// 0.4s is the value: long enough that the ramp reads as intentional at 60fps
    /// and that the display reset (kicked off at fade start) is well under way
    /// before anything else is on screen, short enough that Menu still feels like
    /// it responded immediately. Below roughly 0.3s the fade stops reading as a
    /// fade and starts reading as a stutter; past about 0.5s the remote feels
    /// unresponsive.
    private static let exitFadeDuration: TimeInterval = 0.4

    /// Fade the player to black, then hand the dismissal to `super`.
    ///
    /// The fade runs on every exit rather than only on sessions that set display
    /// criteria. The criteria state is not knowable from here without reaching
    /// into playback internals, the cost of an unnecessary fade is 0.4s of a
    /// calm ramp, and having the exit behave identically every time is worth more
    /// than saving that on SDR content. The one thing the criteria state does
    /// gate is the early reset below.
    private func fadeOutThenDismiss(animated flag: Bool, completion: (() -> Void)?) {
        isFadingOut = true

        // Kick the display reset off at the START of the fade so the roughly
        // one second HDMI handshake overlaps the fade and then continues behind
        // an already-black screen. `stopPlayback()` still calls reset() on
        // teardown; by then the criteria are already nil and it writes nothing.
        // Nothing in stopPlayback() has to precede this: reset() only writes
        // preferredDisplayCriteria and drops its own asset reference, and it
        // touches no player state.
        //
        // This is the load-bearing line of the exit fade, not a nicety. Until it
        // actually wrote nil (it was gated on a flag only this app's own writer
        // ever set, and AetherEngine has owned the criteria for a long time) the
        // fade masked nothing: the engine dropped the criteria during
        // `engine.stop()`, which the player only reaches from `.onDisappear`,
        // after the dismissal. Do not re-gate it.
        let handshakeIncoming = DisplayCriteriaManager.shared.reset()

        // Nothing was released, so no HDMI renegotiation is coming and there is
        // nothing to mask: Match Content is off (the engine's `apply()` guards on
        // `isDisplayCriteriaMatchingEnabled` and writes no criteria at all), or
        // this route never programmed the panel. Cut straight out instead, so that
        // cohort does not pay 0.4s of black for a mask they get no benefit from.
        //
        // This supersedes the original "the fade is unconditional because the
        // container cannot read whether criteria were set" call: it can, by
        // reading `preferredDisplayCriteria` back, which is exactly what reset()
        // now reports. Note the sim always takes this branch, because
        // `getDisplayManager()` bails there — the fade genuinely does not render
        // in the simulator any more, and that is correct, not a regression.
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

    /// Thin wrapper so the fade's completion closure can reach `super.dismiss`.
    /// Swift does not allow `super` inside a closure that explicitly captures
    /// `self`, which the weak capture there is, so the call has to live in a
    /// method body.
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
        // A UIViewPropertyAnimator that is still running when its owner goes
        // away aborts on release, which on tvOS has already cost this codebase
        // one crash. Stop it explicitly and finish at the current position.
        if let animator = exitFadeAnimator, animator.state != .inactive {
            animator.stopAnimation(true)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
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

    /// Pill's bottom-to-rail-top constraint, retargeted between the raised and
    /// lowered offsets as the chrome shows/hides.
    private var skipPillBottomConstraint: NSLayoutConstraint?
    /// Redirects an Up press from any rail button to the pill.
    private var skipPillFocusGuide: UIFocusGuide?
    /// Just above the rail plate — used while the transport chrome is visible.
    private static let skipPillRaisedOffset: CGFloat = -20
    /// Dropped lower over the video — used while the chrome is hidden, so the
    /// pill reads as a standalone lower affordance rather than a floating strip.
    private static let skipPillLoweredOffset: CGFloat = 200

    /// Flag to block dismiss calls that occur immediately after we handled a menu action
    /// This prevents the double-handling issue where handleMenuButton() closes something,
    /// then SwiftUI's responder chain also calls dismiss().
    private var blockNextDismiss = false
    private var blockDismissResetWorkItem: DispatchWorkItem?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.type == .menu {
                isHandlingMenuPress = true
                handleMenuButton()
                return
            }
            if press.type == .select {
                if let vm = viewModel, vm.isScrubbing {
                    isHandlingSelectPress = true
                    inputCoordinator.handle(action: .scrubCommit, source: .irPress)
                    return
                }
                if contentOwnsPresses {
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
                if contentOwnsPresses {
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
    // The ONE handler for directional and Select presses whenever no chrome
    // control owns them: focus on the content anchor (chrome hidden, or up but
    // not entered), on the skip pill (Left/Right seek behind it), or nowhere.
    //
    // It used to be four: SwiftUI's .onTapGesture/.onMoveCommand on a focused
    // SwiftUI layer, tap/long-press recognizers on this view, and
    // GameController copies of the same clicks in RemoteInputHandler.
    //  - An older note here recorded that "UIKit gesture recognizers don't
    //    receive events when SwiftUI has focus", and SwiftUI held focus in
    //    exactly this state. That fits every report of a remote with no
    //    GameController copy of its presses (IR, HDMI-CEC, a clicks-only Siri
    //    Remote) failing to skip until the scrubber, a UIKit view, had focus:
    //    #212, #232, #305.
    //  - The GameController copies were a second opinion on the same click,
    //    classified by the app instead of by tvOS and reconciled only by timing
    //    windows, so one click could land as no skip, one, or two.
    //
    // Arrow and Select presses never travel past this controller, owned or not.
    // The player is full screen: the presenter behind it (Home, the preview
    // carousel) must not page or change state on presses meant for the player.

    private static func isArrow(_ type: UIPress.PressType) -> Bool {
        switch type {
        case .upArrow, .downArrow, .leftArrow, .rightArrow: return true
        default: return false
        }
    }

    /// Whether a directional or Select press that reached this controller
    /// belongs to the content-state grammar.
    private var contentOwnsPresses: Bool {
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
        return focusedView === contentAnchor || focusedView === skipPill
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

        // Up/Down's touch twin. A focused SwiftUI layer got these as move
        // commands from touch swipes for free; a UIKit view gets them only as
        // indirect touches, and the iPhone Remote sends no arrow presses at all.
        // The anchor is full screen, so the engine never has a vertical move to
        // make from it and claiming the swipe steals nothing. Left/Right swipes
        // stay with the swipe-to-scrub pan.
        contentSwipeBinding = DirectionalInputBinding(
            gatedSwipesOn: anchor,
            directions: [.up, .down],
            shouldHandle: { [weak self] _ in self?.contentOwnsPresses ?? false },
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
    /// of travel and Down cancels. Otherwise both surface the controls with
    /// focus already on the scrubber (the rail's preferred focus puts the
    /// scrubber proxy first), so Up from the scrubber then reaches the buttons.
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
        vm.enterControlsFocus()
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
    /// once one has been seen, a `.select` is only ever a centre click.
    private func edgeClickDirection() -> Bool? {
        guard !Self.clickpadRingSeen else { return nil }
        return RemoteInputHandler.active?.clickpadEdge
    }

    private func endContentPress(_ type: UIPress.PressType) {
        if type == .select, contentSelectPending {
            contentSelectPending = false
            toggleControlsFromContent()
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

    /// Select with nothing else focused shows or hides the controls. It never
    /// toggles playback (that is the play/pause button, and Select on the
    /// focused scrubber).
    private func toggleControlsFromContent() {
        guard let vm = viewModel, !vm.playbackState.isFailed else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            if vm.showControls {
                vm.showControls = false
            } else {
                vm.showControlsTemporarily()
            }
        }
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

        // Cancel auto-skip countdown if active (highest priority)
        if vm.skipCountdownSeconds > 0 {
            vm.cancelSkipCountdown()
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
        // The focus engine reads the SAME indirect touch stream this recognizer
        // does, and a recognizer that reaches .began cancels the competing
        // interaction. An unconstrained pan therefore swallowed vertical swipes
        // and the engine never turned them into the move commands that drive
        // `.onMoveCommand` (swipe up/down to the transport controls). Gate the
        // begin so only a clearly horizontal, actionable swipe is claimed.
        panRecognizer.delegate = self
        view.addGestureRecognizer(panRecognizer)
        panGestureRecognizer = panRecognizer
    }

    /// True when a touch-surface swipe should drive the scrubber. Mirrors the
    /// bail conditions in `handlePanGesture` so the recognizer never *begins*
    /// in a state where it would no-op — beginning is what steals the gesture
    /// from the focus engine.
    ///
    /// Controls-focus mode does NOT disqualify a swipe. The scrubber is only
    /// on screen once the controls are up, and raising them is what sets
    /// `controlsFocusActive` — gating on it meant the pan refused to begin in
    /// exactly the state where the user can see the thing they want to drag.
    /// Only focus resting on a transport BUTTON blocks the swipe, so a
    /// horizontal flick there still moves focus along the row.
    private var panCanDriveScrub: Bool {
        guard let vm = viewModel else { return false }
        return !vm.playbackState.isFailed
            && vm.postVideoState == .hidden
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
              !vm.playbackState.isFailed
        else { return }

        vm.showControlsTemporarily()
    }

    @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        // Kept in sync with `panCanDriveScrub`, which stops the recognizer from
        // beginning (and thus stealing the gesture) in these same states.
        guard panCanDriveScrub else { return }

        // Touch-surface pan drives continuous swipe-to-scrub whether the item
        // is playing or paused. It used to require `.paused`, so a swipe during
        // playback did nothing at all — the recognizer still began and swallowed
        // the gesture, but the handler returned immediately.

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

        // Static metadata (re-applied on episode advance via itemGeneration).
        applyRailMetadata(vm: vm)

        // Scrubber focus proxy: an invisible view geometrically below the
        // rail's button cluster (see its constraints above) so the focus
        // engine's own downward search from ANY cluster button lands here,
        // not on a same-row cone candidate. The bar itself renders the
        // focus indication (grow-and-brighten) — the proxy draws nothing.
        scrubberProxy?.onFocusChange = { [weak bar] focused in
            bar?.setFocusEmphasis(focused)
        }
        // Scrubber input model, unified with the content-focused path (see
        // RemoteInputHandler): a quick Left/Right tap skips by `tapSeekSeconds`,
        // a hold (>= holdThreshold) starts the FF/RW shuttle, and any press
        // while already shuttling bumps its speed. The proxy owns tap-vs-hold
        // detection; the closures below just carry the resolved intent.
        //
        // Controls-focus mode is deliberately NOT exited here. Leaving it
        // active keeps the GameController seek path swallowed (see
        // RemoteInputHandler.emit), so while the scrubber holds focus the proxy
        // is the SOLE seek handler — no press is acted on twice (a double
        // `stepSeek` would otherwise coalesce into a 2x skip).
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
            }
            .store(in: &cancellables)

        // The meta row's audio slot names the track that is playing, so it has
        // to follow the selection — both the user's pick and the engine's own
        // late-arriving track list (issue #200).
        vm.$currentAudioTrackId
            .combineLatest(vm.$audioTracks)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak vm] _ in
                if let vm { self?.applyRailMetadata(vm: vm) }
            }
            .store(in: &cancellables)

        vm.$currentTime
            .combineLatest(vm.$duration, vm.$isScrubbing, vm.$scrubTime)
            .combineLatest(vm.$wheelScrubbing.removeDuplicates())
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak vm] combined, isWheelScrubbing in
                let (currentTime, duration, isScrubbing, scrubTime) = combined
                guard let self, let vm else { return }
                self.progressBar?.update(
                    currentTime: currentTime, duration: duration,
                    isScrubbing: isScrubbing, scrubTime: scrubTime,
                    scrubStepLabelText: vm.scrubStepLabel,
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

                // Mid-playback buffering (seek landings, engine stalls)
                // borrows the same quiet cue — no skeleton, no centered
                // spinner, just the label. Buffering must NOT feed the
                // skeleton/focus gates above: the bar keeps its fill and the
                // scrubber stays focusable through a rebuffer.
                self.loadingLabel?.isHidden = !(loading || state == .buffering)

                if state == .paused, vm.duration > 0 {
                    let minutesLeft = Int(max(0, vm.duration - vm.currentTime) / 60)
                    self.pauseTimeLabel?.text = "Paused · \(minutesLeft)m left"
                }

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
                self?.applyChromeVisibility()
                self?.applyPostVideoState(state)
            }
            .store(in: &cancellables)

        // The page's live parts: the countdown ring and the Play Next / Play
        // Now title both key off the countdown.
        vm.$countdownSeconds
            .combineLatest(vm.$isCountdownPaused, vm.$nextEpisode)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPostVideoContent() }
            .store(in: &cancellables)

        vm.$subtitleTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak rail] tracks in
                // Port of the old card binding: same enabled-look, applied
                // to the rail's subtitles button now.
                rail?.subtitlesButton.alpha = tracks.isEmpty ? 0.4 : 1
            }
            .store(in: &cancellables)

        vm.$upNextEpisodes
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak vm] episodes in
                guard let self, let vm else { return }
                self.upNextEpisodesCache = episodes
                self.rail?.setUpNextAvailable(!episodes.isEmpty && vm.metadata.type == "episode")
                // The open Up Next panel is reading a snapshot of the old
                // list — a fresh instance is built per presentation, so
                // there's no way to refresh it in place. Dismiss rather
                // than leave a stale list on screen; doesn't touch the
                // CC/audio/info panels, which don't key off this publisher.
                if self.isShowingUpNextPanel {
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
        rail.onReplayLongPress = { [weak vm] in vm?.replayWithCaptions() }
        rail.onSubtitles = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            self.presentRailPanel(
                content: CardTrackListView(
                    header: "Subtitles", tracks: vm.subtitleTracks,
                    selectedTrackId: vm.currentSubtitleTrackId, showsOffRow: true,
                    steppers: [
                        // Delay: sticky per movie/episode (ratingKey).
                        CardStepperConfig(
                            title: "Delay",
                            value: { [weak vm] in SubtitleAdjustments.formattedDelay(vm?.subtitleDelaySeconds ?? 0) },
                            onStep: { [weak vm] step in vm?.adjustSubtitleDelay(bySteps: step) }),
                        // Height: sticky per title, like Delay above.
                        CardStepperConfig(
                            title: "Height",
                            value: { [weak vm] in
                                SubtitleAdjustments.formattedHeight(vm?.subtitleHeightUnits ?? 0)
                            },
                            onStep: { [weak vm] step in vm?.adjustSubtitleHeight(bySteps: step) }),
                    ],
                    onSelect: { [weak vm, weak self] id in
                        vm?.selectSubtitleTrack(id: id)
                        self?.activeRailPanel?.dismissPanel()
                    }),
                width: 520, from: rail.subtitlesButton)
        }
        rail.onAudio = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            self.presentRailPanel(
                content: CardTrackListView(
                    header: "Audio", tracks: vm.audioTracks,
                    selectedTrackId: vm.currentAudioTrackId, showsOffRow: false,
                    onSelect: { [weak vm, weak self] id in
                        if let id { vm?.selectAudioTrack(id: id) }
                        self?.activeRailPanel?.dismissPanel()
                    }),
                width: 520, from: rail.audioButton)
        }
        rail.onInfo = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            // The Advanced tab exists only on the aether route (an AetherPlayer
            // is present). Its provider reads the engine telemetry snapshot.
            let advancedProvider: (() -> AetherAdvancedStats?)? =
                vm.aetherPlayer != nil ? { [weak vm] in vm?.aetherPlayer?.advancedStats() } : nil
            self.presentRailPanel(
                content: PlayerInfoTabsView(metadata: vm.metadata, modes: vm.streamingModeInfo,
                                            advancedProvider: advancedProvider),
                width: 560, from: rail.infoButton)
        }
        rail.onUpNext = { [weak self] in
            guard let self, let vm = self.viewModel, !self.upNextEpisodesCache.isEmpty else { return }
            let presented = self.presentRailPanel(
                content: UpNextListView(
                    episodes: self.upNextEpisodesCache, currentRatingKey: vm.metadata.ratingKey,
                    seasonNumber: vm.metadata.parentIndex, serverURL: vm.serverURL, authToken: vm.authToken,
                    onSelect: { [weak self, weak vm] episode in
                        vm?.exitControlsFocus()
                        Task { await vm?.playEpisode(episode) }
                        self?.activeRailPanel?.dismissPanel()
                    }),
                width: 520, from: rail.upNextButton)
            self.isShowingUpNextPanel = presented
        }

        rail.onInsights = { [weak self] in
            guard let self, self.insightsButtonShouldBeAvailable else { return }
            self.presentRailPanel(
                content: InsightsPanelContainerView(
                    cast: self.insightsCastCache,
                    trivia: self.insightsTriviaCache,
                    suppressedTriviaIDs: self.suppressedTriviaIDsCache,
                    hideSpoilers: Self.hideTriviaSpoilers),
                width: 640, from: rail.insightsButton)
        }

        // Content filter is not exposed in the player yet — the button stays
        // hidden (its default in PlayerRailView) until the feature is ready.
    }

    /// Spoiler filtering is forced OFF for everyone for now, and the Appearance
    /// setting that used to drive it is gone. `TriviaFact` fails CLOSED on a
    /// missing or malformed spoiler tag, so filtering on it dropped facts that
    /// were never spoilers. The `hideSpoilers:` plumbing stays — flip this one
    /// constant (or re-add the setting behind it) to bring the filter back.
    private static let hideTriviaSpoilers = false

    /// Whether the Insights panel has anything to show: a non-empty cast
    /// list, or at least one trivia fact left after the hide-spoilers /
    /// suppression filter. Either section alone is enough to surface the
    /// rail button; both empty means fully graceful-absent (no button).
    private var insightsButtonShouldBeAvailable: Bool {
        if !insightsCastCache.isEmpty { return true }
        guard let trivia = insightsTriviaCache else { return false }
        return !trivia.visibleFacts(hideSpoilers: Self.hideTriviaSpoilers,
                                    suppressed: suppressedTriviaIDsCache).isEmpty
    }

    /// Re-derives the rail's Insights button visibility from the current
    /// cast + trivia snapshots. Called from both the `$insightsCast` and
    /// `$insightsTrivia` sinks since either can flip the combined
    /// availability independently of the other.
    private func updateInsightsAvailability() {
        rail?.setInsightsAvailable(insightsButtonShouldBeAvailable)
    }

    /// Shared presenter for the CC/audio/info/Up Next rail panel. Only
    /// one panel is ever up: presenting a new one dismisses whatever's
    /// showing. Guarded on the rail cluster actually being visible and
    /// not mid-scrub — the rail's buttons are hidden during a scrub and
    /// while loading, but a stray callback firing in that window (e.g.
    /// a race on the loading→ready edge) must not construct a panel
    /// anchored to a rail that isn't there to anchor to.
    ///
    /// Returns whether a panel was actually presented, so callers that
    /// track "which content is showing" (Task 6's Up Next staleness
    /// check) know whether their flag should stick.
    @discardableResult
    private func presentRailPanel(content: UIView, width: CGFloat, from button: UIView) -> Bool {
        guard let rail, rail.alpha > 0.5, viewModel?.isScrubbing != true else { return false }
        // Every presentation resets the content-type flag — only onUpNext
        // re-marks it (after this call returns). Without this, a CC/audio/info
        // panel superseding an open Up Next panel leaves the flag stuck true
        // (the old panel's onDismiss identity guard rightly won't touch it),
        // and the next $upNextEpisodes emission would dismiss the wrong panel.
        isShowingUpNextPanel = false
        activeRailPanel?.dismissPanel()
        let panel = PlayerRailPanelView.present(content: content, width: width,
                                                in: view, aboveRail: rail, towards: button)
        // The system's Menu gesture recognizer races the panel's own
        // responder-chain consumption and calls dismiss(animated:) on this
        // VC afterwards — arm the block so that echo is swallowed instead
        // of force-dismissing a panel that just handled Menu internally.
        panel.onMenuHandled = { [weak self] in self?.blockDismissTemporarily() }
        panel.onDismiss = { [weak self, weak panel] in
            guard let self else { return }
            // Guard on identity: a superseding presentRailPanel() call
            // dismisses this panel asynchronously (0.15s fade) then
            // synchronously swaps in the next one, so this completion can
            // fire after `activeRailPanel`/`isShowingUpNextPanel` already
            // describe a newer panel — must not clobber that state.
            if self.activeRailPanel === panel {
                self.activeRailPanel = nil
                // Re-arm the container's Left/Right recognizers. An ENABLED
                // recognizer on an ancestor intercepts a press even when its
                // handler no-ops, so `isEnabled` has to track panel presence,
                // not just `controlsFocusActive`.
                self.applyChromeVisibility()
                self.isShowingUpNextPanel = false
                // Only clear the ambient-suppression flag if nothing
                // superseded this panel (the identity guard above already
                // confirms that) — a superseding presentRailPanel() call
                // sets it back to true right below before this can fire.
                self.viewModel?.isRailPanelOpen = false
            }
            self.setNeedsFocusUpdate(); self.updateFocusIfNeeded()
        }
        activeRailPanel = panel
        // Disarm them for the panel that just came up (see above).
        applyChromeVisibility()
        // A rail panel is a full-screen-adjacent overlay the ambient-pause
        // backdrop must not show through/around — see
        // UniversalPlayerViewModel.isRailPanelOpen.
        viewModel?.isRailPanelOpen = true
        view.setNeedsFocusUpdate(); view.updateFocusIfNeeded()
        return true
    }

    /// Eyebrow + title + meta row from the current item, ported from the
    /// 2a card's identical composition.
    ///
    /// The audio slot names the track that is actually PLAYING, so it must be
    /// derived from the view model's live selection rather than the item's
    /// stream list — reading the part's first audio stream showed the same
    /// label no matter which track the user picked (issue #200). Re-applied on
    /// every `$currentAudioTrackId` / `$audioTracks` emission (see bindChrome).
    private func applyRailMetadata(vm: UniversalPlayerViewModel) {
        let meta = vm.metadata
        rail?.setTitle(vm.title, eyebrow: vm.subtitle)

        let runtime = meta.duration.map { "\($0 / 60000) min" }
        rail?.setMeta(rating: meta.contentRating, runtime: runtime,
                      audio: railAudioLabel(vm: vm))
    }

    /// One-line name for the selected audio track, e.g. "English · TrueHD 7.1".
    /// Falls back to the track's own display name when there is no codec/channel
    /// detail to add, and to nil (slot hidden) before tracks have loaded.
    private func railAudioLabel(vm: UniversalPlayerViewModel) -> String? {
        // Before the engine publishes its track list the selection is unknown;
        // the default track is the honest guess, and the sink below corrects it
        // the moment a real selection lands.
        let track = vm.audioTracks.first(where: { $0.id == vm.currentAudioTrackId })
            ?? vm.audioTracks.first(where: { $0.isDefault })
        guard let track else { return nil }

        let format = track.audioFormatString
        let language = track.language ?? track.languageDisplay.capitalized
        guard !format.isEmpty, format != "Audio" else { return language }
        return "\(language) · \(format)"
    }

    /// Single writer for all chrome alphas. Every visibility rule lives
    /// here so no two sinks can fight over the same view's alpha (the old
    /// setChromeHidden / setAuxChromeHidden split let the ~0.5s time-sink
    /// re-reveal card/pill/panel over hidden controls). Called from the
    /// showControls, pausePresentation, playbackState, and time sinks; the
    /// guard-on-change makes per-tick calls free.
    ///
    /// Rules:
    /// - chromeVisible: controls up AND the frame is live (not ambient
    ///   pause). `|| isScrubbing` keeps the scrubber + scrim up during a
    ///   scrub even on the one off-device path (MPRemoteCommand
    ///   scrubNudge) that can begin a scrub without showControls being set.
    /// - railVisible: chrome visible AND not scrubbing — scrubbing hides
    ///   the rail and skip pill so focus reads unambiguously on the
    ///   scrubber (user call 2026-07-03).
    /// - paused: playback paused AND the frame is live (not ambient) —
    ///   drives the top-left pause indicator and the full-frame dim.
    /// - loading: the top-left "Loading" label shows whenever loading/idle
    ///   AND not ambient (the progress bar's own skeleton shimmer carries
    ///   the rest of the loading look); it uses `isHidden` from the state
    ///   sink too so it never intercepts focus while alpha is mid-fade.
    /// - scrubberProxy.isFocusEnabled: a FOCUS gate, not an alpha write (the
    ///   proxy is always invisible) — it must never be focusable while
    ///   controls are hidden, mid-scrub, or ambient, and only actually
    ///   reachable once controls-focus mode has moved focus onto the rail.
    // MARK: - Post-video (Up Next)

    /// Mount or unmount the Up Next page and hand it focus. The focus update
    /// is the load-bearing half: `preferredFocusEnvironments` alone changes
    /// nothing until the engine is asked to re-resolve, which is why the
    /// SwiftUI version rendered with nothing focused.
    private func applyPostVideoState(_ state: PostVideoState) {
        if state != .hidden {
            let overlay = postVideoOverlay ?? makePostVideoOverlay()
            if overlay.superview == nil {
                overlay.frame = view.bounds
                overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                overlay.alpha = 0
                overlay.resetFocusGrace()
                view.addSubview(overlay)
                UIView.animate(withDuration: 0.35) { overlay.alpha = 1 }
            }
            refreshPostVideoContent()
        } else {
            postVideoOverlay?.removeFromSuperview()
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
            backdrop: vm.loadingArtImage ?? vm.loadingThumbImage
        )
        overlay.setCountdown(
            remaining: vm.countdownSeconds,
            total: vm.countdownTotalSeconds,
            isPaused: vm.isCountdownPaused
        )
    }

    private func applyChromeVisibility() {
        guard let vm = viewModel else { return }
        let ambient = vm.pausePresentation != .frame
        let isLoading = vm.playbackState == .loading || vm.playbackState == .idle
        // Buffering shares the loading label but none of the other loading
        // treatment (no skeleton, no focus gate) — see the state sink.
        let showsActivityCue = isLoading || vm.playbackState == .buffering
        let chromeVisible = (vm.showControls || vm.isScrubbing) && !ambient
        let railVisible = chromeVisible && !vm.isScrubbing

        // Every APPEARANCE of the rail starts on the scrubber: it is the primary
        // affordance, and "where you left off" is scoped to one visit. The rail's
        // `lastFocusedButton` still wins WITHIN a visit — that is what returns
        // focus to the button that opened a rail panel after Menu — but it must
        // not survive the rail going away and coming back. Resetting only when
        // controls-focus ends is not enough now that an open panel deliberately
        // counts as still-in-the-rail (see `railOwnsFocus`).
        if railVisible && !railWasVisible { rail?.resetFocusMemory() }
        railWasVisible = railVisible
        let paused = vm.playbackState == .paused && !ambient && hasPlayedSinceLoad
        // Ambient pause keeps the scrubber (and its bottom scrim) up as a
        // read-only position indicator even though the rail fades. Not shown
        // while loading — there is no meaningful position yet.
        let scrubberVisible = chromeVisible || (ambient && !isLoading)
        // For a show, the episode title stays put in the rail during ambient
        // (same place, same size) while the rest of the rail empties out. The
        // rail view itself is held at alpha 1 so that held title shows; the
        // plate/eyebrow/meta/buttons fade inside `setAmbient`. Movies keep
        // nothing here (logo only).
        let keepRailTitle = ambient && vm.metadata.type == "episode"
        let railAlpha: CGFloat = keepRailTitle ? 1 : (railVisible ? 1 : 0)

        // The proxy is the rail's first focus landing, so it must be focusable
        // as soon as the chrome is up — NOT only after controls-focus mode has
        // already moved focus onto a rail button (the old rule, which made the
        // subtitles button the de-facto first landing).
        //
        // The `isFocused` term is load-bearing: a left/right press on the
        // focused proxy calls exitControlsFocus() and begins a scrub, which
        // clears BOTH `controlsFocusActive` and `railVisible`. Without this
        // term the proxy would stop being focusable in the middle of the very
        // gesture it is servicing, and the focus update that follows would yank
        // focus off the scrubber mid-shuttle. A view that currently holds focus
        // keeps it; the gate only governs whether focus may ARRIVE here.
        let proxyHasFocus = scrubberProxy?.isFocused == true
        scrubberProxy?.isFocusEnabled =
            (railVisible && !isLoading) || (proxyHasFocus && !isLoading && !ambient)

        // The content anchor holds focus whenever nothing else should: not
        // while the rail owns it, not while the skip pill does, not over
        // post-video, and not in the error state, where it is also HIDDEN so
        // its full-screen frame cannot occlude the SwiftUI error buttons below
        // it. Unlike the SwiftUI layer it replaces, this gate is synchronous,
        // so the focus update each state change triggers lands on the anchor
        // instead of on a view that only becomes focusable after SwiftUI's next
        // render (which could leave focus nowhere).
        let anchorEnabled = vm.postVideoState == .hidden
            && !vm.playbackState.isFailed
            && !vm.controlsFocusActive
            && !vm.skipPillOwnsFocus
        let anchorLosingFocus = contentAnchor?.isFocused == true && !anchorEnabled
        // Leaving the error state (Try Again): focus is on an error button that
        // is about to disappear, so hand it back explicitly.
        let anchorReturning = contentAnchor?.isHidden == true && !vm.playbackState.isFailed
        contentAnchor?.isFocusEnabled = anchorEnabled
        contentAnchor?.isHidden = vm.playbackState.isFailed
        if vm.postVideoState != .hidden || vm.playbackState.isFailed {
            // A press or hold in flight must not complete against a state that
            // no longer takes content presses (a tap landing as a skip behind
            // post-video). Keyed on those states, NOT on `anchorEnabled`: the
            // skip pill takes content presses while the anchor is gated off, and
            // this runs on every clock tick.
            contentPressDetector.cancel()
            contentDirectionalPressType = nil
            contentSelectPending = false
        }
        if anchorLosingFocus || anchorReturning {
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }

        // The skip pill lives independently of the rail: it stays up whenever a
        // marker is active (chrome shown OR hidden), so the user can jump forward
        // without first surfacing the controls. Hidden only while loading, during
        // ambient pause, or when post-video has taken over.
        let skipVisible = vm.showSkipButton && !isLoading && !ambient && vm.postVideoState == .hidden

        // Whether the pill owns focus (e.g. controls just hid with a marker up).
        // The focus re-resolution happens AFTER the alpha write below: the engine
        // only treats the pill as focusable once its model alpha is 1, so pushing
        // focus before the fade write would land nowhere.
        let ownsFocus = vm.skipPillOwnsFocus
        let ownershipChanged = ownsFocus != lastSkipPillOwnsFocus
        lastSkipPillOwnsFocus = ownsFocus

        // Pill sits just above the rail plate while the chrome is up, and drops
        // lower over the video when it hides.
        let pillOffset = railVisible ? Self.skipPillRaisedOffset : Self.skipPillLoweredOffset
        let pillOffsetChanged = skipPillBottomConstraint?.constant != pillOffset
        skipPillBottomConstraint?.constant = pillOffset
        refreshSkipGuideEnabled()

        // The panel floats above the rail — a scrub/ambient/hide that
        // takes the rail away must take the panel with it, since it
        // has nothing to anchor to and no route back to visible.
        if !railVisible {
            activeRailPanel?.dismissPanel()
        }

        let targets: [(UIView?, CGFloat)] = [
            (chromeScrim, chromeVisible ? 1 : 0),
            (progressBar, scrubberVisible ? 1 : 0),
            (ambientScrim, (ambient && !isLoading) ? 1 : 0),
            (rail, railAlpha),
            (skipPill, skipVisible ? 1 : 0),
            (pauseIndicator, paused ? 1 : 0),
            (pausedDimView, paused ? 1 : 0),
            (loadingLabel, showsActivityCue && !ambient ? 1 : 0),
        ]
        // `setAmbient` also drives the rail's sub-view alphas (plate/eyebrow/
        // meta/buttons vs. the held title), which the `targets` diff below
        // doesn't see, so fold its own change-detection in. (No rail → nothing
        // to animate there, so treat as unchanged.)
        let railAmbientChanged = rail.map { $0.ambientState != (ambient, keepRailTitle) } ?? false
        let targetsChanged = targets.contains(where: { view, alpha in
            view.map { abs($0.alpha - alpha) > 0.01 } == true
        })
        // Captions lift out of the rail's way on the SAME animation block, so
        // the two travel on one curve. Marking the overlay dirty before the
        // guard keeps its state correct even on the early-out path, where
        // nothing visible is moving anyway.
        let captionLiftChanged = captionOverlay.map { $0.controlsVisible != chromeVisible } ?? false
        captionOverlay?.controlsVisible = chromeVisible
        guard targetsChanged || railAmbientChanged || ownershipChanged
                || pillOffsetChanged || captionLiftChanged else { return }
        UIView.animate(withDuration: 0.25) {
            for (view, alpha) in targets { view?.alpha = alpha }
            self.rail?.setAmbient(ambient, keepTitle: keepRailTitle)
            if pillOffsetChanged { self.view.layoutIfNeeded() }
            if captionLiftChanged { self.captionOverlay?.layoutIfNeeded() }
        }
        // Model alpha is now 1 for a visible pill, so the engine will accept it
        // as a focus target. Re-resolve toward/away from the pill exactly once.
        if ownershipChanged {
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
    }

    /// Sync the pill's title (including any live countdown suffix) and
    /// re-evaluate its visibility + focus ownership.
    /// Sync the pill's title, drive the auto-skip fill sweep, and re-evaluate
    /// visibility + focus ownership. The fill starts when the countdown begins
    /// (seconds jump 0 → N, which IS the total duration) and clears when it
    /// cancels or fires; a mid-countdown re-show restarts with the remaining
    /// seconds so the sweep still lands with the skip.
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

    /// The Up→pill focus bridge is live only while the rail AND pill are on
    /// screen and the pill isn't already focused — disabling it when the pill
    /// holds focus keeps Down from being trapped straight back onto the pill.
    private func refreshSkipGuideEnabled(pillFocusedOverride: Bool? = nil) {
        guard let vm = viewModel else { skipPillFocusGuide?.isEnabled = false; return }
        let isLoading = vm.playbackState == .loading || vm.playbackState == .idle
        let railVisible = vm.showControls && !vm.isScrubbing && vm.pausePresentation == .frame
        let skipVisible = vm.showSkipButton && !isLoading
            && vm.pausePresentation == .frame && vm.postVideoState == .hidden
        let pillFocused = pillFocusedOverride ?? (skipPill?.isFocused ?? false)
        skipPillFocusGuide?.isEnabled = railVisible && skipVisible && !pillFocused
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)

        // `controlsFocusActive` means "the rail owns focus", and it is the SOLE
        // suppressor of seek input (the GameController path's `emit` gate and
        // the content anchor's focus gate both key on it). But it was once only
        // SET from the content layer's Up/Down (`handleContentVertical` now). The rail is focusable whenever chrome is up
        // (`scrubberProxy.isFocusEnabled = railVisible …`), so raising it any
        // other way — Select → .playPause → showControlsTemporarily() — left
        // focus sitting in the rail with the flag false, and every Left/Right
        // then BOTH moved focus and seeked 30s. Drive the flag from where focus
        // actually is; entry path stops mattering.
        //
        // Decide from the DESTINATION, and only when focus actually landed
        // somewhere. Two traps make that phrasing load-bearing:
        //   - Dismissing a rail panel passes through a transient `next == nil`
        //     before focus re-lands. Treating that as "left the rail" runs
        //     exitControlsFocus(), whose sink calls `rail.resetFocusMemory()`,
        //     so the rail forgets the button that opened the panel.
        //   - The SwiftUI content layer focuses as a `UIKitFocusableViewResponderItem`,
        //     NOT a UIView, so `nextFocusedView` is nil there too. Gate on
        //     `nextFocusedItem` (which is non-nil) and test containment on the
        //     view (which correctly reports "not the rail").
        if let vm = viewModel, context.nextFocusedItem != nil {
            if railOwnsFocus(context.nextFocusedView) {
                vm.enterControlsFocus()
            } else {
                vm.exitControlsFocus()
            }
        }

        // Focus moved to/from the pill: retoggle the Up→pill bridge so it never
        // traps the pill's own Down press. Read the new focus from the context —
        // `isFocused` isn't reliably updated yet mid-transition.
        refreshSkipGuideEnabled(pillFocusedOverride: context.nextFocusedView === skipPill)
    }

    /// The scrubber proxy is a SIBLING of the rail, not a descendant (see the
    /// setup comment at `railView.scrubberFocusProxy = proxy`), so "focus is in
    /// the rail" needs both roots.
    private func railOwnsFocus(_ view: UIView?) -> Bool {
        guard let view else { return false }
        if let proxy = scrubberProxy, view === proxy { return true }
        if let rail, view.isDescendant(of: rail) { return true }
        // A presented rail panel is an EXTENSION of the rail, not an exit from
        // it. Its view is added to the window, so `isDescendant(of: rail)` is
        // false — but treating that as "focus left the rail" runs
        // exitControlsFocus(), whose sink calls `rail.resetFocusMemory()`.
        // Dismissing the panel then landed focus on the rail's default first
        // stop (the INVISIBLE scrubber proxy) instead of the button that opened
        // it, which reads as focus disappearing.
        if let panel = activeRailPanel, panel.window != nil, view.isDescendant(of: panel) { return true }
        return false
    }
}

/// Invisible focus stop for the scrubber. Sits geometrically below the
/// rail's button cluster (see the container's constraints) so the focus
/// engine's downward search from ANY cluster button lands here rather than
/// settling on a same-row cone candidate — the bug this view fixes. Draws
/// nothing; the progress bar itself is the visible focus indicator
/// (`PlayerProgressBarView.setFocusEmphasis(_:)`).
private final class ScrubberFocusProxyView: UIView {

    /// Focus gate, set by `PlayerContainerViewController.applyChromeVisibility()`.
    /// Never true while controls are hidden, mid-scrub, or ambient.
    var isFocusEnabled = false

    /// Fired when this view gains or loses focus.
    var onFocusChange: ((Bool) -> Void)?

    /// Quick Left/Right tap (released before `holdThreshold`) → skip. Arg: forward.
    var onSkip: ((Bool) -> Void)?
    /// Left/Right hold, or any Left/Right press while already scrubbing → shuttle.
    /// Arg: forward.
    var onShuttle: ((Bool) -> Void)?
    /// Center/`.select` press.
    var onSelect: (() -> Void)?
    /// Whether a shuttle is currently running — a press during one bumps speed
    /// immediately instead of waiting to distinguish tap from hold.
    var isScrubbingProvider: (() -> Bool)?

    /// `.select`/`.leftArrow`/`.rightArrow` are consumed here; everything else
    /// (notably `.menu`) is passed to `super` so it bubbles to the container.

    override var canBecomeFocused: Bool { isFocusEnabled }

    // Tap-vs-hold detection for the directional press — the same
    // `DirectionalPressDetector` RemoteInputHandler uses, so both focus
    // regimes behave identically by construction rather than by two hand
    // -rolled timers staying in sync.
    private let directionalDetector = DirectionalPressDetector()

    override init(frame: CGRect) {
        super.init(frame: frame)
        directionalDetector.onHold = { [weak self] forward in self?.onShuttle?(forward) }
        directionalDetector.onTap = { [weak self] forward in self?.onSkip?(forward) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if context.nextFocusedView === self {
            onFocusChange?(true)
        } else if context.previouslyFocusedView === self {
            onFocusChange?(false)
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            case .select:
                onSelect?()
            case .leftArrow:
                beginArrow(forward: false)
            case .rightArrow:
                beginArrow(forward: true)
            default:
                super.pressesBegan(presses, with: event)
            }
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            case .leftArrow, .rightArrow:
                endArrow()
            case .select:
                break  // consumed at began
            default:
                super.pressesEnded(presses, with: event)
            }
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            case .leftArrow, .rightArrow:
                cancelArrow()
            case .select:
                break
            default:
                super.pressesCancelled(presses, with: event)
            }
        }
    }

    private func beginArrow(forward: Bool) {
        // Already shuttling: bump/redirect immediately, no tap-vs-hold wait.
        if isScrubbingProvider?() == true {
            onShuttle?(forward)
            return
        }
        directionalDetector.begin(forward: forward)
    }

    private func endArrow() {
        directionalDetector.end()
    }

    private func cancelArrow() {
        directionalDetector.cancel()
    }
}

/// Invisible, full-screen focus stop for the content state: chrome hidden, or
/// up but not yet entered. It replaces the focusable SwiftUI layer that used to
/// hold focus here.
///
/// It handles no presses itself. They bubble to the container, whose
/// "Content-state presses" section is the single owner of that grammar, the
/// same way the rail's buttons already let Menu and Play/Pause bubble.
///
/// Full screen on purpose: the focus engine never finds a candidate beyond
/// its edges, so no directional press or swipe from here moves focus on its
/// own. That is the same geometry the SwiftUI layer had, and what every
/// Up/Down/Left/Right rule in the container assumes. Stacked above the video,
/// captions and full-frame scrims (so nothing full-screen occludes it) and
/// below the rail and every other control (so it occludes none of them). It is
/// hidden in the error state, where the SwiftUI error buttons below it need
/// focus.
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

/// 2a left-readability scrim: horizontal black gradient behind the card
/// (rgba(0,0,0,.8) → .2 @46% → transparent @66%).
final class ChromeScrimView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        let gradient = layer as! CAGradientLayer
        gradient.colors = [
            UIColor.black.withAlphaComponent(0.8).cgColor,
            UIColor.black.withAlphaComponent(0.2).cgColor,
            UIColor.black.withAlphaComponent(0).cgColor,
        ]
        gradient.locations = [0, 0.46, 0.66]
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

    /// Only let the swipe-to-scrub pan claim a gesture that is clearly
    /// HORIZONTAL and that it will actually act on. On tvOS the focus engine
    /// consumes the same indirect-touch stream; once a recognizer begins, the
    /// competing interaction is cancelled. Refusing here (rather than bailing
    /// inside the action) leaves vertical swipes to the focus engine, which is
    /// what surfaces the transport controls via `.onMoveCommand`.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
              pan === panGestureRecognizer
        else { return true }

        guard panCanDriveScrub else { return false }

        // Never while the clickpad is physically down. A click disturbs touch
        // sensing, and the jump in reported position reads as a fast swipe: the
        // pan began mid-click and put the player into swipe-scrub, so the
        // click's own Left/Right then nudged an uncommitted scrub cursor
        // instead of skipping, and nothing moved until the user pressed Select.
        guard !RemoteInputHandler.isClickpadDown else { return false }

        // Decide on VELOCITY, not translation. This is called the instant the
        // pan clears its slop threshold, when translation is still near zero
        // and its direction is noise; velocity is already well-defined. Require
        // a decisive horizontal bias (2:1) so a diagonal drift toward the
        // controls still reads as vertical and reaches the focus engine.
        let velocity = pan.velocity(in: view)
        guard velocity != .zero else { return false }
        return abs(velocity.x) > abs(velocity.y) * 2
    }
}
