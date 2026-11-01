// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerInsightsPanelView.swift
//  Rivulet
//
//  The Insights card row: one sub-tab's cast or trivia, laid out
//  sideways and scrolled with focus. Cast cards open the actor view; trivia
//  cards size to their text so a fact reads in full.
//

import UIKit

final class InsightsCastListView: UIView {

    private enum Metrics {
        static let gap: CGFloat = 40
    }

    var onSelectCast: (MediaPerson) -> Void

    private let cast: [MediaPerson]
    private let trivia: TitleTrivia?
    private let suppressedTriviaIDs: Set<String>
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let attribution = UILabel()
    /// The card focus was last on, so returning from an actor lands back on it.
    private weak var lastFocusedCard: UIView?

    /// Card counts for the shown tab, for tests.
    var triviaRowCount: Int { stack.arrangedSubviews.filter { $0 is InsightsTriviaCardView }.count }
    var hasTriviaSection: Bool { triviaRowCount > 0 }
    var castRowCount: Int { stack.arrangedSubviews.filter { $0 is InsightsCastCardView }.count }

    init(
        cast: [MediaPerson],
        trivia: TitleTrivia?,
        suppressedTriviaIDs: Set<String>,
        initialTab: InsightsTab,
        onSelectCast: @escaping (MediaPerson) -> Void
    ) {
        self.cast = cast
        self.trivia = trivia
        self.suppressedTriviaIDs = suppressedTriviaIDs
        self.onSelectCast = onSelectCast
        super.init(frame: .zero)

        // Cards float over the video and run off the screen edge, like the Chapters row.
        scrollView.clipsToBounds = false
        scrollView.showsHorizontalScrollIndicator = false
        stack.axis = .horizontal
        stack.spacing = Metrics.gap
        stack.alignment = .center
        scrollView.addSubview(stack)

        attribution.font = .systemFont(ofSize: 15, weight: .regular)
        attribution.textColor = UIColor.white.withAlphaComponent(0.6)
        applyChromeTextShadow([attribution])
        attribution.text = trivia.map { "Info from " + $0.attribution.map(\.name).joined(separator: " · ") }
        attribution.isHidden = true

        [scrollView, stack, attribution].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(scrollView)
        addSubview(attribution)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            attribution.trailingAnchor.constraint(equalTo: trailingAnchor),
            attribution.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        buildCards(for: initialTab)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTab(_ tab: InsightsTab) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        scrollView.contentOffset.x = 0
        buildCards(for: tab)
    }

    private func buildCards(for tab: InsightsTab) {
        let facts: [TriviaFact]
        switch tab {
        case .cast:
            for person in cast {
                let card = InsightsCastCardView(person: person)
                card.onPress = { [weak self] in self?.onSelectCast(person) }
                stack.addArrangedSubview(card)
            }
            facts = []
        case .topTen:
            facts = trivia?.topTenFacts(suppressed: suppressedTriviaIDs) ?? []
        case .category(let category):
            facts = (trivia?.visibleFacts(suppressed: suppressedTriviaIDs) ?? []).filter { $0.category == category }
        }
        for fact in facts {
            stack.addArrangedSubview(InsightsTriviaCardView(fact: fact, showsCategory: tab == .topTen))
        }
        attribution.isHidden = facts.isEmpty || (trivia?.attribution.isEmpty ?? true)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let card = lastFocusedCard, card.superview === stack { return [card] }
        return stack.arrangedSubviews.first.map { [$0] } ?? []
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if let next = context.nextFocusedView, next.superview === stack { lastFocusedCard = next }
    }
}

// MARK: - Cast card

/// Apple's InSight cards sit on a blur material, not glass. A
/// glass view per card also cost about 2.5 ms each to build on a pill move.
private func makeInsightsCardMaterial() -> UIView {
    let view = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    view.isUserInteractionEnabled = false
    view.clipsToBounds = true
    view.layer.cornerRadius = InsightsCastCardView.Metrics.radius
    view.layer.cornerCurve = .continuous
    return view
}

/// A cast member: round headshot, name and role. Select opens their bio.
/// Sizes match the Apple TV app's InSight cast card.
final class InsightsCastCardView: UIControl {

    enum Metrics {
        static let size = CGSize(width: 260, height: 230)
        static let radius: CGFloat = 48
        static let padding = UIEdgeInsets(top: 24, left: 20, bottom: 24, right: 20)
        static let headshot: CGFloat = 116
        static let headshotToName: CGFloat = 11
    }

    var onPress: (() -> Void)?
    private let plate = UIView()
    private let headshot = UIImageView()
    private let name = UILabel()
    private let role = UILabel()
    private var imageTask: Task<Void, Never>?

    init(person: MediaPerson) {
        super.init(frame: .zero)
        let material = makeInsightsCardMaterial()
        // Apple's focused card is a white 0.9 platter with dark text.
        plate.backgroundColor = UIColor.white.withAlphaComponent(0.9)
        plate.layer.cornerRadius = Metrics.radius
        plate.layer.cornerCurve = .continuous
        plate.alpha = 0
        plate.isUserInteractionEnabled = false

        let shadow = UIView()
        shadow.isUserInteractionEnabled = false
        shadow.layer.shadowColor = UIColor.black.cgColor
        shadow.layer.shadowOpacity = 0.16
        shadow.layer.shadowOffset = CGSize(width: 0, height: 8)
        shadow.layer.shadowRadius = 6
        shadow.layer.shadowPath = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: Metrics.headshot, height: Metrics.headshot)).cgPath

        headshot.contentMode = .scaleAspectFill
        headshot.clipsToBounds = true
        headshot.layer.cornerRadius = Metrics.headshot / 2
        headshot.layer.borderWidth = 0.5
        headshot.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        headshot.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        headshot.tintColor = UIColor.white.withAlphaComponent(0.35)
        headshot.image = UIImage(systemName: "person.fill")

        name.text = person.name
        name.font = .preferredFont(forTextStyle: .caption1)
        name.textAlignment = .center
        role.text = person.role
        role.font = .preferredFont(forTextStyle: .caption2)
        role.textAlignment = .center
        applyTextColors(focused: false)

        [material, plate, shadow, headshot, name, role].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Metrics.size.width),
            heightAnchor.constraint(equalToConstant: Metrics.size.height),
            material.topAnchor.constraint(equalTo: topAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),
            material.leadingAnchor.constraint(equalTo: leadingAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),
            plate.topAnchor.constraint(equalTo: topAnchor),
            plate.bottomAnchor.constraint(equalTo: bottomAnchor),
            plate.leadingAnchor.constraint(equalTo: leadingAnchor),
            plate.trailingAnchor.constraint(equalTo: trailingAnchor),
            headshot.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.padding.top),
            headshot.centerXAnchor.constraint(equalTo: centerXAnchor),
            headshot.widthAnchor.constraint(equalToConstant: Metrics.headshot),
            headshot.heightAnchor.constraint(equalToConstant: Metrics.headshot),
            shadow.topAnchor.constraint(equalTo: headshot.topAnchor),
            shadow.leadingAnchor.constraint(equalTo: headshot.leadingAnchor),
            shadow.widthAnchor.constraint(equalToConstant: Metrics.headshot),
            shadow.heightAnchor.constraint(equalToConstant: Metrics.headshot),
            name.topAnchor.constraint(equalTo: headshot.bottomAnchor, constant: Metrics.headshotToName),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.padding.left),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.padding.right),
            role.topAnchor.constraint(equalTo: name.bottomAnchor),
            role.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.padding.left),
            role.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.padding.right),
        ])

        if let url = person.imageURL {
            imageTask = Task { [weak self] in
                let image = await ImageCacheManager.shared.image(for: url)
                guard let self, !Task.isCancelled, let image else { return }
                self.headshot.image = image
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { imageTask?.cancel() }

    override var canBecomeFocused: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            onPress?()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.animateFocusChange(gained: focused) {
            self.plate.alpha = focused ? 1 : 0
            self.applyTextColors(focused: focused)
            self.transform = focused ? CGAffineTransform(scaleX: 1.05, y: 1.05) : .identity
        }
    }

    private func applyTextColors(focused: Bool) {
        let ink: UIColor = focused ? .black : .white
        name.textColor = ink
        role.textColor = ink.withAlphaComponent(0.6)
    }
}

// MARK: - Trivia card

/// One fact. The card widens until the text fits five lines, so it reads in
/// full; only an outsized fact shrinks its type. Focusable so focus scrolls the row.
final class InsightsTriviaCardView: UIView {

    private enum Metrics {
        static let height = InsightsCastCardView.Metrics.size.height
        static let padding = InsightsCastCardView.Metrics.padding
        static let widths: [CGFloat] = [460, 600, 760, 920]
        static let categoryHeight: CGFloat = 26
    }

    static let textFont = UIFont.systemFont(ofSize: 23, weight: .regular)

    /// The narrowest card that shows `text` whole.
    static func width(for text: String, showsCategory: Bool) -> CGFloat {
        let room = Metrics.height - Metrics.padding.top - Metrics.padding.bottom
            - (showsCategory ? Metrics.categoryHeight : 0)
        for width in Metrics.widths {
            let bounds = (text as NSString).boundingRect(
                with: CGSize(width: width - Metrics.padding.left - Metrics.padding.right, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: textFont], context: nil)
            if ceil(bounds.height) <= room { return width }
        }
        return Metrics.widths.last ?? 920
    }

    private let background = UIView()

    init(fact: TriviaFact, showsCategory: Bool) {
        super.init(frame: .zero)
        let material = makeInsightsCardMaterial()
        background.backgroundColor = .clear
        background.layer.cornerRadius = InsightsCastCardView.Metrics.radius
        background.layer.cornerCurve = .continuous
        background.isUserInteractionEnabled = false

        let category = UILabel()
        category.attributedText = NSAttributedString(
            string: fact.category.tabDisplayName.uppercased(),
            attributes: [.font: UIFont.systemFont(ofSize: 15, weight: .semibold),
                         .foregroundColor: UIColor.white.withAlphaComponent(0.45), .kern: 1.0])
        category.isHidden = !showsCategory

        let text = UILabel()
        text.text = fact.text
        text.font = Self.textFont
        text.textColor = .white
        text.numberOfLines = 0
        text.adjustsFontSizeToFitWidth = true
        text.minimumScaleFactor = 0.7

        [material, background, category, text].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        let padding = Metrics.padding
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width(for: fact.text, showsCategory: showsCategory)),
            heightAnchor.constraint(equalToConstant: Metrics.height),
            material.topAnchor.constraint(equalTo: topAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),
            material.leadingAnchor.constraint(equalTo: leadingAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            category.topAnchor.constraint(equalTo: topAnchor, constant: padding.top),
            category.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding.left),
            text.topAnchor.constraint(equalTo: topAnchor, constant: padding.top + (showsCategory ? Metrics.categoryHeight : 0)),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding.left),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding.right),
            text.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -padding.bottom),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFocused: Bool { true }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.animateFocusChange(gained: focused) {
            self.background.backgroundColor = focused ? UIColor.white.withAlphaComponent(0.12) : .clear
            self.transform = focused ? CGAffineTransform(scaleX: 1.03, y: 1.03) : .identity
        }
    }
}
