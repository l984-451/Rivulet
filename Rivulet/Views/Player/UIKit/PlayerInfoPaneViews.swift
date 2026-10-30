// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerInfoPaneViews.swift
//  Rivulet
//
//  Content for the info pane that opens from the pills below the scrub bar,
//  cloned from AVPlayerViewController's tvOS 26 info panel (measured with DEBUG
//  `AVKitScrubProbe`, RIVULET_SCRUBPROBE=chrome): the Info card and the row of
//  thumbnail cards used for Chapters and Up Next.
//

import UIKit

/// AVKit's control glass, as the tool buttons use it.
func makePaneGlass(cornerRadius: CGFloat) -> UIView {
    let glass = UIVisualEffectView(effect: TransportControlButton.glassEffect())
    glass.isUserInteractionEnabled = false
    glass.clipsToBounds = true
    glass.layer.cornerRadius = cornerRadius
    glass.layer.cornerCurve = .continuous
    return glass
}

/// AVKit's label shadow (black 0.2, radius 30): lifts white text off bright video behind glass.
func applyChromeTextShadow(_ labels: [UILabel]) {
    for label in labels {
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.2
        label.layer.shadowRadius = 30
        label.layer.shadowOffset = .zero
    }
}

// MARK: - PlayerInfoCardView

/// AVKit's Info tab: a 250pt glass card with the poster, title, a two-line
/// summary that opens in full on Select, a "Genre • runtime" line with badges,
/// and the From Beginning action on the right.
final class PlayerInfoCardView: UIView {

    struct Content {
        var posterURL: URL?
        var title: String
        var summary: String?
        var genre: String?
        var runtimeMinutes: Int?
        var badges: [String]
        /// Replaces "Genre • runtime" (Live TV's channel and air time).
        var metaLine: [String]? = nil
        /// Channel logos are fitted, not cropped to the poster frame.
        var posterFits = false
        var showsFromBeginning = true
        var isDescriptionTranslating = false
        var overviewIsMachineTranslated = false
    }

    private enum Metrics {
        static let height: CGFloat = 250
        static let radius: CGFloat = 48
        static let poster = CGRect(x: 23, y: 23, width: 136, height: 204)
        static let posterRadius: CGFloat = 25
        static let textX: CGFloat = 199
        static let titleTop: CGFloat = 33
        static let summaryTop: CGFloat = 80
        static let summaryWidth: CGFloat = 1003
        static let metaTop: CGFloat = 187
        static let actionWidth: CGFloat = 360
        static let actionTrailing: CGFloat = 50
        static let actionTop: CGFloat = 51
    }

    var onFromBeginning: (() -> Void)?
    /// Select on the summary: the host shows it in full.
    var onExpandSummary: ((UIView) -> Void)?

    private let posterView = UIImageView()
    private var posterTask: Task<Void, Never>?
    private let summaryButton = PlayerSummaryButton(text: "")
    private let translationView = DescriptionTranslationView()
    private var translationBelowSummary: NSLayoutConstraint?
    private var translationWithoutSummary: NSLayoutConstraint?

    init(content: Content) {
        super.init(frame: .zero)

        let glass = makePaneGlass(cornerRadius: Metrics.radius)
        posterView.contentMode = content.posterFits ? .scaleAspectFit : .scaleAspectFill
        posterView.clipsToBounds = true
        posterView.layer.cornerRadius = Metrics.posterRadius
        posterView.layer.cornerCurve = .continuous
        posterView.backgroundColor = UIColor.white.withAlphaComponent(0.08)

        let title = UILabel()
        title.text = content.title
        title.font = .systemFont(ofSize: 31, weight: .bold)
        title.textColor = .white

        let summary = summaryButton
        summary.setText(content.summary ?? "")
        summary.setTranslating(content.isDescriptionTranslating)
        summary.isHidden = (content.summary ?? "").isEmpty
        translationView.configure(isTranslating: content.isDescriptionTranslating,
                                  isMachineTranslated: content.overviewIsMachineTranslated)
        summary.onPress = { [weak self, weak summary] in
            guard let summary else { return }
            self?.onExpandSummary?(summary)
        }

        let meta = UIStackView()
        meta.axis = .horizontal
        meta.spacing = 6
        meta.alignment = .center
        let words = content.metaLine ?? [content.genre, content.runtimeMinutes.map { "\($0) min" }].compactMap { $0 }
        if !words.isEmpty {
            let label = UILabel()
            label.text = words.joined(separator: " • ")
            label.font = .systemFont(ofSize: 25, weight: .medium)
            label.textColor = .white
            meta.addArrangedSubview(label)
            meta.setCustomSpacing(15, after: label)
        }
        for badge in content.badges {
            meta.addArrangedSubview(PlayerInfoBadgeView(text: badge))
        }

        let action = PlayerPaneActionButton(title: "From Beginning", symbol: "play.fill")
        action.isHidden = !content.showsFromBeginning
        action.onPress = { [weak self] in self?.onFromBeginning?() }

        [glass, posterView, title, summary, translationView, meta, action].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        translationBelowSummary = translationView.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 2)
        translationWithoutSummary = translationView.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.summaryTop)
        translationBelowSummary?.isActive = !summary.isHidden
        translationWithoutSummary?.isActive = summary.isHidden
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.height),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),

            posterView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.poster.minX),
            posterView.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.poster.minY),
            posterView.widthAnchor.constraint(equalToConstant: Metrics.poster.width),
            posterView.heightAnchor.constraint(equalToConstant: Metrics.poster.height),

            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.textX),
            title.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.titleTop),
            title.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -40),

            summary.textLeading.constraint(equalTo: leadingAnchor, constant: Metrics.textX),
            summary.textTop.constraint(equalTo: topAnchor, constant: Metrics.summaryTop),
            summary.textWidth.constraint(equalToConstant: Metrics.summaryWidth),

            translationView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.textX),
            translationView.widthAnchor.constraint(equalToConstant: Metrics.summaryWidth),

            meta.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.textX),
            meta.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.metaTop),

            action.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.actionTrailing),
            action.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.actionTop),
            action.widthAnchor.constraint(equalToConstant: Metrics.actionWidth),
        ])

        if let url = content.posterURL {
            posterTask = Task { [weak self] in
                let image = await ImageCacheManager.shared.image(for: url)
                guard let self, !Task.isCancelled else { return }
                self.posterView.image = image
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { posterTask?.cancel() }

    func updateDescription(text: String?, isTranslating: Bool, isMachineTranslated: Bool) {
        let text = text ?? ""
        summaryButton.setText(text)
        summaryButton.setTranslating(isTranslating)
        summaryButton.isHidden = text.isEmpty
        translationView.configure(isTranslating: isTranslating, isMachineTranslated: isMachineTranslated)
        translationBelowSummary?.isActive = false
        translationWithoutSummary?.isActive = false
        translationBelowSummary?.isActive = !summaryButton.isHidden
        translationWithoutSummary?.isActive = summaryButton.isHidden
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }
}

/// AVKit's expanding summary: two lines, a focus plate 12pt past the text,
/// Select to read it all.
final class PlayerSummaryButton: UIControl {

    var onPress: (() -> Void)?
    private let label = UILabel()
    private let plate = UIView()
    private let textHeight: NSLayoutConstraint

    // Anchors for the TEXT, which AVKit positions; the plate grows past it.
    var textLeading: NSLayoutXAxisAnchor { label.leadingAnchor }
    var textTop: NSLayoutYAxisAnchor { label.topAnchor }
    var textWidth: NSLayoutDimension { label.widthAnchor }

    init(text: String, lines: Int = 2) {
        // At most `lines` tall, so short text sits at the top with the plate hugging it.
        textHeight = label.heightAnchor.constraint(lessThanOrEqualToConstant: CGFloat(lines) * 32)
        super.init(frame: .zero)
        label.text = text
        label.numberOfLines = lines
        label.font = .systemFont(ofSize: 25, weight: .medium)
        label.textColor = UIColor.white.withAlphaComponent(0.8)
        plate.backgroundColor = .white
        plate.alpha = 0
        plate.layer.cornerRadius = 20
        plate.layer.cornerCurve = .continuous
        plate.isUserInteractionEnabled = false
        [plate, label].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            textHeight,
            plate.leadingAnchor.constraint(equalTo: label.leadingAnchor, constant: -12),
            plate.trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            plate.topAnchor.constraint(equalTo: label.topAnchor, constant: -7),
            plate.bottomAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            leadingAnchor.constraint(equalTo: plate.leadingAnchor),
            trailingAnchor.constraint(equalTo: plate.trailingAnchor),
            topAnchor.constraint(equalTo: plate.topAnchor),
            bottomAnchor.constraint(equalTo: plate.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setText(_ text: String) { label.text = text }
    func setTranslating(_ translating: Bool) { label.alpha = translating ? 0.65 : 1 }

    /// Reading mode: the text may shrink to show more of itself in the same lines.
    func setShrinksToFit(_ shrinks: Bool) {
        label.adjustsFontSizeToFitWidth = shrinks
        label.minimumScaleFactor = shrinks ? 0.7 : 1
    }

    override var canBecomeFocused: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            onPress?()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.animateFocusChange(gained: focused) {
            // ponytail: focused look not measured; AVKit's floating content lifts a plate.
            self.plate.alpha = focused ? 0.15 : 0
            self.transform = focused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
        }
    }
}

/// AVKit's info-panel action (From Beginning): a 66pt capsule, white 0.16 at
/// rest, a 29pt medium title after its glyph.
final class PlayerPaneActionButton: UIControl {

    var onPress: (() -> Void)?
    private let background = UIView()
    private let icon = UIImageView()
    private let label = UILabel()

    init(title: String, symbol: String) {
        super.init(frame: .zero)
        background.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        background.layer.cornerRadius = 33
        background.layer.cornerCurve = .continuous
        background.isUserInteractionEnabled = false
        icon.image = UIImage(systemName: symbol,
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 29, weight: .medium))
        icon.tintColor = .white
        label.text = title
        label.font = .systemFont(ofSize: 29, weight: .medium)
        label.textColor = .white
        let row = UIStackView(arrangedSubviews: [icon, label])
        row.spacing = 12
        row.alignment = .center
        row.isUserInteractionEnabled = false
        [background, row].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 66),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFocused: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            onPress?()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.animateFocusChange(gained: focused) {
            self.background.backgroundColor = focused ? .white : UIColor.white.withAlphaComponent(0.16)
            self.icon.tintColor = focused ? .black : .white
            self.label.textColor = focused ? .black : .white
            self.transform = focused ? CGAffineTransform(scaleX: 1.05, y: 1.05) : .identity
        }
    }
}

/// Outlined badge (rating, HD, CC) after the Info card's meta line.
private final class PlayerInfoBadgeView: UIView {
    init(text: String) {
        super.init(frame: .zero)
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 15, weight: .bold)
        label.textColor = .white
        layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = 2
        layer.cornerRadius = 4
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - PlayerDescriptionOverlayView

/// AVKit's full description, from Select on the Info card's summary: the
/// screen dims to half black and the text sits on a centered glass platter,
/// 820 wide and at most 800 tall, scrolling when longer. Fades 0.24s each way.
final class PlayerDescriptionOverlayView: UIView {

    private enum Metrics {
        static let width: CGFloat = 820
        static let sideInset: CGFloat = 40
        static let verticalInset: CGFloat = 40
        /// Scrolling text keeps this clear at the ends, for the fade.
        static let scrollingInset: CGFloat = 63
        static let maxHeight: CGFloat = 800
        static let radius: CGFloat = 28
        static let fade: TimeInterval = 0.24
    }

    private let platter = UIView()
    private let textClip = UIView()
    private let scrollView = FocusableTextScrollView()
    private let label = UILabel()
    private let translationView = DescriptionTranslationView()
    private let fadeMask = CAGradientLayer()

    init(text: String, isTranslating: Bool = false, isMachineTranslated: Bool = false,
         canTranslate: Bool = false, errorMessage: String? = nil, onTranslate: (() -> Void)? = nil) {
        super.init(frame: .zero)
        label.text = text
        label.alpha = isTranslating ? 0.65 : 1
        label.font = .systemFont(ofSize: 29, weight: .medium)
        label.textColor = .white
        label.numberOfLines = 0
        translationView.configure(isTranslating: isTranslating, isMachineTranslated: isMachineTranslated,
                                  canTranslate: canTranslate, errorMessage: errorMessage, onTranslate: onTranslate)
        scrollView.showsVerticalScrollIndicator = false
        scrollView.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        scrollView.addSubview(label)
        scrollView.addSubview(translationView)
        textClip.addSubview(scrollView)
        let glass = makePaneGlass(cornerRadius: Metrics.radius)
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        platter.addSubview(glass)
        platter.addSubview(textClip)
        platter.alpha = 0
        addSubview(platter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateDescription(text: String?, isTranslating: Bool, isMachineTranslated: Bool,
                           canTranslate: Bool = false, errorMessage: String? = nil,
                           onTranslate: (() -> Void)? = nil) {
        label.text = text ?? ""
        label.alpha = isTranslating ? 0.65 : 1
        translationView.configure(isTranslating: isTranslating, isMachineTranslated: isMachineTranslated,
                                  canTranslate: canTranslate, errorMessage: errorMessage, onTranslate: onTranslate)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let textWidth = Metrics.width - Metrics.sideInset * 2
        let textHeight = ceil(label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        let translationHeight = translationView.sizeThatFits(
            CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        let translationSpacing: CGFloat = textHeight > 0 && translationHeight > 0 ? 12 : 0
        let contentHeight = textHeight + translationSpacing + translationHeight
        let scrolls = contentHeight + Metrics.verticalInset * 2 > Metrics.maxHeight
        let inset = scrolls ? Metrics.scrollingInset : Metrics.verticalInset
        let height = min(Metrics.maxHeight, contentHeight + inset * 2)
        platter.frame = CGRect(x: (bounds.width - Metrics.width) / 2, y: (bounds.height - height) / 2,
                               width: Metrics.width, height: height)
        platter.subviews.first?.frame = platter.bounds
        textClip.frame = CGRect(x: Metrics.sideInset, y: 0, width: textWidth, height: height)
        scrollView.frame = textClip.bounds
        translationView.frame = CGRect(x: 0, y: inset, width: textWidth, height: translationHeight)
        label.frame = CGRect(x: 0, y: inset + translationHeight + translationSpacing,
                             width: textWidth, height: textHeight)
        scrollView.contentSize = CGSize(width: textWidth, height: contentHeight + inset * 2)
        let maximumOffset = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        if scrollView.contentOffset.y > maximumOffset, !scrollView.isDragging, !scrollView.isDecelerating {
            scrollView.contentOffset.y = maximumOffset
        }
        textClip.layer.mask = scrolls ? fadeMask : nil
        if scrolls {
            let edge = NSNumber(value: Double(Metrics.verticalInset / height))
            let farEdge = NSNumber(value: 1 - Double(Metrics.scrollingInset / height))
            fadeMask.colors = [UIColor.clear, .black, .black, .clear].map(\.cgColor)
            fadeMask.locations = [0, edge, farEdge, 1]
            fadeMask.frame = textClip.bounds
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [scrollView] }

    func fadeIn() {
        UIView.animate(withDuration: Metrics.fade) {
            self.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            self.platter.alpha = 1
        }
    }

    func fadeOut(completion: @escaping () -> Void) {
        scrollView.isFocusable = false
        UIView.animate(withDuration: Metrics.fade, animations: {
            self.backgroundColor = .clear
            self.platter.alpha = 0
        }, completion: { _ in completion() })
    }
}

/// Takes focus so swipes and Up/Down scroll the text, as AVKit's does.
private final class FocusableTextScrollView: UIScrollView {
    var isFocusable = true
    override var canBecomeFocused: Bool { isFocusable }
}

// MARK: - PlayerCardRowView

/// AVKit's thumbnail row (Chapters): 320 x 228 cards 40pt apart, scrolling
/// horizontally with focus. Up Next reuses it for episodes.
final class PlayerCardRowView: UIView {

    struct Card {
        var imageURL: URL?
        /// Fallback image when there is no URL; the row loads these one at a time.
        var stillLoader: (() async -> UIImage?)? = nil
        /// "Watching", "Episode 4"... above the title.
        var eyebrow: String?
        var title: String
        var isCurrent: Bool
        var onSelect: () -> Void
    }

    static let cardSize = CGSize(width: 320, height: 228)
    private static let gap: CGFloat = 40

    private let scrollView = UIScrollView()
    private var cells: [PlayerThumbnailCardView] = []
    /// The tail of the serial still queue.
    private var stillTask: Task<Void, Never>?

    init(cards: [Card]) {
        super.init(frame: .zero)
        scrollView.clipsToBounds = false
        scrollView.showsHorizontalScrollIndicator = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = Self.gap
        cells = cards.map { PlayerThumbnailCardView(card: $0) }
        cells.forEach { stack.addArrangedSubview($0) }
        scrollView.addSubview(stack)
        addSubview(scrollView)
        [scrollView, stack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.cardSize.height),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
        // A card with no image, or whose image fails (Plex lists chapter images it never
        // generated), takes its fallback still. One at a time: the engine decodes serially.
        for (cell, card) in zip(cells, cards) {
            guard let load = card.stillLoader else { continue }
            let enqueue = { [weak self, weak cell] in
                guard let self, let cell else { return }
                let previous = self.stillTask
                self.stillTask = Task { [weak self, weak cell] in
                    await previous?.value
                    // A closed pane's queued stills are skipped, not decoded.
                    guard self != nil, cell != nil, let image = await load() else { return }
                    cell?.setImage(image)
                }
            }
            if card.imageURL == nil { enqueue() } else { cell.onImageFailed = enqueue }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }


    /// Down from the pills lands on the current item, as AVKit's chapters do.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        (cells.first(where: \.isCurrent) ?? cells.first).map { [$0] } ?? []
    }

    /// Puts the current item in the second slot before the pane appears, the
    /// focus engine's resting place for it, so entering the row doesn't scroll.
    func scrollToCurrent() {
        layoutIfNeeded()
        guard let current = cells.first(where: \.isCurrent) else { return }
        let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        scrollView.contentOffset.x = min(maxX, max(0, current.frame.minX - Self.cardSize.width - Self.gap))
    }
}

/// One AVKit thumbnail card: image, a dark band under the text, the title in
/// 25pt medium and an optional 21pt eyebrow.
private final class PlayerThumbnailCardView: UIControl {

    let isCurrent: Bool
    var onImageFailed: (() -> Void)?
    private let onSelect: () -> Void
    private let imageView = UIImageView()
    private var imageTask: Task<Void, Never>?

    init(card: PlayerCardRowView.Card) {
        isCurrent = card.isCurrent
        onSelect = card.onSelect
        super.init(frame: .zero)

        layer.cornerRadius = 24
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 4)
        layer.shadowPath = UIBezierPath(roundedRect: CGRect(origin: .zero, size: PlayerCardRowView.cardSize),
                                        cornerRadius: 24).cgPath

        let clip = UIView()
        clip.backgroundColor = UIColor.white.withAlphaComponent(0.1)
        clip.layer.cornerRadius = 24
        clip.layer.cornerCurve = .continuous
        clip.layer.borderWidth = 1
        clip.layer.borderColor = UIColor.white.withAlphaComponent(0.05).cgColor
        clip.clipsToBounds = true
        clip.isUserInteractionEnabled = false

        imageView.contentMode = .scaleAspectFill
        let band = CardBandGradientView()
        let title = UILabel()
        title.text = card.title
        title.font = .systemFont(ofSize: 25, weight: .medium)
        title.textColor = .white
        let eyebrow = UILabel()
        eyebrow.text = card.eyebrow
        eyebrow.font = .systemFont(ofSize: 21, weight: .medium)
        eyebrow.textColor = UIColor.white.withAlphaComponent(0.5)
        eyebrow.isHidden = card.eyebrow == nil

        addSubview(clip)
        [imageView, band, eyebrow, title].forEach { clip.addSubview($0) }
        [clip, imageView, band, eyebrow, title].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: PlayerCardRowView.cardSize.width),
            heightAnchor.constraint(equalToConstant: PlayerCardRowView.cardSize.height),
            clip.topAnchor.constraint(equalTo: topAnchor),
            clip.bottomAnchor.constraint(equalTo: bottomAnchor),
            clip.leadingAnchor.constraint(equalTo: leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: clip.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            band.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            band.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            band.heightAnchor.constraint(equalToConstant: card.eyebrow == nil ? 82 : 108),
            title.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: 14),
            title.trailingAnchor.constraint(lessThanOrEqualTo: clip.trailingAnchor, constant: -14),
            title.topAnchor.constraint(equalTo: clip.topAnchor, constant: 186),
            eyebrow.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            eyebrow.trailingAnchor.constraint(lessThanOrEqualTo: clip.trailingAnchor, constant: -14),
            eyebrow.topAnchor.constraint(equalTo: clip.topAnchor, constant: 160),
        ])

        if let url = card.imageURL {
            imageTask = Task { [weak self] in
                let image = await ImageCacheManager.shared.image(for: url)
                guard let self, !Task.isCancelled else { return }
                if let image { self.imageView.image = image } else { self.onImageFailed?() }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { imageTask?.cancel() }

    func setImage(_ image: UIImage) { imageView.image = image }

    override var canBecomeFocused: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            onSelect()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.animateFocusChange(gained: focused) {
            // ponytail: focus lift not measured; uses the pills' measured shadow.
            self.transform = focused ? CGAffineTransform(scaleX: 1.08, y: 1.08) : .identity
            self.layer.shadowOpacity = focused ? 0.3 : 0.2
            self.layer.shadowRadius = focused ? 15 : 6
            self.layer.shadowOffset = CGSize(width: 0, height: focused ? 20 : 4)
        }
    }
}

/// The dark band AVKit blurs under a card's text; a gradient stands in for the blur.
private final class CardBandGradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        (layer as? CAGradientLayer)?.colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(0.6).cgColor,
        ]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - StreamingModeInfo

/// Per-category delivery mode (Direct Play / Direct Stream / Transcode)
/// shown at the top of each section, so users can confirm playback status
/// without opening the Plex server dashboard.
/// How a Dolby Vision source reaches the screen, for the Details tab.
enum DolbyVisionPlayback: String, Equatable {
    case dualLayer = "Dual Layer (FEL)"
    case convertedTo81 = "Profile 8.1 (converted)"
    case dolbyVision = "Dolby Vision"
    case hdr10BaseLayer = "HDR10 Base Layer"
    case sdr = "SDR"

    /// A Profile 7 source shown as Dolby Vision without the 8.1 rewrite is on
    /// the engine's dual-layer route, which only FEL takes.
    /// videoFormat read SDR on the dual-layer route in #362; an unconverted P7 on the software route is it.
    init?(sourceProfile: Int?, convertedTo81: Bool, onSoftwareRoute: Bool = false,
          presentsDolbyVision: Bool, presentsHDR: Bool) {
        guard let sourceProfile else { return nil }
        if convertedTo81 {
            self = .convertedTo81
        } else if sourceProfile == 7, onSoftwareRoute {
            self = .dualLayer
        } else if presentsDolbyVision {
            self = sourceProfile == 7 ? .dualLayer : .dolbyVision
        } else {
            self = presentsHDR ? .hdr10BaseLayer : .sdr
        }
    }
}

/// A Profile 7 source's enhancement layer, read from the engine's route line (it exposes no property).
/// Only FEL reaches the budget check, so an over-budget line is FEL too.
enum DolbyVisionEnhancementLayer: String, Equatable {
    case full = "Full (FEL)"
    case minimal = "Minimal (MEL)"

    init?(routeLine: String) {
        if routeLine.contains("el_type=FEL") || routeLine.contains("over the real-time budget") {
            self = .full
        } else if routeLine.contains("el_type=MEL") {
            self = .minimal
        } else {
            return nil
        }
    }
}

struct StreamingModeInfo {
    enum Mode: String {
        case unknown = "Unknown"
        case directPlay = "Direct Play"
        case directStream = "Direct Stream"
        case transcode = "Transcode"
    }
    let video: Mode
    let audio: Mode
    let subtitles: Mode
}

// MARK: - PlayerDetailsPaneView

/// The Details tab in the Info card's glass box: the media facts, then the
/// engine's live stats, one section per column (a long one runs on into the
/// next under the same rule), scrolled sideways with focus.
final class PlayerDetailsPaneView: UIView {

    struct Row: Equatable {
        var label: String?
        var value: String
    }

    struct Section: Equatable {
        var title: String
        var rows: [Row]
    }

    private enum Metrics {
        static let height: CGFloat = 250
        static let radius: CGFloat = 48
        static let sideInset: CGFloat = 40
        static let columnWidth: CGFloat = 380
        static let columnGap: CGFloat = 40
        static let columnTop: CGFloat = 22
        static let columnHeight: CGFloat = 208
        static let headerGap: CGFloat = 8
        static let rowGap: CGFloat = 1
        static let sectionGap: CGFloat = 18
    }

    private let media: [Section]
    private let statsProvider: (() -> AetherAdvancedStats?)?
    private let scrollView = UIScrollView()
    private var columns: [DetailsColumnView] = []
    private var shownSections: [Section] = []
    /// Stats value labels by "SECTION/label", rewritten in place each tick.
    private var statLabels: [String: UILabel] = [:]
    private var focusedColumn = 0
    private var tick: Timer?

    init(media: [Section], statsProvider: (() -> AetherAdvancedStats?)?) {
        self.media = media
        self.statsProvider = statsProvider
        super.init(frame: .zero)
        let glass = makePaneGlass(cornerRadius: Metrics.radius)
        scrollView.isScrollEnabled = false
        scrollView.clipsToBounds = true
        scrollView.showsHorizontalScrollIndicator = false
        [glass, scrollView].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.height),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { tick?.invalidate() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        tick?.invalidate()
        tick = nil
        guard window != nil, statsProvider != nil else { return }
        // `.common`, so the tick keeps running while focus scrolls the box.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStats() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        columns.isEmpty ? [] : [columns[min(focusedColumn, columns.count - 1)]]
    }

    // MARK: Content

    private var currentStats: [Section] {
        statsProvider.map { Self.statsSections($0() ?? AetherAdvancedStats()) } ?? []
    }

    private func refreshStats() {
        let stats = currentStats
        let shape = stats.map { ($0.title, $0.rows.map(\.label)) }
        let shownShape = shownSections.filter { !media.contains($0) }.map { ($0.title, $0.rows.map(\.label)) }
        guard shape.elementsEqual(shownShape, by: { $0.0 == $1.0 && $0.1 == $1.1 }) else {
            return rebuild()
        }
        for section in stats {
            for row in section.rows {
                guard let label = statLabels["\(section.title)/\(row.label ?? "")"] else { continue }
                let text = PlayerInfoSheetStyle.infoRowText(row.label ?? "", row.value)
                guard label.attributedText?.string != text.string else { continue }
                label.attributedText = text
            }
        }
    }

    /// Lays the sections into columns: a section starts a new column unless it
    /// fits whole under the one before; one taller than a column runs on into
    /// the next, rows aligned and the header's rule stretched across both.
    private func rebuild() {
        let hadFocus = columns.contains { $0.isFocused }
        columns.forEach { $0.removeFromSuperview() }
        columns = []
        statLabels = [:]
        // Live stats follow AUDIO; FILE and the engine internals come last.
        let stats = currentStats
        let engine = stats.filter { $0.title == "ENGINE" }
        let file = media.filter { $0.title == "FILE" }
        shownSections = media.filter { !file.contains($0) } + stats.filter { !engine.contains($0) } + file + engine

        var column = DetailsColumnView()
        var y: CGFloat = 0
        func closeColumn() {
            columns.append(column)
            column = DetailsColumnView()
            y = 0
        }
        func height(of view: UIView) -> CGFloat {
            if let label = view as? UILabel {
                return ceil(label.sizeThatFits(CGSize(width: Metrics.columnWidth, height: .greatestFiniteMagnitude)).height)
            }
            return view.systemLayoutSizeFitting(CGSize(width: Metrics.columnWidth, height: 0),
                                         withHorizontalFittingPriority: .required,
                                         verticalFittingPriority: .fittingSizeLevel).height
        }
        func place(_ view: UIView, height: CGFloat) {
            view.frame = CGRect(x: 0, y: y, width: Metrics.columnWidth, height: height)
            column.content.addSubview(view)
            y += height
        }

        for section in shownSections {
            let isStats = !media.contains(section)
            let header = PlayerInfoSheetStyle.sectionLabel(section.title)
            let rows = section.rows.map { row -> UILabel in
                let label = row.label.map { PlayerInfoSheetStyle.infoRow($0, row.value) }
                    ?? PlayerInfoSheetStyle.bodyLabel(row.value, secondary: false)
                label.numberOfLines = isStats ? 1 : 2
                if isStats { statLabels["\(section.title)/\(row.label ?? "")"] = label }
                return label
            }
            let headerHeight = height(of: header)
            let rowHeights = rows.map(height(of:))
            let sectionHeight = headerHeight + Metrics.headerGap + rowHeights.reduce(0, +)
                + Metrics.rowGap * CGFloat(max(rows.count - 1, 0))
            if y > 0 {
                if y + Metrics.sectionGap + sectionHeight > Metrics.columnHeight { closeColumn() } else { y += Metrics.sectionGap }
            }
            let headerColumn = columns.count
            place(header, height: headerHeight)
            y += Metrics.headerGap
            let rowTop = y
            for (rowIndex, row) in rows.enumerated() {
                if rowIndex > 0 {
                    if y + Metrics.rowGap + rowHeights[rowIndex] > Metrics.columnHeight {
                        closeColumn()
                        y = rowTop
                    } else {
                        y += Metrics.rowGap
                    }
                }
                place(row, height: rowHeights[rowIndex])
            }
            let spanned = CGFloat(columns.count - headerColumn)
            header.frame.size.width += spanned * (Metrics.columnWidth + Metrics.columnGap)
        }
        if !column.content.subviews.isEmpty { columns.append(column) }

        for (index, column) in columns.enumerated() {
            column.frame = CGRect(
                x: Metrics.sideInset + CGFloat(index) * (Metrics.columnWidth + Metrics.columnGap),
                y: Metrics.columnTop, width: Metrics.columnWidth, height: Metrics.columnHeight)
            column.onFocus = { [weak self] in self?.focus(columnAt: index) }
            scrollView.addSubview(column)
        }
        scrollView.contentSize = CGSize(
            width: Metrics.sideInset * 2 + CGFloat(columns.count) * (Metrics.columnWidth + Metrics.columnGap) - Metrics.columnGap,
            height: Metrics.height)
        if hadFocus {
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
    }

    /// Keeps the focused column on screen with the least travel.
    private func focus(columnAt index: Int) {
        focusedColumn = index
        guard columns.indices.contains(index) else { return }
        let frame = columns[index].frame
        let visible = scrollView.bounds.width
        var x = scrollView.contentOffset.x
        if frame.maxX + Metrics.sideInset > x + visible { x = frame.maxX + Metrics.sideInset - visible }
        if frame.minX - Metrics.sideInset < x { x = frame.minX - Metrics.sideInset }
        x = min(max(0, x), max(0, scrollView.contentSize.width - visible))
        guard x != scrollView.contentOffset.x else { return }
        UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.scrollView.contentOffset.x = x
        }
    }

    // MARK: Section builders

    static func mediaSections(metadata: PlexMetadata, modes: StreamingModeInfo,
                              dolbyVision: DolbyVisionPlayback? = nil,
                              enhancementLayer: DolbyVisionEnhancementLayer? = nil,
                              enhanceDialogue: String? = nil) -> [Section] {
        let media = metadata.Media?.first
        let streams = media?.Part?.first?.Stream ?? []
        var sections: [Section] = []

        var video = [Row(label: "Mode", value: modes.video.rawValue)]
        if let stream = streams.first(where: { $0.isVideo }) {
            if let title = stream.displayTitle ?? stream.extendedDisplayTitle {
                video.append(Row(label: "Format", value: title))
            }
            if stream.isDolbyVision {
                var profile = "Profile \(stream.DOVIProfile ?? 0)"
                if let compat = stream.DOVIBLCompatID { profile += " (CompatID \(compat))" }
                video.append(Row(label: "Dolby Vision", value: profile))
                if let enhancementLayer { video.append(Row(label: "Enhancement Layer", value: enhancementLayer.rawValue)) }
                if let dolbyVision { video.append(Row(label: "Playing As", value: dolbyVision.rawValue)) }
            } else if stream.isHDR {
                video.append(Row(label: "HDR", value: "HDR10"))
            }
            let color = [stream.bitDepth.map { "\($0)-bit" }, stream.colorSpace].compactMap { $0 }
            if !color.isEmpty { video.append(Row(label: "Color", value: color.joined(separator: " · "))) }
        } else if let media {
            if let codec = media.videoCodec { video.append(Row(label: "Codec", value: codec.uppercased())) }
            if let resolution = media.videoResolution { video.append(Row(label: "Resolution", value: resolution)) }
        }
        if let media {
            if let width = media.width, let height = media.height {
                video.append(Row(label: "Dimensions", value: "\(width) × \(height)"))
            }
            if let frameRate = media.videoFrameRate { video.append(Row(label: "Frame Rate", value: frameRate)) }
            // Plex reports kbps; the formatter takes bits/sec.
            if let bitrate = media.bitrate {
                video.append(Row(label: "Bitrate", value: PlayerInfoSheetStyle.bitrate(bitrate * 1000)))
            }
        }
        sections.append(Section(title: "VIDEO", rows: video))

        let audio = streams.filter { $0.isAudio }
        if !audio.isEmpty {
            var rows = [Row(label: "Mode", value: modes.audio.rawValue)]
            if let enhanceDialogue { rows.append(Row(label: "Enhance Dialogue", value: enhanceDialogue)) }
            for (index, stream) in audio.enumerated() { rows.append(audioRow(stream, index: index)) }
            sections.append(Section(title: "AUDIO", rows: rows))
        }

        if let part = media?.Part?.first {
            var rows: [Row] = []
            if let path = part.file { rows.append(Row(label: "Name", value: (path as NSString).lastPathComponent)) }
            if let container = part.container ?? media?.container { rows.append(Row(label: "Container", value: container.uppercased())) }
            if let size = part.size { rows.append(Row(label: "Size", value: PlayerInfoSheetStyle.fileSize(Int64(size)))) }
            if let duration = metadata.duration ?? part.duration {
                rows.append(Row(label: "Duration", value: PlayerInfoSheetStyle.duration(duration)))
            }
            if !rows.isEmpty { sections.append(Section(title: "FILE", rows: rows)) }
        }
        return sections
    }

    /// "English: TrueHD 7.1 Atmos · 4.5 Mbps": parsed fields only, never the track's title.
    static func audioRow(_ stream: PlexStream, index: Int) -> Row {
        let track = MediaTrack(from: stream)
        var parts = [stream.codec == nil ? nil : track.audioFormat, track.audioRole]
        if let bitrate = stream.bitrate, bitrate > 0 { parts.append(PlayerInfoSheetStyle.bitrate(bitrate * 1000)) }
        let value = parts.compactMap { $0 }.joined(separator: " · ")
        return Row(label: stream.language ?? "Track \(index + 1)",
                   value: value.isEmpty ? "Unknown" : value)
    }

    private typealias StatRow = (title: String, value: (AetherAdvancedStats) -> String?)

    private static let statSpecs: [(name: String, rows: [StatRow])] = [
        // One column: frame rate and dropped frames share a row to fit.
        ("DECODE / STREAM", [
            ("Backend", { $0.backend }),
            ("Bitrate", { $0.instantBitrateMbps.map(PlayerInfoSheetStyle.mbps) }),
            ("Avg Bitrate", { $0.averageBitrateMbps.map(PlayerInfoSheetStyle.mbps) }),
            ("Frames", { stats in
                let parts = [stats.observedFps.map(PlayerInfoSheetStyle.fps), stats.droppedFrameCount.map { "\($0) dropped" }]
                    .compactMap { $0 }
                return parts.isEmpty ? nil : parts.joined(separator: " · ")
            }),
            ("Audio Bridge", { $0.audioBridge }),
            ("Audio Delivery", { $0.audioDelivery }),
            ("Audio Bitrate", { $0.audioBridgeBitrateMbps.map(PlayerInfoSheetStyle.mbps) }),
        ]),
        ("BUFFER / NETWORK", [
            ("Buffer", { $0.forwardBufferSeconds.map(PlayerInfoSheetStyle.bufferSeconds) }),
            ("Cached", { $0.cachedBytes.map(PlayerInfoSheetStyle.fileSize) }),
            ("Throughput", { $0.networkThroughputMbps.map(PlayerInfoSheetStyle.mbps) }),
            ("Transferred", { $0.networkTransferredBytes.map(PlayerInfoSheetStyle.fileSize) }),
            ("A/V Sync", { $0.avSyncGapMs.map(PlayerInfoSheetStyle.milliseconds) }),
        ]),
        ("ENGINE", [
            ("Producer Restarts", { $0.producerRestartCount.map { "\($0)" } }),
            ("Muxed", { $0.muxedBytesLifetime.map(PlayerInfoSheetStyle.fileSize) }),
            ("Server Sent", { $0.serverBytesSentLifetime.map(PlayerInfoSheetStyle.fileSize) }),
            ("Server Requests", { $0.serverRequestCount.map { "\($0)" } }),
            ("Demuxer Fetched", { $0.demuxerBytesFetched.map(PlayerInfoSheetStyle.fileSize) }),
            ("Audio Bridge Bytes", { $0.audioBridgeLiveBytes.map { PlayerInfoSheetStyle.fileSize(Int64($0)) } }),
            ("Memory", { $0.rssMb.map { "\($0) MB" } }),
        ]),
    ]

    /// The engine's live stats, keeping only the fields this session reports.
    static func statsSections(_ stats: AetherAdvancedStats) -> [Section] {
        statSpecs.compactMap { spec in
            let rows = spec.rows.compactMap { row in row.value(stats).map { Row(label: row.title, value: $0) } }
            return rows.isEmpty ? nil : Section(title: spec.name, rows: rows)
        }
    }
}

/// One column of the Details box: a focus stop that lights a plate behind it.
private final class DetailsColumnView: UIView {
    let content = UIView()
    private let plate = UIView()
    var onFocus: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        plate.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        plate.layer.cornerRadius = 24
        plate.layer.cornerCurve = .continuous
        plate.alpha = 0
        plate.isUserInteractionEnabled = false
        addSubview(plate)
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        content.frame = bounds
        plate.frame = bounds.insetBy(dx: -16, dy: -12)
    }

    override var canBecomeFocused: Bool { true }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        if focused { onFocus?() }
        coordinator.animateFocusChange(gained: focused) { self.plate.alpha = focused ? 1 : 0 }
    }
}
