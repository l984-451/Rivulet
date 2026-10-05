// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InsightsActorView.swift
//  Rivulet
//
//  A cast member inside the Insights box, laid out like the Info card:
//  portrait, name and a four-line bio on the left, their filmography as a row
//  of posters on the right. Select on the bio spreads it across the box to
//  read; Menu folds it back.
//

import UIKit

final class InsightsActorView: UIView {

    private enum Metrics {
        static let portrait = CGRect(x: 23, y: 23, width: 136, height: 204)
        static let textX: CGFloat = 199
        static let nameTop: CGFloat = 33
        static let bioTop: CGFloat = 80
        static let bioWidth: CGFloat = 600
        static let readingWidth: CGFloat = 1500
        static let postersLeading: CGFloat = 860
        static let posterGap: CGFloat = 20
    }

    private let person: MediaPerson
    /// Internal for tests: the loaded detail, once one has been applied.
    private(set) var detail: PersonDetail?

    private let portrait = UIImageView()
    private let bio = PlayerSummaryButton(text: "Loading…", lines: 4)
    private let posterScroll = UIScrollView()
    private let posterStack = UIStackView()
    private var bioWidth: NSLayoutConstraint?
    private var portraitTask: Task<Void, Never>?
    private var isReading = false

    init(person: MediaPerson) {
        self.person = person
        super.init(frame: .zero)

        portrait.contentMode = .scaleAspectFill
        portrait.clipsToBounds = true
        portrait.layer.cornerRadius = 25
        portrait.layer.cornerCurve = .continuous
        portrait.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        portrait.tintColor = UIColor.white.withAlphaComponent(0.35)
        portrait.image = UIImage(systemName: "person.fill")

        let name = UILabel()
        name.text = person.name
        name.font = .systemFont(ofSize: 31, weight: .bold)
        name.textColor = .white

        bio.onPress = { [weak self] in self?.setReading(!(self?.isReading ?? false)) }

        posterScroll.clipsToBounds = true
        posterScroll.showsHorizontalScrollIndicator = false
        // Room for a focused poster's growth at the ends.
        posterScroll.contentInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        posterStack.axis = .horizontal
        posterStack.spacing = Metrics.posterGap
        posterStack.alignment = .center
        posterScroll.addSubview(posterStack)

        [portrait, name, bio, posterScroll, posterStack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        [portrait, name, bio, posterScroll].forEach { addSubview($0) }
        let bioWidth = bio.textWidth.constraint(equalToConstant: Metrics.bioWidth)
        self.bioWidth = bioWidth
        NSLayoutConstraint.activate([
            portrait.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.portrait.minX),
            portrait.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.portrait.minY),
            portrait.widthAnchor.constraint(equalToConstant: Metrics.portrait.width),
            portrait.heightAnchor.constraint(equalToConstant: Metrics.portrait.height),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.textX),
            name.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.nameTop),
            name.trailingAnchor.constraint(lessThanOrEqualTo: posterScroll.leadingAnchor, constant: -20),
            bio.textLeading.constraint(equalTo: leadingAnchor, constant: Metrics.textX),
            bio.textTop.constraint(equalTo: topAnchor, constant: Metrics.bioTop),
            bioWidth,
            posterScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.postersLeading),
            posterScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -23),
            posterScroll.topAnchor.constraint(equalTo: topAnchor),
            posterScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            posterStack.topAnchor.constraint(equalTo: posterScroll.contentLayoutGuide.topAnchor),
            posterStack.bottomAnchor.constraint(equalTo: posterScroll.contentLayoutGuide.bottomAnchor),
            posterStack.leadingAnchor.constraint(equalTo: posterScroll.contentLayoutGuide.leadingAnchor),
            posterStack.trailingAnchor.constraint(equalTo: posterScroll.contentLayoutGuide.trailingAnchor),
            posterStack.heightAnchor.constraint(equalTo: posterScroll.frameLayoutGuide.heightAnchor),
        ])
        loadPortrait(person.imageURL)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { portraitTask?.cancel() }

    func populate(_ detail: PersonDetail) {
        self.detail = detail
        let text = detail.biography?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        bio.setText(text.isEmpty ? "No biography available." : text)
        if let url = detail.portraitURL, url != person.imageURL { loadPortrait(url) }
        for entry in detail.movies + detail.shows {
            posterStack.addArrangedSubview(InsightsPosterCardView(item: entry.item))
        }
    }

    /// The load failed or found nothing: portrait and name stay, no posters.
    func showDetailsUnavailable() {
        bio.setText("No details available.")
    }

    /// Menu folds a reading bio back first.
    func handleMenuPress() -> Bool {
        guard isReading else { return false }
        setReading(false)
        return true
    }

    private func setReading(_ reading: Bool) {
        isReading = reading
        bioWidth?.constant = reading ? Metrics.readingWidth : Metrics.bioWidth
        bio.setShrinksToFit(reading)
        UIView.animate(withDuration: 0.25) {
            self.posterScroll.alpha = reading ? 0 : 1
            self.layoutIfNeeded()
        }
        posterScroll.isUserInteractionEnabled = !reading
    }

    private func loadPortrait(_ url: URL?) {
        guard let url else { return }
        portraitTask?.cancel()
        portraitTask = Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            guard let self, !Task.isCancelled, let image else { return }
            self.portrait.image = image
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [bio] }
}

/// One filmography title: a poster, display only. Focusable so focus scrolls the row.
private final class InsightsPosterCardView: UIView {

    private static let size = CGSize(width: 136, height: 204)
    private let imageView = UIImageView()
    private var imageTask: Task<Void, Never>?

    init(item: MediaItem) {
        super.init(frame: .zero)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 16
        imageView.layer.cornerCurve = .continuous
        imageView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        imageView.tintColor = UIColor.white.withAlphaComponent(0.35)
        imageView.contentMode = .center
        imageView.image = UIImage(systemName: "film")
        addSubview(imageView)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        if let url = item.artwork.poster {
            imageTask = Task { [weak self] in
                let image = await ImageCacheManager.shared.image(for: url)
                guard let self, !Task.isCancelled, let image else { return }
                self.imageView.contentMode = .scaleAspectFill
                self.imageView.image = image
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { imageTask?.cancel() }

    override var canBecomeFocused: Bool { true }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.animateFocusChange(gained: focused) {
            self.transform = focused ? CGAffineTransform(scaleX: 1.06, y: 1.06) : .identity
        }
    }
}
