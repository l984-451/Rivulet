// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AboutInfoCells.swift
//  Rivulet
//
//  The two static info blocks at the bottom of the UIKit expanded detail,
//  matching the Apple TV+ show-detail reference (Docs/atv_ref/carousel_details_ref_about
//  + _information):
//
//   - AboutCollectionCell  — "About" header + two cards: left = title / genres /
//     synopsis, right = the content-rating block.
//   - InfoColumnsCollectionCell — three columns: Information / Languages /
//     Accessibility, the latter two derived from the item's media streams.
//
//  Both are single full-width cells in the below-fold compositional collection.
//  They are focusable (a subtle lift) so the focus engine can scroll to them in
//  the focus-driven below-fold (FocusScrollControlledCollectionView).
//

import UIKit

// MARK: - About

final class AboutCollectionCell: UICollectionViewCell {
    static let reuseID = "AboutCollectionCell"

    private let header = sectionHeaderLabel("About")
    // Both cards are focusable controls: select the synopsis → description popup;
    // select the advisory → content-rating popup.
    private let leftCard = AboutCardControl()
    private let titleLabel = UILabel()
    private let genresLabel = UILabel()
    private let synopsisLabel = UILabel()

    // Right card = Common Sense Media advisory (inline: age + seal + one-liner;
    // full topic dots + paragraph live in the popup), content-rating fallback.
    private let rightCard = AboutCardControl()

    /// Set by the cell provider; the cell forwards the current data on select.
    var onSelectSynopsis: ((MediaItemDetail) -> Void)?
    var onSelectAdvisory: ((ContentAdvisory) -> Void)?
    private var currentDetail: MediaItemDetail?
    private let advisoryStack = UIStackView()
    private let ageLabel = UILabel()
    private let sealRow = UIStackView()
    private let sealIcon = UIImageView()
    private let sealLabel = UILabel()
    private let oneLinerLabel = UILabel()
    private let topicsStack = UIStackView()
    private let paragraphLabel = UILabel()
    private let fallbackCaption = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        header.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(header)

        for card in [leftCard, rightCard] {
            card.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(card)
        }
        leftCard.onSelect = { [weak self] in
            guard let self, let d = self.currentDetail, !(d.item.overview ?? "").isEmpty else { return }
            self.onSelectSynopsis?(d)
        }
        rightCard.onSelect = { [weak self] in
            guard let self, let a = self.currentDetail?.contentAdvisory, a.hasAny else { return }
            self.onSelectAdvisory?(a)
        }

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 36, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1
        leftCard.addSubview(titleLabel)

        genresLabel.translatesAutoresizingMaskIntoConstraints = false
        genresLabel.font = .systemFont(ofSize: 23, weight: .medium)
        genresLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        genresLabel.numberOfLines = 1
        leftCard.addSubview(genresLabel)

        synopsisLabel.translatesAutoresizingMaskIntoConstraints = false
        synopsisLabel.font = .systemFont(ofSize: 25, weight: .semibold)
        synopsisLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        synopsisLabel.numberOfLines = 6
        leftCard.addSubview(synopsisLabel)

        // Advisory vertical stack.
        advisoryStack.translatesAutoresizingMaskIntoConstraints = false
        advisoryStack.axis = .vertical
        advisoryStack.alignment = .leading
        advisoryStack.spacing = 12
        rightCard.addSubview(advisoryStack)

        ageLabel.font = .systemFont(ofSize: 58, weight: .bold)
        ageLabel.textColor = .white

        sealIcon.image = UIImage(systemName: "checkmark.circle.fill")
        sealIcon.tintColor = .systemGreen
        sealIcon.contentMode = .scaleAspectFit
        sealIcon.setContentHuggingPriority(.required, for: .horizontal)
        sealLabel.font = .systemFont(ofSize: 21, weight: .bold)
        sealLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        sealLabel.text = "Common Sense"
        sealRow.axis = .horizontal
        sealRow.alignment = .center
        sealRow.spacing = 6
        sealRow.addArrangedSubview(sealIcon)
        sealRow.addArrangedSubview(sealLabel)

        oneLinerLabel.font = .systemFont(ofSize: 23, weight: .bold)
        oneLinerLabel.textColor = UIColor.white.withAlphaComponent(0.92)
        oneLinerLabel.numberOfLines = 4

        topicsStack.axis = .vertical
        topicsStack.alignment = .fill
        topicsStack.spacing = 8

        paragraphLabel.font = .systemFont(ofSize: 17, weight: .regular)
        paragraphLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        paragraphLabel.numberOfLines = 5   // teaser; full text would overflow the card

        fallbackCaption.font = .systemFont(ofSize: 17, weight: .regular)
        fallbackCaption.textColor = UIColor.white.withAlphaComponent(0.7)
        fallbackCaption.numberOfLines = 2

        for v in [ageLabel, sealRow, oneLinerLabel, topicsStack, paragraphLabel, fallbackCaption] {
            advisoryStack.addArrangedSubview(v)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),

            leftCard.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            leftCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            leftCard.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            // Left margin (56) + synopsis + gap + advisory = 960 (half the 1920
            // screen). 56 + 620 + 24 + 260 = 960.
            leftCard.widthAnchor.constraint(equalToConstant: 620),

            rightCard.topAnchor.constraint(equalTo: leftCard.topAnchor),
            rightCard.leadingAnchor.constraint(equalTo: leftCard.trailingAnchor, constant: 24),
            rightCard.bottomAnchor.constraint(equalTo: leftCard.bottomAnchor),
            rightCard.widthAnchor.constraint(equalToConstant: 260),

            titleLabel.topAnchor.constraint(equalTo: leftCard.topAnchor, constant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: leftCard.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: leftCard.trailingAnchor, constant: -24),

            genresLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            genresLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            genresLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            synopsisLabel.topAnchor.constraint(equalTo: genresLabel.bottomAnchor, constant: 14),
            synopsisLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            synopsisLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            advisoryStack.topAnchor.constraint(equalTo: rightCard.topAnchor, constant: 22),
            advisoryStack.leadingAnchor.constraint(equalTo: rightCard.leadingAnchor, constant: 24),
            advisoryStack.trailingAnchor.constraint(equalTo: rightCard.trailingAnchor, constant: -24),
            advisoryStack.bottomAnchor.constraint(lessThanOrEqualTo: rightCard.bottomAnchor, constant: -22),

            sealRow.widthAnchor.constraint(equalTo: advisoryStack.widthAnchor),
            oneLinerLabel.widthAnchor.constraint(equalTo: advisoryStack.widthAnchor),
            topicsStack.widthAnchor.constraint(equalTo: advisoryStack.widthAnchor),
            paragraphLabel.widthAnchor.constraint(equalTo: advisoryStack.widthAnchor),
            fallbackCaption.widthAnchor.constraint(equalTo: advisoryStack.widthAnchor),
            sealIcon.heightAnchor.constraint(equalToConstant: 24),
            sealIcon.widthAnchor.constraint(equalToConstant: 24),
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(detail: MediaItemDetail) {
        currentDetail = detail
        titleLabel.text = detail.item.title
        genresLabel.text = detail.genres.prefix(3).joined(separator: ", ")
        genresLabel.isHidden = detail.genres.isEmpty
        synopsisLabel.text = detail.item.overview

        let advisory = detail.contentAdvisory
        if let a = advisory, a.hasAny {
            // Inline = compact: age + seal + one-line description. The topic dots
            // and full text live in the click-to-open popup (ATV+ pattern).
            ageLabel.text = a.ageRating ?? detail.contentRating ?? "NR"
            sealRow.isHidden = false
            oneLinerLabel.text = a.oneLiner
            oneLinerLabel.isHidden = (a.oneLiner ?? "").isEmpty
            fallbackCaption.isHidden = true
        } else {
            // Fallback: content rating + numeric score (no CSM available).
            ageLabel.text = detail.contentRating ?? "NR"
            sealRow.isHidden = true
            oneLinerLabel.isHidden = true
            if let rating = detail.rating {
                fallbackCaption.text = "Rated · " + rating.summary
            } else {
                fallbackCaption.text = "Rated"
            }
            fallbackCaption.isHidden = false
        }
        // Topics + paragraph are popup-only; never shown inline.
        topicsStack.isHidden = true
        paragraphLabel.isHidden = true

        // Selectability: synopsis is clickable when there's an overview; advisory
        // when there's rich CSM (topics/paragraph worth a popup).
        leftCard.selectable = !(detail.item.overview ?? "").isEmpty
        rightCard.selectable = advisory?.hasRichDetail ?? false
    }
    // Focus lives on the two cards (AboutCardControl), not the cell itself.
    override var canBecomeFocused: Bool { false }
}

// MARK: - Information / Languages / Accessibility columns

final class InfoColumnsCollectionCell: UICollectionViewCell {
    static let reuseID = "InfoColumnsCollectionCell"

    private let columns = InfoColumnsView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        columns.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(columns)
        NSLayoutConstraint.activate([
            columns.topAnchor.constraint(equalTo: contentView.topAnchor),
            columns.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            columns.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(detail: MediaItemDetail) { columns.configure(detail: detail) }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations { [weak self] in
            self?.contentView.backgroundColor = UIColor(white: 1, alpha: focused ? 0.05 : 0)
        }
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        contentView.backgroundColor = .clear
    }
}

/// Standalone Information / Languages / Accessibility columns. Reused by the
/// carousel below-fold cell above AND the episode detail page's below-fold.
final class InfoColumnsView: UIView {
    private let information = InfoColumnView()
    private let languages = InfoColumnView()
    private let accessibility = InfoColumnView()
    private let row = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.alignment = .top
        row.spacing = 48
        addSubview(row)
        [information, languages, accessibility].forEach { row.addArrangedSubview($0) }
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(detail: MediaItemDetail) {
        // Information
        var info: [(String, String)] = []
        if let y = detail.item.year { info.append(("Released", "\(y)")) }
        if let runtime = detail.item.runtime, runtime > 0 { info.append(("Run Time", Self.runtime(runtime))) }
        if let r = detail.contentRating, !r.isEmpty { info.append(("Rated", r)) }
        if !detail.genres.isEmpty { info.append(("Genres", detail.genres.prefix(4).joined(separator: ", "))) }
        if !detail.studios.isEmpty { info.append(("Studio", detail.studios.prefix(2).joined(separator: ", "))) }
        information.configure(title: "Information", rows: info)

        // Languages — from the first media source's tracks.
        let source = detail.primarySource
        var langs: [(String, String)] = []
        if let audio = source?.audioTracks, !audio.isEmpty {
            let names = uniqueOrdered(audio.compactMap { Self.languageName($0.language) })
            if !names.isEmpty { langs.append(("Audio", names.joined(separator: ", "))) }
        }
        if let subs = source?.subtitleTracks, !subs.isEmpty {
            let names = uniqueOrdered(subs.compactMap { t -> String? in
                guard let n = Self.languageName(t.language) else { return nil }
                return t.isHearingImpaired ? "\(n) (SDH)" : n
            })
            if !names.isEmpty { langs.append(("Subtitles", names.joined(separator: ", "))) }
        }
        if langs.isEmpty { langs.append(("Audio", "Unknown")) }
        languages.configure(title: "Languages", rows: langs)

        // Accessibility — SDH / AD presence from the tracks.
        var access: [(String, String)] = []
        let hasSDH = source?.subtitleTracks.contains { $0.isHearingImpaired } ?? false
        let hasAD = source?.audioTracks.contains {
            ($0.title ?? $0.extendedTitle ?? "").localizedCaseInsensitiveContains("descri")
        } ?? false
        if hasSDH { access.append(("SDH", "Subtitles for the deaf and hard of hearing are available.")) }
        if hasAD { access.append(("AD", "Audio descriptions are available.")) }
        if access.isEmpty { access.append(("", "No accessibility features detected.")) }
        accessibility.configure(title: "Accessibility", rows: access)
    }

    private func uniqueOrdered(_ values: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for v in values where !seen.contains(v) { seen.insert(v); out.append(v) }
        return out
    }

    private static func runtime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded()); let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m) min"
    }

    static func languageName(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        if let name = Locale.current.localizedString(forLanguageCode: code) { return name.capitalized }
        return code.uppercased()
    }
}

/// One labelled column (header + stacked label/value pairs). Reused by the
/// 3-column below-fold AND the vertically-stacked Info popup.
final class InfoColumnView: UIView {
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 14
        addSubview(stack)
        // Bottom pinned with `=` at high (not required) priority so the column
        // HUGS its content when nothing else drives its height (the vertically-
        // stacked Info popup). In the below-fold's horizontal `.fill` row, the
        // required equal-height stretch outranks this and still wins.
        let bottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom,
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, rows: [(String, String)]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let header = UILabel()
        header.font = .systemFont(ofSize: 40, weight: .bold)
        header.textColor = .white
        header.text = title
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(20, after: header)

        for (label, value) in rows {
            let pair = UIStackView()
            pair.axis = .vertical
            pair.spacing = 2
            if !label.isEmpty {
                let l = UILabel()
                l.font = .systemFont(ofSize: 21, weight: .semibold)
                l.textColor = UIColor.white.withAlphaComponent(0.5)
                l.text = label
                pair.addArrangedSubview(l)
            }
            let v = UILabel()
            v.font = .systemFont(ofSize: 26, weight: .semibold)
            v.textColor = UIColor.white.withAlphaComponent(0.9)
            v.numberOfLines = 0
            v.text = value
            pair.addArrangedSubview(v)
            stack.addArrangedSubview(pair)
        }
    }
}

// MARK: - Shared

private func sectionHeaderLabel(_ text: String) -> UILabel {
    let l = UILabel()
    l.font = .systemFont(ofSize: 30, weight: .semibold)
    l.textColor = .white
    l.text = text
    return l
}

/// Full-width darkened band behind the Information / Languages / Accessibility
/// area. Added as a SECTION BACKGROUND decoration so it spans edge-to-edge
/// (the full section rect) even though the columns themselves are inset.
final class InfoBandDecorationView: UICollectionReusableView {
    static let kind = "infoBand"
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0, alpha: 0.28)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Focusable About card

/// A focusable About card (synopsis or advisory). Selecting it opens the matching
/// popup. Focus appearance = subtle brighten + scale (matches the glass style).
final class AboutCardControl: UIControl {
    var onSelect: (() -> Void)?
    /// Gates focus/selection — e.g. the advisory card only when CSM is present.
    var selectable: Bool = true {
        didSet { if selectable != oldValue { setNeedsFocusUpdate() } }
    }
    override var canBecomeFocused: Bool { selectable }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 1, alpha: 0.06)
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        addTarget(self, action: #selector(fire), for: .primaryActionTriggered)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { onSelect?() }

    // primaryActionTriggered is unreliable for a bare UIControl on tvOS; the
    // remote Select press is delivered to the FOCUSED view's press handlers, so
    // handle it here directly.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { return }
        super.pressesBegan(presses, with: event)
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) {
            onSelect?()
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = (context.nextFocusedView === self)
        coordinator.addCoordinatedAnimations { [weak self] in
            guard let self else { return }
            self.backgroundColor = UIColor(white: 1, alpha: focused ? 0.14 : 0.06)
            self.transform = focused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
        }
    }
}
