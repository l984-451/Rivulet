// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  The app's one Yes/No popup, on `InfoPopupViewController`'s card; `cancelTitle: nil`
//  makes it a one-button notice. Buttons own Select through press recognizers, and Menu cancels.
//  Confirm takes initial focus, or cancel for a destructive prompt. An `alternateTitle` adds a
//  third choice between Cancel and Confirm (the iCloud sign-out question).

import UIKit

final class ConfirmationPopupViewController: UIViewController {

    private let titleText: String
    private let message: String
    private let confirmTitle: String
    private let cancelTitle: String?
    private let alternateTitle: String?
    private let onAlternate: (() -> Void)?
    private let destructive: Bool
    private let cardWidth: CGFloat
    private let onConfirm: () -> Void
    private let onCancel: (() -> Void)?

    private let card = UIView()
    private var confirmButton: PopupPillButton!
    private var cancelButton: PopupPillButton?

    init(title: String,
         message: String,
         confirmTitle: String,
         cancelTitle: String? = String(localized: "Cancel"),
         alternateTitle: String? = nil,
         onAlternate: (() -> Void)? = nil,
         destructive: Bool = false,
         width: CGFloat = 840,
         onConfirm: @escaping () -> Void,
         onCancel: (() -> Void)? = nil) {
        self.titleText = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
        self.alternateTitle = alternateTitle
        self.onAlternate = onAlternate
        self.destructive = destructive
        self.cardWidth = width
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)

        // Prominent Liquid Glass (tvOS 26), falling back to a regular blur —
        // identical to InfoPopupViewController so all popups read as one family.
        let effect: UIVisualEffect
        if #available(tvOS 26.0, *) { effect = UIGlassEffect() }
        else { effect = UIBlurEffect(style: .regular) }
        let blur = UIVisualEffectView(effect: effect)
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 38
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true

        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        card.addSubview(blur)

        let titleLabel = label(titleText, size: 34, weight: .bold, color: .white, lines: 2)
        titleLabel.textAlignment = .center
        let messageLabel = label(message, size: 24, weight: .regular,
                                 color: .white.withAlphaComponent(0.85), lines: 0)
        messageLabel.textAlignment = .center

        confirmButton = PopupPillButton(title: confirmTitle, destructive: destructive) { [weak self] in
            self?.dismiss(animated: true) { self?.onConfirm() }
        }
        cancelButton = cancelTitle.map { title in
            PopupPillButton(title: title, destructive: false) { [weak self] in self?.cancel() }
        }

        let alternateButton = alternateTitle.map { title in
            PopupPillButton(title: title, destructive: false) { [weak self] in
                self?.dismiss(animated: true) { self?.onAlternate?() }
            }
        }

        let buttonRow = UIStackView(arrangedSubviews: [cancelButton, alternateButton, confirmButton].compactMap { $0 })
        buttonRow.axis = .horizontal
        buttonRow.alignment = .center
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 24

        let stack = UIStackView(arrangedSubviews: [titleLabel, messageLabel, buttonRow])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 18
        stack.setCustomSpacing(36, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(stack)

        let pad: CGFloat = PreviewCarouselGeometry.expandedChromeInset
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: cardWidth),

            blur.topAnchor.constraint(equalTo: card.topAnchor),
            blur.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            stack.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: pad),
            stack.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -pad),
            stack.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -pad),

            buttonRow.heightAnchor.constraint(equalToConstant: 72),
        ])

        // Menu cancels (the buttons own Select via their own recognizers).
        let menuTap = UITapGestureRecognizer(target: self, action: #selector(menuPressed))
        menuTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        view.addGestureRecognizer(menuTap)
    }

    @objc private func menuPressed() { cancel() }

    private func cancel() {
        dismiss(animated: true) { [weak self] in self?.onCancel?() }
    }

    // Destructive prompts default focus to Cancel; otherwise to Confirm.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [(destructive ? cancelButton : nil) ?? confirmButton].compactMap { $0 }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func label(_ text: String, size: CGFloat, weight: UIFont.Weight,
                       color: UIColor, lines: Int) -> UILabel {
        let l = UILabel()
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.numberOfLines = lines
        l.text = text
        return l
    }
}

// MARK: - Focusable pill button

/// A focusable pill: bright white + dark text on focus, translucent glass
/// otherwise (destructive turns red on focus). Owns Select via a press-typed
/// tap recognizer, since a bare control's primaryAction doesn't fire on tvOS.
final class PopupPillButton: UIView {

    private let labelView = UILabel()
    private let onPress: () -> Void
    private let destructive: Bool

    override var canBecomeFocused: Bool { true }

    init(title: String, destructive: Bool, onPress: @escaping () -> Void) {
        self.onPress = onPress
        self.destructive = destructive
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 30
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        applyUnfocusedStyle()

        labelView.text = title
        labelView.font = .systemFont(ofSize: 26, weight: .semibold)
        labelView.textColor = .white
        labelView.textAlignment = .center
        labelView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelView)
        NSLayoutConstraint.activate([
            labelView.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            labelView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            labelView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            labelView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -36),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(pressed))
        tap.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        addGestureRecognizer(tap)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { onPress() }

    /// Replaces the label, e.g. with a symbol attachment; it keeps the focus colour.
    func setTitle(_ title: NSAttributedString) { labelView.attributedText = title }

    private func applyUnfocusedStyle() {
        backgroundColor = UIColor.white.withAlphaComponent(0.12)
        layer.borderColor = UIColor.white.withAlphaComponent(0.20).cgColor
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                with coordinator: UIFocusAnimationCoordinator) {
        let focused = context.nextFocusedView === self
        coordinator.animateFocusChange(gained: focused) {
            if focused {
                self.backgroundColor = self.destructive ? .systemRed : .white
                self.labelView.textColor = self.destructive ? .white : .black
                self.layer.borderColor = UIColor.clear.cgColor
                self.transform = CGAffineTransform(scaleX: 1.06, y: 1.06)
            } else {
                self.applyUnfocusedStyle()
                self.labelView.textColor = .white
                self.transform = .identity
            }
        }
    }
}
