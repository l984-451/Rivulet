// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveCardCell.swift
//  Rivulet
//
//  The 16:9 card of the Browse layout and multiview's "Add More" row: the
//  programme's landscape art (the channel's logo when there is none), a LIVE
//  pill or start time, the channel's logo in the corner, and the title over a
//  gradient, with how far through the programme is.
//

import UIKit

/// One card's content.
struct LiveCardItem: Hashable {
    enum Kind: Hashable {
        /// A channel and what is on it now.
        case channel
        /// A programme starting soon on `channel`.
        case upcoming
        /// A recording Plex or Dispatcharr has lined up.
        case recording
    }

    let id: String
    let kind: Kind
    let channel: UnifiedChannel?
    let program: UnifiedProgram?
    let recording: LiveTVScheduledRecording?

    static func channel(_ channel: UnifiedChannel, program: UnifiedProgram?, section: String) -> LiveCardItem {
        LiveCardItem(id: "\(section)|\(channel.id)", kind: .channel, channel: channel,
                     program: program, recording: nil)
    }

    static func upcoming(_ program: UnifiedProgram, on channel: UnifiedChannel) -> LiveCardItem {
        LiveCardItem(id: "soon|\(program.id)", kind: .upcoming, channel: channel,
                     program: program, recording: nil)
    }

    static func recording(_ recording: LiveTVScheduledRecording, channel: UnifiedChannel?) -> LiveCardItem {
        LiveCardItem(id: "rec|\(recording.id)", kind: .recording, channel: channel,
                     program: nil, recording: recording)
    }
}

extension Array where Element == LiveCardItem {
    /// First of each id. A diffable snapshot traps on a repeated identifier,
    /// and a merged lineup can list a channel twice.
    func uniquedById() -> [LiveCardItem] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}

final class LiveCardCell: UICollectionViewCell {
    static let reuseID = "LiveCardCell"
    static let aspect: CGFloat = 9.0 / 16.0

    private let card = UIView()
    private let artView = UIImageView()
    private let logoFallback = UIImageView()
    private let gradient = CAGradientLayer()
    private let pill = UILabel()
    private let pillBackground = UIView()
    private let cornerLogo = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private var progressWidth: NSLayoutConstraint!

    private var artTask: Task<Void, Never>?
    private var logoTask: Task<Void, Never>?
    private var artURL: URL?
    private var logoURL: URL?

    private static let timeFormat = Date.FormatStyle.dateTime.hour().minute()

    override init(frame: CGRect) {
        super.init(frame: frame)

        card.backgroundColor = UIColor(white: 0.14, alpha: 1)
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        // Shadow on the unclipped content view, so the lift reads on focus.
        contentView.layer.shadowColor = UIColor.black.cgColor
        contentView.layer.shadowOpacity = 0
        contentView.layer.shadowRadius = 24
        contentView.layer.shadowOffset = CGSize(width: 0, height: 16)

        artView.contentMode = .scaleAspectFill
        artView.clipsToBounds = true
        logoFallback.contentMode = .scaleAspectFit
        [artView, logoFallback].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview($0)
        }

        gradient.colors = [UIColor.black.withAlphaComponent(0).cgColor,
                           UIColor.black.withAlphaComponent(0.8).cgColor]
        gradient.locations = [0.35, 1]
        card.layer.addSublayer(gradient)

        pillBackground.layer.cornerRadius = 8
        pillBackground.layer.cornerCurve = .continuous
        pill.font = .systemFont(ofSize: 18, weight: .bold)
        pill.textColor = .white
        cornerLogo.contentMode = .scaleAspectFit
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.textColor = .white
        detailLabel.font = .systemFont(ofSize: 18, weight: .medium)
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        progressTrack.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        progressTrack.layer.cornerRadius = 2
        progressFill.backgroundColor = .white
        progressFill.layer.cornerRadius = 2

        [pillBackground, pill, cornerLogo, titleLabel, detailLabel, progressTrack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview($0)
        }
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.addSubview(progressFill)
        progressWidth = progressFill.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            artView.topAnchor.constraint(equalTo: card.topAnchor),
            artView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            artView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            artView.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            logoFallback.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            logoFallback.centerYAnchor.constraint(equalTo: card.centerYAnchor, constant: -18),
            logoFallback.widthAnchor.constraint(equalTo: card.widthAnchor, multiplier: 0.42),
            logoFallback.heightAnchor.constraint(equalTo: card.heightAnchor, multiplier: 0.36),

            pill.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            pill.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            pillBackground.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: -10),
            pillBackground.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: 10),
            pillBackground.topAnchor.constraint(equalTo: pill.topAnchor, constant: -5),
            pillBackground.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: 5),

            cornerLogo.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            cornerLogo.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            cornerLogo.widthAnchor.constraint(equalToConstant: 70),
            cornerLogo.heightAnchor.constraint(equalToConstant: 36),

            progressTrack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            progressTrack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            progressTrack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            progressTrack.heightAnchor.constraint(equalToConstant: 4),
            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            progressWidth,

            detailLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -16),
            detailLabel.bottomAnchor.constraint(equalTo: progressTrack.topAnchor, constant: -8),

            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -16),
            titleLabel.bottomAnchor.constraint(equalTo: detailLabel.topAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// How far through the programme, 0...1; applied against the track's
    /// real width on layout.
    private var progressFraction: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = card.bounds
        CATransaction.commit()
        let width = progressTrack.bounds.width * progressFraction
        if abs(progressWidth.constant - width) > 0.5 { progressWidth.constant = width }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artTask?.cancel()
        logoTask?.cancel()
        artTask = nil
        logoTask = nil
        artURL = nil
        logoURL = nil
        artView.image = nil
        logoFallback.image = nil
        cornerLogo.image = nil
    }

    func configure(_ item: LiveCardItem, now: Date = Date()) {
        let channel = item.channel
        let program = item.program

        // Text
        switch item.kind {
        case .channel:
            titleLabel.text = program?.title ?? channel?.name ?? "Live"
            detailLabel.text = [channel?.channelNumber.map(String.init), channel?.name]
                .compactMap { $0 }
                .joined(separator: " · ")
            setPill("▶ LIVE", color: .systemRed)
        case .upcoming:
            titleLabel.text = program?.title ?? "Upcoming"
            detailLabel.text = channel?.name
            setPill(program.map { $0.startTime.formatted(Self.timeFormat) }, color: UIColor.white.withAlphaComponent(0.25))
        case .recording:
            let recording = item.recording
            titleLabel.text = recording?.title ?? "Recording"
            detailLabel.text = [recording?.subtitle, recording?.channelName]
                .compactMap { $0 }
                .joined(separator: " · ")
            if recording?.status == .recording {
                setPill("● REC", color: .systemRed)
            } else {
                setPill(recording.map { $0.startTime.formatted(Self.timeFormat) },
                        color: UIColor.white.withAlphaComponent(0.25))
            }
        }

        // Progress through what is on now.
        var progress: Double?
        if item.kind == .channel, let program, program.endTime > program.startTime,
           program.startTime <= now, program.endTime > now {
            progress = now.timeIntervalSince(program.startTime) / program.endTime.timeIntervalSince(program.startTime)
        }
        progressTrack.isHidden = progress == nil
        progressFraction = CGFloat(min(max(progress ?? 0, 0), 1))
        setNeedsLayout()

        // Art: the programme's own 16:9 image (its icon counts once the
        // classifier has seen it is wide), else the channel's logo on the
        // card's dark fill.
        let wideIcon = program?.iconURL.flatMap { EPGImageClassifier.shared.isLandscape($0) ? $0 : nil }
        let art = program?.landscapeURL ?? wideIcon ?? item.recording?.posterURL
        let logo = channel?.logoURL
        load(art: art)
        load(logo: logo, asFallback: art == nil)
    }

    private func setPill(_ text: String?, color: UIColor) {
        pill.text = text
        pill.isHidden = text == nil
        pillBackground.isHidden = text == nil
        pillBackground.backgroundColor = color
    }

    private func load(art url: URL?) {
        guard url != artURL else { return }
        artTask?.cancel()
        artURL = url
        artView.image = nil
        guard let url else { return }
        artTask = Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            guard let self, !Task.isCancelled, self.artURL == url else { return }
            self.artView.image = image
        }
    }

    /// The logo goes big in the middle when there is no art, and small in
    /// the corner when there is.
    private func load(logo url: URL?, asFallback: Bool) {
        logoFallback.isHidden = !asFallback
        cornerLogo.isHidden = asFallback
        guard url != logoURL else {
            let image = logoFallback.image ?? cornerLogo.image
            logoFallback.image = asFallback ? image : nil
            cornerLogo.image = asFallback ? nil : image
            return
        }
        logoTask?.cancel()
        logoURL = url
        logoFallback.image = nil
        cornerLogo.image = nil
        guard let url else { return }
        logoTask = Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url, quality: .thumb)
            guard let self, !Task.isCancelled, self.logoURL == url else { return }
            if asFallback {
                self.logoFallback.image = image
            } else {
                self.cornerLogo.image = image
            }
        }
    }

    // MARK: Focus

    override var canBecomeFocused: Bool { true }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations {
            self.transform = focused ? CGAffineTransform(scaleX: 1.08, y: 1.08) : .identity
            self.contentView.layer.shadowOpacity = focused ? 0.55 : 0
        }
    }
}
