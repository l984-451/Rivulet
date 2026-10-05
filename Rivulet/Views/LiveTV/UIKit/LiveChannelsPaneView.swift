// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveChannelsPaneView.swift
//  Rivulet
//
//  The Live TV player's Channels pane, in the same glass box as VOD's Info,
//  Details and Insights: every channel in guide order as a row of cards
//  (programme art, "6 · FOX 6", what's on now), opened on the one playing.
//

import UIKit

final class LiveChannelsPaneView: UIView {

    private enum Metrics {
        static let height: CGFloat = 250
        static let radius: CGFloat = 48
        static let gap: CGFloat = 24
        static let sideInset: CGFloat = 30
    }

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var cards: [LiveChannelCardView] = []
    private var didScrollToCurrent = false

    init(channels: [UnifiedChannel],
         currentChannelId: String?,
         programProvider: @MainActor (UnifiedChannel) -> UnifiedProgram?,
         onSelect: @escaping (UnifiedChannel) -> Void) {
        super.init(frame: .zero)
        let glass = makePaneGlass(cornerRadius: Metrics.radius)
        // Cards scroll under the box's own rounded edge.
        scrollView.clipsToBounds = true
        scrollView.layer.cornerRadius = Metrics.radius
        scrollView.layer.cornerCurve = .continuous
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInset = UIEdgeInsets(top: 0, left: Metrics.sideInset, bottom: 0, right: Metrics.sideInset)
        stack.axis = .horizontal
        stack.spacing = Metrics.gap
        stack.alignment = .center
        scrollView.addSubview(stack)
        cards = channels.map { channel in
            let card = LiveChannelCardView(channel: channel, program: programProvider(channel),
                                           isCurrent: channel.id == currentChannelId)
            card.onPress = { onSelect(channel) }
            return card
        }
        cards.forEach { stack.addArrangedSubview($0) }

        [glass, scrollView, stack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(glass)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.height),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Opens on the playing channel, placed before the pane's first frame.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard !didScrollToCurrent, scrollView.bounds.width > 0,
              let current = cards.first(where: \.isCurrent) else { return }
        didScrollToCurrent = true
        stack.layoutIfNeeded()
        let maxX = max(-Metrics.sideInset, scrollView.contentSize.width + Metrics.sideInset - scrollView.bounds.width)
        scrollView.contentOffset.x = min(max(-Metrics.sideInset, current.frame.minX - Metrics.sideInset - Metrics.gap), maxX)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        (cards.first(where: \.isCurrent) ?? cards.first).map { [$0] } ?? []
    }
}

/// One channel: programme art (or the channel logo), how far through the
/// programme is, the channel line and the programme title.
private final class LiveChannelCardView: UIView {

    private enum Metrics {
        static let size = CGSize(width: 260, height: 206)
        static let art = CGRect(x: 10, y: 8, width: 240, height: 135)
    }

    let isCurrent: Bool
    var onPress: (() -> Void)?
    private let plate = UIView()
    private let art = UIImageView()
    private var imageTask: Task<Void, Never>?

    init(channel: UnifiedChannel, program: UnifiedProgram?, isCurrent: Bool) {
        self.isCurrent = isCurrent
        super.init(frame: .zero)
        plate.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        plate.layer.cornerRadius = 24
        plate.layer.cornerCurve = .continuous
        plate.alpha = isCurrent ? 0.5 : 0
        plate.isUserInteractionEnabled = false

        art.clipsToBounds = true
        art.layer.cornerRadius = 16
        art.layer.cornerCurve = .continuous
        art.backgroundColor = UIColor.white.withAlphaComponent(0.08)

        let channelLine = UILabel()
        channelLine.text = [isCurrent ? "Watching" : nil, channel.channelNumber.map(String.init), channel.name]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        channelLine.font = .systemFont(ofSize: 19, weight: .medium)
        channelLine.textColor = UIColor.white.withAlphaComponent(0.6)
        let title = UILabel()
        title.text = program?.title ?? "No guide data"
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        title.textColor = .white

        [plate, art, channelLine, title].forEach {
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
            art.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.art.minX),
            art.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.art.minY),
            art.widthAnchor.constraint(equalToConstant: Metrics.art.width),
            art.heightAnchor.constraint(equalToConstant: Metrics.art.height),
            channelLine.leadingAnchor.constraint(equalTo: art.leadingAnchor),
            channelLine.trailingAnchor.constraint(lessThanOrEqualTo: art.trailingAnchor),
            channelLine.topAnchor.constraint(equalTo: art.bottomAnchor, constant: 7),
            title.leadingAnchor.constraint(equalTo: art.leadingAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: art.trailingAnchor),
            title.topAnchor.constraint(equalTo: channelLine.bottomAnchor, constant: 1),
        ])
        addProgress(for: program)
        loadArt(channel: channel, program: program)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { imageTask?.cancel() }

    /// How far through the programme the broadcast is, when the guide says.
    private func addProgress(for program: UnifiedProgram?) {
        guard let program else { return }
        let total = program.endTime.timeIntervalSince(program.startTime)
        guard total > 0 else { return }
        let fraction = min(max(Date().timeIntervalSince(program.startTime) / total, 0), 1)
        let track = UIView()
        track.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        track.layer.cornerRadius = 2
        let fill = UIView()
        fill.backgroundColor = .white
        fill.layer.cornerRadius = 2
        track.addSubview(fill)
        art.addSubview(track)
        [track, fill].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            track.leadingAnchor.constraint(equalTo: art.leadingAnchor, constant: 10),
            track.trailingAnchor.constraint(equalTo: art.trailingAnchor, constant: -10),
            track.bottomAnchor.constraint(equalTo: art.bottomAnchor, constant: -10),
            track.heightAnchor.constraint(equalToConstant: 4),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: CGFloat(max(fraction, 0.001))),
        ])
    }

    /// Landscape programme art fills the frame; posters and channel logos are
    /// fitted, since cropping a 2:3 poster to 16:9 keeps only a sliver.
    private func loadArt(channel: UnifiedChannel, program: UnifiedProgram?) {
        let measured = [program?.iconURL, program?.posterURL].compactMap { $0 }
            .first(where: { EPGImageClassifier.shared.isLandscape($0) })
        let landscape = program?.landscapeURL ?? measured
        guard let url = landscape ?? channel.logoURL ?? program?.posterURL ?? program?.iconURL else { return }
        art.contentMode = landscape != nil ? .scaleAspectFill : .scaleAspectFit
        imageTask = Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            guard let self, !Task.isCancelled else { return }
            self.art.image = image
        }
    }

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
            self.plate.alpha = focused ? 1 : (self.isCurrent ? 0.5 : 0)
            self.transform = focused ? CGAffineTransform(scaleX: 1.05, y: 1.05) : .identity
        }
    }
}
