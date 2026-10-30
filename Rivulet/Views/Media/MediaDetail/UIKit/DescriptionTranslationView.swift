// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit

/// Content-sized description status. Only the native action button takes focus.
final class DescriptionTranslationView: UIView {
    private let symbolView = UIImageView()
    private let statusLabel = UILabel()
    private let errorLabel = UILabel()
    private let translateButton = UIButton(type: .system)
    private var onTranslate: (() -> Void)?
    private var isTranslating = false
    private var compactStatus = false
    private var measuredWidth: CGFloat = 0
    private static let pulseKey = "descriptionTranslationPulse"
    private let spacing: CGFloat = 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        setContentHuggingPriority(.required, for: .vertical)

        let font = UIFont.preferredFont(forTextStyle: .caption2)
        symbolView.image = UIImage(systemName: "translate",
                                   withConfiguration: UIImage.SymbolConfiguration(font: font))
        symbolView.contentMode = .scaleAspectFit
        symbolView.tintColor = .secondaryLabel
        symbolView.isAccessibilityElement = false
        symbolView.isUserInteractionEnabled = false

        statusLabel.font = font
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.adjustsFontForContentSizeCategory = true
        errorLabel.font = font
        errorLabel.textColor = .secondaryLabel
        errorLabel.numberOfLines = 0
        errorLabel.adjustsFontForContentSizeCategory = true

        var configuration = UIButton.Configuration.tinted()
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .label
        configuration.image = UIImage(systemName: "translate",
                                      withConfiguration: UIImage.SymbolConfiguration(font: font))
        configuration.imagePadding = 8
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .caption1)
            return attributes
        }
        translateButton.configuration = configuration
        translateButton.addTarget(self, action: #selector(translatePressed), for: .primaryActionTriggered)

        [symbolView, statusLabel, errorLabel, translateButton].forEach { addSubview($0) }
        NotificationCenter.default.addObserver(self, selector: #selector(reduceMotionChanged),
                                               name: UIAccessibility.reduceMotionStatusDidChangeNotification,
                                               object: nil)
        configure(isTranslating: false, isMachineTranslated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    func configure(isTranslating: Bool, isMachineTranslated: Bool, canTranslate: Bool = false,
                   errorMessage: String? = nil, onTranslate: (() -> Void)? = nil, compact: Bool = false) {
        self.isTranslating = isTranslating
        compactStatus = compact
        self.onTranslate = onTranslate
        statusLabel.text = isTranslating ? (compact ? "…" : "Translating…")
            : (isMachineTranslated && !compact ? "Translated by AI" : nil)
        statusLabel.numberOfLines = compact ? 1 : 0
        statusLabel.isHidden = statusLabel.text == nil
        statusLabel.isAccessibilityElement = !compact
        symbolView.isHidden = !isTranslating && !isMachineTranslated
        symbolView.isAccessibilityElement = compact && !symbolView.isHidden
        symbolView.accessibilityLabel = compact ? (isTranslating ? "Translating…" : "Translated by AI") : nil

        let error = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasError = !isTranslating && error?.isEmpty == false
        errorLabel.text = hasError ? error : nil
        errorLabel.isHidden = errorLabel.text == nil
        let actionWasFocused = translateButton.isFocused
        translateButton.isHidden = isTranslating || !canTranslate || onTranslate == nil
        translateButton.configuration?.title = errorLabel.isHidden ? "Translate" : "Retry"
        isHidden = symbolView.isHidden && errorLabel.isHidden && translateButton.isHidden
        if actionWasFocused && translateButton.isHidden { setNeedsFocusUpdate() }
        updatePulse()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        guard !isHidden else { return CGSize(width: UIView.noIntrinsicMetric, height: 0) }
        let fitted = arrangement(width: compactStatus ? 600 : (bounds.width > 0 ? bounds.width : 600))
        return CGSize(width: compactStatus ? fitted.width : UIView.noIntrinsicMetric, height: fitted.height)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        arrangement(width: size.width > 0 && size.width.isFinite ? size.width : 600)
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        sizeThatFits(targetSize)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if measuredWidth != bounds.width {
            measuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        _ = arrangement(width: bounds.width, place: true)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updatePulse()
    }

    private func arrangement(width: CGFloat, place: Bool = false) -> CGSize {
        guard !isHidden, width > 0 else { return .zero }
        var height: CGFloat = 0
        var usedWidth: CGFloat = 0
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        if !symbolView.isHidden {
            let symbolSize = ceil(statusLabel.font.lineHeight)
            let gap = statusLabel.isHidden ? 0 : spacing
            let textWidth = max(0, width - symbolSize - gap)
            let textSize = statusLabel.isHidden ? .zero
                : statusLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
            let rowHeight = max(symbolSize, ceil(textSize.height))
            if place {
                symbolView.frame = CGRect(x: rightToLeft ? width - symbolSize : 0, y: 0,
                                          width: symbolSize, height: symbolSize)
                statusLabel.frame = CGRect(x: rightToLeft ? 0 : symbolSize + gap, y: 0,
                                           width: textWidth, height: rowHeight)
            }
            height = rowHeight
            usedWidth = min(width, symbolSize + gap + ceil(textSize.width))
        }
        if !errorLabel.isHidden {
            if height > 0 { height += spacing }
            let size = errorLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            if place {
                errorLabel.frame = CGRect(x: 0, y: height, width: width, height: ceil(size.height))
            }
            height += ceil(size.height)
            usedWidth = max(usedWidth, min(width, ceil(size.width)))
        }
        if !translateButton.isHidden {
            if height > 0 { height += spacing }
            let size = translateButton.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            let buttonWidth = min(width, ceil(size.width))
            let buttonHeight = max(44, ceil(size.height))
            if place {
                translateButton.frame = CGRect(x: rightToLeft ? width - buttonWidth : 0, y: height,
                                               width: buttonWidth, height: buttonHeight)
            }
            height += buttonHeight
            usedWidth = max(usedWidth, buttonWidth)
        }
        return CGSize(width: usedWidth, height: height)
    }

    private func updatePulse() {
        let shouldPulse = isTranslating && !isHidden && window != nil && !UIAccessibility.isReduceMotionEnabled
        guard shouldPulse else {
            symbolView.layer.removeAnimation(forKey: Self.pulseKey)
            return
        }
        guard symbolView.layer.animation(forKey: Self.pulseKey) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.45
        pulse.duration = 1.25
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        symbolView.layer.add(pulse, forKey: Self.pulseKey)
    }

    @objc private func reduceMotionChanged() { updatePulse() }
    @objc private func translatePressed() {
        guard !translateButton.isHidden else { return }
        onTranslate?()
    }
}
