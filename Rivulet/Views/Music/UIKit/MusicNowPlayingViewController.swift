// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicNowPlayingViewController.swift
//  Rivulet
//
//  Music's Now Playing: 524pt artwork over a wash of its colours, the timeline
//  at y 911 with a row of round buttons above it and Info and the lyrics | queue
//  switch below. Three stages from that switch: plain, lyrics, queue. The focus
//  engine moves between the rows; only the timeline owns Left and Right.
//  Measured from Apple Music on tvOS 26.
//

import UIKit
import Combine

@MainActor
final class MusicNowPlayingViewController: UIViewController, UIGestureRecognizerDelegate {
    private enum Mode { case plain, lyrics, queue }

    private enum Metrics {
        static let art = MusicQueueStripView.card
        static let artTop: CGFloat = 170
        static let lyricsArtX: CGFloat = 148
        static let lyricsX: CGFloat = 840
        static let button: CGFloat = 72
        /// The controls' container starts under the queue cards' text, so it never covers a card.
        static let controlsTop: CGFloat = 786
        static let upperTop: CGFloat = 802
        static let barCenter: CGFloat = 911
        static let bottomTop: CGFloat = 975
        /// Apple moves the artwork down when the controls leave (measured in its lyrics stage).
        static let hiddenShift: CGFloat = 40
        /// AVKit's timeouts: 5s with focus on the timeline, 8s with it on a button.
        static let autoHide: TimeInterval = 5
        static let autoHideInButtons: TimeInterval = 8
        /// AVKit ignores Menu this long after an auto-hide: a press aimed at the controls must not close the page.
        static let menuLockout: CFTimeInterval = 0.5
        /// Apple returns a browsed lyric to the sung line after this long, while the song plays.
        static let lyricsReturn: TimeInterval = 10
        /// A held Up or Down steps this often. Rivulet's own: Apple has no press path.
        static let lyricRepeat: TimeInterval = 0.15
    }

    // MARK: - Presentation

    private static var presenter: AnyCancellable?
    private static var foregroundReturn: AnyCancellable?
    private static weak var current: MusicNowPlayingViewController?

    /// Now Playing follows `MusicQueue.showNowPlaying`, on top of whatever is presented.
    static func installPresenter() {
        guard presenter == nil else { return }
        presenter = MusicQueue.shared.$showNowPlaying
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { show in
                guard show else { current?.close(); return }
                guard current == nil, let top = MusicPresenter.top(from: nil) else { return }
                let page = MusicNowPlayingViewController()
                // Full screen, so `viewDidDisappear` runs and clears the flag.
                page.modalPresentationStyle = .fullScreen
                page.modalTransitionStyle = .crossDissolve
                current = page
                top.present(page, animated: true)
            }
        // tvOS tells an app nothing when the system Now Playing opens it, so coming back
        // while music plays stands in for it (#442).
        foregroundReturn = NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { _ in
                let queue = MusicQueue.shared
                if queue.currentTrack != nil, queue.playbackState == .playing { queue.showNowPlaying = true }
            }
    }

    // MARK: - State

    private let queue = MusicQueue.shared
    /// Opens on lyrics when they were last left on (#443).
    private var mode = UserDefaults.standard.bool(forKey: lyricsChosenKey) ? Mode.lyrics : Mode.plain {
        didSet { UserDefaults.standard.set(mode == .lyrics, forKey: Self.lyricsChosenKey) }
    }
    private static let lyricsChosenKey = "musicNowPlayingLyricsChosen"
    private var controlsHidden = false
    private var observers = Set<AnyCancellable>()
    private var artworkTask: Task<Void, Never>?
    private var infoTask: Task<Void, Never>?
    private var menuTask: Task<Void, Never>?
    private var lyricsFallback: DispatchWorkItem?
    private var hideTimer: Timer?
    private var browseTimer: Timer?
    private var repeatTimer: Timer?
    private let lyricsPan = UIPanGestureRecognizer()
    private var autoHiddenAt: CFTimeInterval = 0
    private var stageAnimator: UIViewPropertyAnimator?
    private var anchorBinding: DirectionalInputBinding?
    private var swipeBinding: DirectionalInputBinding?

    /// One-shot focus target: the anchor on hide, the timeline on show.
    private var pendingFocus: UIFocusEnvironment?
    /// Where focus was last, so a menu or the Info panel hands it back to its button.
    private weak var lastFocused: UIView?
    private weak var lastUpper: UIView?
    /// The track changed under an open menu or the Info panel: More still holds the last track's rows.
    private var menuIsStale = false

    /// The lyrics stage is chosen and this track has lines. Without them it draws as the plain stage.
    private var lyricsShown: Bool { mode == .lyrics && hasLyrics }
    private var hasLyrics = false

    /// Hidden controls over loaded lyrics: Up, Down, a vertical touch and Select belong to the lyrics.
    private var lyricsBrowsable: Bool {
        controlsHidden && lyricsShown && queue.currentLyrics != nil && presentedViewController == nil
    }
    private var isBrowsingLyrics: Bool { lyricsBrowsable && lyricsPane.isBrowsing }

    private func browses(_ direction: DirectionalInputBinding.Direction) -> Bool {
        (direction == .up || direction == .down) && lyricsBrowsable
    }

    // MARK: - Views

    private let backdrop = AmbientBackdropView()
    private let scrim = GradientView()
    private let header = MusicChrome.label(size: 29, weight: .medium, color: UIColor(white: 1, alpha: 0.6))
    private let artwork = UIImageView()
    private let caption = MusicNowPlayingCaptionView()
    private let lyricsPane = MusicLyricsPaneView()
    private let strip = MusicQueueStripView()
    private let controls = UIView()
    private let shuffleButton = MusicChrome.pill(title: nil, symbol: "shuffle", height: Metrics.button)
    private let repeatButton = MusicChrome.pill(title: nil, symbol: "repeat", height: Metrics.button)
    private let favoriteButton = MusicChrome.pill(title: nil, symbol: "star", height: Metrics.button)
    private let moreButton = MusicChrome.pill(title: nil, symbol: "ellipsis", height: Metrics.button)
    private let infoButton = MusicChrome.pill(title: String(localized: "Info"), symbol: nil, height: Metrics.button)
    private let modeSwitch = MusicModeSwitchView()
    private let progressBar = PlayerProgressBarView()
    private let scrubberProxy = ScrubberFocusProxyView()
    private let anchor = PreviewFocusAnchorView()
    private let barGuide = UIFocusGuide()
    private let bottomGuide = UIFocusGuide()
    private let stripGuide = UIFocusGuide()

    private var upperButtons: [UIButton] { [shuffleButton, repeatButton, favoriteButton, moreButton] }

    // MARK: - View

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let bounds = view.bounds

        backdrop.showsVignette = false
        backdrop.imageTransform = Self.wash
        for layer in [backdrop, scrim] as [UIView] {
            layer.frame = bounds
            layer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            layer.isUserInteractionEnabled = false
            view.addSubview(layer)
        }
        // AVKit's dimming while the controls show: clear down to y 384, 55% black from y 968.
        scrim.gradientLayer.colors = [0, 0.55, 0.55].map { UIColor(white: 0, alpha: $0).cgColor }
        scrim.gradientLayer.locations = [0.356, 0.896, 1]

        header.textAlignment = .center
        header.frame = CGRect(x: 480, y: 100 - header.font.ascender, width: bounds.width - 960,
                              height: ceil(header.font.lineHeight))
        artwork.contentMode = .scaleAspectFill
        artwork.clipsToBounds = true
        artwork.layer.cornerRadius = 12
        artwork.layer.cornerCurve = .continuous
        lyricsPane.frame = CGRect(x: Metrics.lyricsX, y: 0, width: bounds.width - Metrics.lyricsX - MusicMetrics.margin,
                                  height: bounds.height)
        // Not between tracks: the pane still holds the last one's lines, or the player its clock.
        lyricsPane.clock = { [weak self] in
            guard let queue = self?.queue, queue.currentLyrics != nil, queue.playbackState != .loading else { return nil }
            return queue.playbackTime
        }
        lyricsPane.isScanning = { [weak self] in self?.queue.scanLevel ?? 0 != 0 }
        caption.marqueesTitle = true
        // Exactly the cards and their text: a taller strip would sit under the controls' container.
        strip.frame = CGRect(x: 0, y: Metrics.artTop, width: bounds.width, height: Metrics.controlsTop - Metrics.artTop)
        strip.onSelect = { [weak self] in self?.jump(by: $0) }
        [header, artwork, caption, lyricsPane, strip].forEach(view.addSubview)
        // Beside the pane, not in it: the pane's blend and edge mask would eat the pill.
        view.insertSubview(lyricsPane.pill, aboveSubview: lyricsPane)

        buildControls()

        // 1pt at the origin: it covers nothing, and holds focus only while the controls are hidden.
        anchor.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        anchor.isUserInteractionEnabled = false
        view.addSubview(anchor)
        anchorBinding = DirectionalInputBinding(
            view: anchor, directions: DirectionalInputBinding.Direction.allCases, holds: [.up, .down],
            onTap: { [weak self] in self?.anchorInput($0, held: false) },
            onHold: { [weak self] in self?.anchorInput($0, held: true) },
            onHoldEnd: { [weak self] in self?.anchorHoldEnded($0) },
            // Over the lyrics a vertical touch is the pan's, never a swipe's.
            swipeGate: { [weak self] in self?.browses($0) != true })
        // As the video player's scrub pan: indirect touches only, never a press, gated before it begins.
        lyricsPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        lyricsPan.allowedPressTypes = []
        lyricsPan.addTarget(self, action: #selector(lyricsPanned))
        lyricsPan.delegate = self
        anchor.addGestureRecognizer(lyricsPan)
        addPressRecognizer(.select, on: anchor, action: #selector(selectWhileHidden))
        addPressRecognizer(.menu, on: view, action: #selector(menuPressed))
        addPressRecognizer(.playPause, on: view, action: #selector(playPausePressed))

        observeQueue()
        applyStage(animated: false)
        menuTask = Task { [weak self] in
            await MusicMenus.loadPlaylists()
            self?.refreshMenu()
        }
    }

    private func buildControls() {
        let bounds = view.bounds
        controls.frame = CGRect(x: 0, y: Metrics.controlsTop, width: bounds.width, height: bounds.height - Metrics.controlsTop)
        view.addSubview(controls)
        let top = Metrics.controlsTop

        // Upper row: 72pt circles on a 100 pitch, the last one's right edge at x 1840.
        for (index, button) in upperButtons.reversed().enumerated() {
            controls.addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: controls.topAnchor, constant: Metrics.upperTop - top),
                button.trailingAnchor.constraint(equalTo: controls.trailingAnchor,
                                                 constant: -MusicMetrics.margin - CGFloat(index) * 100),
            ])
        }
        shuffleButton.addAction(UIAction { [weak self] _ in
            self?.queue.toggleShuffle()
            self?.refreshToggles()
        }, for: .primaryActionTriggered)
        repeatButton.addAction(UIAction { [weak self] _ in
            self?.queue.cycleRepeatMode()
            self?.refreshToggles()
        }, for: .primaryActionTriggered)
        // The star flips here, in the press's own frame; the queue reverts it if the server refuses.
        favoriteButton.addAction(UIAction { [weak self] _ in
            guard let self, let track = queue.currentTrack else { return }
            queue.toggleFavorite(track)
            refreshToggles()
        }, for: .primaryActionTriggered)
        moreButton.showsMenuAsPrimaryAction = true

        // The AVKit-measured bar, with its track's centre line on Apple Music's y 911.
        progressBar.padsMinutes = false
        progressBar.showsScrubThumbnail = false
        progressBar.frame = CGRect(x: MusicMetrics.margin, y: Metrics.barCenter - 10 - top,
                                   width: bounds.width - MusicMetrics.margin * 2, height: 72)
        controls.addSubview(progressBar)

        infoButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 34, bottom: 0, trailing: 34)
        infoButton.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 31, weight: .semibold)
            return attributes
        }
        infoButton.addAction(UIAction { [weak self] _ in self?.showInfo() }, for: .primaryActionTriggered)
        modeSwitch.translatesAutoresizingMaskIntoConstraints = false
        modeSwitch.lyrics.onSelect = { [weak self] in self?.toggle(.lyrics) }
        modeSwitch.queue.onSelect = { [weak self] in self?.toggle(.queue) }
        [infoButton, modeSwitch].forEach(controls.addSubview)
        NSLayoutConstraint.activate([
            infoButton.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: MusicMetrics.margin),
            infoButton.topAnchor.constraint(equalTo: controls.topAnchor, constant: Metrics.bottomTop - top),
            modeSwitch.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -MusicMetrics.margin),
            modeSwitch.topAnchor.constraint(equalTo: infoButton.topAnchor),
        ])

        // The timeline's focus stop, over the bar as the video players place it.
        scrubberProxy.frame = CGRect(x: progressBar.frame.minX, y: Metrics.barCenter - 18,
                                     width: progressBar.frame.width, height: 64)
        scrubberProxy.isFocusEnabled = true
        scrubberProxy.onSkip = { [weak self] forward in self?.skip(forward: forward) }
        // A hold starts a scan, and while one runs every Left or Right steps it instead of skipping.
        scrubberProxy.isScrubbingProvider = { [weak self] in self?.queue.scanLevel ?? 0 != 0 }
        scrubberProxy.onShuttle = { [weak self] forward in
            self?.queue.scan(forward: forward)
            self?.restartHideTimer()
        }
        scrubberProxy.onSelect = { [weak self] in
            self?.queue.togglePlayPause()
            self?.restartHideTimer()
        }
        view.addSubview(scrubberProxy)
        // A touch swipe is no arrow press. Not while the clickpad is down: a click jolts the touch.
        swipeBinding = DirectionalInputBinding(
            gatedSwipesOn: scrubberProxy, directions: [.left, .right],
            shouldHandle: { [weak self] _ in
                guard let self else { return false }
                return scrubberProxy.isFocused && !RemoteInputHandler.isClickpadDown && presentedViewController == nil
            },
            onSwipe: { [weak self] direction in self?.skip(forward: direction == .right) })

        // The bar is as wide as the screen and the buttons sit in its corners, so guides in the
        // gaps say where Up and Down lead. They belong to the container: a covered guide is skipped.
        for (guide, y) in [(stripGuide, 790), (barGuide, 878), (bottomGuide, 961)] as [(UIFocusGuide, CGFloat)] {
            controls.addLayoutGuide(guide)
            NSLayoutConstraint.activate([
                guide.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
                guide.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
                guide.topAnchor.constraint(equalTo: controls.topAnchor, constant: y - top),
                guide.heightAnchor.constraint(equalToConstant: 10),
            ])
        }
        barGuide.preferredFocusEnvironments = [favoriteButton]
        bottomGuide.preferredFocusEnvironments = [infoButton]
        stripGuide.isEnabled = false
    }

    private func addPressRecognizer(_ type: UIPress.PressType, on target: UIView, action: Selector) {
        let tap = UITapGestureRecognizer(target: self, action: action)
        tap.allowedPressTypes = [NSNumber(value: type.rawValue)]
        tap.delegate = self
        target.addGestureRecognizer(tap)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        restartHideTimer()
    }

    /// Through the presenter: a controller asked to dismiss itself while a menu or the Info
    /// panel is open over it closes only that.
    private func close() {
        presentingViewController?.dismiss(animated: true)
    }

    // Closed, not covered by a menu: nothing over Now Playing is full screen.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard presentedViewController == nil else { return }
        [hideTimer, browseTimer, repeatTimer].forEach { $0?.invalidate() }
        queue.endScan()
        [artworkTask, infoTask, menuTask].forEach { $0?.cancel() }
        if Self.current === self { Self.current = nil }
        queue.showNowPlaying = false
    }

    // MARK: - Queue state

    private func observeQueue() {
        let main = DispatchQueue.main
        queue.$currentTrack.receive(on: main).sink { [weak self] _ in self?.trackChanged() }.store(in: &observers)
        queue.$playbackState.receive(on: main).sink { [weak self] _ in
            guard let self else { return }
            caption.setPlaying(queue.playbackState == .playing)
            reloadStrip()
        }.store(in: &observers)
        // A scan draws as the video players' shuttle does: AVKit's glyph and level beside the time.
        queue.$currentTime.combineLatest(queue.$duration, queue.$scanLevel).receive(on: main)
            .sink { [weak self] time, duration, level in
                self?.progressBar.update(currentTime: time, duration: duration, isScrubbing: level != 0, scrubTime: time,
                                         scanLevel: level, scrubThumbnail: nil, markers: [], chapters: [])
            }.store(in: &observers)
        Publishers.Merge3(queue.$isShuffled.map { _ in () }, queue.$repeatMode.map { _ in () },
                          queue.$favoriteOverrides.map { _ in () })
            .receive(on: main).sink { [weak self] in self?.refreshToggles() }.store(in: &observers)
        Publishers.Merge(queue.$queue.map { _ in () }, queue.$history.map { _ in () })
            .receive(on: main).sink { [weak self] in self?.reloadStrip() }.store(in: &observers)
        queue.$currentLyrics.receive(on: main).sink { [weak self] _ in self?.lyricsChanged() }.store(in: &observers)
    }

    private func trackChanged() {
        // A browsed line belongs to the track that just left.
        endLyricBrowsing(animated: false)
        // An Info panel still fetching its year would open for the track that just left.
        infoTask?.cancel()
        let track = queue.currentTrack
        header.text = track?.albumTitle
        caption.configure(title: track?.title ?? "", artist: track?.artistName, showsBars: true,
                          isPlaying: queue.playbackState == .playing)
        artworkTask?.cancel()
        if artwork.image == nil { artwork.image = MusicChrome.placeholder(side: Metrics.art) }
        artworkTask = MusicChrome.loadArtwork(track?.artwork.poster, quality: .full) { [weak self] image in
            self?.artwork.image = image ?? MusicChrome.placeholder(side: Metrics.art)
        }
        backdrop.setAmbient(url: track?.artwork.poster)
        // The Info panel names the track it opened on, so it leaves with that track.
        if presentedViewController is TileMenuPopupViewController { dismiss(animated: false) }
        refreshToggles()
        refreshMenu()
        reloadStrip()
    }

    private func reloadStrip() {
        guard let track = queue.currentTrack else { return }
        strip.update(tracks: queue.history + [track] + queue.queue, currentIndex: queue.history.count,
                     isPlaying: queue.playbackState == .playing)
    }

    // The lyrics are nil for a moment after every track change. Dropping to the plain stage at
    // once would swing the artwork across the screen and back, so a missing set waits briefly.
    private func lyricsChanged() {
        endLyricBrowsing(animated: false)
        lyricsFallback?.cancel()
        if let lines = queue.currentLyrics {
            lyricsPane.setLines(lines)
            setLyricsAvailable(true)
        } else {
            let fallback = DispatchWorkItem { [weak self] in self?.setLyricsAvailable(false) }
            lyricsFallback = fallback
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: fallback)
        }
    }

    private func setLyricsAvailable(_ available: Bool) {
        guard available != hasLyrics else { return }
        hasLyrics = available
        refreshToggles()
        applyStage(animated: view.window != nil)
    }

    /// Every toggle shows its state, focused or not. Called in the press's own turn, and again
    /// when the queue reports a change made elsewhere.
    private func refreshToggles() {
        shuffleButton.isOn = queue.isShuffled
        repeatButton.isOn = queue.repeatMode != .off
        setGlyph(repeatButton, queue.repeatMode == .one ? "repeat.1" : "repeat")
        setGlyph(favoriteButton, queue.currentTrack.map(queue.isFavorite) == true ? "star.fill" : "star")
        modeSwitch.lyrics.isOn = lyricsShown
        // Never disabled: a track change must not take focus from the view that holds it.
        modeSwitch.lyrics.isDimmed = !hasLyrics
        modeSwitch.queue.isOn = mode == .queue
        restartHideTimer()
    }

    private func setGlyph(_ button: UIButton, _ symbol: String) {
        button.configuration?.image = UIImage(systemName: symbol)
    }

    // MARK: - Stage

    private func toggle(_ target: Mode) {
        restartHideTimer()
        // A segment whose track has no lyrics is inert.
        if target == .lyrics, !hasLyrics { return }
        mode = mode == target ? .plain : target
        // Shuffle and Repeat leave with the queue; Up from the timeline must not aim at one.
        if mode != .queue, lastUpper === shuffleButton || lastUpper === repeatButton { lastUpper = nil }
        refreshToggles()
        applyStage(animated: true)
    }

    /// One animator moves the artwork, fades the stages and the queue's two buttons.
    private func applyStage(animated: Bool) {
        // The pill is gone before the strip can take focus under it.
        if !lyricsShown { endLyricBrowsing(animated: false) }
        let queueShown = mode == .queue
        stageAnimator?.stopAnimation(true)
        // Everything the move touches is on screen for it; what ends up invisible is hidden after.
        for view in [artwork, caption, lyricsPane, strip, shuffleButton, repeatButton] as [UIView] { view.isHidden = false }
        let changes = {
            self.layoutStage()
            self.header.alpha = self.lyricsShown ? 0 : 1
            self.lyricsPane.alpha = self.lyricsShown ? 1 : 0
            self.strip.alpha = queueShown ? 1 : 0
            self.shuffleButton.alpha = queueShown ? 1 : 0
            self.repeatButton.alpha = queueShown ? 1 : 0
        }
        // A hidden view covers nothing: the artwork must not sit over the playing card.
        let finish = {
            self.artwork.isHidden = queueShown
            self.caption.isHidden = queueShown
            self.strip.isHidden = !queueShown
            self.lyricsPane.isHidden = !self.lyricsShown
            self.shuffleButton.isHidden = !queueShown
            self.repeatButton.isHidden = !queueShown
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            changes()
            finish()
            return
        }
        let animator = UIViewPropertyAnimator(duration: 0.45, curve: .easeInOut, animations: changes)
        animator.addCompletion { position in if position == .end { finish() } }
        stageAnimator = animator
        animator.startAnimation()
    }

    /// The artwork is centred, or beside the lyrics; with the controls gone it sits 40pt lower.
    private func layoutStage() {
        let x = lyricsShown ? Metrics.lyricsArtX : (view.bounds.width - Metrics.art) / 2
        let y = Metrics.artTop + (controlsHidden && mode != .queue ? Metrics.hiddenShift : 0)
        artwork.frame = CGRect(x: x, y: y, width: Metrics.art, height: Metrics.art)
        caption.frame = CGRect(x: x, y: y + Metrics.art, width: Metrics.art, height: MusicNowPlayingCaptionView.height)
    }

    /// Apple's ground is the artwork's colours with no picture left in them: here the cover's
    /// sixteen patch colours, each a soft blob, at one mid brightness so white text reads over any cover.
    private nonisolated static func wash(_ image: UIImage) -> UIImage {
        let (side, grid) = (32, 4)
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let source = image.cgImage,
              let bitmap = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                     space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        bitmap.interpolationQuality = .high
        bitmap.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        let block = side / grid
        // The bitmap's first row is the picture's top row.
        let colors: [UIColor] = (0..<(grid * grid)).map { patch in
            var sum = [0, 0, 0]
            for y in 0..<block {
                for x in 0..<block {
                    let index = ((patch / grid * block + y) * side + patch % grid * block + x) * 4
                    for channel in 0..<3 { sum[channel] += Int(pixels[index + channel]) }
                }
            }
            let mean = sum.map { CGFloat($0) / CGFloat(block * block * 255) }
            var (hue, saturation, brightness): (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
            UIColor(red: mean[0], green: mean[1], blue: mean[2], alpha: 1)
                .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            // A near-black patch has no hue worth amplifying.
            return UIColor(hue: hue, saturation: min(0.85, saturation * 2.2 * min(1, brightness * 3)),
                           brightness: 0.6 + 0.22 * brightness, alpha: 1)
        }
        let size = CGSize(width: 320, height: 180)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            // The middle patches set the ground the blobs sit on.
            colors[5].setFill()
            renderer.fill(CGRect(origin: .zero, size: size))
            for (index, color) in colors.enumerated() {
                let stops = [0.75, 0.4, 0].map { color.withAlphaComponent($0).cgColor } as CFArray
                guard let gradient = CGGradient(colorsSpace: space, colors: stops, locations: [0, 0.5, 1]) else { continue }
                let center = CGPoint(x: (CGFloat(index % grid) + 0.5) * size.width / CGFloat(grid),
                                     y: (CGFloat(index / grid) + 0.5) * size.height / CGFloat(grid))
                renderer.cgContext.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                                      endCenter: center, endRadius: size.width * 0.4, options: [])
            }
        }
    }

    // MARK: - Actions

    private func skip(forward: Bool) {
        if forward { queue.skipToNext() } else { queue.skipToPrevious() }
        restartHideTimer()
    }

    private func jump(by distance: Int) {
        if distance > 0 {
            queue.jumpToQueueItem(at: distance - 1)
        } else {
            queue.jumpToHistoryItem(at: queue.history.count + distance)
        }
        restartHideTimer()
    }

    /// From the More menu and the Info panel. Dismissing through the presenter also closes
    /// whatever of those is still on its way out.
    private func navigate(_ request: MusicNavigationRequest) {
        presentingViewController?.dismiss(animated: true) { MusicPresenter.show(request) }
    }

    // Reassigning the menu while it is open would close it under the user, so a change under an
    // open menu or panel waits for focus to come back, which is when nothing is open any more.
    private func refreshMenu(focusReturned: Bool = false) {
        menuIsStale = !focusReturned && presentedViewController != nil
        guard !menuIsStale, let track = queue.currentTrack else { return }
        moreButton.menu = MusicMenus.uiMenu(MusicMenus.track(track, screen: .nowPlaying) { [weak self] in self?.navigate($0) })
    }

    /// Apple's tvOS 26 Info panel is in no source. This one names the track and offers the two
    /// "Go to" rows tvOS 17 documented. The year is the album's, so it is fetched on the press.
    private func showInfo() {
        restartHideTimer()
        guard let track = queue.currentTrack, presentedViewController == nil else { return }
        infoTask?.cancel()
        infoTask = Task { [weak self] in
            var year: Int?
            if let ref = track.albumRef {
                year = (try? await MusicProviderRegistry.shared.provider(for: ref)?.albumDetail(for: ref))?.album.year
            }
            guard let self, !Task.isCancelled, presentedViewController == nil, view.window != nil else { return }
            let format = [
                year.map(String.init),
                track.audioCodec?.uppercased(),
                track.sampleRate.map { String(format: "%g kHz", Double($0) / 1000) },
                track.bitrate.map { "\($0) kbps" },
            ].compactMap { $0 }.joined(separator: " · ")
            let header = TileMenuHeader(
                title: track.title,
                detail: [track.artistName, track.albumTitle].compactMap { $0 }.joined(separator: " · "),
                summary: format)
            let rows = MusicMenus.track(track, screen: .nowPlaying) { [weak self] in self?.navigate($0) }
                .filter { $0.children.isEmpty }
            MusicMenus.presentPopup(rows, from: self, sourceFrame: infoButton.convert(infoButton.bounds, to: nil),
                                    header: header)
        }
    }

    // MARK: - Controls

    @objc private func menuPressed() {
        // Menu cancels a scan: the song goes back to where the scan began.
        if queue.scanLevel != 0 {
            queue.endScan(cancelled: true)
            return restartHideTimer()
        }
        guard controlsHidden else { return setControlsHidden(true) }
        // Menu steps back from a browsed lyric before it closes the page. The lockout keeps a
        // doubled press from doing both.
        if lyricsPane.isBrowsing {
            endLyricBrowsing()
            autoHiddenAt = CACurrentMediaTime()
            return
        }
        guard CACurrentMediaTime() - autoHiddenAt > Metrics.menuLockout else { return }
        // Not through the flag: once the queue has run out it is already false and nothing follows.
        close()
    }

    @objc private func playPausePressed() {
        queue.togglePlayPause()
        // Pausing to read: the browsed line and the hidden controls stay.
        if isBrowsingLyrics { return restartBrowseTimer() }
        setControlsHidden(false)
        restartHideTimer()
    }

    @objc private func selectWhileHidden() {
        // On a browsed lyric Select plays from it. Otherwise it is the usual toggle.
        if isBrowsingLyrics {
            // A track still loading has no position to move.
            if queue.playbackState != .loading, let start = lyricsPane.commitSelection() {
                queue.seek(to: MusicLyricsColumn.seekTime(start, duration: queue.duration))
                // `play()` fades in from silence, so not while the song already plays.
                if queue.playbackState != .playing { queue.play() }
            }
            return restartBrowseTimer()
        }
        queue.togglePlayPause()
        setControlsHidden(false)
    }

    // A press a menu or the Info panel declines must not act on the screen behind it.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard presentedViewController == nil else { return false }
        guard gestureRecognizer === lyricsPan else { return true }
        // Not while the clickpad is down: a click jolts the touch and would read as a drag.
        guard lyricsBrowsable, !RemoteInputHandler.isClickpadDown else { return false }
        let velocity = lyricsPan.velocity(in: view)
        return velocity != .zero && abs(velocity.y) > abs(velocity.x)
    }

    // A drag in progress must not fail a click: the pan runs beside every press recognizer, and
    // only the swipes exclude it.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (gestureRecognizer === lyricsPan || other === lyricsPan)
            && !(gestureRecognizer is UISwipeGestureRecognizer) && !(other is UISwipeGestureRecognizer)
    }

    // MARK: - Lyric browsing

    /// The hidden state's arrows: a lyric step over the lyrics, the controls everywhere else.
    private func anchorInput(_ direction: DirectionalInputBinding.Direction, held: Bool) {
        guard browses(direction) else {
            // A held arrow waits for its release: still down, it would walk focus on from the timeline.
            if !held { setControlsHidden(false) }
            return
        }
        let delta = direction == .down ? 1 : -1
        lyricsPane.step(delta)
        restartBrowseTimer()
        guard held else { return }
        repeatTimer?.invalidate()
        let timer = Timer(timeInterval: Metrics.lyricRepeat, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Select, Menu, a new track or the controls ended browsing under the held arrow.
                guard self.browses(direction), self.lyricsPane.isBrowsing else {
                    self.repeatTimer?.invalidate()
                    return
                }
                self.lyricsPane.step(delta)
                self.restartBrowseTimer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func anchorHoldEnded(_ direction: DirectionalInputBinding.Direction) {
        repeatTimer?.invalidate()
        if !browses(direction) { setControlsHidden(false) }
    }

    @objc private func lyricsPanned() {
        switch lyricsPan.state {
        case .began:
            lyricsPane.beginDrag()
            restartBrowseTimer()
        case .changed:
            lyricsPane.drag(by: lyricsPan.translation(in: view).y)
        case .ended:
            lyricsPane.endDrag(velocity: lyricsPan.velocity(in: view).y)
            restartBrowseTimer()
        case .cancelled, .failed:
            lyricsPane.endDrag(velocity: 0)
            restartBrowseTimer()
        default: break
        }
    }

    private func restartBrowseTimer() {
        browseTimer?.invalidate()
        guard lyricsPane.isBrowsing else { return }
        let timer = Timer(timeInterval: Metrics.lyricsReturn, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Apple holds the browsed line while the song is paused. A finger still down holds it too.
                if self.queue.playbackState == .playing, self.lyricsPane.endBrowsing(animated: true, timedOut: true) {
                    self.repeatTimer?.invalidate()
                } else {
                    self.restartBrowseTimer()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        browseTimer = timer
    }

    private func endLyricBrowsing(animated: Bool = true) {
        browseTimer?.invalidate()
        repeatTimer?.invalidate()
        lyricsPane.endBrowsing(animated: animated)
    }

    private func setControlsHidden(_ hidden: Bool) {
        guard hidden != controlsHidden else { return }
        if !hidden { endLyricBrowsing() }
        controlsHidden = hidden
        // Focus moves first: the engine only honours a target that can take it now.
        if hidden {
            anchor.isUserInteractionEnabled = true
            moveFocus(to: anchor)
        }
        scrubberProxy.isFocusEnabled = !hidden
        controls.isUserInteractionEnabled = !hidden
        strip.isUserInteractionEnabled = !hidden
        if !hidden {
            moveFocus(to: scrubberProxy)
            anchor.isUserInteractionEnabled = false
        }
        let fade = {
            self.controls.alpha = hidden ? 0 : 1
            self.scrim.alpha = hidden ? 0 : 1
        }
        let move = {
            self.layoutStage()
            self.lyricsPane.setControlsVisible(!hidden)
        }
        if UIAccessibility.isReduceMotionEnabled {
            fade()
            move()
        } else {
            // AVKit's controls fade. The artwork's move is Rivulet's own and keeps its pace.
            UIViewPropertyAnimator(duration: 0.167, controlPoint1: CGPoint(x: 0.33, y: 0),
                                   controlPoint2: CGPoint(x: 0.83, y: 0.83), animations: fade).startAnimation()
            UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState],
                           animations: move)
        }
        restartHideTimer()
    }

    private func moveFocus(to target: UIFocusEnvironment) {
        pendingFocus = target
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        // Left set, it would pull every later focus update back to it.
        pendingFocus = nil
    }

    // A press that moves nothing (Right on the last card) is still the user at work.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presentedViewController == nil { restartHideTimer() }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presentedViewController == nil { restartHideTimer() }
        super.pressesEnded(presses, with: event)
    }

    // The same for a touch remote, whose swipes are no presses.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if presentedViewController == nil { restartHideTimer() }
        super.touchesBegan(touches, with: event)
    }

    private func restartHideTimer() {
        hideTimer?.invalidate()
        guard !controlsHidden else { return }
        let interval = scrubberProxy.isFocused ? Metrics.autoHide : Metrics.autoHideInButtons
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoHide() }
        }
        // Common modes: the default mode stalls while a scroll or a menu tracks.
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    // Focus outside the view means a menu or the Info panel is open: the controls stay.
    // They stay through a scan and a loading track too, as AVKit's do.
    private func autoHide() {
        guard let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView,
              focused.isDescendant(of: view), queue.scanLevel == 0, queue.playbackState != .loading
        else { return restartHideTimer() }
        autoHiddenAt = CACurrentMediaTime()
        setControlsHidden(true)
    }

    // MARK: - Focus

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let pendingFocus { return [pendingFocus] }
        if controlsHidden { return [anchor] }
        if let lastFocused, lastFocused.window != nil { return [lastFocused, scrubberProxy] }
        return [scrubberProxy]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        // A menu or the Info panel took focus: everything stays as it is for the way back.
        guard let next = context.nextFocusedView, next.isDescendant(of: view) else { return }
        lastFocused = next
        if menuIsStale { refreshMenu(focusReturned: true) }
        // The bar fills while it holds focus and shows only its tick otherwise.
        progressBar.setFocusDimmed(next !== scrubberProxy, coordinator: coordinator)
        // A scan belongs to the timeline: leaving it plays on from where the scan reached.
        if next !== scrubberProxy { queue.endScan() }
        let inUpper = upperButtons.contains { $0 === next }
        let inStrip = next.isDescendant(of: strip)
        if inUpper { lastUpper = next }
        let upper = lastUpper ?? favoriteButton
        // Each guide is off while focus is in the row it leads to, or it would catch the way out.
        barGuide.isEnabled = !inUpper && !inStrip
        barGuide.preferredFocusEnvironments = [upper]
        bottomGuide.isEnabled = !(next === infoButton || next.isDescendant(of: modeSwitch))
        // Under the cards: Up from the buttons enters the strip, Down from a card returns to them.
        stripGuide.isEnabled = mode == .queue && (inUpper || inStrip)
        stripGuide.preferredFocusEnvironments = inStrip ? [upper] : [strip]
        restartHideTimer()
    }
}

// MARK: - Mode switch

/// Apple's joined lyrics | queue capsule, 172x72, with two focusable segments. A segment that is
/// on carries a 72x62 knob at 38% white; the focused one a white knob and a dark glyph.
@MainActor
final class MusicModeSwitchView: UIView {
    let lyrics = Segment(symbol: "quote.bubble", onSymbol: "quote.bubble.fill")
    let queue = Segment(symbol: "list.bullet", onSymbol: "list.bullet")

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 1, alpha: 0.10)
        layer.cornerRadius = 36
        // The knobs sit 4pt in from the capsule's ends, so their glyphs are at x 40 and 132.
        lyrics.frame = CGRect(x: 4, y: 5, width: 72, height: 62)
        queue.frame = CGRect(x: 96, y: 5, width: 72, height: 62)
        [lyrics, queue].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: 172, height: 72) }

    @MainActor
    final class Segment: UIView {
        var onSelect: (() -> Void)?
        var isOn = false { didSet { if isOn != oldValue { apply() } } }
        /// No lyrics for this track: still focusable, but dim and inert.
        var isDimmed = false { didSet { if isDimmed != oldValue { apply() } } }

        private let symbol: String
        private let onSymbol: String
        private let glyph = UIImageView()
        private let dot = UIView()
        private var showsFocus = false

        init(symbol: String, onSymbol: String) {
            self.symbol = symbol
            self.onSymbol = onSymbol
            super.init(frame: .zero)
            layer.cornerRadius = 31
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowRadius = 10
            layer.shadowOffset = CGSize(width: 0, height: 6)
            layer.shadowOpacity = 0
            glyph.contentMode = .center
            glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
            dot.backgroundColor = UIColor(white: 0.1, alpha: 1)
            dot.layer.cornerRadius = 3
            [glyph, dot].forEach(addSubview)
            apply()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            glyph.frame = bounds
            dot.frame = CGRect(x: bounds.midX - 3, y: bounds.midY + 18, width: 6, height: 6)
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 31).cgPath
        }

        override var canBecomeFocused: Bool { true }

        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            let focused = context.nextFocusedView === self
            coordinator.animateFocusChange(gained: focused) {
                self.showsFocus = focused
                self.apply()
            }
        }

        /// Off: glyph only. On: the grey knob and the filled glyph. Focused: the white knob, with
        /// the dot Apple gives a button that is on, since the white fill hides the grey one.
        private func apply() {
            backgroundColor = showsFocus ? .white : (isOn ? UIColor(white: 1, alpha: 0.38) : .clear)
            layer.shadowOpacity = showsFocus ? 0.25 : 0
            glyph.image = UIImage(systemName: isOn ? onSymbol : symbol)
            glyph.tintColor = (showsFocus ? UIColor(white: 0.1, alpha: 1) : .white).withAlphaComponent(isDimmed ? 0.3 : 1)
            dot.isHidden = !(isOn && showsFocus)
        }

        // Select does not fire a plain view's primary action on tvOS, so the press is read here.
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard presses.contains(where: { $0.type == .select }) else { return super.pressesBegan(presses, with: event) }
            onSelect?()
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard presses.contains(where: { $0.type == .select }) else { return super.pressesEnded(presses, with: event) }
        }
    }
}
