// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ShellSidebarViewController.swift
//  Rivulet
//
//  The custom shell sidebar, embedded in RootShellViewController. Sizes and
//  type come from the Apple TV app's own sidebar.
//

import UIKit

// MARK: - Metrics

private enum Metrics {
    /// Values are the Apple TV app's own sidebar where one was read; the panel
    /// frame, pill origin and morph timing are still the system sidebar's.
    static let panelWidth: CGFloat = 340
    static let panelInset: CGFloat = 35
    /// The Apple TV app's panel radius, not the system tab sidebar's 52.
    static let panelCornerRadius: CGFloat = 40
    /// The TV app's section insets: rows sit 10pt inside the glass.
    static let contentLeading: CGFloat = 10
    static let contentTrailing: CGFloat = 10
    /// 55 (list top inset, window) - 36 (panel inset).
    static let contentTop: CGFloat = 19
    static let contentBottom: CGFloat = 15
    static let rowPitch: CGFloat = 78
    /// The TV app's focus platter: 72pt tall, 3pt inside the 78pt row.
    static let capsuleHeight: CGFloat = 72
    /// The TV app's row columns: icon centred in a 72pt leading column, title
    /// 2pt after it, 16pt trailing margin.
    static let iconCenterX: CGFloat = 36
    static let titleLeading: CGFloat = 74
    static let titleTrailing: CGFloat = 16
    static var capsuleRadius: CGFloat { capsuleHeight / 2 }
    static var capsuleVerticalInset: CGFloat { (rowPitch - capsuleHeight) / 2 }
    static let sectionGap: CGFloat = 70
    /// A break with no header and no Settings below it: the arranged rows after Home.
    static let quietSectionGap: CGFloat = 30
    static let pillOrigin = CGPoint(x: 50, y: 50)
    static let pillHeight: CGFloat = 60
    /// The TV app's 50pt icon disc, centred in the 60pt pill.
    static let pillDiscSize: CGFloat = 50
    static var pillDiscInset: CGFloat { (pillHeight - pillDiscSize) / 2 }
    static let pillTrailing: CGFloat = 41
    /// The TV app's sidebar avatar, and how much it grows under focus.
    static let avatarSize: CGFloat = 50
    static let avatarFocusGrowth: CGFloat = 4
    /// The profile header band: the first tab sits this far below the list top.
    static let profileBandHeight: CGFloat = 90
    /// While music plays the profile slot is the avatar's column plus the Now
    /// Playing pill, which is as tall as the avatar and centred on it.
    static var avatarColumnWidth: CGFloat { iconCenterX * 2 }
    static var nowPlayingHeight: CGFloat { avatarSize }
    static let nowPlayingInset: CGFloat = 18
    static let nowPlayingBarsGap: CGFloat = 12
    static let nowPlayingBarsPeak: CGFloat = 20
    /// A long title scrolls at this speed, pauses at the start of each lap, and fades at the right edge.
    static let marqueeGap: CGFloat = 40
    static let marqueeSpeed: CGFloat = 30
    static let marqueePause: CFTimeInterval = 1.5
    static let marqueeFade: CGFloat = 24
    /// One spring crossfade, checked by eye against the system morph. A
    /// three-phase timing from 120fps frame analysis looked worse on screen.
    static let morphDuration: TimeInterval = 0.45
    static let morphDamping: CGFloat = 0.9
    /// The chevron trails the morph by this fraction of it and slides in 12pt.
    static let chevronDelayFactor: Double = 0.3
    static let chevronSlide: CGFloat = 12
    /// Profile avatar, pill glyph and pill label scales at the far end of a morph.
    static let collapsedAvatarScale: CGFloat = 1.25
    static let expandedPillIconScale: CGFloat = 0.75
    static let expandedPillLabelScale: CGFloat = 0.9
    /// Notch hide and reveal (collapsed pill, below the top row).
    static let notchHideDuration: TimeInterval = 0.18
    static let notchRevealDuration: TimeInterval = 0.5
    static let notchRevealDelay: TimeInterval = 0.4
    static let notchRevealScale: CGFloat = 0.65
    static let notchRevealRise: CGFloat = 6
    /// Profile header, measured on device (tvOS 27): avatar centre 26pt below
    /// the list top, clock right edge 12.5pt inside it, name 8.5pt further
    /// right while focused.
    static let headerCenterY: CGFloat = 26
    static let headerTrailing: CGFloat = 12.5
    static let focusedNameShift: CGFloat = 8.5
    /// Darkens the glass toward the system sidebar's tone; the sole knob for
    /// the material tuning pass, to be converged against sampled pixels.
    static let glassTint = UIColor.black.withAlphaComponent(0.12)
}

/// How far down a page's own content has to start to clear the collapsed pill.
///
/// The pill draws over the top-left of whatever tab is mounted, and it only
/// hides once focus moves below the top row — so anything a page puts at its
/// own top edge renders under it. Home with the hero off put the first row's
/// title there (#298) and Search put the text field there (#292).
enum ShellPillMetrics {
    /// Pill bottom (50 + 60) plus a small gap.
    static let contentClearance: CGFloat = Metrics.pillOrigin.y + Metrics.pillHeight + 14
}

/// System row coloring: focused = solid white capsule, dark content; selected
/// but unfocused = translucent capsule, full-white content; otherwise bare, dim.
/// Resting 0.7 is the TV app's value; its focused 0.9 / 0.7 pair rides a
/// PlusL / PlusD layer this sidebar does not have.
private func sidebarRowColors(focused: Bool, selected: Bool) -> (background: UIColor, content: UIColor) {
    if focused { return (UIColor.white.withAlphaComponent(0.91), .black) }
    if selected { return (UIColor.white.withAlphaComponent(0.1), .white) }
    return (.clear, UIColor.white.withAlphaComponent(0.7))
}

/// The text style's font at the emphasized (bold) weight, as the TV app asks
/// for it: from the style, never a hard-coded size.
private func emphasizedFont(_ style: UIFont.TextStyle) -> UIFont {
    let base = UIFont.preferredFont(forTextStyle: style)
    return base.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? base
}

/// A round profile picture drawn over a glyph, which shows until it loads.
private final class SidebarAvatarView: UIView {
    private let imageView = UIImageView()

    func setImageScale(_ scale: CGFloat) {
        imageView.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    var url: URL? {
        didSet {
            guard url != oldValue else { return }
            imageView.image = url.flatMap { ImageCacheManager.shared.cachedImage(for: $0) }
            guard let url, imageView.image == nil else { return }
            Task { [weak self] in
                let loaded = await ImageCacheManager.shared.image(for: url)
                if self?.url == url { self?.imageView.image = loaded }
            }
        }
    }

    init(diameter: CGFloat) {
        super.init(frame: .zero)
        imageView.contentMode = .scaleAspectFill
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        isUserInteractionEnabled = false
        clipsToBounds = true
        layer.cornerRadius = diameter / 2
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: diameter),
                                     heightAnchor.constraint(equalToConstant: diameter),
                                     imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
                                     imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     imageView.topAnchor.constraint(equalTo: topAnchor),
                                     imageView.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Collection view

/// Directs its opening focus at a specific row. `remembersLastFocusedIndexPath`
/// only restores the last-touched cell; the sidebar needs the SELECTED tab
/// focused on every open, so it sets `preferredFocusIndexPath` first.
final class SidebarCollectionView: UICollectionView {
    var preferredFocusIndexPath: IndexPath?

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // The cell must exist right now, or the engine ignores this and falls
        // back to its own pick (realized in aimInitialFocus).
        if let indexPath = preferredFocusIndexPath, let cell = cellForItem(at: indexPath) {
            return [cell]
        }
        return super.preferredFocusEnvironments
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        // The aim is for the OPENING move only, and nothing was clearing it.
        // Left set, EVERY later focus update while the sidebar was open
        // resolved back through it to the selected row — so the expand
        // animator's completion, which requests focus ~0.3s after opening,
        // yanked the user back from whatever row they had already moved to.
        // The next open re-aims via `aimInitialFocus`.
        if let next = context.nextFocusedItem as? UIView, next.isDescendant(of: self) {
            preferredFocusIndexPath = nil
        }
    }
}

// MARK: - Row cell

final class ShellSidebarRowCell: UICollectionViewCell {
    static let reuseIdentifier = "ShellSidebarRowCell"

    private let backgroundPill = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    /// The library's server, a small line above the title while libraries
    /// from several servers are mixed. Hidden otherwise, so the title centres.
    private let serverLabel = UILabel()
    private let textStack = UIStackView()
    private var isSelectedTab = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundPill.layer.cornerRadius = Metrics.capsuleRadius
        backgroundPill.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(backgroundPill)

        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.font = .preferredFont(forTextStyle: .caption1)
        serverLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        serverLabel.isHidden = true
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.addArrangedSubview(serverLabel)
        textStack.addArrangedSubview(titleLabel)
        for view in [iconView, textStack] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }

        NSLayoutConstraint.activate([
            backgroundPill.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backgroundPill.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            backgroundPill.topAnchor.constraint(equalTo: contentView.topAnchor,
                                                constant: Metrics.capsuleVerticalInset),
            backgroundPill.bottomAnchor.constraint(equalTo: contentView.bottomAnchor,
                                                   constant: -Metrics.capsuleVerticalInset),
            iconView.centerXAnchor.constraint(equalTo: contentView.leadingAnchor,
                                              constant: Metrics.iconCenterX),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            textStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor,
                                               constant: Metrics.titleLeading),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor,
                                                constant: -Metrics.titleTrailing),
            textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        applyAppearance(focused: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(item: ShellSidebarItem, isSelectedTab: Bool) {
        self.isSelectedTab = isSelectedTab
        iconView.image = UIImage(systemName: item.icon)
        titleLabel.text = item.title
        serverLabel.text = item.badge
        serverLabel.isHidden = item.badge == nil
        applyAppearance(focused: isFocused)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        if focused {
            coordinator.addCoordinatedAnimations({ self.applyAppearance(focused: true) })
        } else {
            // Clear instantly: running the unfocus through the coordinator
            // leaves the old row's white capsule ghosting behind the move.
            applyAppearance(focused: false)
        }
    }

    private func applyAppearance(focused: Bool) {
        let colors = sidebarRowColors(focused: focused, selected: isSelectedTab)
        backgroundPill.backgroundColor = colors.background
        iconView.tintColor = colors.content
        titleLabel.textColor = colors.content
        serverLabel.textColor = colors.content.withAlphaComponent(0.6)
    }
}

// MARK: - Now Playing pill

/// One line that scrolls left in a loop while `isScrolling` and wider than its
/// bounds, pausing at the start of each lap; otherwise it truncates. The offset
/// is a function of the clock, so the system stripping layer animations
/// (inactive app, a cell leaving the window) costs nothing.
private final class SidebarMarqueeLabel: UIView {
    private let track = UIView()
    private let label = UILabel()
    private let copy = UILabel()
    private let fadeMask = CAGradientLayer()
    private var scrollStart: CFTimeInterval = 0
    private var link: CADisplayLink?

    var text: String? {
        didSet { label.text = text; copy.text = text; setNeedsLayout() }
    }
    var font: UIFont? {
        didSet { label.font = font; copy.font = font; setNeedsLayout() }
    }
    var textColor: UIColor? {
        didSet { label.textColor = textColor; copy.textColor = textColor }
    }
    var isScrolling = false {
        didSet { if isScrolling != oldValue { setNeedsLayout() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        fadeMask.colors = [UIColor.black, .black, .clear].map(\.cgColor)
        track.addSubview(label)
        track.addSubview(copy)
        addSubview(track)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let textWidth = ceil(label.intrinsicContentSize.width)
        let scrolls = isScrolling && bounds.width > 0 && textWidth > bounds.width
        copy.isHidden = !scrolls
        track.transform = .identity
        if scrolls {
            label.frame = CGRect(x: 0, y: 0, width: textWidth, height: bounds.height)
            copy.frame = label.frame.offsetBy(dx: textWidth + Metrics.marqueeGap, dy: 0)
            track.frame = CGRect(x: 0, y: 0, width: textWidth * 2 + Metrics.marqueeGap, height: bounds.height)
            fadeMask.frame = bounds
            fadeMask.locations = [0, NSNumber(value: 1 - Double(Metrics.marqueeFade / bounds.width)), 1]
            layer.mask = fadeMask
        } else {
            track.frame = bounds
            label.frame = bounds
            layer.mask = nil
        }
        updateLink(running: scrolls && window != nil)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    private func updateLink(running: Bool) {
        if running, link == nil {
            scrollStart = CACurrentMediaTime()
            let link = CADisplayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            self.link = link
        } else if !running {
            link?.invalidate()
            link = nil
        }
    }

    /// A lap is a pause at the start, then one text width and gap to the left.
    @objc private func step() {
        let distance = label.frame.width + Metrics.marqueeGap
        let lap = Metrics.marqueePause + CFTimeInterval(distance / Metrics.marqueeSpeed)
        let into = (CACurrentMediaTime() - scrollStart).truncatingRemainder(dividingBy: lap)
        let offset = into < Metrics.marqueePause ? 0 : CGFloat(into - Metrics.marqueePause) * Metrics.marqueeSpeed
        track.transform = CGAffineTransform(translationX: -offset, y: 0)
    }
}

/// The Now Playing pill beside the avatar: playing bars and "title · artist".
final class ShellSidebarNowPlayingCell: UICollectionViewCell {
    static let reuseIdentifier = "ShellSidebarNowPlayingCell"

    private let capsule = UIView()
    private let bars = MusicPlaybackBarsView(peak: Metrics.nowPlayingBarsPeak)
    private let marquee = SidebarMarqueeLabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        capsule.layer.cornerRadius = Metrics.nowPlayingHeight / 2
        marquee.font = .preferredFont(forTextStyle: .caption1)
        for view in [capsule, bars, marquee] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            capsule.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            capsule.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            capsule.centerYAnchor.constraint(equalTo: contentView.topAnchor, constant: Metrics.headerCenterY),
            capsule.heightAnchor.constraint(equalToConstant: Metrics.nowPlayingHeight),
            bars.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: Metrics.nowPlayingInset),
            bars.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            marquee.leadingAnchor.constraint(equalTo: bars.trailingAnchor, constant: Metrics.nowPlayingBarsGap),
            marquee.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -Metrics.nowPlayingInset),
            marquee.topAnchor.constraint(equalTo: capsule.topAnchor),
            marquee.bottomAnchor.constraint(equalTo: capsule.bottomAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        applyAppearance(focused: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(item: ShellSidebarItem) {
        guard let track = item.nowPlaying else { return }
        marquee.text = track.line
        bars.isPlaying = track.isPlaying
        if let artist = track.artist, !artist.isEmpty {
            accessibilityLabel = String(localized: "Now Playing, \(track.title), \(artist)")
        } else {
            accessibilityLabel = String(localized: "Now Playing, \(track.title)")
        }
        applyAppearance(focused: isFocused)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        if focused {
            coordinator.addCoordinatedAnimations({ self.applyAppearance(focused: true) })
        } else {
            applyAppearance(focused: false)
        }
    }

    // Unfocused it wears the selected row's translucent capsule, so it reads as a pill.
    private func applyAppearance(focused: Bool) {
        let colors = sidebarRowColors(focused: focused, selected: true)
        capsule.backgroundColor = colors.background
        marquee.textColor = colors.content
        bars.barColor = colors.content
        marquee.isScrolling = focused
    }
}

// MARK: - Profile header cell

/// The profile entry, above the tabs: avatar, first name and the time, no focus
/// platter. Focus grows the avatar, brightens the name and, where there is a
/// profile to switch to, swaps the clock for a "Switch Profile" caption.
final class ShellSidebarProfileCell: UICollectionViewCell {
    static let reuseIdentifier = "ShellSidebarProfileCell"

    private let iconView = UIImageView()
    private let avatarView = SidebarAvatarView(diameter: Metrics.avatarSize)
    private let nameLabel = UILabel()
    private let captionLabel = UILabel()
    private let clockLabel = UILabel()
    private var nameCenterY: NSLayoutConstraint!
    private var nameLeading: NSLayoutConstraint!
    /// The name stops at the clock at rest, and runs to the edge while focused,
    /// where the clock is hidden (#385).
    private var nameBeforeClock: NSLayoutConstraint!
    private var nameToEdge: NSLayoutConstraint!
    private var canSwitch = false
    /// Just the avatar: the slot is shared with the Now Playing pill.
    private var compact = false
    private var clockTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        nameLabel.font = .preferredFont(forTextStyle: .caption1)
        captionLabel.font = .systemFont(ofSize: 21, weight: .regular)
        captionLabel.text = String(localized: "Switch Profile")
        captionLabel.textColor = UIColor.white.withAlphaComponent(0.3)
        clockLabel.font = .preferredFont(forTextStyle: .caption2)
        clockLabel.textColor = UIColor.white.withAlphaComponent(0.3)
        clockLabel.isAccessibilityElement = false
        for view in [iconView, avatarView, nameLabel, captionLabel, clockLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        nameCenterY = nameLabel.centerYAnchor.constraint(equalTo: contentView.topAnchor,
                                                         constant: Metrics.headerCenterY)
        nameLeading = nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor,
                                                         constant: Metrics.titleLeading)
        nameBeforeClock = nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: clockLabel.leadingAnchor, constant: -8)
        nameToEdge = nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor,
                                                         constant: -Metrics.headerTrailing)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: contentView.leadingAnchor,
                                              constant: Metrics.iconCenterX),
            iconView.centerYAnchor.constraint(equalTo: contentView.topAnchor, constant: Metrics.headerCenterY),
            avatarView.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            avatarView.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            nameLeading,
            nameBeforeClock,
            nameCenterY,
            captionLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor,
                                                   constant: -Metrics.titleTrailing),
            captionLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor),
            clockLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor,
                                                 constant: -Metrics.headerTrailing),
            clockLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
        ])
        clockLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        isAccessibilityElement = true
        applyAppearance(focused: false)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshClock),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { clockTimer?.invalidate() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { clockTimer?.invalidate(); clockTimer = nil } else { refreshClock() }
    }

    /// Redraws the time in the user's 12/24-hour style and re-arms the timer for
    /// the next minute boundary, so there is no per-second tick.
    @objc private func refreshClock() {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        clockLabel.text = formatter.string(from: Date())
        clockTimer?.invalidate()
        guard window != nil else { return }
        let next = Calendar.current.nextDate(after: Date(), matching: DateComponents(second: 0),
                                             matchingPolicy: .nextTime) ?? Date().addingTimeInterval(60)
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshClock() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    func setAvatarImageScale(_ scale: CGFloat) {
        avatarView.setImageScale(scale)
    }

    func configure(item: ShellSidebarItem, compact: Bool = false) {
        self.compact = compact
        iconView.image = UIImage(systemName: item.icon)
        avatarView.url = item.avatarURL
        nameLabel.text = item.title
        canSwitch = item.canSwitchProfile
        accessibilityLabel = canSwitch ? String(localized: "\(item.title), Switch Profile") : item.title
        accessibilityTraits = canSwitch ? .button : .staticText
        applyAppearance(focused: isFocused)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({
            self.applyAppearance(focused: focused)
            self.contentView.layoutIfNeeded()
        })
    }

    private func applyAppearance(focused: Bool) {
        iconView.tintColor = .white
        nameLabel.textColor = focused ? .white : UIColor.white.withAlphaComponent(0.5)
        let captioned = focused && canSwitch && !compact
        captionLabel.alpha = captioned ? 1 : 0
        nameLabel.isHidden = compact
        clockLabel.alpha = focused || compact ? 0 : 1
        nameBeforeClock.isActive = !focused && !compact
        nameToEdge.isActive = focused || compact
        // The name rises by half the caption so the pair stays centred on the avatar.
        nameCenterY.constant = Metrics.headerCenterY - (captioned ? captionLabel.font.lineHeight / 2 : 0)
        nameLeading.constant = compact ? Metrics.iconCenterX
            : Metrics.titleLeading + (focused ? Metrics.focusedNameShift : 0)
        let scale = focused ? (Metrics.avatarSize + Metrics.avatarFocusGrowth) / Metrics.avatarSize : 1
        avatarView.transform = CGAffineTransform(scaleX: scale, y: scale)
        iconView.transform = avatarView.transform
    }
}

// MARK: - Section header

final class ShellSidebarHeaderView: UICollectionReusableView {
    static let reuseIdentifier = "ShellSidebarHeaderView"
    static let elementKind = "ShellSidebarHeader"
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = emphasizedFont(.caption2)
        label.textColor = .tertiaryLabel.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 28),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Controller

final class ShellSidebarViewController: UIViewController {

    private enum State { case expanded, collapsed }

    private var state: State = .expanded
    private var sections: [ShellSidebarSection] = []
    private var selectedTab: SidebarTab = .home

    /// ONE glass card morphs between panel and pill, as the trace showed the
    /// system does: frame and corner radius animate together on one spring;
    /// the list fades out and clips inside the shrinking card while the pill
    /// content fades in.
    private let cardView = UIView()
    private let glassView: UIVisualEffectView = {
        let effect = UIGlassEffect(style: .regular)
        effect.tintColor = Metrics.glassTint
        return UIVisualEffectView(effect: effect)
    }()
    /// `chevron.compact.left` at callout size, as the TV app's pill draws it.
    private let pillChevron = UIImageView(image: UIImage(
        systemName: "chevron.compact.left",
        withConfiguration: UIImage.SymbolConfiguration(textStyle: .callout)))
    private let pillIcon = UIImageView()
    private let pillIconDisc = UIView()
    private let pillAvatar = SidebarAvatarView(diameter: Metrics.pillDiscSize)
    private let pillLabel = UILabel()
    private let pillStack = UIStackView()
    private var collectionView: SidebarCollectionView!
    private var transitionAnimator: UIViewPropertyAnimator?

    // MARK: Shell integration
    // When embedded, RootShellViewController owns expansion, focus handoff,
    // and tab authority; the sidebar reports intent through these callbacks.
    // The preview modal path keeps `embedded` false and self-drives.
    var embedded = false
    var onTabSelected: ((SidebarTab) -> Void)?
    var onCollapseRequested: (() -> Void)?
    private var pillHidden = false
    /// The remote gesture that last moved focus between rows (see `stopsUpwardRun`).
    private var lastFocusMoveGesture = -1
    /// While the profile panel is up the pill names the user, not the tab.
    private var pillShowsProfile = false
    /// Move from a row's long-press menu: the held row's key, and the order to put back on Menu.
    private var rowMove: GrabReorderController?
    private var heldKey: String?
    private var orderBeforeMove: [String] = []
    /// The row focus follows to once the next sections arrive (a step or a cancel).
    private var pendingFocusKey: String?
    /// Horizontal swipes close the open sidebar, the touch twin of the arrow presses below.
    private var closeSwipe: DirectionalInputBinding?

    var isExpanded: Bool { state == .expanded }
    var focusTarget: UIView { collectionView }

    func setPillShowsProfile(_ shows: Bool) {
        pillShowsProfile = shows
        configurePill()
    }

    /// `aimAt` opens on that row instead of the selected tab's.
    func setExpanded(_ expanded: Bool, animated: Bool, aimAt tab: SidebarTab? = nil) {
        if expanded { aimInitialFocus(at: tab ?? selectedTab) }
        setState(expanded ? .expanded : .collapsed)
        if !animated {
            transitionAnimator?.stopAnimation(false)
            transitionAnimator?.finishAnimation(at: .end)
        }
    }

    /// Directs the sidebar's opening focus at the currently selected tab's
    /// row (Home opens on Home, Settings on Settings). The cell must be
    /// realized before the focus engine reads `preferredFocusEnvironments`,
    /// so unhide + lay out + scroll it into view first.
    private func aimInitialFocus(at tab: SidebarTab) {
        guard let indexPath = indexPath(for: tab) else {
            collectionView.preferredFocusIndexPath = nil
            return
        }
        collectionView.isHidden = false
        collectionView.preferredFocusIndexPath = indexPath
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        collectionView.layoutIfNeeded()
    }

    private func indexPath(for tab: SidebarTab) -> IndexPath? {
        for (s, section) in sections.enumerated() {
            if let i = section.items.firstIndex(where: { $0.tab == tab }) {
                return IndexPath(item: i, section: s)
            }
        }
        return nil
    }

    /// Selection pushed down from the shell (SwiftUI is the tab authority).
    func setSelectedTabExternal(_ tab: SidebarTab) {
        guard tab != selectedTab else { return }
        selectedTab = tab
        configurePill()
        collectionView.reloadData()
    }

    /// Live section updates pushed from SwiftUI, which observes every store
    /// that feeds the sidebar. Diffed, so idle updates cost nothing; no
    /// snapshot dance, the whole point of owning the shell.
    func setSections(_ new: [ShellSidebarSection]) {
        guard new != sections else { return }
        let old = sections
        sections = new
        guard isViewLoaded else { return }
        // A track change or a pause only redraws the pill; reloading would disturb its focus.
        if Self.hasPill(old), Self.hasPill(new), Self.withoutPill(old) == Self.withoutPill(new) {
            let pill = collectionView.cellForItem(at: IndexPath(item: 1, section: 0)) as? ShellSidebarNowPlayingCell
            pill?.configure(item: new[0].items[1])
            return
        }
        let pillFocused = Self.hasPill(old) && TileLongPress.focusedCell(in: collectionView).flatMap { old[$0.section].items[safe: $0.item] }?.tab == .nowPlaying
        collectionView.reloadData()
        configurePill()
        if pillFocused, !Self.hasPill(new) { focusProfileSlotFallback() }
        if let key = pendingFocusKey ?? heldKey { focusRow(key) }
    }

    private static func hasPill(_ sections: [ShellSidebarSection]) -> Bool {
        sections.first?.items.contains { $0.tab == .nowPlaying } == true
    }

    private static func withoutPill(_ sections: [ShellSidebarSection]) -> [ShellSidebarSection] {
        sections.map { ShellSidebarSection(title: $0.title, items: $0.items.filter { $0.tab != .nowPlaying }) }
    }

    /// The pill left while focused: focus goes to the avatar, or the first row if it takes none.
    private func focusProfileSlotFallback() {
        let avatar = IndexPath(item: 0, section: 0)
        let target = item(at: avatar)?.canSwitchProfile == true ? avatar : IndexPath(item: 0, section: 1)
        if item(at: target) != nil { focus(at: target) }
    }

    /// Left and Right between the avatar and the pill are focus moves, not a request to close.
    private func movesWithinProfileSlot(_ direction: DirectionalInputBinding.Direction) -> Bool {
        guard Self.hasPill(sections), let focused = TileLongPress.focusedCell(in: collectionView), focused.section == 0
        else { return false }
        switch direction {
        case .right: return focused.item == 0
        case .left: return focused.item == 1 && item(at: IndexPath(item: 0, section: 0))?.canSwitchProfile == true
        default: return false
        }
    }

    /// Collapsed-state pill visibility, driven by the below-top focus signal.
    func setPillHidden(_ hidden: Bool) {
        guard hidden != pillHidden else { return }
        pillHidden = hidden
        guard state == .collapsed, transitionAnimator == nil else { return }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let duration = hidden || reduceMotion ? Metrics.notchHideDuration : Metrics.notchRevealDuration
        let startTime = CACurrentMediaTime()
        pillStack.alpha = 1
        for part in [cardView, pillChevron] {
            let layer = part.layer
            let visibleOpacity = layer.presentation()?.opacity ?? layer.opacity
            var start = layer.presentation()?.transform ?? CATransform3DIdentity
            let revealing = !hidden && visibleOpacity < 0.01
            if revealing, !reduceMotion {
                let scale = Metrics.notchRevealScale
                start = CATransform3DMakeScale(scale, scale, 1)
                // Scale the capsule and chevron around the same centre while rising into place.
                start.m41 = (cardView.center.x - part.center.x) * (1 - scale)
                start.m42 = (cardView.center.y - part.center.y) * (1 - scale) + Metrics.notchRevealRise
            }
            let motion = CABasicAnimation(keyPath: "transform")
            motion.fromValue = start
            motion.toValue = CATransform3DIdentity
            motion.duration = duration
            motion.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = visibleOpacity
            fade.toValue = hidden ? 0 : 1
            fade.duration = Metrics.notchHideDuration
            fade.fillMode = .forwards
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

            let visibility = CAAnimationGroup()
            visibility.animations = reduceMotion ? [fade] : [motion, fade]
            visibility.duration = duration
            visibility.beginTime = layer.convertTime(startTime, from: nil) + (revealing && !reduceMotion ? Metrics.notchRevealDelay : 0)
            visibility.fillMode = .backwards
            part.alpha = hidden ? 0 : 1
            layer.add(visibility, forKey: "pillVisibility")
        }
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        sections = Self.liveSections()
        buildViews()
        configurePill()
        applyState(expanded: true, animated: false)
        closeSwipe = DirectionalInputBinding(
            gatedSwipesOn: view, directions: [.left, .right],
            shouldHandle: { [weak self] direction in
                guard let self else { return false }
                return state == .expanded && rowMove?.isMoving != true && !movesWithinProfileSlot(direction)
            },
            onSwipe: { [weak self] _ in self?.requestCollapse() })
    }

    private func requestCollapse() {
        if embedded { onCollapseRequested?() } else { setState(.collapsed) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard transitionAnimator == nil else { return }
        cardView.frame = state == .expanded ? panelFrame : pillFrame
        layoutListInCard()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        state == .expanded ? [collectionView] : []
    }

    // MARK: Input

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // A row on the move keeps the sidebar open.
        if rowMove?.handleKeyPresses(presses) == true { return }
        guard rowMove?.isMoving != true else { return }
        for press in presses {
            switch (press.type, state) {
            case (.leftArrow, .expanded), (.rightArrow, .expanded):
                if movesWithinProfileSlot(press.type == .leftArrow ? .left : .right) { continue }
                requestCollapse()
                return
            case (.leftArrow, .collapsed) where !embedded:
                setState(.expanded)
                return
            default:
                break
            }
        }
        super.pressesBegan(presses, with: event)
    }

    // MARK: Morph

    private var panelFrame: CGRect {
        CGRect(x: Metrics.panelInset, y: Metrics.panelInset,
               width: Metrics.panelWidth,
               height: view.bounds.height - 2 * Metrics.panelInset)
    }

    private var pillFrame: CGRect {
        let content = pillStack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return CGRect(x: Metrics.pillOrigin.x, y: Metrics.pillOrigin.y,
                      width: content.width + Metrics.pillDiscInset + Metrics.pillTrailing,
                      height: Metrics.pillHeight)
    }

    private func setState(_ newState: State) {
        guard newState != state, transitionAnimator == nil else { return }
        state = newState
        applyState(expanded: newState == .expanded, animated: true)
    }

    private var profileToPillOffset: CGPoint {
        CGPoint(x: Metrics.contentLeading + Metrics.iconCenterX - Metrics.pillDiscInset - Metrics.pillDiscSize / 2,
                y: Metrics.contentTop + Metrics.headerCenterY - Metrics.pillHeight / 2)
    }

    private func applyState(expanded: Bool, animated: Bool) {
        cardView.layer.removeAnimation(forKey: "pillVisibility")
        pillChevron.layer.removeAnimation(forKey: "pillVisibility")
        let targetFrame = expanded ? panelFrame : pillFrame
        let targetRadius = expanded ? Metrics.panelCornerRadius : Metrics.pillHeight / 2
        let pillTransform = expanded
            ? CGAffineTransform(translationX: profileToPillOffset.x, y: profileToPillOffset.y)
            : .identity
        collectionView.isHidden = false
        collectionView.layoutIfNeeded()
        let profileCell = collectionView.visibleCells.compactMap { $0 as? ShellSidebarProfileCell }.first
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let chevronTransform = expanded && !reduceMotion
            ? CGAffineTransform(translationX: Metrics.chevronSlide, y: 0)
            : .identity
        let applyArtworkState: (Bool) -> Void = { expanded in
            profileCell?.setAvatarImageScale(expanded || reduceMotion ? 1 : Metrics.collapsedAvatarScale)
            let iconScale: CGFloat = expanded && !reduceMotion ? Metrics.expandedPillIconScale : 1
            self.pillIcon.transform = CGAffineTransform(scaleX: iconScale, y: iconScale)
            let labelScale: CGFloat = expanded && !reduceMotion ? Metrics.expandedPillLabelScale : 1
            self.pillLabel.transform = CGAffineTransform(scaleX: labelScale, y: labelScale)
        }
        cardView.alpha = 1
        let pillContentAlpha: CGFloat = !expanded && !pillHidden ? 1 : 0
        guard animated else {
            applyArtworkState(expanded)
            cardView.frame = targetFrame
            cardView.layer.cornerRadius = targetRadius
            layoutListInCard()
            pillStack.transform = pillTransform
            collectionView.alpha = expanded ? 1 : 0
            pillStack.alpha = pillContentAlpha
            pillChevron.alpha = pillContentAlpha
            pillChevron.transform = chevronTransform
            collectionView.isHidden = !expanded
            if !expanded, pillHidden { cardView.alpha = 0 }
            view.setNeedsLayout()
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
            return
        }
        applyArtworkState(!expanded)
        let animator = UIViewPropertyAnimator(duration: Metrics.morphDuration,
                                              dampingRatio: Metrics.morphDamping) {
            self.cardView.frame = targetFrame
            self.cardView.layer.cornerRadius = targetRadius
            self.layoutListInCard()
            self.pillStack.transform = pillTransform
            self.cardView.alpha = expanded || !self.pillHidden ? 1 : 0
            self.collectionView.alpha = expanded ? 1 : 0
            self.pillStack.alpha = pillContentAlpha
            applyArtworkState(expanded)
        }
        animator.addAnimations({
            self.pillChevron.alpha = pillContentAlpha
            self.pillChevron.transform = chevronTransform
        }, delayFactor: expanded || reduceMotion ? 0 : Metrics.chevronDelayFactor)
        animator.addCompletion { _ in
            self.transitionAnimator = nil
            // The pill's title can change mid-morph (Menu to Home): fit it now.
            self.view.setNeedsLayout()
            if self.state == .collapsed {
                // A hidden list is invisible to the focus engine; alpha 0 is not.
                self.collectionView.isHidden = true
                // pillHidden can flip mid-morph: a below-top focus change posts
                // while this animator is in flight, and setPillHidden bails on a
                // live transition. Reconcile the card, contents and chevron
                // together so they reflect the latest visibility request.
                let pillAlpha: CGFloat = self.pillHidden ? 0 : 1
                self.cardView.alpha = pillAlpha
                self.pillStack.alpha = pillAlpha
                self.pillChevron.alpha = pillAlpha
            }
            self.setNeedsFocusUpdate()
            self.updateFocusIfNeeded()
        }
        transitionAnimator = animator
        animator.startAnimation()
    }

    // MARK: Views

    private func buildViews() {
        cardView.layer.cornerCurve = .continuous
        cardView.layer.masksToBounds = true
        view.addSubview(cardView)

        glassView.frame = cardView.bounds
        glassView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cardView.addSubview(glassView)

        collectionView = SidebarCollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.backgroundColor = .clear
        // The card is the frame of reference; without this the scroll view
        // adds the window safe-area top (6pt at this geometry) to the list.
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.dataSource = self
        collectionView.delegate = self
        // Off: initial focus is directed at the selected tab, not the last
        // one the user happened to touch (see aimInitialFocus).
        collectionView.remembersLastFocusedIndexPath = false
        collectionView.register(ShellSidebarRowCell.self,
                                forCellWithReuseIdentifier: ShellSidebarRowCell.reuseIdentifier)
        collectionView.register(ShellSidebarProfileCell.self,
                                forCellWithReuseIdentifier: ShellSidebarProfileCell.reuseIdentifier)
        collectionView.register(ShellSidebarNowPlayingCell.self,
                                forCellWithReuseIdentifier: ShellSidebarNowPlayingCell.reuseIdentifier)
        collectionView.register(ShellSidebarHeaderView.self,
                                forSupplementaryViewOfKind: ShellSidebarHeaderView.elementKind,
                                withReuseIdentifier: ShellSidebarHeaderView.reuseIdentifier)
        cardView.addSubview(collectionView)
        installRowMenu()

        // Back-chevron, as the system pill shows: OUTSIDE the capsule, to its
        // left, white. Lives on the main view (not the glass card) so it sits
        // outside the glass, and fades with the pill.
        pillChevron.tintColor = .white
        pillChevron.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(pillChevron, belowSubview: cardView)

        pillIcon.tintColor = .white
        pillIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
        pillIcon.translatesAutoresizingMaskIntoConstraints = false
        // Disc tone is a photo estimate; the TV app's colour was not read.
        pillIconDisc.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        pillIconDisc.layer.cornerRadius = Metrics.pillDiscSize / 2
        pillIconDisc.addSubview(pillIcon)
        pillIconDisc.addSubview(pillAvatar)
        pillLabel.font = emphasizedFont(.body)
        pillLabel.textColor = .white
        pillStack.addArrangedSubview(pillIconDisc)
        pillStack.addArrangedSubview(pillLabel)
        pillStack.axis = .horizontal
        pillStack.spacing = 12
        pillStack.alignment = .center
        pillStack.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(pillStack)

        NSLayoutConstraint.activate([
            pillIconDisc.widthAnchor.constraint(equalToConstant: Metrics.pillDiscSize),
            pillIconDisc.heightAnchor.constraint(equalToConstant: Metrics.pillDiscSize),
            pillIcon.centerXAnchor.constraint(equalTo: pillIconDisc.centerXAnchor),
            pillIcon.centerYAnchor.constraint(equalTo: pillIconDisc.centerYAnchor),
            pillAvatar.centerXAnchor.constraint(equalTo: pillIconDisc.centerXAnchor),
            pillAvatar.centerYAnchor.constraint(equalTo: pillIconDisc.centerYAnchor),
            pillStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor,
                                               constant: Metrics.pillDiscInset),
            pillStack.centerYAnchor.constraint(equalTo: cardView.topAnchor,
                                               constant: Metrics.pillHeight / 2),
            // Chevron sits just left of the collapsed pill, vertically centered
            // on it. The pill's left edge is at pillOrigin.x.
            pillChevron.trailingAnchor.constraint(equalTo: view.leadingAnchor,
                                                  constant: Metrics.pillOrigin.x - 4),
            pillChevron.centerYAnchor.constraint(equalTo: view.topAnchor,
                                                 constant: Metrics.pillOrigin.y + Metrics.pillHeight / 2),
        ])
    }

    /// The list keeps its full panel-state size and lets the shrinking card
    /// CLIP it (with a fade), matching the portal look of the system morph;
    /// resizing the list itself would squish rows mid-animation.
    private func layoutListInCard() {
        // Keep the fading profile centred on the pill icon throughout the card morph.
        let offset = state == .expanded ? CGPoint.zero : profileToPillOffset
        collectionView.frame = CGRect(
            x: Metrics.contentLeading - offset.x,
            y: Metrics.contentTop - offset.y,
            width: Metrics.panelWidth - Metrics.contentLeading - Metrics.contentTrailing,
            height: panelFrame.height - Metrics.contentTop - Metrics.contentBottom)
    }

    private func configurePill() {
        let item = item(for: pillShowsProfile ? .account : selectedTab)
        pillIcon.image = UIImage(systemName: item.icon)
        pillAvatar.url = item.avatarURL
        pillLabel.text = item.title
        // The pill is as wide as its title: resize it when it is at rest.
        view.setNeedsLayout()
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, _ in
            // The profile header is section 0 and brings its own gap beneath.
            let isProfile = self?.sections[sectionIndex].items.first?.tab == .account
            let followsProfile = sectionIndex == 1 && self?.sections[0].items.first?.tab == .account
            let itemSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .absolute(isProfile ? Metrics.profileBandHeight : Metrics.rowPitch))
            let group: NSCollectionLayoutGroup
            if isProfile {
                // Alone the avatar row fills the width; with music, the avatar's column and the pill.
                let count = self?.sections[sectionIndex].items.count ?? 1
                group = .custom(layoutSize: itemSize) { environment in
                    let width = environment.container.effectiveContentSize.width
                    let band = Metrics.profileBandHeight
                    guard count > 1 else { return [NSCollectionLayoutGroupCustomItem(frame: CGRect(x: 0, y: 0, width: width, height: band))] }
                    let column = Metrics.avatarColumnWidth
                    return [
                        NSCollectionLayoutGroupCustomItem(frame: CGRect(x: 0, y: 0, width: column, height: band)),
                        NSCollectionLayoutGroupCustomItem(frame: CGRect(
                            x: column, y: 0, width: width - column - Metrics.headerTrailing, height: band)),
                    ]
                }
            } else {
                group = .vertical(layoutSize: itemSize, subitems: [NSCollectionLayoutItem(layoutSize: itemSize)])
            }
            let section = NSCollectionLayoutSection(group: group)
            // Window safe-area insets (80 leading / 60 top) must not shift
            // rows: the card's own geometry is the only frame of reference.
            section.contentInsetsReference = .none
            section.interGroupSpacing = 0
            // Measured: every section break is one 70pt gap; a titled section
            // draws its header inside the gap, an untitled one leaves it empty.
            if self?.sections[sectionIndex].title != nil {
                let headerSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                        heightDimension: .absolute(Metrics.sectionGap))
                section.boundarySupplementaryItems = [
                    NSCollectionLayoutBoundarySupplementaryItem(
                        layoutSize: headerSize,
                        elementKind: ShellSidebarHeaderView.elementKind,
                        alignment: .top)
                ]
            } else if sectionIndex > 0, !followsProfile {
                let isSettings = self?.sections[sectionIndex].items.first?.tab == .settings
                section.contentInsets = NSDirectionalEdgeInsets(top: isSettings ? Metrics.sectionGap : Metrics.quietSectionGap,
                                                                leading: 0, bottom: 0, trailing: 0)
            }
            return section
        }
    }

    // MARK: Data

    private static func liveSections() -> [ShellSidebarSection] {
        let defaults = UserDefaults.standard
        func flag(_ key: String, default fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }
        let profileName = ShellSidebarModel.currentProfileName
        return ShellSidebarModel.sections(
            libraries: SidebarLibrary.current(),
            liveTVSources: LiveTVDataStore.shared.sources,
            combineLiveTV: flag("combineLiveTVSources", default: true),
            showDiscover: flag("showDiscoverTab", default: true) && PlexAuthManager.shared.hasCredentials,
            showWatchlist: flag("showWatchlistTab", default: true) && PlexAuthManager.shared.hasCredentials,
            showFavorites: flag("showFavoritesTab", default: false) && PersonalHomeRows.offersFavorites,
            order: LibrarySettingsManager.shared.libraryOrder,
            hiddenKeys: LibrarySettingsManager.shared.hiddenLibraryKeys,
            profileName: profileName)
    }

    private func item(for tab: SidebarTab) -> ShellSidebarItem {
        for section in sections {
            if let match = section.items.first(where: { $0.tab == tab }) { return match }
        }
        return ShellSidebarItem(tab: .home, title: String(localized: "Home"), icon: "house.fill")
    }

}

// MARK: - Collection view

extension ShellSidebarViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].items.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let item = sections[indexPath.section].items[indexPath.item]
        if item.tab == .account {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ShellSidebarProfileCell.reuseIdentifier,
                for: indexPath) as! ShellSidebarProfileCell
            cell.configure(item: item, compact: sections[indexPath.section].items.count > 1)
            return cell
        }
        if item.tab == .nowPlaying {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ShellSidebarNowPlayingCell.reuseIdentifier,
                for: indexPath) as! ShellSidebarNowPlayingCell
            cell.configure(item: item)
            return cell
        }
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: ShellSidebarRowCell.reuseIdentifier,
            for: indexPath) as! ShellSidebarRowCell
        cell.configure(item: item, isSelectedTab: item.tab == selectedTab)
        cell.contentView.setReorderWiggle(heldKey != nil && item.arrangeKey == heldKey)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView,
                        viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: ShellSidebarHeaderView.reuseIdentifier,
            for: indexPath) as! ShellSidebarHeaderView
        header.label.text = sections[indexPath.section].title
        return header
    }

    /// With one profile the profile row does nothing on Select, so it takes no focus (#385).
    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        let item = sections[indexPath.section].items[indexPath.item]
        return item.tab != .account || item.canSwitchProfile
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if let rowMove, rowMove.swallowsNextSelect { rowMove.swallowsNextSelect = false; return }
        guard rowMove?.isMoving != true else { return }
        let tab = sections[indexPath.section].items[indexPath.item].tab
        if tab != .account, tab != .nowPlaying { select(tab: tab) }
        if embedded { onTabSelected?(tab) }
    }

    func collectionView(_ collectionView: UICollectionView,
                        shouldUpdateFocusIn context: UICollectionViewFocusUpdateContext) -> Bool {
        // Move: focus stays on the held row; only the follow-the-step request passes.
        if let heldKey, rowMove?.isMoving == true {
            return context.focusHeading.isEmpty
                && context.nextFocusedIndexPath.flatMap(item(at:))?.arrangeKey == heldKey
        }
        if ShellSidebarModel.stopsUpwardRun(
            from: context.previouslyFocusedIndexPath.flatMap(tab(at:)),
            to: context.nextFocusedIndexPath.flatMap(tab(at:)),
            headingUp: context.focusHeading.contains(.up),
            gestureAlreadyMoved: lastFocusMoveGesture == MenuPressInterceptor.remoteGestures.count) {
            return false
        }
        // Containment: while expanded, focus stays inside the sidebar; the
        // shell moves it out explicitly on collapse (state flips first, so
        // that move is never blocked).
        guard embedded, state == .expanded else { return true }
        if let nextView = context.nextFocusedView, !nextView.isDescendant(of: view) {
            return false
        }
        return true
    }

    func collectionView(_ collectionView: UICollectionView,
                        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        if context.nextFocusedIndexPath != nil {
            lastFocusMoveGesture = MenuPressInterceptor.remoteGestures.count
        }
    }

    private func tab(at indexPath: IndexPath) -> SidebarTab? {
        item(at: indexPath)?.tab
    }

    private func item(at indexPath: IndexPath) -> ShellSidebarItem? {
        sections.indices.contains(indexPath.section) ? sections[indexPath.section].items[safe: indexPath.item] : nil
    }

    private func select(tab: SidebarTab) {
        selectedTab = tab
        configurePill()
        collectionView.reloadData()
    }
}

// MARK: - Row menu and Move

extension ShellSidebarViewController {
    /// The arrangeable rows shown, in order.
    private var arrangeKeys: [String] { sections.flatMap(\.items).compactMap(\.arrangeKey) }

    fileprivate func installRowMenu() {
        collectionView.addGestureRecognizer(TileLongPress.makeRecognizer(target: self, action: #selector(handleRowLongPress(_:))))
        rowMove = GrabReorderController(
            view: collectionView, axis: .vertical,
            count: { [weak self] in self?.arrangeKeys.count ?? 0 },
            canMove: { _, _ in true },
            onStep: { [weak self] from, to in
                guard let self, let key = heldKey else { return }
                // Saved at each step; the sidebar redraws from it and focus follows in setSections.
                LibrarySettingsManager.shared.moveSidebarRow(key: key, up: to < from, visible: arrangeKeys)
            },
            onDrop: { [weak self] _, _ in self?.endRowMove(restoring: false) },
            onCancel: { [weak self] _ in self?.endRowMove(restoring: true) })
    }

    /// Menu while a row is on the move: put the order back. True when it did.
    func cancelRowMove() -> Bool {
        guard let rowMove, rowMove.isMoving else { return false }
        rowMove.cancel()
        return true
    }

    @objc private func handleRowLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, state == .expanded, rowMove?.isMoving != true,
              let indexPath = TileLongPress.focusedCell(in: collectionView),
              let item = item(at: indexPath), let key = item.arrangeKey else { return }
        var top: UIViewController = view.window?.rootViewController ?? self
        while let presented = top.presentedViewController { top = presented }
        guard top.presentedViewController == nil, !(top is TileMenuPopupViewController) else { return }
        let frame = collectionView.cellForItem(at: indexPath).map { $0.convert($0.bounds, to: nil) }
        top.present(TileMenuPopupViewController(sections: rowMenu(for: key, tab: item.tab), sourceFrame: frame),
                    animated: false)
    }

    private func rowMenu(for key: String, tab: SidebarTab) -> [[TileMenuAction]] {
        let move = TileMenuAction(title: "Move", systemImage: "arrow.up.arrow.down") { [weak self] in
            self?.beginRowMove(key)
        }
        // A video library also shuffles, unfiltered. After Move, so a stray Select on a fresh menu plays nothing.
        let shuffle = ShufflePlayback.library(for: tab).map { library in
            TileMenuAction(title: "Shuffle", systemImage: "shuffle") { [weak self] in
                guard let self else { return }
                ShufflePlayback.shuffle(library, from: self)
            }
        }
        if SidebarArrangement.isLiveTV(key) {
            let current = LiveTVLayout(rawValue: UserDefaults.standard.string(forKey: "liveTVLayout") ?? "") ?? .fallback
            let layouts = [LiveTVLayout.browse, .guide].map { layout -> TileMenuAction in
                TileMenuAction(verbatim: layout.description,
                               systemImage: layout == current ? "checkmark" : (layout == .guide ? "list.bullet.rectangle" : "square.grid.2x2")) {
                    UserDefaults.standard.set(layout.rawValue, forKey: "liveTVLayout")
                }
            }
            return [layouts, [move]]
        }
        guard SidebarArrangement.server(ofKey: key) != nil else { return [[move]] }
        let hide = TileMenuAction(title: "Hide from Sidebar", systemImage: "eye.slash") { [weak self] in
            self?.hideRow(key)
        }
        return [[move, shuffle].compactMap { $0 }, [hide]]
    }

    private func hideRow(_ key: String) {
        let settings = LibrarySettingsManager.shared
        if SidebarArrangement.isAppRow(key) {
            let playlists = arrangeKeys.filter { SidebarArrangement.isAppRow($0) && SidebarArrangement.server(ofKey: $0) != nil }
            settings.setPlaylistsRow(key, visible: false, allKeys: playlists)
        } else {
            settings.hideLibrary(key)
        }
    }

    private func beginRowMove(_ key: String) {
        guard let rowMove, !rowMove.isMoving, let index = arrangeKeys.firstIndex(of: key) else { return }
        orderBeforeMove = LibrarySettingsManager.shared.libraryOrder
        heldKey = key
        rowMove.begin(at: index)
        updateRowWiggle()
        focusRow(key)
    }

    private func endRowMove(restoring: Bool) {
        let key = heldKey
        heldKey = nil
        updateRowWiggle()
        guard restoring else { return }
        pendingFocusKey = key
        LibrarySettingsManager.shared.libraryOrder = orderBeforeMove
    }

    private func updateRowWiggle() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            let held = heldKey != nil && item(at: indexPath)?.arrangeKey == heldKey
            collectionView.cellForItem(at: indexPath)?.contentView.setReorderWiggle(held)
        }
    }

    /// Focus onto `key`'s row; the sidebar already holds focus, so the request is honoured.
    private func focusRow(_ key: String) {
        pendingFocusKey = nil
        guard let indexPath = sections.indices.lazy.compactMap({ s in
            self.sections[s].items.firstIndex { $0.arrangeKey == key }.map { IndexPath(item: $0, section: s) }
        }).first else { return }
        focus(at: indexPath)
        updateRowWiggle()
    }

    fileprivate func focus(at indexPath: IndexPath) {
        collectionView.preferredFocusIndexPath = indexPath
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        collectionView.layoutIfNeeded()
        // Only an environment holding focus may move it. After the menu closes
        // nothing holds it, so the request goes from the top, through the shell's
        // preferred environments down to this row.
        let holdsFocus = (UIFocusSystem.focusSystem(for: collectionView)?.focusedItem as? UIView)?
            .isDescendant(of: collectionView) == true
        let requester: UIFocusEnvironment = holdsFocus ? collectionView : (view.window?.rootViewController ?? self)
        requester.setNeedsFocusUpdate()
        requester.updateFocusIfNeeded()
    }
}
