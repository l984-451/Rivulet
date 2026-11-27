// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  A capsule season pill for the below-fold's season row.

import UIKit

final class SeasonPillView: UIControl {

    private let capsuleBackground = UIView()
    private let label = UILabel()
    private var isSelectedSeason = false
    private var isFocusedPill = false

    /// Invoked when this pill takes focus. The host scrolls the rail to the
    /// season from here: moving across the pills live-scrolls the episodes, so
    /// the focused pill IS the current season.
    var onFocused: (() -> Void)?
    /// Invoked when this pill is pressed/selected. Focus already switched the
    /// season, so Select opens that season's own detail page. Where the host
    /// leaves that unwired it falls back to re-affirming the season in the rail.
    var onSelected: (() -> Void)?

    /// The host enables the selected pill for entry, then all pills while navigating the row.
    var focusEnabled = false
    override var canBecomeFocused: Bool { focusEnabled }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations { [weak self] in self?.setFocused(focused) }
        if focused { onFocused?() }
    }

    // Select never fires primaryActionTriggered on a plain UIControl on tvOS; own both phases.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { return }
        super.pressesBegan(presses, with: event)
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) {
            onSelected?()
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SeasonPillView is not Storyboard-backed") }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false

        capsuleBackground.isUserInteractionEnabled = false
        capsuleBackground.layer.cornerCurve = .continuous
        capsuleBackground.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(capsuleBackground)

        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            // Capsule padding. The capsule's LEFT edge sits on the shared content
            // edge (the row leading); the text is naturally indented inside it.
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Measured on device (tvOS 27): 66 tall, radius 33.
            heightAnchor.constraint(equalToConstant: 66),
        ])
        applyStyle()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        capsuleBackground.bounds = CGRect(origin: .zero, size: bounds.size)
        capsuleBackground.center = CGPoint(x: bounds.midX, y: bounds.midY)
        capsuleBackground.layer.cornerRadius = bounds.height / 2
        updateTransforms()
    }

    func configure(label text: String, isSelected: Bool) {
        label.text = text
        isSelectedSeason = isSelected
        applyStyle()
    }

    func setSelected(_ selected: Bool) {
        guard isSelectedSeason != selected else { return }
        isSelectedSeason = selected
        applyStyle()
    }

    func setFocused(_ focused: Bool) {
        let rowPills = superview?.subviews.compactMap { $0 as? SeasonPillView } ?? [self]
        if focused {
            for pill in rowPills where pill !== self {
                pill.isFocusedPill = false
                pill.updateTransforms()
            }
        }
        isFocusedPill = focused
        updateTransforms()
        let rowHasFocus = rowPills.contains { $0.isFocusedPill }
        for pill in rowPills {
            pill.applyStyle(anotherPillFocused: rowHasFocus && !pill.isFocusedPill)
        }
    }

    private func updateTransforms() {
        let widthScale = isFocusedPill && bounds.width > 0 ? (bounds.width + 8) / bounds.width : 1
        let heightScale = isFocusedPill && bounds.height > 0 ? (bounds.height + 8) / bounds.height : 1
        capsuleBackground.transform = CGAffineTransform(scaleX: widthScale, y: heightScale)
        label.transform = CGAffineTransform(scaleX: widthScale, y: widthScale)
    }

    private func applyStyle() {
        let anotherPillFocused = superview?.subviews.contains {
            guard let pill = $0 as? SeasonPillView else { return false }
            return pill !== self && pill.isFocusedPill
        } ?? false
        applyStyle(anotherPillFocused: anotherPillFocused)
    }

    private func applyStyle(anotherPillFocused: Bool) {
        // Matches the ATV+ reference: the active season is a bright frosted
        // capsule even when focus is currently on an episode. Focus can scale
        // that same capsule, but selection owns the visible chip.
        label.font = .systemFont(ofSize: 29, weight: (isFocusedPill || isSelectedSeason) ? .semibold : .medium)

        let fill: UIColor
        let textColor: UIColor
        if isFocusedPill {
            fill = UIColor.white.withAlphaComponent(0.88)
            textColor = .black
        } else if isSelectedSeason && !anotherPillFocused {
            // Selected but unfocused: translucent grey, white text.
            fill = UIColor.white.withAlphaComponent(0.35)
            textColor = .white
        } else {
            fill = .clear
            textColor = UIColor.white.withAlphaComponent(0.52)
        }
        capsuleBackground.backgroundColor = fill
        label.textColor = textColor
    }

    /// The pill's season label.
    static func seasonLabel(for season: MediaItem) -> String {
        if let n = season.seasonNumber {
            return n == 0 ? String(localized: "Specials") : String(localized: "Season \(n)")
        }
        return season.title
    }
}
