// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TextEntryViewController.swift
//  Rivulet
//
//  Text entry for a Settings row: opens the system keyboard at once, as tvOS
//  Settings does, or a page of its own when the field has suggestions. Return
//  or the button calls `onCommit`, Menu calls `onCancel`.
//

import UIKit

@MainActor
final class TextEntryViewController: UIViewController {

    /// Label + value pair for a suggestion pill.
    typealias Suggestion = (label: String, value: String)

    private let titleText: String
    private let message: String?
    private let fieldName: String
    private let initialText: String
    private let suggestions: [Suggestion]
    private let keyboard: UIKeyboardType
    private let isSecure: Bool
    private let contentType: UITextContentType?
    private let submitTitle: String
    private let allowsEmpty: Bool

    /// Final text, on the button / keyboard return only. Never called on cancel.
    private let onCommit: (String) -> Void
    /// Menu: the caller leaves its value unchanged.
    private let onCancel: (() -> Void)?

    private let textField = UITextField()
    private var submitButton: TextEntryPillButton!
    /// No page of its own: the keyboard opens on arrival and closing it leaves.
    private var opensKeyboard: Bool { suggestions.isEmpty }

    /// - Parameters:
    ///   - fieldName: the keyboard's header, so it must name the field
    ///     ("Password"), never show an example value.
    ///   - message: one sentence, Apple's style: what to enter, then "and
    ///     select Continue." Shown above the field.
    ///   - allowsEmpty: an optional field may be committed empty.
    init(title: String,
         message: String? = nil,
         fieldName: String? = nil,
         initialText: String,
         suggestions: [Suggestion] = [],
         keyboardType: UIKeyboardType = .default,
         isSecure: Bool = false,
         contentType: UITextContentType? = nil,
         submitTitle: String = String(localized: "Done"),
         allowsEmpty: Bool = true,
         onCommit: @escaping (String) -> Void,
         onCancel: (() -> Void)? = nil) {
        self.titleText = title
        self.message = message
        self.fieldName = fieldName ?? title
        self.initialText = initialText
        self.suggestions = suggestions
        self.keyboard = keyboardType
        self.isSecure = isSecure
        self.contentType = contentType
        self.submitTitle = submitTitle
        self.allowsEmpty = allowsEmpty
        self.onCommit = onCommit
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        // Full-screen, like the system page: the screen behind is blurred out
        // so nothing competes with the one question being asked. The keyboard
        // brings its own blur.
        if !opensKeyboard {
            let backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
            backdrop.frame = view.bounds
            backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(backdrop)
        }

        let titleLabel = UILabel()
        titleLabel.text = titleText
        titleLabel.font = .systemFont(ofSize: 57, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        var arranged: [UIView] = [titleLabel]
        if let message {
            let messageLabel = UILabel()
            messageLabel.text = message
            messageLabel.font = .systemFont(ofSize: 29, weight: .regular)
            messageLabel.textColor = UIColor.white.withAlphaComponent(0.6)
            messageLabel.textAlignment = .center
            messageLabel.numberOfLines = 0
            arranged.append(messageLabel)
        }

        textField.text = initialText
        textField.placeholder = fieldName
        textField.borderStyle = .roundedRect
        textField.font = .systemFont(ofSize: 38, weight: .regular)
        textField.keyboardType = keyboard
        textField.autocorrectionType = .no
        // Only prose gets a capital: not an address, username, or password.
        textField.autocapitalizationType = (keyboard == .default && contentType == nil) ? .sentences : .none
        textField.isSecureTextEntry = isSecure
        textField.textContentType = contentType
        textField.clearButtonMode = .whileEditing
        textField.returnKeyType = submitTitle == String(localized: "Done") ? .done : .continue
        textField.delegate = self
        textField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        // The keyboard's return button. tvOS sends this, not `textFieldShouldReturn`.
        textField.addTarget(self, action: #selector(returnPressed), for: .editingDidEndOnExit)
        textField.addTarget(self, action: #selector(editingEnded), for: .editingDidEnd)
        // A required field's Done stays off until something is typed.
        textField.enablesReturnKeyAutomatically = !allowsEmpty
        textField.translatesAutoresizingMaskIntoConstraints = false
        arranged.append(textField)

        let stack = UIStackView(arrangedSubviews: arranged)
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 24
        stack.setCustomSpacing(56, after: arranged[arranged.count - 2])

        // Suggestions: a focusable pill per preset, filling the field on Select.
        if !suggestions.isEmpty {
            let pills = suggestions.map { suggestion in
                TextEntryPillButton(title: suggestion.label, prominent: false) { [weak self] in
                    self?.textField.text = suggestion.value
                    self?.textChanged()
                }
            }
            let pillRow = UIStackView(arrangedSubviews: pills)
            pillRow.axis = .horizontal
            pillRow.alignment = .center
            pillRow.distribution = .fillProportionally
            pillRow.spacing = 16
            stack.setCustomSpacing(40, after: textField)
            stack.addArrangedSubview(pillRow)
            pillRow.heightAnchor.constraint(equalToConstant: 64).isActive = true
        }

        submitButton = TextEntryPillButton(title: submitTitle, prominent: true) { [weak self] in
            self?.commit()
        }
        let buttonRow = UIStackView(arrangedSubviews: [submitButton])
        buttonRow.axis = .vertical
        buttonRow.alignment = .center
        stack.setCustomSpacing(56, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 1])
        stack.addArrangedSubview(buttonRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Kept in the hierarchy so the field can take the keyboard, never seen.
        stack.alpha = opensKeyboard ? 0 : 1
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.widthAnchor.constraint(equalToConstant: 1100),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 230),
            textField.heightAnchor.constraint(equalToConstant: 90),
            submitButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            submitButton.heightAnchor.constraint(equalToConstant: 72)
        ])
        textChanged()

        let menuTap = UITapGestureRecognizer(target: self, action: #selector(menuPressed))
        menuTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        view.addGestureRecognizer(menuTap)
    }

    // Focus starts on the field: one Select opens the keyboard. Must run once
    // the view is in the window; an earlier request is a no-op.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [textField]
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if opensKeyboard, !textField.isFirstResponder, !committed {
            textField.becomeFirstResponder()
            return
        }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private var canCommit: Bool {
        allowsEmpty || !(textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A required field's button stays dimmed until something is typed.
    @objc private func textChanged() {
        submitButton.isEnabled = canCommit
    }

    @objc private func menuPressed() { cancel() }

    private var returning = false

    /// Submits once the keyboard has closed, so the next page presents cleanly.
    @objc private func returnPressed() {
        returning = true
        DispatchQueue.main.async { [weak self] in self?.commit() }
    }

    /// Menu on the keyboard: with no page to fall back to, leave.
    @objc private func editingEnded() {
        guard opensKeyboard, !returning, !committed else { return }
        cancel()
    }

    private var committed = false

    private func commit() {
        guard canCommit, !committed else {
            if opensKeyboard, !committed { cancel() }
            return
        }
        committed = true
        let value = textField.text ?? ""
        dismiss(animated: true) { [onCommit] in onCommit(value) }
    }

    private func cancel() {
        guard !committed else { return }
        committed = true
        dismiss(animated: true) { [onCancel] in onCancel?() }
    }
}

extension TextEntryViewController: UITextFieldDelegate {
    // Hardware keyboards report return here; the on-screen one goes through
    // `.editingDidEndOnExit`.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        true
    }
}

// MARK: - Focusable pill button

/// Focusable pill matching the confirm-popup vocabulary: bright white + dark
/// text on focus, translucent glass otherwise. Owns Select via a press-typed
/// tap recognizer, since a bare control's primaryAction doesn't fire on tvOS.
private final class TextEntryPillButton: UIView {

    private let labelView = UILabel()
    private let onPress: () -> Void
    private let prominent: Bool

    override var canBecomeFocused: Bool { isEnabled }

    var isEnabled = true {
        didSet { alpha = isEnabled ? 1 : 0.4 }
    }

    init(title: String, prominent: Bool, onPress: @escaping () -> Void) {
        self.onPress = onPress
        self.prominent = prominent
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 30
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        applyUnfocusedStyle()

        labelView.text = title
        labelView.font = .systemFont(ofSize: 26, weight: prominent ? .semibold : .medium)
        labelView.textColor = .white
        labelView.textAlignment = .center
        labelView.lineBreakMode = .byTruncatingTail
        labelView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelView)
        NSLayoutConstraint.activate([
            labelView.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            labelView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            labelView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            labelView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(pressed))
        tap.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        addGestureRecognizer(tap)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { if isEnabled { onPress() } }

    private func applyUnfocusedStyle() {
        backgroundColor = UIColor.white.withAlphaComponent(0.12)
        layer.borderColor = UIColor.white.withAlphaComponent(0.20).cgColor
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({
            if focused {
                self.backgroundColor = .white
                self.labelView.textColor = .black
                self.layer.borderColor = UIColor.clear.cgColor
                self.transform = CGAffineTransform(scaleX: 1.06, y: 1.06)
            } else {
                self.applyUnfocusedStyle()
                self.labelView.textColor = .white
                self.transform = .identity
            }
        })
    }
}
