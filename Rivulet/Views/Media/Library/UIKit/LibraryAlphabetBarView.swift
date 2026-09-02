// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LibraryAlphabetBarView.swift
//  Rivulet
//
//  The A–Z strip on the library grid's right margin (issue #308). Focusing a
//  letter jumps the grid to it. Each letter is a plain focusable view, so
//  Up/Down walks the strip and Right from the last grid column enters it, on
//  every remote type. The owner shows it only while focus is in the grid and
//  draws the large letter indicator itself.
//
//  This view is exactly the strip's column, nothing wider. The focus engine's
//  occlusion test is geometric, not hit-test based: a transparent full-bleed
//  view above the grid made every tile "visually occluded" and unfocusable
//  (UIFocusDebugger said so), which no hitTest override can undo.
//

import UIKit

final class LibraryAlphabetBarView: UIView {
    /// Index (into the letters passed to `setLetters`) of the letter that
    /// just took focus.
    var onLetterFocused: ((Int) -> Void)?
    /// Select or Left on a letter: the owner hands focus back to the grid.
    /// Left is handled here, not by the engine: from a letter the engine's
    /// own Left search picks the shell's edge catcher over every grid tile.
    var onLetterSelected: (() -> Void)?
    /// Fires when focus enters or leaves the strip.
    var onFocusContainmentChanged: ((Bool) -> Void)?

    /// The letter covering the focused grid tile. Drawn bright in the strip
    /// so the strip always says where you are, and the one Right from the
    /// grid lands on: while focus is outside the strip only this letter is
    /// focusable, so a directional entry cannot land on whichever letter is
    /// geometrically nearest and jump the grid somewhere unrelated. Once
    /// inside, every letter is focusable. (Container `preferredFocusEnvironments`
    /// is ignored by directional searches; gating `canBecomeFocused` is not.)
    var entryIndex: Int? {
        didSet {
            for (index, letter) in letterViews.enumerated() { letter.isCurrent = index == entryIndex }
            updateEntryGuide()
        }
    }

    /// Catches Right from the grid anywhere along the strip's height and
    /// hands it to the current letter, so entry never depends on the engine
    /// choosing an off-axis letter by itself. Full height, so it is never an
    /// Up/Down candidate; inert while the strip has focus, so Up/Down inside
    /// it pass straight through.
    private let entryGuide = UIFocusGuide()

    static let width: CGFloat = 44

    private let stack = UIStackView()
    private var stackHeight: NSLayoutConstraint!
    private var letterViews: [LetterView] { stack.arrangedSubviews.compactMap { $0 as? LetterView } }
    private var containsFocus = false
    private static let rowHeight: CGFloat = 34
    /// Keeps a long non-Latin strip inside the title-safe band; rows shrink
    /// to fit rather than run off the screen.
    private static let maxHeight: CGFloat = 920

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addLayoutGuide(entryGuide)
        stackHeight = stack.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stackHeight,
            entryGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            entryGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            entryGuide.topAnchor.constraint(equalTo: topAnchor),
            entryGuide.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateEntryGuide() {
        let target = containsFocus ? nil : entryIndex.flatMap { letterViews[safe: $0] }
        entryGuide.preferredFocusEnvironments = target.map { [$0] } ?? []
    }

    func setLetters(_ letters: [String]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        entryIndex = nil
        for (index, letter) in letters.enumerated() {
            let view = LetterView(letter)
            view.onFocused = { [weak self] in
                guard let self else { return }
                self.entryIndex = index
                self.onLetterFocused?(index)
            }
            view.onSelected = { [weak self] in self?.onLetterSelected?() }
            view.isFocusable = { [weak self] in
                guard let self else { return false }
                return self.containsFocus || self.entryIndex == nil || self.entryIndex == index
            }
            stack.addArrangedSubview(view)
        }
        stackHeight.constant = min(Self.maxHeight, Self.rowHeight * CGFloat(letters.count))
        updateEntryGuide()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let inside = context.nextFocusedView?.isDescendant(of: self) == true
        guard inside != containsFocus else { return }
        containsFocus = inside
        updateEntryGuide()
        onFocusContainmentChanged?(inside)
    }

    private final class LetterView: UIView {
        var onFocused: (() -> Void)?
        var onSelected: (() -> Void)?
        var isFocusable: () -> Bool = { true }
        /// Bright when this letter covers the focused tile, focused or not.
        var isCurrent = false {
            didSet { if !isFocused { label.alpha = isCurrent ? 1 : 0.5 } }
        }
        /// Select / Left are consumed in both phases: an Ended that bubbles
        /// without its Began makes the system apply its own default handling.
        private var handledTypes: Set<UIPress.PressType> = []
        private let label = UILabel()

        init(_ letter: String) {
            super.init(frame: .zero)
            label.text = letter
            label.font = .systemFont(ofSize: 26, weight: .semibold)
            label.textColor = .white
            label.alpha = 0.5
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }

        required init?(coder: NSCoder) { fatalError() }

        override var canBecomeFocused: Bool { isFocusable() }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if let press = presses.first(where: { $0.type == .select || $0.type == .leftArrow }) {
                handledTypes.insert(press.type)
                onSelected?()
                return
            }
            super.pressesBegan(presses, with: event)
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if let press = presses.first(where: { handledTypes.contains($0.type) }) {
                handledTypes.remove(press.type)
                return
            }
            super.pressesEnded(presses, with: event)
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if let press = presses.first(where: { handledTypes.contains($0.type) }) {
                handledTypes.remove(press.type)
                return
            }
            super.pressesCancelled(presses, with: event)
        }

        override func didUpdateFocus(in context: UIFocusUpdateContext,
                                     with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            let focused = context.nextFocusedView === self
            coordinator.addCoordinatedAnimations {
                self.label.alpha = focused || self.isCurrent ? 1 : 0.5
                self.label.transform = focused ? CGAffineTransform(scaleX: 1.35, y: 1.35) : .identity
            }
            if focused { onFocused?() }
        }
    }
}

/// The large letter shown mid-screen while the strip has focus. A separate
/// view, hidden (not faded) before any focus request into the grid: while it
/// is visible it occludes the tiles beneath it for the focus engine.
final class LibraryLetterIndicatorView: UIView {
    private let label = UILabel()

    var letter: String? {
        didSet { label.text = letter }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0, alpha: 0.55)
        layer.cornerRadius = 32
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        isUserInteractionEnabled = false
        isHidden = true
        label.font = .systemFont(ofSize: 140, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        guard isHidden else { return }
        alpha = 0
        isHidden = false
        UIView.animate(withDuration: 0.15) { self.alpha = 1 }
    }

    func hide() {
        isHidden = true
        alpha = 0
    }
}
