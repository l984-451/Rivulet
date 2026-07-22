// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveGuideInfoCardView.swift
//  Rivulet
//
//  Rail-panel info card for Live TV. The VOD player's CardInfoView is built
//  around PlexMetadata; live channels have no Plex metadata, so this card is
//  fed from the guide (UnifiedProgram) instead: channel line, the programme
//  airing now (title, time range, summary), and what's on next.
//
//  Presented inside PlayerRailPanelView, which supplies the glass, the focus
//  fence, and Menu handling. The card itself is one focusable block (same
//  model as CardInfoView) so the panel ring carries the focus treatment.
//

import UIKit

final class LiveGuideInfoCardView: UIView {

    /// Mirrors CardInfoView's hook: the panel brightens its border while the
    /// card holds focus.
    var onFocusChange: ((Bool) -> Void)?

    init(channel: UnifiedChannel, current: UnifiedProgram?, next: UnifiedProgram?) {
        super.init(frame: .zero)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .fill
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Channel line: "7 · Seven"
        let channelLabel = UILabel()
        channelLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        channelLabel.textColor = UIColor.white.withAlphaComponent(0.66)
        channelLabel.text = [channel.channelNumber.map(String.init), channel.name]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        stack.addArrangedSubview(channelLabel)

        // Now playing
        let titleLabel = UILabel()
        titleLabel.font = .systemFont(ofSize: 30, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        titleLabel.text = current?.title ?? "No guide data available."
        stack.addArrangedSubview(titleLabel)

        if let current {
            let timeLabel = UILabel()
            timeLabel.font = .systemFont(ofSize: 20, weight: .regular)
            timeLabel.textColor = UIColor.white.withAlphaComponent(0.55)
            timeLabel.text = Self.timeRange(current)
            stack.addArrangedSubview(timeLabel)

            if let summary = current.description, !summary.isEmpty {
                let summaryLabel = UILabel()
                summaryLabel.font = .systemFont(ofSize: 21, weight: .regular)
                summaryLabel.textColor = UIColor.white.withAlphaComponent(0.8)
                summaryLabel.numberOfLines = 7
                summaryLabel.text = summary
                stack.setCustomSpacing(14, after: timeLabel)
                stack.addArrangedSubview(summaryLabel)
            }
        }

        // Up next
        if let next {
            let nextHeader = UILabel()
            nextHeader.font = .systemFont(ofSize: 20, weight: .semibold)
            nextHeader.textColor = UIColor.white.withAlphaComponent(0.5)
            nextHeader.text = "UP NEXT"
            if let last = stack.arrangedSubviews.last {
                stack.setCustomSpacing(22, after: last)
            }
            stack.addArrangedSubview(nextHeader)

            let nextLabel = UILabel()
            nextLabel.font = .systemFont(ofSize: 23, weight: .medium)
            nextLabel.textColor = .white
            nextLabel.numberOfLines = 2
            nextLabel.text = "\(Self.timeRange(next))  \(next.title)"
            stack.setCustomSpacing(6, after: nextHeader)
            stack.addArrangedSubview(nextLabel)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static func timeRange(_ program: UnifiedProgram) -> String {
        "\(timeFormatter.string(from: program.startTime)) – \(timeFormatter.string(from: program.endTime))"
    }

    // MARK: - Focus

    override var canBecomeFocused: Bool { true }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if context.nextFocusedView === self {
            onFocusChange?(true)
        } else if context.previouslyFocusedView === self {
            onFocusChange?(false)
        }
    }
}
