// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Long-press action menu for poster tiles: a glass panel at the pressed tile over a dimmed backdrop.
// Hand-built because UIKit context menus never engage on tvOS 26; driven by `TileLongPress`.
// Each row owns Select through a press-typed tap (a bare control's primaryAction misses Select).

import UIKit

/// One tappable entry in the tile long-press menu. Plain data + closure —
/// deliberately not UIAction, whose handler cannot be invoked publicly.
struct TileMenuAction {
    let title: String
    let systemImage: String
    var destructive: Bool = false
    let handler: () -> Void
}

/// What a menu is about, shown above its actions: the programme a Live TV
/// menu acts on, with its time and a few lines of description. Optional; tile
/// menus leave it out.
struct TileMenuHeader {
    let title: String
    var detail: String? = nil
    var summary: String? = nil
}

/// Installs the select long-press that opens tile menus. One shared
/// permissive delegate: the recognizer must be allowed to run alongside
/// the collection view's own press recognizers or the system's
/// select-press recognition forces it to fail before it can begin.
@MainActor
enum TileLongPress {
    static let minimumPressDuration: TimeInterval = 0.6

    private final class SimultaneousDelegate: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }

    private static let sharedDelegate = SimultaneousDelegate()

    static func makeRecognizer(target: Any?, action: Selector) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer(target: target, action: action)
        recognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        recognizer.minimumPressDuration = minimumPressDuration
        recognizer.delegate = sharedDelegate
        return recognizer
    }

    /// Select for a view that also opens a menu on hold: fires on release, and
    /// never once `longPress` has claimed the press.
    static func makeSelectTap(target: Any?, action: Selector,
                              yieldingTo longPress: UILongPressGestureRecognizer) -> UITapGestureRecognizer {
        let tap = UITapGestureRecognizer(target: target, action: action)
        tap.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        tap.cancelsTouchesInView = false
        tap.delegate = sharedDelegate
        tap.require(toFail: longPress)
        return tap
    }

    /// The collection-view cell that currently has focus, resolved from the
    /// engine's focused view (focus can sit on the cell or a subview).
    /// Not `UIScreen.focusedView`: this app's focus is scene-based, and that
    /// accessor raises an assertion (crashed Live TV Browse's `viewWillAppear`).
    static func focusedCell(in collectionView: UICollectionView) -> IndexPath? {
        var view = UIFocusSystem.focusSystem(for: collectionView)?.focusedItem as? UIView
        while let current = view {
            if let cell = current as? UICollectionViewCell,
               let indexPath = collectionView.indexPath(for: cell) {
                return indexPath
            }
            view = current.superview
        }
        return nil
    }
}

final class TileMenuPopupViewController: UIViewController {

    /// Action groups, with a hairline divider between groups.
    private let sections: [[TileMenuAction]]
    private let header: TileMenuHeader?
    /// The pressed tile's frame in window coordinates. The popup is
    /// full-screen, so window coords map 1:1 onto its view. The panel
    /// top-aligns with the tile and sits beside it.
    private let sourceFrame: CGRect?
    private var firstRow: MenuRowButton?
    private var panel: UIVisualEffectView!
    /// The dim the backdrop animates to.
    private let dimColor = UIColor.black.withAlphaComponent(0.55)
    private var isDismissing = false

    /// Present with `animated: false` — entrance/exit run in-controller so
    /// the panel can grow from / shrink to the tile's corner.
    init(sections: [[TileMenuAction]], sourceFrame: CGRect? = nil, header: TileMenuHeader? = nil) {
        self.sections = sections.filter { !$0.isEmpty }
        self.header = header
        self.sourceFrame = sourceFrame
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Layout constants, matched against a screenshot of the system menu
    // (1920x1080), tvOS 27: 66pt row pitch, hairline group dividers, glass panel
    // with 16pt content inset, panel corner 50.
    private let rowHeight: CGFloat = 66
    private let panelInset: CGFloat = 16
    private let dividerVerticalPad: CGFloat = 8

    override func viewDidLoad() {
        super.viewDidLoad()

        // The system menu dims the UI behind the panel; content stays
        // visible (no blur). Starts clear; the entrance animates it in.
        view.backgroundColor = .clear

        var arranged: [UIView] = []
        let headerView = header.map(Self.makeHeaderView)
        if let headerView {
            arranged.append(headerView)
            if !sections.isEmpty { arranged.append(DividerView()) }
        }
        for (sectionIndex, section) in sections.enumerated() {
            if sectionIndex > 0 {
                arranged.append(DividerView())
            }
            for action in section {
                let row = MenuRowButton(action: action) { [weak self] handler in
                    self?.animateOut { handler() }
                }
                if firstRow == nil { firstRow = row }
                arranged.append(row)
            }
        }

        let stack = UIStackView(arrangedSubviews: arranged)
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let effect: UIVisualEffect
        if #available(tvOS 26.0, *) { effect = UIGlassEffect() }
        else { effect = UIBlurEffect(style: .regular) }
        panel = UIVisualEffectView(effect: effect)
        panel.layer.cornerRadius = 50
        panel.layer.cornerCurve = .continuous
        panel.clipsToBounds = true
        panel.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: panelInset),
            stack.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: panelInset),
            stack.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -panelInset),
            stack.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -panelInset),
        ])

        // Panel size: rows + dividers, wide enough for the longest title. A
        // header asks for a wider panel so its description reads as prose.
        let actionCount = sections.reduce(0) { $0 + $1.count }
        let dividerCount = max(0, sections.count - 1) + (headerView != nil && !sections.isEmpty ? 1 : 0)
        let minimumWidth: CGFloat = headerView == nil ? 440 : 620
        let panelWidth = min(max(Self.widestRowWidth(for: sections) + panelInset * 2, minimumWidth), 680)
        var headerHeight: CGFloat = 0
        if let headerView {
            headerHeight = ceil(headerView.systemLayoutSizeFitting(
                CGSize(width: panelWidth - panelInset * 2, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height)
        }
        let panelHeight = CGFloat(actionCount) * rowHeight
            + CGFloat(dividerCount) * (1 + dividerVerticalPad * 2)
            + headerHeight
            + panelInset * 2

        // Beside the tile, top edges aligned: right of it when there's
        // room, else left. Clamped into the overscan-safe region.
        let safe = view.bounds.insetBy(dx: 80, dy: 50)
        let gap: CGFloat = 16
        var origin: CGPoint
        var growsFromLeftEdge = true  // panel's tile-adjacent top corner
        if let sourceFrame {
            origin = CGPoint(x: sourceFrame.maxX + gap, y: sourceFrame.minY)
            if origin.x + panelWidth > safe.maxX {
                origin.x = sourceFrame.minX - gap - panelWidth
                growsFromLeftEdge = false
            }
        } else {
            origin = CGPoint(x: view.bounds.midX - panelWidth / 2,
                             y: view.bounds.midY - panelHeight / 2)
        }
        origin.x = min(max(origin.x, safe.minX), safe.maxX - panelWidth)
        origin.y = min(max(origin.y, safe.minY), safe.maxY - panelHeight)
        panel.frame = CGRect(origin: origin, size: CGSize(width: panelWidth, height: panelHeight))
        view.addSubview(panel)

        // The system menu grows out of the tile's top corner and shrinks
        // back into it. Anchor the scale at the panel's tile-adjacent top
        // corner (re-deriving position so the frame stays put).
        let anchor = CGPoint(x: growsFromLeftEdge ? 0 : 1, y: 0)
        let frame = panel.frame
        panel.layer.anchorPoint = anchor
        panel.layer.position = CGPoint(x: frame.minX + frame.width * anchor.x,
                                       y: frame.minY + frame.height * anchor.y)

        // Entrance start state; animated in viewDidAppear.
        panel.transform = CGAffineTransform(scaleX: 0.02, y: 0.02)
        panel.alpha = 0

        // Menu cancels (rows own Select via their own recognizers).
        let menuTap = UITapGestureRecognizer(target: self, action: #selector(menuPressed))
        menuTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        view.addGestureRecognizer(menuTap)
    }

    /// Title, a detail line, and up to four lines of summary, inset to line up
    /// with the row titles below.
    private static func makeHeaderView(_ header: TileMenuHeader) -> UIView {
        let title = UILabel()
        title.text = header.title
        title.font = .systemFont(ofSize: 32, weight: .bold)
        title.textColor = .white
        title.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [title])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .fill

        if let detail = header.detail, !detail.isEmpty {
            let label = UILabel()
            label.text = detail
            label.font = .systemFont(ofSize: 22, weight: .medium)
            label.textColor = UIColor.white.withAlphaComponent(0.65)
            label.numberOfLines = 2
            stack.addArrangedSubview(label)
        }
        if let summary = header.summary, !summary.isEmpty {
            let label = UILabel()
            label.text = summary
            label.font = .systemFont(ofSize: 21, weight: .regular)
            label.textColor = UIColor.white.withAlphaComponent(0.8)
            label.numberOfLines = 4
            stack.setCustomSpacing(14, after: stack.arrangedSubviews.last ?? title)
            stack.addArrangedSubview(label)
        }

        let container = UIView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -26),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        return container
    }

    private static func widestRowWidth(for sections: [[TileMenuAction]]) -> CGFloat {
        let font = MenuRowButton.titleFont
        var widest: CGFloat = 0
        for action in sections.joined() {
            let text = (action.title as NSString).size(withAttributes: [.font: font]).width
            widest = max(widest, MenuRowButton.contentWidth(forTitleWidth: text))
        }
        return ceil(widest)
    }

    @objc private func menuPressed() { animateOut() }

    /// Shrink back into the tile's corner, then tear down. `completion`
    /// runs after the dismissal (action handlers).
    private func animateOut(completion: (() -> Void)? = nil) {
        guard !isDismissing else { return }
        isDismissing = true
        let exit = UIViewPropertyAnimator(duration: 0.22, curve: .easeIn) {
            self.panel.transform = CGAffineTransform(scaleX: 0.02, y: 0.02)
            self.panel.alpha = 0
            self.view.backgroundColor = .clear
        }
        exit.addCompletion { _ in
            self.dismiss(animated: false) { completion?() }
        }
        exit.startAnimation()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [firstRow].compactMap { $0 }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Grow out of the tile's corner (the anchor set in viewDidLoad).
        let entrance = UIViewPropertyAnimator(duration: 0.42, dampingRatio: 0.82) {
            self.panel.transform = .identity
            self.view.backgroundColor = self.dimColor
        }
        // The panel fades in faster than it grows, like the system menu.
        UIViewPropertyAnimator(duration: 0.15, curve: .easeOut) {
            self.panel.alpha = 1
        }.startAnimation()
        entrance.startAnimation()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }
}

// MARK: - Divider

/// Hairline group separator, inset like the system menu's.
private final class DividerView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        let line = UIView()
        line.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 1 + 8 * 2),
            line.heightAnchor.constraint(equalToConstant: 1),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Focusable action row

/// A focusable action row matching the system context menu's: SF-symbol
/// glyph leading, then the title. Focused = white capsule with dark
/// content (red capsule for destructive); unfocused = transparent on the
/// glass with white (red for destructive) content.
private final class MenuRowButton: UIView {

    static let titleFont = UIFont.systemFont(ofSize: 26, weight: .medium)

    private static let leadingPad: CGFloat = 26
    private static let iconWidth: CGFloat = 40
    private static let iconTitleGap: CGFloat = 14
    private static let trailingPad: CGFloat = 30

    static func contentWidth(forTitleWidth titleWidth: CGFloat) -> CGFloat {
        leadingPad + iconWidth + iconTitleGap + titleWidth + trailingPad
    }

    private static let highlightHeight: CGFloat = 74
    private let highlight = UIView()
    private let iconView = UIImageView()
    private let labelView = UILabel()
    private let destructive: Bool
    private let onPress: (@escaping () -> Void) -> Void
    private let handler: () -> Void

    override var canBecomeFocused: Bool { true }

    init(action: TileMenuAction, onPress: @escaping (@escaping () -> Void) -> Void) {
        self.destructive = action.destructive
        self.onPress = onPress
        self.handler = action.handler
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // The focus capsule is 74pt tall, taller than the 66pt row pitch.
        highlight.layer.cornerRadius = Self.highlightHeight / 2
        highlight.layer.cornerCurve = .continuous
        highlight.translatesAutoresizingMaskIntoConstraints = false
        highlight.isUserInteractionEnabled = false
        addSubview(highlight)

        iconView.image = UIImage(systemName: action.systemImage)
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        labelView.text = action.title
        labelView.font = Self.titleFont
        labelView.textAlignment = .left
        labelView.numberOfLines = 1
        labelView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelView)

        applyUnfocusedAppearance()

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 66),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            highlight.centerYAnchor.constraint(equalTo: centerYAnchor),
            highlight.heightAnchor.constraint(equalToConstant: Self.highlightHeight),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingPad),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconWidth),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelView.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Self.iconTitleGap),
            labelView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.trailingPad),
            labelView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(pressed))
        tap.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        addGestureRecognizer(tap)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { onPress(handler) }

    private func applyUnfocusedAppearance() {
        highlight.backgroundColor = .clear
        let content: UIColor = destructive ? .systemRed : .white
        labelView.textColor = content
        iconView.tintColor = content
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        let focused = context.nextFocusedView === self
        coordinator.animateFocusChange(gained: focused) {
            if focused {
                self.highlight.backgroundColor = self.destructive ? .systemRed : .white
                self.labelView.textColor = self.destructive ? .white : .black
                self.iconView.tintColor = self.destructive ? .white : .black
            } else {
                self.applyUnfocusedAppearance()
            }
        }
    }
}
