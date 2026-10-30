// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SettingsLeftPanelView.swift
//  Rivulet
//
//  Left description panel for the UIKit Settings split, matching
//  tvOS Settings: a per-PAGE icon tile (540×540, centred in the 870×654 panel)
//  plus a per-ROW description pinned just below the panel (Body, secondary
//  label) that crossfades as focus moves. Reuses `SettingsDescriptorStore`.
//

import UIKit

final class SettingsLeftPanelView: UIView {

    static let width: CGFloat = 870
    /// Every explainer fits in this many lines at full size (`SettingsDescriptorLengthTests`).
    static let descriptionLines = 3
    static let descriptionFont = UIFont.preferredFont(forTextStyle: .body)

    private let iconContainer = UIView()
    private let iconView = UIImageView()
    /// The focused App Icon option's artwork, shown in place of the page tile.
    private let artworkView = UIImageView()
    private let descriptionLabel = UILabel()
    private let subtextLabel = UILabel()
    /// Page-level instruction shown under the icon (e.g. the reorder hint on the
    /// libraries page). Collapses to zero height when the page has no hint.
    private let hintLabel = UILabel()
    private var hintHeightZero: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        iconContainer.layer.cornerRadius = 110
        iconContainer.layer.cornerCurve = .continuous
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconContainer)

        iconView.contentMode = .center
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 200, weight: .medium)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(iconView)

        artworkView.contentMode = .scaleAspectFill
        artworkView.layer.cornerRadius = 40
        artworkView.layer.cornerCurve = .continuous
        artworkView.clipsToBounds = true
        artworkView.isHidden = true
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(artworkView)

        descriptionLabel.font = Self.descriptionFont
        descriptionLabel.textColor = .secondaryLabel
        descriptionLabel.numberOfLines = Self.descriptionLines
        descriptionLabel.textAlignment = .center
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(descriptionLabel)

        hintLabel.numberOfLines = 2
        hintLabel.textAlignment = .center
        hintLabel.isHidden = true
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hintLabel)

        subtextLabel.font = .monospacedSystemFont(ofSize: 24, weight: .medium)
        subtextLabel.textColor = SettingsPalette.dim
        subtextLabel.numberOfLines = 2
        subtextLabel.textAlignment = .center
        subtextLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtextLabel)

        // Hint collapses to zero height on pages without one.
        hintHeightZero = hintLabel.heightAnchor.constraint(equalToConstant: 0)
        hintHeightZero.isActive = true

        NSLayoutConstraint.activate([
            iconContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 540),
            iconContainer.heightAnchor.constraint(equalToConstant: 540),

            // The Home Screen icon's 5:3, as wide as the tile.
            artworkView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            artworkView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            artworkView.widthAnchor.constraint(equalTo: iconContainer.widthAnchor),
            artworkView.heightAnchor.constraint(equalTo: artworkView.widthAnchor, multiplier: 3.0 / 5.0),

            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),

            hintLabel.topAnchor.constraint(equalTo: iconContainer.bottomAnchor, constant: 12),
            hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 700),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),

            // Pinned under the panel whatever the image, as tvOS Settings does.
            descriptionLabel.topAnchor.constraint(equalTo: bottomAnchor),
            descriptionLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            descriptionLabel.trailingAnchor.constraint(equalTo: trailingAnchor),

            subtextLabel.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 12),
            subtextLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtextLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 700)
        ])
    }

    /// Pages that show a page-level instruction under the icon.
    private func hint(for page: SettingsPage) -> String? {
        switch page {
        case .libraries, .liveTVFavorites: return "Long press to re-arrange items"
        default:         return nil
        }
    }

    /// Reorder-style hint: an up/down glyph + text, dim like the description.
    private func hintAttributed(_ text: String) -> NSAttributedString {
        let color = SettingsPalette.caption.resolvedColor(with: traitCollection)
        let result = NSMutableAttributedString()
        let cfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        if let img = UIImage(systemName: "arrow.up.arrow.down", withConfiguration: cfg)?
            .withTintColor(color, renderingMode: .alwaysOriginal) {
            let attachment = NSTextAttachment()
            attachment.image = img
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "  "))
        }
        result.append(NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 24, weight: .medium),
            .foregroundColor: color
        ]))
        return result
    }

    /// Set the page icon (matching `pageInfo(for:)`). Crossfades when animated
    /// (on a page change), like the SwiftUI panel's symbol-replace transition.
    func configure(page: SettingsPage, animated: Bool = false) {
        show(id: nil)
        let info = SettingsDescriptorStore.pageInfo(for: page)
        let color = info.color
        let apply = {
            self.iconContainer.backgroundColor = color.withAlphaComponent(0.18)
            self.iconView.image = UIImage(systemName: info.icon)
            self.iconView.tintColor = color
        }
        if animated {
            UIView.transition(with: iconContainer, duration: 0.3, options: .transitionCrossDissolve, animations: apply)
        } else {
            apply()
        }

        // Page-level instruction under the icon (collapses when none).
        if let text = hint(for: page) {
            hintLabel.attributedText = hintAttributed(text)
            hintLabel.isHidden = false
            hintHeightZero.isActive = false
        } else {
            hintLabel.attributedText = nil
            hintLabel.isHidden = true
            hintHeightZero.isActive = true
        }
    }

    /// Update the per-row description (crossfade), keyed by `focusedSettingId`.
    func show(id: String?, subtext: String? = nil) {
        let descriptor = id.flatMap { SettingsDescriptorStore.descriptor(for: $0) }
        let artwork = id.flatMap(Self.appIconArtwork)
        UIView.transition(with: self, duration: 0.25, options: .transitionCrossDissolve) {
            self.artworkView.image = artwork
            self.artworkView.isHidden = artwork == nil
            self.iconContainer.isHidden = artwork != nil
            self.descriptionLabel.text = descriptor?.description ?? " "
            self.descriptionLabel.alpha = descriptor != nil ? 1 : 0
            self.subtextLabel.text = subtext
            self.subtextLabel.isHidden = (subtext == nil)
        }
    }

    /// Artwork for an App Icon option row (`ai_<rawValue>`); nil for every other row.
    private static func appIconArtwork(for id: String) -> UIImage? {
        guard id.hasPrefix("ai_"), let icon = AppIcon(rawValue: String(id.dropFirst(3))) else { return nil }
        return UIImage(named: "AppIconArt-\(icon.rawValue)")
    }
}
