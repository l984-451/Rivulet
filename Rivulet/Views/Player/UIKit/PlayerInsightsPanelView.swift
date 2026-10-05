// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerInsightsPanelView.swift
//  Rivulet
//
//  The Insights box's card row: one sub-tab's cast or trivia, laid out
//  sideways and scrolled with focus. Cast cards open the actor view; trivia
//  cards size to their text so a fact reads in full.
//

import UIKit

final class InsightsCastListView: UIView {

    private enum Metrics {
        static let cardHeight: CGFloat = 206
        static let gap: CGFloat = 24
        static let sideInset: CGFloat = 30
    }

    var onSelectCast: (MediaPerson) -> Void

    private let cast: [MediaPerson]
    private let trivia: TitleTrivia?
    private let suppressedTriviaIDs: Set<String>
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let attribution = UILabel()

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

        // Cards scroll under the box's own rounded edge.
        scrollView.clipsToBounds = true
        scrollView.layer.cornerRadius = 48
        scrollView.layer.cornerCurve = .continuous
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInset = UIEdgeInsets(top: 0, left: Metrics.sideInset, bottom: 0, right: Metrics.sideInset)
        stack.axis = .horizontal
        stack.spacing = Metrics.gap
        stack.alignment = .center
        scrollView.addSubview(stack)

        attribution.font = .systemFont(ofSize: 15, weight: .regular)
        attribution.textColor = UIColor.white.withAlphaComponent(0.35)
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
            attribution.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            attribution.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        buildCards(for: initialTab)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTab(_ tab: InsightsTab) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        scrollView.contentOffset.x = -Metrics.sideInset
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
        stack.arrangedSubviews.first.map { [$0] } ?? []
    }
}

// MARK: - Cast card

/// A cast member: round headshot, name and role. Select opens their bio.
final class InsightsCastCardView: UIControl {

    private enum Metrics {
        static let size = CGSize(width: 220, height: 206)
        static let headshot: CGFloat = 128
    }

    var onPress: (() -> Void)?
    private let plate = UIView()
    private let headshot = UIImageView()
    private var imageTask: Task<Void, Never>?

    init(person: MediaPerson) {
        super.init(frame: .zero)
        plate.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        plate.layer.cornerRadius = 24
        plate.layer.cornerCurve = .continuous
        plate.alpha = 0
        plate.isUserInteractionEnabled = false

        headshot.contentMode = .scaleAspectFill
        headshot.clipsToBounds = true
        headshot.layer.cornerRadius = Metrics.headshot / 2
        headshot.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        headshot.tintColor = UIColor.white.withAlphaComponent(0.35)
        headshot.image = UIImage(systemName: "person.fill")

        let name = UILabel()
        name.text = person.name
        name.font = .systemFont(ofSize: 23, weight: .semibold)
        name.textColor = .white
        name.textAlignment = .center
        let role = UILabel()
        role.text = person.role
        role.font = .systemFont(ofSize: 19, weight: .regular)
        role.textColor = UIColor.white.withAlphaComponent(0.6)
        role.textAlignment = .center

        [plate, headshot, name, role].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Metrics.size.width),
            heightAnchor.constraint(equalToConstant: Metrics.size.height),
            plate.topAnchor.constraint(equalTo: topAnchor),
            plate.bottomAnchor.constraint(equalTo: bottomAnchor),
            plate.leadingAnchor.constraint(equalTo: leadingAnchor),
            plate.trailingAnchor.constraint(equalTo: trailingAnchor),
            headshot.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            headshot.centerXAnchor.constraint(equalTo: centerXAnchor),
            headshot.widthAnchor.constraint(equalToConstant: Metrics.headshot),
            headshot.heightAnchor.constraint(equalToConstant: Metrics.headshot),
            name.topAnchor.constraint(equalTo: headshot.bottomAnchor, constant: 10),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            role.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            role.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            role.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
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
            self.transform = focused ? CGAffineTransform(scaleX: 1.05, y: 1.05) : .identity
        }
    }
}

// MARK: - Trivia card

/// One fact. The card widens until the text fits five lines, so it reads in
/// full; only an outsized fact shrinks its type. Focusable so focus scrolls the row.
final class InsightsTriviaCardView: UIView {

    private enum Metrics {
        static let height: CGFloat = 206
        static let padding = UIEdgeInsets(top: 18, left: 22, bottom: 18, right: 22)
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
        background.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        background.layer.cornerRadius = 24
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

        [background, category, text].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        let padding = Metrics.padding
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width(for: fact.text, showsCategory: showsCategory)),
            heightAnchor.constraint(equalToConstant: Metrics.height),
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
            self.background.backgroundColor = UIColor.white.withAlphaComponent(focused ? 0.18 : 0.08)
            self.transform = focused ? CGAffineTransform(scaleX: 1.03, y: 1.03) : .identity
        }
    }
}
