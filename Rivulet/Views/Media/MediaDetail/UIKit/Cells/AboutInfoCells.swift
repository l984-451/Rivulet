// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  The detail's About cards and Information / Languages / Accessibility columns
//  (Docs/atv_ref/carousel_details_ref_about, _information). The cells are not focusable; their cards are.

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
    private let descriptionAttribution = DescriptionTranslationView()

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

    // Review scores wrap to the card's measured width; select → ratings popup.
    private let ratingsCard = AboutCardControl()
    private let ratingsGrid = RatingsGridView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        header.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(header)

        for card in [leftCard, rightCard] {
            card.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(card)
        }
        for card in [leftCard, rightCard, ratingsCard] { card.focusScale = 1.02 }
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
        synopsisLabel.numberOfLines = 3
        synopsisLabel.lineBreakMode = .byTruncatingTail
        leftCard.addSubview(synopsisLabel)
        descriptionAttribution.translatesAutoresizingMaskIntoConstraints = false
        leftCard.addSubview(descriptionAttribution)

        // Advisory vertical stack.
        advisoryStack.translatesAutoresizingMaskIntoConstraints = false
        advisoryStack.axis = .vertical
        advisoryStack.alignment = .leading
        advisoryStack.spacing = 12
        rightCard.addSubview(advisoryStack)

        ratingsCard.onSelect = { [weak self] in self?.presentRatings() }
        ratingsCard.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(ratingsCard)
        ratingsGrid.translatesAutoresizingMaskIntoConstraints = false
        ratingsCard.addSubview(ratingsGrid)

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
            leftCard.widthAnchor.constraint(equalToConstant: Self.wideCard),

            rightCard.topAnchor.constraint(equalTo: leftCard.topAnchor),
            rightCard.leadingAnchor.constraint(equalTo: leftCard.trailingAnchor, constant: MediaRowMetrics.tileGap),
            rightCard.bottomAnchor.constraint(equalTo: leftCard.bottomAnchor),
            rightCard.widthAnchor.constraint(equalToConstant: Self.narrowCard),

            ratingsCard.topAnchor.constraint(equalTo: leftCard.topAnchor),
            ratingsCard.leadingAnchor.constraint(equalTo: rightCard.trailingAnchor, constant: MediaRowMetrics.tileGap),
            ratingsCard.bottomAnchor.constraint(equalTo: leftCard.bottomAnchor),
            ratingsCard.widthAnchor.constraint(equalToConstant: Self.wideCard),
            ratingsGrid.topAnchor.constraint(equalTo: ratingsCard.topAnchor, constant: 22),
            ratingsGrid.leadingAnchor.constraint(equalTo: ratingsCard.leadingAnchor, constant: 24),
            ratingsGrid.trailingAnchor.constraint(equalTo: ratingsCard.trailingAnchor, constant: -24),
            ratingsGrid.bottomAnchor.constraint(equalTo: ratingsCard.bottomAnchor, constant: -22),

            titleLabel.topAnchor.constraint(equalTo: leftCard.topAnchor, constant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: leftCard.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: leftCard.trailingAnchor, constant: -24),

            genresLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            genresLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            genresLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            synopsisLabel.topAnchor.constraint(equalTo: genresLabel.bottomAnchor, constant: 14),
            synopsisLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            synopsisLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            descriptionAttribution.topAnchor.constraint(equalTo: synopsisLabel.bottomAnchor, constant: 8),
            descriptionAttribution.leadingAnchor.constraint(equalTo: synopsisLabel.leadingAnchor),
            descriptionAttribution.trailingAnchor.constraint(equalTo: synopsisLabel.trailingAnchor),
            descriptionAttribution.bottomAnchor.constraint(lessThanOrEqualTo: leftCard.bottomAnchor, constant: -22),

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

    // Synopsis, advisory and ratings split the full row 2:1:2, so Common Sense
    // sits centred (Apple's cards are 2 and 1 grid columns, left-aligned).
    private static let cardsWidth = 1920 - 2 * MediaRowMetrics.rowLeading - 2 * MediaRowMetrics.tileGap
    private static let wideCard = (cardsWidth * 2 / 5).rounded(.down)
    private static let narrowCard = (cardsWidth / 5).rounded(.down)

    static func height(for detail: MediaItemDetail?) -> CGFloat {
        guard let detail else { return 370 }
        let grid = RatingsGridView()
        grid.configure(detail.ratings)
        return max(370, 94 + grid.sizeThatFits(CGSize(width: wideCard - 48, height: .greatestFiniteMagnitude)).height)
    }

    func configure(detail: MediaItemDetail) {
        currentDetail = detail
        titleLabel.text = detail.item.title
        genresLabel.text = detail.genres.prefix(3).joined(separator: ", ")
        genresLabel.isHidden = detail.genres.isEmpty
        synopsisLabel.text = detail.item.overview
        descriptionAttribution.configure(isTranslating: false,
                                         isMachineTranslated: detail.item.overviewIsMachineTranslated == true
                                            && detail.item.overview?.isEmpty == false)

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
            // Fallback: content rating only (no CSM available).
            ageLabel.text = detail.contentRating ?? "NR"
            sealRow.isHidden = true
            oneLinerLabel.isHidden = true
            fallbackCaption.text = "Rated"
            fallbackCaption.isHidden = false
        }
        // Topics + paragraph are popup-only; never shown inline.
        topicsStack.isHidden = true
        paragraphLabel.isHidden = true

        // Selectability: synopsis is clickable when there's an overview; advisory
        // when there's rich CSM (topics/paragraph worth a popup).
        leftCard.selectable = !(detail.item.overview ?? "").isEmpty
        rightCard.selectable = advisory?.hasRichDetail ?? false

        ratingsGrid.configure(detail.ratings)
        ratingsCard.isHidden = detail.ratings.isEmpty
        ratingsCard.selectable = !detail.ratings.isEmpty
    }

    private func presentRatings() {
        guard let ratings = currentDetail?.ratings, !ratings.isEmpty,
              var top = window?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        top.present(InfoPopupViewController(content: InfoPopupContent.ratings(ratings), width: 720,
                                            scrollable: ratings.contains(where: { $0.nativeDisplay != nil })), animated: true)
    }
    // Focus lives on the cards (AboutCardControl), not the cell itself.
    override var canBecomeFocused: Bool { false }

    /// The card focus left from, so returning from its popup lands back on it
    /// instead of the first card.
    private weak var lastFocusedCard: AboutCardControl?

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let card = lastFocusedCard, card.canBecomeFocused, !card.isHidden { return [card] }
        return super.preferredFocusEnvironments
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if let card = context.nextFocusedView as? AboutCardControl, card.isDescendant(of: contentView) {
            lastFocusedCard = card
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        lastFocusedCard = nil
    }
}

// MARK: - Information / Languages / Accessibility columns

final class InfoColumnsCollectionCell: UICollectionViewCell {
    static let reuseID = "InfoColumnsCollectionCell"

    private let columns = InfoColumnsView(style: .footer)
    private var detail: MediaItemDetail?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The cell spans the collection edge to edge, so its own fill is the band.
        contentView.backgroundColor = UIColor(white: 0, alpha: 0.2)
        columns.translatesAutoresizingMaskIntoConstraints = false
        columns.onSelect = { [weak self] in self?.presentFullInfo() }
        contentView.addSubview(columns)
        NSLayoutConstraint.activate([
            columns.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.topInset),
            // The cell spans the collection, which overhangs the screen's left
            // edge when expanded: the rows' own leading rests it on the margin.
            columns.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: BelowFoldCollectionView.rowLeading),
            columns.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -PreviewCarouselGeometry.expandedChromeInset),
            columns.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    /// 14 puts the 36 pt header's baseline 48 below the band top.
    private static let topInset: CGFloat = 14
    private static let bottomInset: CGFloat = 56

    /// Band height that fits `detail`'s tallest column in a row `columnsWidth` wide.
    static func height(for detail: MediaItemDetail, columnsWidth: CGFloat) -> CGFloat {
        let sizing = InfoColumnsView(style: .footer)
        sizing.configure(detail: detail)
        let fitted = sizing.systemLayoutSizeFitting(
            CGSize(width: columnsWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return topInset + fitted.height.rounded(.up) + bottomInset
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(detail: MediaItemDetail) {
        self.detail = detail
        columns.configure(detail: detail)
    }

    /// Select on a column opens the same full-info popup as the hero Info button.
    private func presentFullInfo() {
        guard var detail else { return }
        Task { [weak self] in
            let extra = await RatingsClient.shared.ratings(for: detail, within: 1)
            if !extra.isEmpty { detail.ratings = MediaRating.ordered(detail.ratings + extra) }
            guard var top = self?.window?.rootViewController else { return }
            while let presented = top.presentedViewController { top = presented }
            let popup = InfoPopupViewController(content: InfoPopupContent.fullInfo(detail: detail),
                                                width: InfoPopupViewController.infoWidth, height: 900, scrollable: true)
            top.present(popup, animated: true)
        }
    }
}

/// Standalone Information / Languages / Accessibility columns. Reused by the
/// carousel below-fold cell above AND the episode detail page's below-fold.
final class InfoColumnsView: UIView {
    private let information = InfoColumnView()
    private let languages = InfoColumnView()
    private let accessibility = InfoColumnView()
    private let row = UIStackView()
    private let style: InfoColumnView.Style
    /// Select on a column's card (footer style only).
    var onSelect: (() -> Void)?

    init(style: InfoColumnView.Style = .standard) {
        self.style = style
        super.init(frame: .zero)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.alignment = .top
        row.spacing = style.columnGap
        addSubview(row)
        [information, languages, accessibility].forEach { column in
            column.onSelect = { [weak self] in self?.onSelect?() }
            row.addArrangedSubview(column)
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
        // Information
        var info: [(String, String)] = []
        if let y = detail.item.year { info.append(("Released", "\(y)")) }
        if let runtime = detail.item.runtime, runtime > 0 { info.append(("Run Time", Self.runtime(runtime))) }
        if let r = detail.contentRating, !r.isEmpty { info.append(("Rated", r)) }
        if !detail.genres.isEmpty { info.append(("Genres", detail.genres.prefix(4).joined(separator: ", "))) }
        if !detail.studios.isEmpty { info.append(("Studio", detail.studios.prefix(2).joined(separator: ", "))) }
        information.configure(title: "Information", rows: info, style: style)

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
        languages.configure(title: "Languages", rows: langs, style: style)

        // Accessibility — SDH / AD presence from the tracks.
        var access: [(String, String)] = []
        let hasSDH = source?.subtitleTracks.contains { $0.isHearingImpaired } ?? false
        let hasAD = source?.audioTracks.contains {
            ($0.title ?? $0.extendedTitle ?? "").localizedCaseInsensitiveContains("descri")
        } ?? false
        if hasSDH { access.append(("SDH", "Subtitles for the deaf and hard of hearing are available.")) }
        if hasAD { access.append(("AD", "Audio descriptions are available.")) }
        if access.isEmpty { access.append(("", "No accessibility features detected.")) }
        accessibility.configure(title: "Accessibility", rows: access, style: style)
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
    /// Type and spacing for one use of the column. `standard` is the Info popup
    /// and the episode page; `footer` is the movie/show page's bottom band.
    nonisolated struct Style {
        // Measured on device (tvOS 27): 29 pt header, 23 pt label and value, 80 pt row pitch.
        var headerFont = UIFont.systemFont(ofSize: 29, weight: .bold)
        var headerColor = UIColor.white.withAlphaComponent(0.7)
        var headerGap: CGFloat = 20
        var labelFont = UIFont.systemFont(ofSize: 23, weight: .medium)
        var labelColor = UIColor.white.withAlphaComponent(0.31)
        var valueFont = UIFont.systemFont(ofSize: 23, weight: .medium)
        var valueColor = UIColor.white.withAlphaComponent(0.7)
        var valueLines = 0
        var valueLineSpacing: CGFloat = 0
        var pairGap: CGFloat = 1
        var rowGap: CGFloat = 24
        var columnGap: CGFloat = 48
        /// Wraps the rows (not the header) in a focusable card.
        var focusCard = false

        /// The info popup (the defaults above).
        static let popup = Style()
        /// The episode page's columns: the footer's type with a 38 pt header, no card.
        static let standard = Style(
            headerFont: .systemFont(ofSize: 38, weight: .bold),
            headerColor: UIColor.white.withAlphaComponent(0.7),
            headerGap: 30,
            labelFont: .systemFont(ofSize: 23, weight: .medium),
            labelColor: UIColor.white.withAlphaComponent(0.3),
            valueFont: .systemFont(ofSize: 23, weight: .medium),
            valueColor: UIColor.white.withAlphaComponent(0.7),
            valueLines: 5,
            valueLineSpacing: 2,
            pairGap: 9,
            rowGap: 30,
            columnGap: 50)
        static let footer = Style(
            headerFont: .systemFont(ofSize: 36, weight: .bold),
            headerColor: UIColor.white.withAlphaComponent(0.7),
            headerGap: 30,
            labelFont: .systemFont(ofSize: 23, weight: .medium),
            labelColor: UIColor.white.withAlphaComponent(0.3),
            valueFont: .systemFont(ofSize: 23, weight: .medium),
            valueColor: UIColor.white.withAlphaComponent(0.7),
            valueLines: 5,
            valueLineSpacing: 2,
            pairGap: 9,
            rowGap: 30,
            columnGap: 50,
            focusCard: true)
    }

    /// How far the focus card reaches past the rows on every side.
    private static let cardOutset: CGFloat = 15

    private let stack = UIStackView()
    private var stackLeading: NSLayoutConstraint!
    private var stackTrailing: NSLayoutConstraint!
    /// Select on the rows card (footer style only).
    var onSelect: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        addSubview(stack)
        // High, not required: the column hugs its content in the Info popup, and the
        // below-fold row's required equal-height stretch still wins.
        let bottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottom.priority = .defaultHigh
        stackLeading = stack.leadingAnchor.constraint(equalTo: leadingAnchor)
        stackTrailing = stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stackLeading,
            stackTrailing,
            bottom,
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, rows: [(String, String)], style: Style = .standard) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let header = UILabel()
        header.font = style.headerFont
        header.textColor = style.headerColor
        header.text = title

        // The card overhangs the column, so the stack does too and the header
        // is inset back to the column edge.
        let outset = style.focusCard ? Self.cardOutset : 0
        stackLeading.constant = -outset
        stackTrailing.constant = outset

        let rowStack: UIStackView
        if style.focusCard {
            let headerBox = Self.inset(header, by: .init(top: 0, left: outset, bottom: 0, right: outset))
            rowStack = UIStackView()
            rowStack.axis = .vertical
            let card = AboutCardControl()
            card.restAlpha = 0
            card.layer.cornerRadius = 24
            card.focusScale = 1.054
            card.onSelect = { [weak self] in self?.onSelect?() }
            rowStack.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(rowStack)
            NSLayoutConstraint.activate([
                rowStack.topAnchor.constraint(equalTo: card.topAnchor, constant: outset),
                rowStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: outset),
                rowStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -outset),
                rowStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -outset),
            ])
            stack.addArrangedSubview(headerBox)
            stack.setCustomSpacing(style.headerGap - outset, after: headerBox)
            stack.addArrangedSubview(card)
        } else {
            rowStack = stack
            stack.addArrangedSubview(header)
            stack.setCustomSpacing(style.headerGap, after: header)
        }
        rowStack.spacing = style.rowGap

        for (label, value) in rows {
            let pair = UIStackView()
            pair.axis = .vertical
            pair.spacing = style.pairGap
            if !label.isEmpty {
                let l = UILabel()
                l.font = style.labelFont
                l.textColor = style.labelColor
                l.text = label
                pair.addArrangedSubview(l)
            }
            let v = UILabel()
            v.font = style.valueFont
            v.textColor = style.valueColor
            v.numberOfLines = style.valueLines
            if style.valueLineSpacing > 0 {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = style.valueLineSpacing
                paragraph.lineBreakMode = .byTruncatingTail
                v.attributedText = NSAttributedString(string: value, attributes: [.paragraphStyle: paragraph])
            } else {
                v.text = value
            }
            pair.addArrangedSubview(v)
            rowStack.addArrangedSubview(pair)
        }
    }

    private static func inset(_ view: UIView, by insets: UIEdgeInsets) -> UIView {
        let box = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: box.topAnchor, constant: insets.top),
            view.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -insets.right),
            view.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -insets.bottom),
        ])
        return box
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

// MARK: - Ratings grid

/// Shared score presentation for About, carousel, episode and full information.
/// Each source keeps its own icon, native value and accessible source identity.
final class RatingsGridView: MediaMetadataFlowView {
    func configure(_ ratings: [MediaRating]) {
        accessibilityIdentifier = "media.ratings"
        setItems(ratings.map { MediaRatingChipView(rating: $0) })
    }

    static func row(_ ratings: [MediaRating]) -> UIView {
        let grid = RatingsGridView()
        grid.configure(ratings)
        return grid
    }
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
    /// Focus scale; nil derives it from the card's width (1.134 at 260 down to 1.073 at 560).
    var focusScale: CGFloat?
    private func scale(forWidth width: CGFloat) -> CGFloat {
        if let focusScale { return focusScale }
        let t = min(max((width - 260) / 300, 0), 1)
        return 1.134 - t * (1.134 - 1.073)
    }
    /// Fill alpha when not focused. 0 = no card at rest (the footer columns).
    var restAlpha: CGFloat = 0.06 {
        didSet { backgroundColor = UIColor(white: 1, alpha: restAlpha) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 1, alpha: restAlpha)
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
            self.backgroundColor = UIColor(white: 1, alpha: focused ? 0.14 : self.restAlpha)
            let s = self.scale(forWidth: self.bounds.width)
            self.transform = focused ? CGAffineTransform(scaleX: s, y: s) : .identity
        }
    }
}
