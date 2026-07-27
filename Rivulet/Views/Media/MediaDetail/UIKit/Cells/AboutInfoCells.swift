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
    private let leftCard = DetailCardControl()
    private let titleLabel = UILabel()
    private let genresLabel = UILabel()
    private let synopsisLabel = UILabel()

    // Right card = Common Sense Media advisory (inline: age + seal + one-liner;
    // full topic dots + paragraph live in the popup), content-rating fallback.
    private let rightCard = DetailCardControl()

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
            if let score = detail.rating, score > 0 {
                fallbackCaption.text = "Rated · " + String(format: "%.1f / 10 average rating", score)
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
    // Focus lives on the two cards (DetailCardControl), not the cell itself.
    override var canBecomeFocused: Bool { false }
}

// MARK: - Information / Languages / Accessibility columns

/// One labelled section of the detail's info block. Travels from the card that
/// was selected up to the popup that renders it, so the callback chain carries a
/// named type rather than an anonymous title/rows tuple.
struct DetailInfoSection {
    let title: String
    let rows: [(String, String)]
}

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

    /// Select on a card → open that section in full. Also what makes the cards
    /// focusable, so the focus-driven below-fold can reach them.
    var onSelectColumn: ((DetailInfoSection) -> Void)? {
        get { columns.onSelectColumn }
        set { columns.onSelectColumn = newValue }
    }

    // Focus lives on the three cards (DetailCardControl), not the cell itself.
    override var canBecomeFocused: Bool { false }
}

/// Standalone Information / Languages / Accessibility columns. Reused by the
/// carousel below-fold cell above AND the episode detail page's below-fold.
final class InfoColumnsView: UIView {

    /// One column: its card, the view inside it, and the section it last
    /// rendered. Bundling these keeps the card, its content, and its Select
    /// payload from drifting out of step — they used to be three arrays held
    /// together by index.
    private final class Column {
        let card = DetailCardControl()
        let view = InfoColumnView()
        var section = DetailInfoSection(title: "", rows: [])
    }

    private let columns = [Column(), Column(), Column()]
    private let row = UIStackView()

    /// Select on a card → open that section in full. A card's own copy trims
    /// long values to stay scannable, so the popup is where the complete list
    /// lives. Setting this makes the cards focusable AND selectable; leaving it
    /// nil keeps them inert (the episode detail page, which scrolls normally
    /// and has nothing to open).
    var onSelectColumn: ((DetailInfoSection) -> Void)? {
        didSet { columns.forEach { $0.card.selectable = onSelectColumn != nil } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.distribution = .fillEqually
        // .fill (not .top) so the three cards are equal height however far their
        // text wraps — ragged card bottoms read as broken.
        row.alignment = .fill
        row.spacing = 24
        addSubview(row)
        for column in columns {
            column.card.selectable = false   // opt-in via onSelectColumn
            column.card.onSelect = { [weak self, weak column] in
                guard let column else { return }
                self?.onSelectColumn?(column.section)
            }
            column.card.embed(column.view)
            row.addArrangedSubview(column.card)
        }
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
        // Information. `card` is the trimmed value shown on the card itself,
        // `full` the untrimmed one the popup gets. Built once as triples so a
        // new row can't be added to one and forgotten in the other.
        var information: [(label: String, card: String, full: String)] = []
        if let y = detail.item.year { information.append(("Released", "\(y)", "\(y)")) }
        if let runtime = detail.item.runtime, runtime > 0 {
            let text = Self.runtime(runtime)
            information.append(("Run Time", text, text))
        }
        if let r = detail.contentRating, !r.isEmpty { information.append(("Rated", r, r)) }
        if !detail.genres.isEmpty {
            information.append(("Genres",
                                detail.genres.prefix(4).joined(separator: ", "),
                                detail.genres.joined(separator: ", ")))
        }
        if !detail.studios.isEmpty {
            information.append(("Studio",
                                detail.studios.prefix(2).joined(separator: ", "),
                                detail.studios.joined(separator: ", ")))
        }

        // Languages — from the first media source's tracks.
        let source = detail.mediaSources.first
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

        // Accessibility — SDH / AD presence from the tracks.
        var access: [(String, String)] = []
        let hasSDH = source?.subtitleTracks.contains { $0.isHearingImpaired } ?? false
        let hasAD = source?.audioTracks.contains {
            ($0.title ?? $0.extendedTitle ?? "").localizedCaseInsensitiveContains("descri")
        } ?? false
        if hasSDH { access.append(("SDH", "Subtitles for the deaf and hard of hearing are available.")) }
        if hasAD { access.append(("AD", "Audio descriptions are available.")) }
        if access.isEmpty { access.append(("", "No accessibility features detected.")) }

        apply(
            .init(title: "Information", rows: information.map { ($0.label, $0.full) }),
            cardRows: information.map { ($0.label, $0.card) },
            to: columns[0])
        apply(.init(title: "Languages", rows: langs), cardRows: langs, to: columns[1])
        apply(.init(title: "Accessibility", rows: access), cardRows: access, to: columns[2])
    }

    /// The card renders `cardRows`; `section` is what a Select hands to the popup.
    private func apply(_ section: DetailInfoSection,
                       cardRows: [(String, String)],
                       to column: Column) {
        column.section = section
        column.view.configure(title: section.title, rows: cardRows)
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

// MARK: - Focusable detail card

/// A focusable detail card (About synopsis / advisory, the info columns).
/// Selecting it opens the matching popup. Focus appearance = subtle brighten +
/// scale (matches the glass style).
final class DetailCardControl: UIControl {
    /// Content inset — the card owns its own padding so every surface using one
    /// gets the same, rather than restating four numbers per call site.
    static let contentInsets = UIEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)

    var onSelect: (() -> Void)?
    /// Gates focus AND selection: a card with nothing to open is skipped by the
    /// focus engine rather than becoming a dead-end focus target.
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

    /// Pin a content view inside the card's standard padding.
    func embed(_ view: UIView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        let inset = Self.contentInsets
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor, constant: inset.top),
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset.left),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset.right),
            view.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -inset.bottom),
        ])
    }

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
