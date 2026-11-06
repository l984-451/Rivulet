// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicChrome.swift
//  Rivulet
//
//  The shared primitives of the UIKit Music surface: measured numbers, the
//  system pill, the artwork loader, the page background, the focus platter
//  and the playback bars. Numbers were measured from Apple Music on tvOS 26.
//

import UIKit

/// Points on a 1920x1080 canvas.
nonisolated enum MusicMetrics {
    /// Content spans x 80..1840 and starts at y 60 on every Music screen.
    static let margin: CGFloat = 80
    static let top: CGFloat = 60
    static let pillHeight: CGFloat = 66
    static let pillGap: CGFloat = 24
    static let lockupArt: CGFloat = 320
    static let lockupGap: CGFloat = 40
    /// Label block under the art: 8pt gap and two 38pt callout lines.
    static let lockupFooter: CGFloat = 96
    static let secondary = UIColor(white: 1, alpha: 0.55)
    /// Apple's `tertiaryLabel`, fixed to its dark value: the Music pages are always dark.
    static let tertiary = UIColor.tertiaryLabel.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
}

@MainActor
enum MusicChrome {

    // MARK: - Pill

    /// The system bordered capsule: it supplies the near-white focus fill, the
    /// dark label and the fixed 4pt focus outset. A nil title makes a circle.
    static func pill(title: String?, symbol: String?, height: CGFloat = MusicMetrics.pillHeight) -> MusicPillButton {
        var config = UIButton.Configuration.bordered()
        config.cornerStyle = .capsule
        config.image = symbol.flatMap { UIImage(systemName: $0) }
        // Now Playing's 72pt circles carry a lighter glyph than the pages' 66pt ones.
        let nowPlaying = height > MusicMetrics.pillHeight
        config.preferredSymbolConfigurationForImage = title != nil
            ? UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
            : UIImage.SymbolConfiguration(pointSize: 22, weight: nowPlaying ? .semibold : .bold)
        if let title {
            config.title = title
            config.imagePadding = 11
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 31, bottom: 0, trailing: 31)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = .systemFont(ofSize: 29, weight: .semibold)
                return attributes
            }
        } else {
            config.contentInsets = .zero
        }
        let button = MusicPillButton(configuration: config)
        // Apple's Now Playing buttons barely grow on focus: 72 to 74, measured.
        if nowPlaying { button.focusOutset = 1 }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: height).isActive = true
        if title == nil {
            button.widthAnchor.constraint(equalToConstant: height).isActive = true
        } else if symbol != nil {
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 192).isActive = true
        }
        return button
    }

    // MARK: - Artwork

    /// The one Music image path: cached, decoded off the main thread. A cell
    /// keeps the returned task and cancels it on reuse, which drops a late image.
    @discardableResult
    static func loadArtwork(_ url: URL?,
                            quality: ImageQuality = .thumb,
                            apply: @escaping @MainActor (UIImage?) -> Void) -> Task<Void, Never>? {
        guard let url else { apply(nil); return nil }
        return Task {
            let image = await ImageCacheManager.shared.image(for: url, quality: quality)
            guard !Task.isCancelled else { return }
            apply(image)
        }
    }

    private static var placeholders: [String: UIImage] = [:]

    /// Apple's stand-in for missing artwork: a grey tile with a light glyph.
    static func placeholder(_ symbol: String = "music.note", side: CGFloat = MusicMetrics.lockupArt) -> UIImage {
        let key = "\(symbol)-\(side)"
        if let cached = placeholders[key] { return cached }
        let size = CGSize(width: side, height: side)
        let glyph = UIImage(systemName: symbol,
                            withConfiguration: UIImage.SymbolConfiguration(pointSize: side * 0.34, weight: .regular))?
            .withTintColor(UIColor(white: 0.68, alpha: 1), renderingMode: .alwaysOriginal)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(white: 0.35, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            if let glyph {
                glyph.draw(at: CGPoint(x: (side - glyph.size.width) / 2, y: (side - glyph.size.height) / 2))
            }
        }
        placeholders[key] = image
        return image
    }

    // MARK: - Background

    /// Apple's page ground: a vertical blue-grey gradient, never black.
    static func background() -> GradientView {
        let view = GradientView()
        view.gradientLayer.colors = [
            UIColor(red: 25 / 255, green: 44 / 255, blue: 58 / 255, alpha: 1).cgColor,
            UIColor(red: 26 / 255, green: 43 / 255, blue: 55 / 255, alpha: 1).cgColor,
            UIColor(red: 26 / 255, green: 34 / 255, blue: 46 / 255, alpha: 1).cgColor,
        ]
        view.isUserInteractionEnabled = false
        return view
    }

    // MARK: - Failure

    /// The app's "Unable to Load" card for a page whose list failed. Hidden
    /// until needed: a visible view above the collection occludes its cells.
    static func failureView(retry: @escaping () -> Void) -> HomeStateView {
        let view = HomeStateView()
        view.backgroundColor = .clear
        view.configure(kind: .error(message: String(localized: "Check the connection to your server and try again.")))
        view.onAction = retry
        view.isHidden = true
        // Its one button sits under none of the header's, so a guide over the card leads Down to it.
        let guide = UIFocusGuide()
        view.addLayoutGuide(guide)
        guide.preferredFocusEnvironments = [view]
        NSLayoutConstraint.activate([
            guide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            guide.topAnchor.constraint(equalTo: view.topAnchor),
            guide.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        return view
    }

    // MARK: - Text

    static func label(size: CGFloat, weight: UIFont.Weight, color: UIColor = .white, lines: Int = 1) -> UILabel {
        let label = UILabel()
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.numberOfLines = lines
        return label
    }

    /// "3:58", or "1:02:07" past an hour. Rounded, as Apple Music shows it.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs)
                         : String(format: "%d:%02d", minutes, secs)
    }

    /// Apple's line under a track list: "12 songs, 48 minutes", the count alone when the
    /// duration is unknown, and nothing for an empty list.
    static func songSummary(count: Int, duration: TimeInterval?) -> String {
        guard count >= 1 else { return "" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute]
        // Apple rounds to the nearest minute and drops the formatter's commas.
        let minutes = ((duration ?? 0) / 60).rounded()
        guard minutes >= 1, let length = formatter.string(from: minutes * 60) else {
            return String(localized: "\(count) Songs")
        }
        return String(localized: "\(count) songs, \(length.replacingOccurrences(of: ",", with: ""))")
    }
}

// MARK: - Focus platter

/// The glass rounded rectangle behind a focused row, in Apple's values: a 20% white tint,
/// a 20pt continuous corner and a 45pt shadow dropped by 40. Hidden at rest.
final class MusicFocusPlatterView: UIView {
    static let cornerRadius: CGFloat = 20

    /// Holds the shadow and cuts it out under the glass, which would otherwise show it through.
    private let shadowWell = UIView()
    private let shadowCaster = UIView()
    private let shadowCutout = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        alpha = 0
        shadowCaster.layer.shadowColor = UIColor.black.cgColor
        shadowCaster.layer.shadowOpacity = 0.6
        shadowCaster.layer.shadowRadius = 45
        shadowCaster.layer.shadowOffset = CGSize(width: 0, height: 40)
        shadowCutout.fillRule = .evenOdd
        shadowWell.layer.mask = shadowCutout
        shadowWell.addSubview(shadowCaster)
        let effect = UIGlassEffect(style: .regular)
        effect.tintColor = UIColor(white: 1, alpha: 0.2)
        let glass = UIVisualEffectView(effect: effect)
        glass.clipsToBounds = true
        glass.layer.cornerRadius = Self.cornerRadius
        glass.layer.cornerCurve = .continuous
        for view in [shadowWell, shadowCaster, glass] {
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        addSubview(shadowWell)
        addSubview(glass)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let shape = UIBezierPath(roundedRect: bounds, cornerRadius: Self.cornerRadius)
        shadowCaster.layer.shadowPath = shape.cgPath
        // Room for the whole shadow: its 40pt drop plus the blur's reach.
        let well = UIBezierPath(rect: bounds.insetBy(dx: -200, dy: -200))
        well.append(shape)
        shadowCutout.path = well.cgPath
    }
}

// MARK: - List label

/// One line of text between track rows: a disc heading, or the song count under the list.
final class MusicListLabelView: UICollectionReusableView {
    private let label = UILabel()
    private var top: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `top` is the line's distance from the view's top edge.
    func configure(text: String, font: UIFont, color: UIColor, top: CGFloat) {
        label.text = text
        label.font = font
        label.textColor = color
        self.top = top
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = CGRect(x: 0, y: top, width: bounds.width, height: ceil(label.font.lineHeight))
    }
}

// MARK: - Pill button

/// The system pill with Apple Music's fills: 10% white at rest, and for a toggle that is on the
/// lighter disc and the dot under the glyph that Apple gives AutoPlay.
final class MusicPillButton: UIButton {
    var isOn = false {
        didSet { if isOn != oldValue { setNeedsUpdateConfiguration() } }
    }

    /// How far the focused fill grows per side. The system's own growth is 4pt.
    var focusOutset: CGFloat = 4

    private let dot = UIView(frame: CGRect(x: 0, y: 0, width: 6, height: 6))

    // The system rest fill is 16% white; Apple Music's measures 10%. Focused, the fill is the system's.
    override func updateConfiguration() {
        super.updateConfiguration()
        configuration?.background.backgroundColor = isFocused ? nil : UIColor(white: 1, alpha: isOn ? 0.37 : 0.10)
        if dot.superview == nil {
            dot.layer.cornerRadius = 3
            dot.isUserInteractionEnabled = false
            addSubview(dot)
        }
        // The dot is what still says "on" under the white focus fill.
        dot.isHidden = !isOn
        dot.backgroundColor = isFocused ? UIColor(white: 0.1, alpha: 1) : .white
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dot.center = CGPoint(x: bounds.midX, y: bounds.midY + 20.5)
        bringSubviewToFront(dot)
    }

    // The system grows the focused button by 4pt a side; a smaller outset scales it back.
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard focusOutset != 4, bounds.height > 0 else { return }
        let focused = context.nextFocusedView === self
        let x = focused ? (bounds.width + focusOutset * 2) / (bounds.width + 8) : 1
        let y = focused ? (bounds.height + focusOutset * 2) / (bounds.height + 8) : 1
        coordinator.addCoordinatedAnimations { self.transform = CGAffineTransform(scaleX: x, y: y) }
    }
}

// MARK: - Playback bars

/// Four equaliser bars for the playing track. They rest as dots when paused.
final class MusicPlaybackBarsView: UIView {
    private let bars = (0..<4).map { _ in CALayer() }
    private let barWidth: CGFloat = 4
    private let barGap: CGFloat = 3
    /// Tallest bar. A list row centres the bars; Now Playing stands them on the title's baseline.
    private let peak: CGFloat
    private let standsOnBaseline: Bool

    var isPlaying = false {
        didSet { if isPlaying != oldValue { animate() } }
    }

    /// White by default; the sidebar darkens them on its white focus capsule.
    var barColor: UIColor = .white {
        didSet { bars.forEach { $0.backgroundColor = barColor.cgColor } }
    }

    init(peak: CGFloat = 24, standsOnBaseline: Bool = false) {
        self.peak = peak
        self.standsOnBaseline = standsOnBaseline
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        for bar in bars {
            bar.backgroundColor = UIColor.white.cgColor
            bar.cornerRadius = barWidth / 2
            if standsOnBaseline { bar.anchorPoint = CGPoint(x: 0.5, y: 1) }
            layer.addSublayer(bar)
        }
        // Core Animation also drops animations when the app leaves the foreground.
        NotificationCenter.default.addObserver(self, selector: #selector(setNeedsLayout),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: 4 * barWidth + 3 * barGap, height: peak)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let left = (bounds.width - intrinsicContentSize.width) / 2
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: barWidth)
            bar.position = CGPoint(x: left + CGFloat(index) * (barWidth + barGap) + barWidth / 2,
                                   y: standsOnBaseline ? bounds.maxY : bounds.midY)
        }
        CATransaction.commit()
        animate()
    }

    // Core Animation drops animations when the layer leaves the window.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { setNeedsLayout() }
    }

    private func animate() {
        let peaks = [14, 24, 18, 22].map { $0 * peak / 24 }
        let periods: [CFTimeInterval] = [0.42, 0.36, 0.5, 0.4]
        for (index, bar) in bars.enumerated() {
            bar.removeAnimation(forKey: "bars")
            guard isPlaying, window != nil, !UIAccessibility.isReduceMotionEnabled else {
                bar.bounds.size.height = isPlaying ? peaks[index] : barWidth
                continue
            }
            let animation = CABasicAnimation(keyPath: "bounds.size.height")
            animation.fromValue = barWidth + 2
            animation.toValue = peaks[index]
            animation.duration = periods[index]
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(animation, forKey: "bars")
        }
    }
}

// MARK: - Header cell

/// The top of a Music page: title lines and the owner's buttons. A focus
/// container: the collection offers it, and it forwards to its buttons.
@MainActor
final class MusicHeaderCell: UICollectionViewCell {
    /// `album` and `playlist` put the buttons under the text, the last at the right edge. `grid` and
    /// `browse` (the Library: body-size title, caption count) right-align them on the title's row.
    enum Layout {
        case album, playlist, grid, browse

        /// Text baselines from the page top. Apple sets a playlist's higher than an album's.
        var baselines: [CGFloat] {
            switch self {
            case .album: [157, 213, 260]
            case .playlist: [138, 189, 273]
            case .grid: [106, 152, 0]
            case .browse: [88, 120, 0]
            }
        }

        var pillTop: CGFloat {
            switch self {
            case .album: 348
            case .playlist: 364
            case .grid, .browse: MusicMetrics.top
            }
        }

        var buttonsOnTitleRow: Bool { self == .grid || self == .browse }
        var titleSize: CGFloat { self == .browse ? 29 : 57 }
        var line2Font: UIFont {
            switch self {
            case .browse: .systemFont(ofSize: 23, weight: .medium)
            case .grid: .systemFont(ofSize: 29, weight: .regular)
            default: .systemFont(ofSize: 38, weight: .regular)
            }
        }
        /// Apple's Library header sets its buttons 26 apart; its pages 24.
        var pillGap: CGFloat { self == .browse ? 26 : MusicMetrics.pillGap }
        /// Side padding of a titled pill: Apple's Library Shuffle is 212 wide, its album page's 204.
        var pillInset: CGFloat { self == .browse ? 35 : 31 }

        /// Header height on an album or playlist page: the first row starts here.
        var height: CGFloat { self == .album ? 455 : 468 }
    }

    private static let titleFont = UIFont.systemFont(ofSize: 57, weight: .bold)

    /// How far a title that wraps to a second line pushes everything under it.
    static func titleOverflow(_ title: String, width: CGFloat) -> CGFloat {
        let box = (title as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: .usesLineFragmentOrigin, attributes: [.font: titleFont], context: nil)
        return box.height > titleFont.lineHeight * 1.5 ? titleFont.lineHeight.rounded() : 0
    }

    private let title = MusicChrome.label(size: 57, weight: .bold)
    private let line2 = UILabel()
    private let line3 = MusicChrome.label(size: 29, weight: .regular, color: UIColor(white: 1, alpha: 0.5))
    private let entryGuide = UIFocusGuide()
    private let exitGuide = UIFocusGuide()
    private var buttons: [UIButton] = []
    private var buttonConstraints: [NSLayoutConstraint] = []
    private var pillTops: [NSLayoutConstraint] = []
    private var layout: Layout = .album
    /// The button that held focus when a menu or another page took it.
    private weak var lastFocused: UIView?
    /// The tile focus came up from: Down from the title row's buttons returns to it.
    private weak var cameFrom: UIView?
    /// True while focus is outside the header: only the first button can take it.
    private var isGated = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = false
        title.minimumScaleFactor = 0.7
        [title, line2, line3].forEach(contentView.addSubview)
        contentView.addLayoutGuide(entryGuide)
        contentView.addLayoutGuide(exitGuide)
        exitGuide.isEnabled = false
        NSLayoutConstraint.activate([
            // Under the buttons, across every column, so Down finds it before the nearest tile.
            exitGuide.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            exitGuide.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            exitGuide.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            exitGuide.heightAnchor.constraint(equalToConstant: 40),
            entryGuide.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            entryGuide.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            entryGuide.topAnchor.constraint(equalTo: contentView.topAnchor),
            entryGuide.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(layout: Layout, title: String, line2: String?, line3: String? = nil, buttons: [UIButton]) {
        self.layout = layout
        self.title.text = title
        // A page title wraps to two lines at full size; the grid's one line shrinks to fit.
        self.title.font = .systemFont(ofSize: layout.titleSize, weight: .bold)
        self.title.numberOfLines = layout.buttonsOnTitleRow ? 1 : 2
        self.title.adjustsFontSizeToFitWidth = layout == .grid
        self.line2.text = line2
        self.line2.font = layout.line2Font
        self.line2.textColor = MusicMetrics.secondary
        self.line3.text = line3
        setNeedsLayout()
        // The list under the header may have changed: the tile focus came from is not to be trusted.
        cameFrom = nil
        exitGuide.isEnabled = false
        guard self.buttons != buttons else { return }
        NSLayoutConstraint.deactivate(buttonConstraints)
        self.buttons.forEach { $0.removeFromSuperview() }
        self.buttons = buttons
        buttons.forEach(contentView.addSubview)
        // The Library swaps button sets on one cell: the new set takes the gate as it stands.
        if let last = lastFocused, !buttons.contains(where: { $0 === last }) { lastFocused = nil }
        applyGate()
        for button in buttons where button.configuration?.title != nil {
            button.configuration?.contentInsets.leading = layout.pillInset
            button.configuration?.contentInsets.trailing = layout.pillInset
        }
        entryGuide.preferredFocusEnvironments = Array(buttons.prefix(1))

        // The pills chain from the left; `trailingCount` of them hang from the right edge instead.
        let trailingCount = layout.buttonsOnTitleRow ? buttons.count : 1
        let split = buttons.count - trailingCount
        pillTops = buttons.map { $0.topAnchor.constraint(equalTo: contentView.topAnchor) }
        buttonConstraints = pillTops
        for (index, button) in buttons.enumerated() {
            if index < split {
                buttonConstraints.append(button.leadingAnchor.constraint(
                    equalTo: index == 0 ? contentView.leadingAnchor : buttons[index - 1].trailingAnchor,
                    constant: index == 0 ? 0 : layout.pillGap))
            } else {
                buttonConstraints.append(button.trailingAnchor.constraint(
                    equalTo: index == buttons.count - 1 ? contentView.trailingAnchor : buttons[index + 1].leadingAnchor,
                    constant: index == buttons.count - 1 ? 0 : -layout.pillGap))
            }
        }
        NSLayoutConstraint.activate(buttonConstraints)
    }

    // Baselines measured from the page top: the cell is the first thing on the page.
    override func layoutSubviews() {
        super.layoutSubviews()
        let full = contentView.bounds.width
        let overflow = layout.buttonsOnTitleRow ? 0 : Self.titleOverflow(title.text ?? "", width: full)
        pillTops.forEach { $0.constant = layout.pillTop + overflow }
        contentView.layoutIfNeeded()
        let width = layout.buttonsOnTitleRow ? (buttons.first?.frame.minX ?? full) - 40 : full
        for (index, (label, baseline)) in zip([title, line2, line3], layout.baselines).enumerated() {
            // The title grows down by its second line; the lines under it move by the same amount.
            label.frame = CGRect(x: 0, y: baseline - label.font.ascender + (index == 0 ? 0 : overflow),
                                 width: width, height: ceil(label.font.lineHeight) + (index == 0 ? overflow : 0))
        }
    }

    // MARK: Focus

    override var canBecomeFocused: Bool { false }

    // Back from a menu or a page the menu opened, focus returns to the button that opened it.
    override var preferredFocusEnvironments: [UIFocusEnvironment] { (lastFocused.map { [$0] } ?? []) + buttons }

    // A directional move takes the nearest button, so while focus is outside only the first one can
    // take it, and a guide leads Up to it. The header starts gated: focus may never have been in it.
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard let next = context.nextFocusedView else { return }
        let inside = next.isDescendant(of: self)
        if inside {
            if let previous = context.previouslyFocusedView, !previous.isDescendant(of: self),
               superview.map(previous.isDescendant(of:)) == true {
                cameFrom = previous
            }
            lastFocused = next
        } else if superview.map(next.isDescendant(of:)) == true {
            // Into the rows. A menu or a page taking focus keeps both, so focus can come back.
            lastFocused = nil
            cameFrom = nil
        }
        isGated = !inside
        entryGuide.isEnabled = !inside
        exitGuide.preferredFocusEnvironments = cameFrom.map { [$0] } ?? []
        exitGuide.isEnabled = inside && layout.buttonsOnTitleRow && cameFrom?.window != nil
        applyGate()
    }

    /// Gated, the button a menu or a page will hand focus back to stays reachable with the first.
    private func applyGate() {
        for (index, button) in buttons.enumerated() {
            button.isUserInteractionEnabled = !isGated || index == 0 || button === lastFocused
        }
    }
}
