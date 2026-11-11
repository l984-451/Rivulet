// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  The reusable frosted popup card, fixed width and hugging content built by `InfoPopupContent`.
//  The card is focusable, or Menu never reaches the modal; press recognizers own Menu and Select.

import UIKit

/// Card height and scroll insets for a measured content height (InfoPopupCardLayoutTests).
/// Insets apply only when content overflows; on short content they clip the last line.
struct InfoPopupCardLayout {
    let cardHeight: CGFloat
    let scrolls: Bool
    let insetTop: CGFloat
    let insetBottom: CGFloat

    /// Breathing room for content scrolling in and out of the card's edges.
    private static let scrollInsetTop: CGFloat = 8
    private static let scrollInsetBottom: CGFloat = 72

    static func make(contentHeight: CGFloat, pad: CGFloat, screenHeight: CGFloat) -> InfoPopupCardLayout {
        let natural = contentHeight + 2 * pad
        let cardHeight = min(natural, screenHeight * 0.85)
        return make(cardHeight: cardHeight, scrolls: natural > cardHeight + 0.5)
    }

    /// Forced height: the caller has decided the content is long enough that
    /// measuring it is unreliable, so the card always scrolls.
    static func make(fixedHeight: CGFloat, screenHeight: CGFloat) -> InfoPopupCardLayout {
        make(cardHeight: min(fixedHeight, screenHeight * 0.92), scrolls: true)
    }

    private static func make(cardHeight: CGFloat, scrolls: Bool) -> InfoPopupCardLayout {
        InfoPopupCardLayout(
            cardHeight: cardHeight,
            scrolls: scrolls,
            insetTop: scrolls ? scrollInsetTop : 0,
            insetBottom: scrolls ? scrollInsetBottom : 0
        )
    }
}

final class InfoPopupViewController: UIViewController {

    /// The description and person popups are 896 x 460, the info popup 820 wide (measured on device, tvOS 27).
    static let descriptionSize = CGSize(width: 896, height: 460)
    static let infoWidth: CGFloat = 820

    /// Focusable card so the modal owns the remote.
    private final class FocusableCard: UIView {
        override var canBecomeFocused: Bool { true }
    }

    private let content: UIView
    private let cardWidth: CGFloat
    /// When set, the card is forced to this height (clamped to the screen)
    /// instead of measuring the content. Use for content-heavy popups where the
    /// scroll-view content measurement under-reports and leaves the card small.
    private let fixedHeight: CGFloat?
    private let scrollable: Bool
    private let card = FocusableCard()
    private let scroll = UIScrollView()
    /// Card height (scrollable mode): set in viewDidLayoutSubviews to the content's
    /// intrinsic height capped at ~85% screen, so tall content overflows + scrolls.
    private var cardHeight: NSLayoutConstraint!

    /// `scrollable` caps the card at about 85% of the screen and scrolls with Up/Down.
    /// `height` fixes the card height, for long content the measurement under-sizes; it implies scrolling.
    init(content: UIView, width: CGFloat = 760, height: CGFloat? = nil, scrollable: Bool = false) {
        self.content = content
        self.cardWidth = width
        self.fixedHeight = height
        self.scrollable = scrollable || height != nil
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)

        // Prominent Liquid Glass (tvOS 26), falling back to a regular blur.
        let effect: UIVisualEffect
        if #available(tvOS 26.0, *) { effect = UIGlassEffect() }
        else { effect = UIBlurEffect(style: .regular) }
        let blur = UIVisualEffectView(effect: effect)
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 64
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true

        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        card.addSubview(blur)

        content.translatesAutoresizingMaskIntoConstraints = false

        // Match the carousel detail's left margin so the popup padding feels native.
        let pad: CGFloat = PreviewCarouselGeometry.expandedChromeInset
        var constraints: [NSLayoutConstraint] = [
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: cardWidth),

            blur.topAnchor.constraint(equalTo: card.topAnchor),
            blur.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ]
        if scrollable {
            // Cap the card at ~85% of the screen; content scrolls (driven by
            // Up/Down). The card hugs short content and caps tall content.
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.showsVerticalScrollIndicator = false
            scroll.isScrollEnabled = false   // driven manually via DirectionalInputBinding
            scroll.clipsToBounds = true
            // Breathing room so content scrolling in/out fades within the card,
            // not flush against its edges.
            // Insets are owned by `apply(_:)` once the content is measured.
            scroll.contentInset = .zero
            blur.contentView.addSubview(scroll)
            scroll.addSubview(content)
            // Sized in viewDidLayoutSubviews. Tying it to the content here squashes the
            // content to the cap, so it never scrolls.
            cardHeight = card.heightAnchor.constraint(equalToConstant: 320)
            constraints += [
                cardHeight,
                scroll.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: pad),
                scroll.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: pad),
                scroll.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -pad),
                scroll.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -pad),
                content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            ]
        } else {
            blur.contentView.addSubview(content)
            constraints += [
                content.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: pad),
                content.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: pad),
                content.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -pad),
                content.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -pad),
            ]
        }
        NSLayoutConstraint.activate(constraints)

        for pressType in [UIPress.PressType.menu, .select] {
            let tap = UITapGestureRecognizer(target: self, action: #selector(dismissSelf))
            tap.allowedPressTypes = [NSNumber(value: pressType.rawValue)]
            view.addGestureRecognizer(tap)
        }

        // Arrow presses and swipes both drive the popup; the card is the only focus target, so swipes steal nothing.
        var directions: [DirectionalInputBinding.Direction] = scrollable ? [.up, .down] : []
        if onHorizontalMove != nil { directions += [.left, .right] }
        if !directions.isEmpty {
            directionalInput = DirectionalInputBinding(
                view: view,
                directions: directions,
                onTap: { [weak self] direction in
                    switch direction {
                    case .up: self?.scrollContent(by: -440)
                    case .down: self?.scrollContent(by: 440)
                    case .left, .right: self?.onHorizontalMove?(direction)
                    }
                }
            )
        }
    }

    /// Left/Right, for content that pages sideways (the ratings popup's reviews). Set before presenting.
    var onHorizontalMove: ((DirectionalInputBinding.Direction) -> Void)?

    private var directionalInput: DirectionalInputBinding?

    /// Called after the popup finishes dismissing (Menu/Select). Optional.
    var onDismiss: (() -> Void)?

    @objc private func dismissSelf() {
        dismiss(animated: true) { [weak self] in self?.onDismiss?() }
    }
    private func scrollContent(by dy: CGFloat) {
        view.layoutIfNeeded()
        let inset = scroll.adjustedContentInset
        let minY = -inset.top
        let maxY = max(minY, scroll.contentSize.height - scroll.bounds.height + inset.bottom)
        let y = min(max(minY, scroll.contentOffset.y + dy), maxY)
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut]) {
            self.scroll.contentOffset = CGPoint(x: 0, y: y)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard scrollable else { return }
        // 1. Multiline labels measure before their final width and clip the last line, so pin
        // preferredMaxLayoutWidth to the laid-out width. Only on change, so it converges.
        var changed = false
        func fix(_ v: UIView) {
            if let l = v as? UILabel, l.numberOfLines != 1, l.bounds.width > 1,
               abs(l.preferredMaxLayoutWidth - l.bounds.width) > 0.5 {
                l.preferredMaxLayoutWidth = l.bounds.width
                changed = true
            }
            v.subviews.forEach(fix)
        }
        fix(content)
        if changed { view.setNeedsLayout(); return }
        // 2a. Forced height: skip the (unreliable) content measurement entirely
        // and pin the card to the requested height, clamped to the screen. Tall
        // content overflows + scrolls; short content just leaves headroom.
        if let h = fixedHeight {
            apply(InfoPopupCardLayout.make(fixedHeight: h, screenHeight: view.bounds.height))
            return
        }
        // 2. Measure the content view, not `scroll.contentSize`, which under-reports mid-layout.
        // Capped at 85% of the screen.
        let pad = PreviewCarouselGeometry.expandedChromeInset
        let innerWidth = cardWidth - 2 * pad
        let contentH = content.systemLayoutSizeFitting(
            CGSize(width: innerWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height
        guard contentH > 1 else { return }
        apply(InfoPopupCardLayout.make(
            contentHeight: contentH, pad: pad, screenHeight: view.bounds.height))
    }

    /// Single writer for the card height and the scroll insets. Both insets
    /// track the overflow state — leaving the top one applied to content that
    /// fit pushed it 8pt down and clipped its last line.
    private func apply(_ layout: InfoPopupCardLayout) {
        scroll.contentInset.top = layout.insetTop
        scroll.contentInset.bottom = layout.insetBottom
        if !layout.scrolls { scroll.contentOffset = .zero }
        if abs(cardHeight.constant - layout.cardHeight) > 0.5 {
            cardHeight.constant = layout.cardHeight
            view.setNeedsLayout()
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [card] }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }
}

// MARK: - Reusable content builders

enum InfoPopupContent {

    /// Title + genre line + full body (the About "description" popup).
    static func description(title: String, subtitle: String?, body: String?) -> UIView {
        let stack = verticalStack(spacing: 10)
        stack.addArrangedSubview(label(title, size: 31, weight: .bold, color: .white, lines: 2))
        if let subtitle, !subtitle.isEmpty {
            let s = label(subtitle, size: 20, weight: .medium, color: .white.withAlphaComponent(0.6), lines: 1)
            stack.addArrangedSubview(s)
            stack.setCustomSpacing(20, after: s)
        }
        if let body, !body.isEmpty {
            stack.addArrangedSubview(label(body, size: 24, weight: .regular, color: .white.withAlphaComponent(0.9), lines: 0))
        }
        return stack
    }

    /// Every review score, one row each: score, then source and who it's from,
    /// then the critic strip when there is one.
    static func ratings(_ ratings: [MediaRating], strip: ReviewStripView? = nil) -> UIView {
        let stack = verticalStack(spacing: 22)
        stack.addArrangedSubview(label(String(localized: "Ratings"), size: 30, weight: .semibold, color: .white, lines: 1))
        for rating in ratings {
            let score = label(rating.badgeText + (rating.scale ?? ""), size: 30, weight: .bold, color: .white, lines: 1)
            score.widthAnchor.constraint(equalToConstant: 170).isActive = true
            let text = verticalStack(spacing: 2)
            text.addArrangedSubview(label(rating.name, size: 24, weight: .semibold, color: .white, lines: 1))
            text.addArrangedSubview(label(rating.detailText, size: 20, weight: .medium,
                                          color: .white.withAlphaComponent(0.6), lines: 1))
            let row = UIStackView(arrangedSubviews: [score, text])
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 20
            stack.addArrangedSubview(row)
        }
        if let strip {
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(34, after: last) }
            stack.addArrangedSubview(label(String(localized: "Critic Reviews"), size: 24, weight: .semibold, color: .white, lines: 1))
            stack.addArrangedSubview(strip)
        }
        return stack
    }

    /// Common Sense advisory: green-check + age, one-liner, per-topic dot meters.
    static func advisory(_ advisory: ContentAdvisory) -> UIView {
        let stack = verticalStack(spacing: 18)

        let sealRow = UIStackView()
        sealRow.axis = .horizontal
        sealRow.alignment = .center
        sealRow.spacing = 8
        let seal = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        seal.tintColor = .systemGreen
        seal.contentMode = .scaleAspectFit
        seal.translatesAutoresizingMaskIntoConstraints = false
        seal.widthAnchor.constraint(equalToConstant: 30).isActive = true
        seal.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let ageText = advisory.ageRating.map { String(localized: "age \($0.replacingOccurrences(of: "+", with: ""))") } ?? "Common Sense"
        sealRow.addArrangedSubview(seal)
        sealRow.addArrangedSubview(label(ageText, size: 30, weight: .bold, color: .white, lines: 1))
        stack.addArrangedSubview(sealRow)

        if let one = advisory.oneLiner, !one.isEmpty {
            let o = label(one, size: 24, weight: .regular, color: .white.withAlphaComponent(0.9), lines: 0)
            stack.addArrangedSubview(o)
            stack.setCustomSpacing(24, after: o)
        }

        let topics = advisory.topics.sorted { a, b in
            if a.isPositive != b.isPositive { return !a.isPositive }
            return (a.rating ?? 0) > (b.rating ?? 0)
        }
        for topic in topics { stack.addArrangedSubview(topicRow(topic)) }
        return stack
    }

    /// The full structured Info popup (movies/shows): title / genre / synopsis,
    /// a meta + capability-badge row, then Information / Languages / Accessibility
    /// sections stacked vertically. Present with `scrollable: true`.
    static func fullInfo(detail: MediaItemDetail) -> UIView {
        let stack = verticalStack(spacing: 16)
        stack.addArrangedSubview(label(detail.item.title, size: 31, weight: .bold, color: .white, lines: 2))
        if let genre = detail.genres.first, !genre.isEmpty {
            stack.addArrangedSubview(label(genre, size: 21, weight: .semibold, color: .white.withAlphaComponent(0.6), lines: 1))
        }
        let overviewText = detail.item.overview?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let overviewText, !overviewText.isEmpty {
            let syn = label(overviewText, size: 24, weight: .regular, color: .white.withAlphaComponent(0.9), lines: 0)
            stack.addArrangedSubview(syn)
            stack.setCustomSpacing(22, after: syn)
        } else {
            // Seasons (and some shows) carry no synopsis of their own on Plex,
            // which left the popup showing only the title. Say so rather than
            // render a blank card.
            let placeholder = label(String(localized: "No information found on Plex."), size: 24, weight: .regular,
                                     color: .white.withAlphaComponent(0.5), lines: 0)
            stack.addArrangedSubview(placeholder)
            stack.setCustomSpacing(22, after: placeholder)
        }
        stack.addArrangedSubview(metaRow(detail))
        if !detail.ratings.isEmpty {
            let meta = stack.arrangedSubviews.last!
            stack.setCustomSpacing(30, after: meta)
            stack.addArrangedSubview(RatingsGridView.row(detail.ratings))
        }

        let source = detail.primarySource
        let isContainer = detail.item.kind == .season || detail.item.kind == .show

        // Information
        var info: [(String, String)] = []
        if let y = detail.item.year { info.append((String(localized: "Released"), "\(y)")) }
        // Containers have no runtime; surface episode count + watched progress,
        // which is the useful "info" for a season/show.
        if isContainer, let progress = detail.item.childProgress, progress.total > 0 {
            info.append((String(localized: "Episodes"), "\(progress.total)"))
            info.append((String(localized: "Watched"), String(localized: "\(progress.played) of \(progress.total)")))
        }
        if let rt = detail.item.runtime, rt > 0 { info.append((String(localized: "Run Time"), runtimeString(rt))) }
        if let r = detail.contentRating, !r.isEmpty { info.append((String(localized: "Rated"), r)) }
        if let region = detail.regionOfOrigin, !region.isEmpty { info.append((String(localized: "Region of Origin"), region)) }
        addSection(title: String(localized: "Information"), rows: info, to: stack)

        // Languages
        var langs: [(String, String)] = []
        if let first = source?.audioTracks.first, let n = InfoColumnsView.languageName(first.language) {
            langs.append((String(localized: "Original Audio"), n))
        }
        if let audio = source?.audioTracks, !audio.isEmpty {
            let summary = audioSummary(audio)
            if !summary.isEmpty { langs.append((String(localized: "Audio"), summary)) }
        }
        if let subs = source?.subtitleTracks, !subs.isEmpty {
            let names = uniqueOrdered(subs.compactMap { t -> String? in
                guard let n = InfoColumnsView.languageName(t.language) else { return nil }
                return t.isHearingImpaired ? "\(n) (SDH)" : n
            })
            if !names.isEmpty { langs.append((String(localized: "Subtitles"), names.joined(separator: ", "))) }
        }
        addSection(title: String(localized: "Languages"), rows: langs, to: stack)

        // Accessibility
        var access: [(String, String)] = []
        if source?.subtitleTracks.contains(where: { $0.isHearingImpaired }) ?? false {
            access.append(("SDH", String(localized: "Subtitles for the deaf and hard of hearing (SDH) refer to subtitles in the original language with the addition of relevant non-dialogue information.")))
        }
        if source?.audioTracks.contains(where: { ($0.title ?? $0.extendedTitle ?? "").localizedCaseInsensitiveContains("descri") }) ?? false {
            access.append(("AD", String(localized: "Audio descriptions (AD) refer to a narration track describing what is happening on screen, to provide context for those who are blind or have low vision.")))
        }
        if !access.isEmpty { addSection(title: String(localized: "Accessibility"), rows: access, to: stack) }
        return stack
    }

    private static func addSection(title: String, rows: [(String, String)], to stack: UIStackView) {
        guard !rows.isEmpty else { return }
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(30, after: last) }
        let col = InfoColumnView()
        col.configure(title: title, rows: rows, style: .popup)
        stack.addArrangedSubview(col)
    }

    private static func metaRow(_ detail: MediaItemDetail) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        var parts: [String] = []
        if let y = detail.item.year { parts.append("\(y)") }
        if let rt = detail.item.runtime, rt > 0 { parts.append(runtimeString(rt)) }
        if let r = detail.contentRating, !r.isEmpty { parts.append(r) }
        if !parts.isEmpty {
            row.addArrangedSubview(label(parts.joined(separator: "  ·  "), size: 20, weight: .semibold, color: .white.withAlphaComponent(0.7), lines: 1))
        }
        let source = detail.primarySource
        var badges = source?.qualityBadges() ?? []
        if source?.subtitleTracks.contains(where: { $0.isHearingImpaired }) ?? false { badges.append("SDH") }
        if source?.audioTracks.contains(where: { ($0.title ?? $0.extendedTitle ?? "").localizedCaseInsensitiveContains("descri") }) ?? false { badges.append("AD") }
        for raw in badges {
            let text = raw.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { row.addArrangedSubview(badgeLabel(text, filled: text == "4K")) }
        }
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        return row
    }

    private static func badgeLabel(_ text: String, filled: Bool = false) -> UIView {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 16, weight: .semibold)
        l.textColor = filled ? .black : .white.withAlphaComponent(0.9)
        l.translatesAutoresizingMaskIntoConstraints = false
        let container = UIView()
        container.layer.borderWidth = filled ? 0 : 1
        container.layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        container.layer.cornerRadius = 5
        container.backgroundColor = filled ? .white.withAlphaComponent(0.9) : .clear
        container.addSubview(l)
        NSLayoutConstraint.activate([
            l.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            l.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),
            l.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 7),
            l.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -7),
        ])
        return container
    }

    /// "English (Dolby Atmos, Dolby 5.1, AAC, AD), French (Canada) (…)" — group
    /// audio tracks by language and list each language's distinct formats.
    private static func audioSummary(_ tracks: [AudioTrack]) -> String {
        var byLang: [String: [String]] = [:]
        var order: [String] = []
        for t in tracks {
            guard let name = InfoColumnsView.languageName(t.language) else { continue }
            if byLang[name] == nil { byLang[name] = []; order.append(name) }
            let fmt = audioFormat(t)
            if !fmt.isEmpty, !(byLang[name]?.contains(fmt) ?? false) { byLang[name]?.append(fmt) }
            if (t.title ?? t.extendedTitle ?? "").localizedCaseInsensitiveContains("descri"),
               !(byLang[name]?.contains("AD") ?? false) { byLang[name]?.append("AD") }
        }
        return order.map { name in
            let fmts = byLang[name] ?? []
            return fmts.isEmpty ? name : "\(name) (\(fmts.joined(separator: ", ")))"
        }.joined(separator: ", ")
    }

    private static func audioFormat(_ t: AudioTrack) -> String {
        let codec = t.codec.lowercased()
        let title = (t.extendedTitle ?? t.title ?? "").lowercased()
        if title.contains("atmos") || (t.channelLayout ?? "").lowercased().contains("atmos") {
            return "Dolby Atmos"
        }
        let layout = t.channelLayout ?? t.channels.map { $0 >= 6 ? "\($0 - 1).1" : ($0 >= 2 ? "Stereo" : "Mono") } ?? ""
        let isDolby = (codec == "eac3" || codec == "ac3" || codec == "truehd")
        if isDolby, !layout.isEmpty, layout != "Stereo", layout != "Mono" { return "Dolby \(layout)" }
        switch codec {
        case "aac": return "AAC"
        case "dts", "dca": return "DTS"
        case "truehd": return "Dolby TrueHD"
        case "flac": return "FLAC"
        case "ac3", "eac3": return layout.isEmpty ? "Dolby Digital" : "Dolby \(layout)"
        default: return layout.isEmpty ? codec.uppercased() : layout
        }
    }

    private static func runtimeString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded()); let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return m > 0 ? String(localized: "\(h) hr \(m) min") : String(localized: "\(h) hr") }
        return String(localized: "\(m) min")
    }

    private static func uniqueOrdered(_ values: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for v in values where !seen.contains(v) { seen.insert(v); out.append(v) }
        return out
    }

    // MARK: helpers

    private static func verticalStack(spacing: CGFloat) -> UIStackView {
        let s = UIStackView()
        s.axis = .vertical
        s.alignment = .fill
        s.spacing = spacing
        return s
    }

    private static func label(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor, lines: Int, monospaced: Bool = false) -> UILabel {
        let l = UILabel()
        l.font = monospaced ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.numberOfLines = lines
        l.text = text
        return l
    }

    /// What's New: title, each version with its bullets, and a Done pill that only shows Select (the card
    /// holds focus). Present content-sized.
    static func changelog(_ entries: [(version: String, features: [String])]) -> UIView {
        let stack = verticalStack(spacing: 8)
        stack.addArrangedSubview(label(String(localized: "What's New"), size: 44, weight: .bold, color: .white, lines: 1))
        for (i, entry) in entries.enumerated() {
            if i > 0, let last = stack.arrangedSubviews.last { stack.setCustomSpacing(40, after: last) }
            let ver = label(String(localized: "Version \(entry.version)"), size: 22, weight: .regular, color: .white.withAlphaComponent(0.5), lines: 1)
            stack.addArrangedSubview(ver)
            stack.setCustomSpacing(24, after: ver)
            addChangelogLines(entry.features, to: stack, after: ver)
        }

        let done = label(String(localized: "Done"), size: 26, weight: .semibold, color: .black, lines: 1)
        done.textAlignment = .center
        done.translatesAutoresizingMaskIntoConstraints = false
        let pill = UIView()
        pill.backgroundColor = .white
        pill.layer.cornerRadius = 28
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(done)
        let pillRow = UIView()
        pillRow.translatesAutoresizingMaskIntoConstraints = false
        pillRow.addSubview(pill)
        NSLayoutConstraint.activate([
            done.topAnchor.constraint(equalTo: pill.topAnchor, constant: 14),
            done.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -14),
            done.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 48),
            done.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -48),
            pill.topAnchor.constraint(equalTo: pillRow.topAnchor),
            pill.bottomAnchor.constraint(equalTo: pillRow.bottomAnchor),
            pill.centerXAnchor.constraint(equalTo: pillRow.centerXAnchor)
        ])
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(32, after: last) }
        stack.addArrangedSubview(pillRow)
        // Breathing room below the Done pill so it never sits tight against the
        // card's bottom margin. The card hugs content, so without this the pill
        // looks clipped on short changelogs; with it, it stays clear at any length.
        let bottomSpacer = UIView()
        bottomSpacer.translatesAutoresizingMaskIntoConstraints = false
        bottomSpacer.heightAnchor.constraint(equalToConstant: 24).isActive = true
        stack.setCustomSpacing(0, after: pillRow)
        stack.addArrangedSubview(bottomSpacer)
        return stack
    }

    /// Full changelog history: every released version's notes, newest first.
    /// Present with `scrollable: true` — Up/Down pages, Select/Menu dismiss.
    static func changelogHistory(_ entries: [(version: String, features: [String])]) -> UIView {
        let stack = verticalStack(spacing: 8)
        stack.addArrangedSubview(label(String(localized: "Changelog"), size: 44, weight: .bold, color: .white, lines: 1))
        for entry in entries {
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(40, after: last) }
            let ver = label(String(localized: "Version \(entry.version)"), size: 27, weight: .semibold, color: .white.withAlphaComponent(0.92), lines: 1)
            stack.addArrangedSubview(ver)
            stack.setCustomSpacing(14, after: ver)
            addChangelogLines(entry.features, to: stack, after: ver)
        }
        return stack
    }

    /// One entry's lines: `## ` headings, `> ` notes, and bullets.
    private static func addChangelogLines(_ lines: [String], to stack: UIStackView, after version: UIView) {
        for line in lines {
            if let heading = WhatsNewView.heading(line) {
                if let last = stack.arrangedSubviews.last, last !== version { stack.setCustomSpacing(22, after: last) }
                let head = label(heading, size: 25, weight: .bold, color: .white, lines: 0)
                stack.addArrangedSubview(head)
                stack.setCustomSpacing(10, after: head)
            } else if let note = WhatsNewView.note(line) {
                let text = label(note, size: 24, weight: .medium, color: .white.withAlphaComponent(0.85), lines: 0)
                text.attributedText = changelogText(note, font: text.font, color: text.textColor)
                stack.addArrangedSubview(text)
                stack.setCustomSpacing(18, after: text)
            } else {
                stack.addArrangedSubview(changelogBullet(line))
            }
        }
    }

    /// One changelog feature: a small dot (top-aligned to the first text line) +
    /// a wrapping label.
    private static func changelogBullet(_ text: String) -> UIView {
        let dot = UIView()
        dot.backgroundColor = UIColor.white.withAlphaComponent(0.55)
        dot.layer.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        let dotWrap = UIView()
        dotWrap.translatesAutoresizingMaskIntoConstraints = false
        dotWrap.addSubview(dot)
        NSLayoutConstraint.activate([
            dotWrap.widthAnchor.constraint(equalToConstant: 10),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            dot.centerXAnchor.constraint(equalTo: dotWrap.centerXAnchor),
            dot.topAnchor.constraint(equalTo: dotWrap.topAnchor, constant: 12)
        ])
        let textLabel = label(text, size: 24, weight: .medium, color: .white.withAlphaComponent(0.85), lines: 0)
        textLabel.attributedText = changelogText(text, font: textLabel.font, color: textLabel.textColor)
        let row = UIStackView(arrangedSubviews: [dotWrap, textLabel])
        row.axis = .horizontal
        row.alignment = .fill
        row.spacing = 14
        return row
    }

    /// A line's text, with a trailing `@name` drawn as a small tag.
    private static func changelogText(_ line: String, font: UIFont, color: UIColor) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        guard let range = line.range(of: #" @[A-Za-z0-9-]+$"#, options: .regularExpression) else {
            return NSAttributedString(string: line, attributes: attributes)
        }
        let result = NSMutableAttributedString(string: String(line[..<range.lowerBound]) + "  ", attributes: attributes)
        let tag = NSTextAttachment(image: changelogTag(String(line[range].dropFirst())))
        tag.bounds = CGRect(origin: CGPoint(x: 0, y: (font.capHeight - tag.image!.size.height) / 2), size: tag.image!.size)
        result.append(NSAttributedString(attachment: tag))
        return result
    }

    private static func changelogTag(_ name: String) -> UIImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 19, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        let text = (name as NSString).size(withAttributes: attributes)
        let size = CGSize(width: ceil(text.width) + 24, height: ceil(text.height) + 8)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.white.withAlphaComponent(0.18).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2).fill()
            (name as NSString).draw(at: CGPoint(x: 12, y: 4), withAttributes: attributes)
        }
    }

    /// Licenses: Rivulet's own, the TMDB attribution, then every bundled dependency's full
    /// license text. Present with `scrollable: true`.
    static func acknowledgements() -> UIView {
        let stack = verticalStack(spacing: 12)
        stack.addArrangedSubview(label(String(localized: "Licenses & Legal"), size: 40, weight: .bold, color: .white, lines: 1))

        let app = label(OpenSourceLicenses.appLicense, size: 24, weight: .regular, color: .white.withAlphaComponent(0.85), lines: 0)
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[0])
        stack.addArrangedSubview(app)

        if let tmdb = UIImage(named: "TMDBLogo") {
            let iv = UIImageView(image: tmdb)
            iv.contentMode = .scaleAspectFit
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.heightAnchor.constraint(equalToConstant: 30).isActive = true
            let row = UIStackView(arrangedSubviews: [iv, UIView()])  // trailing spacer → left-aligned
            row.axis = .horizontal
            row.alignment = .center
            stack.addArrangedSubview(row)
        }

        for entry in OpenSourceLicenses.entries {
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(28, after: last) }
            stack.addArrangedSubview(label(entry.name, size: 28, weight: .semibold, color: .white, lines: 1))
            stack.addArrangedSubview(label(entry.summary, size: 22, weight: .regular, color: .white.withAlphaComponent(0.78), lines: 0))
            stack.addArrangedSubview(label(entry.licenseText, size: 17, weight: .regular, color: .white.withAlphaComponent(0.55), lines: 0, monospaced: true))
        }
        return stack
    }

    private static func topicRow(_ topic: ContentAdvisory.Topic) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 16

        let name = label(topic.label, size: 22, weight: .regular, color: .white.withAlphaComponent(0.92), lines: 1)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let dots = UIStackView()
        dots.axis = .horizontal
        dots.spacing = 8
        dots.alignment = .center
        dots.setContentHuggingPriority(.required, for: .horizontal)
        let filled = max(0, min(5, topic.rating ?? 0))
        for i in 0..<5 {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 12).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 12).isActive = true
            dot.layer.cornerRadius = 6
            dot.backgroundColor = i < filled ? UIColor.white.withAlphaComponent(0.95) : UIColor.white.withAlphaComponent(0.22)
            dots.addArrangedSubview(dot)
        }
        row.addArrangedSubview(name)
        row.addArrangedSubview(dots)
        return row
    }
}
