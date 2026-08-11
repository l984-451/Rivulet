// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SeasonPillView.swift
//  Rivulet
//
//  A capsule season selector pill. The below-fold hosts a horizontal row of
//  these, driven by its data + focus.
//
//  Faithful to source: label 24pt (semibold when selected, regular otherwise),
//  black-on-white when focused, capsule fill white(focused) /
//  white-0.2(selected) / clear, a white-0.4 border when selected-not-focused,
//  20/10 padding, 1.05 focus scale.
//

import UIKit

final class SeasonPillView: UIControl {

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

    /// Host-controlled focusability. Pills are focusable ONLY while the user is
    /// in the pill row (detailsFocusTarget == .pills). When focus is on the
    /// episodes the pills are NOT focusable, so the focus engine's spatial Up
    /// move finds no pill to grab — the host then routes focus straight to the
    /// SELECTED season's pill with no intermediate wrong-pill landing.
    var focusEnabled = false
    override var canBecomeFocused: Bool { focusEnabled }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations { [weak self] in self?.setFocused(focused) }
        if focused { onFocused?() }
    }

    // Select does not fire .primaryActionTriggered on a plain UIControl on
    // tvOS, so the wired target never ran and pill Select has never fired.
    // Consume the press in BOTH began/ended so the focused pill owns the cycle
    // (mirrors AboutCardControl, a UIControl in this same directory).
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
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.clear.cgColor

        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            // Capsule padding. The capsule's LEFT edge sits on the shared content
            // edge (the row leading); the text is naturally indented inside it.
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        applyStyle()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Capsule: corner radius = half the height.
        layer.cornerRadius = bounds.height / 2
    }

    func configure(label text: String, isSelected: Bool) {
        label.text = text
        isSelectedSeason = isSelected
        applyStyle()
    }

    /// Selection is independent of focus (spike: selected = white-0.2 fill +
    /// border; focused = white fill, black text). The host updates selection
    /// when the user picks a season / scrolls across a season boundary.
    func setSelected(_ selected: Bool) {
        guard isSelectedSeason != selected else { return }
        isSelectedSeason = selected
        applyStyle()
    }

    /// Driven by the host's focus engine once wired.
    func setFocused(_ focused: Bool) {
        isFocusedPill = focused
        applyStyle()
        transform = focused ? CGAffineTransform(scaleX: 1.05, y: 1.05) : .identity
    }

    private func applyStyle() {
        // Matches the ATV+ reference: the active season is a bright frosted
        // capsule even when focus is currently on an episode. Focus can scale
        // that same capsule, but selection owns the visible chip.
        label.font = .systemFont(ofSize: 31, weight: (isFocusedPill || isSelectedSeason) ? .semibold : .medium)

        let fill: UIColor
        let textColor: UIColor
        if isFocusedPill || isSelectedSeason {
            fill = UIColor.white.withAlphaComponent(0.88)
            textColor = .black
        } else {
            fill = .clear
            textColor = UIColor.white.withAlphaComponent(0.72)
        }
        backgroundColor = fill
        label.textColor = textColor
        layer.borderWidth = 0
    }

    /// Season label mirroring SwiftUI `SeasonPillBar.seasonLabel(for:)`.
    static func seasonLabel(for season: MediaItem) -> String {
        if let n = season.seasonNumber {
            return n == 0 ? "Specials" : "Season \(n)"
        }
        return season.title
    }
}
