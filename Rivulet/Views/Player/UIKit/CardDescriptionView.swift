// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CardDescriptionView.swift
//  Rivulet
//
//  Description tab of the player's Now Playing Info popup (issue #267): the
//  item's title, a context line, and its summary, so the description stays
//  readable during playback. Sibling of `CardInfoView` (tech metadata) and
//  `CardStatsView` (live telemetry); shares their scroll surface and row
//  focus targets.
//
//  Each paragraph is its own `InfoFocusRowView`, full width rather than
//  two-up. A single paragraph taller than the panel has only one focus target,
//  so it scrolls from the clickpad edge clicks `InfoScrollView.pressesBegan`
//  handles, not from swipes — the same ceiling the other sheets have for an
//  over-tall row.
//
//  The title block sits at the top with the summary directly under it; a short
//  summary leaves the rest of the fixed-height panel empty rather than floating
//  in the middle of it (see `setupViews`).
//

import UIKit

final class CardDescriptionView: UIView, InfoTabSheet {

    private enum Metrics {
        /// Gap between the title block and the summary.
        static let headerGap: CGFloat = 20
        /// Gap between summary paragraphs.
        static let paragraphSpacing: CGFloat = 12
    }

    private let scrollView = InfoScrollView()
    /// Sizes the scroll content; holds the pinned header and the summary.
    private let content = UIView()
    private let headerRow = InfoFocusRowView()
    private let summaryStack = UIStackView()

    /// Fires when focus enters/leaves this sheet, so the hosting panel can
    /// brighten its ring (the sheet draws no focus treatment of its own).
    var onFocusChange: ((Bool) -> Void)? {
        didSet { scrollView.onFocusChange = onFocusChange }
    }

    var infoScrollView: InfoScrollView { scrollView }

    init(metadata: PlexMetadata) {
        super.init(frame: .zero)
        setupViews()
        populate(metadata: metadata)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Title at the top, summary directly under it. Both read from the top
    /// down, which is the only arrangement that looks deliberate.
    ///
    /// The summary used to be CENTERED in the height left under the title,
    /// because the panel is a fixed 520pt viewport and a short summary leaves
    /// most of it empty. That is what issue #278 reported: on a two-sentence
    /// synopsis it floated with roughly 190pt of nothing above it and 260pt
    /// below, reading as a layout bug rather than as breathing room. Empty
    /// space at the BOTTOM of a fixed sheet is unremarkable; a paragraph
    /// hovering in the middle of one is not.
    private func setupViews() {
        summaryStack.axis = .vertical
        summaryStack.spacing = Metrics.paragraphSpacing
        summaryStack.alignment = .fill

        [scrollView, content, headerRow, summaryStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        content.addSubview(headerRow)
        content.addSubview(summaryStack)
        scrollView.addSubview(content)
        addSubview(scrollView)

        // Beat the panel's own height cap so a short sheet hugs its content
        // instead of collapsing to zero height — same idiom as CardInfoView.
        let scrollHeight = scrollView.heightAnchor.constraint(equalTo: content.heightAnchor)
        // ONE BELOW `.defaultHigh`, not AT it. At `.defaultHigh` this ties with
        // the content's own vertical compression resistance, and the solver
        // resolves the tie by SQUASHING the content to the viewport instead of
        // breaking this constraint. `contentSize` then reports the squashed
        // height, so the sheet believes it fits while part of it is unreachable:
        // measured on device at stackH=448 naturalH=468, contentSize==bounds==448.
        // That makes `InfoScrollView.needsFocusableRows` false, every row
        // unfocusable, and the Down crossing from the pills into the sheet dead.
        // One below, the cap wins, the content keeps its real height, and the
        // sheet is scrollable. Short content still hugs (hugging is only 250).
        scrollHeight.priority = .defaultHigh - 1

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollHeight,

            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            // At least a viewport tall, so a short sheet doesn't collapse and
            // leave the panel shorter than its siblings.
            content.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),

            headerRow.topAnchor.constraint(equalTo: content.topAnchor),
            headerRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            headerRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            summaryStack.topAnchor.constraint(equalTo: headerRow.bottomAnchor,
                                              constant: Metrics.headerGap),
            summaryStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            summaryStack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            // Required, so a summary taller than the viewport GROWS the scroll
            // content instead of overflowing it unscrollably.
            summaryStack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])
    }

    private func populate(metadata: PlexMetadata) {
        let header = UIStackView()
        header.axis = .vertical
        header.spacing = 4
        header.alignment = .fill
        if let context = Self.contextLine(for: metadata) {
            header.addArrangedSubview(PlayerInfoSheetStyle.bodyLabel(context, secondary: true))
        }
        header.addArrangedSubview(PlayerInfoSheetStyle.titleLabel(metadata.title ?? "Now Playing"))
        headerRow.setFullWidth(header)

        for paragraph in Self.paragraphs(of: metadata.summary) {
            let row = InfoFocusRowView()
            row.setFullWidth(PlayerInfoSheetStyle.bodyLabel(paragraph, secondary: false))
            summaryStack.addArrangedSubview(row)
        }
    }

    // MARK: - Content (pure, unit-tested)

    /// Line above the title: the show and episode number for an episode, or
    /// year / rating / runtime for anything else. Nil when nothing is known.
    nonisolated static func contextLine(for metadata: PlexMetadata) -> String? {
        let parts: [String?]
        if metadata.type == "episode" {
            parts = [metadata.grandparentTitle, metadata.episodeString]
        } else {
            parts = [metadata.year.map(String.init), metadata.contentRating, metadata.durationFormatted]
        }
        let line = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }

    /// Summary split into paragraphs, blank lines dropped. One focus target per
    /// paragraph is what lets a swipe walk a long summary.
    nonisolated static func paragraphs(of summary: String?) -> [String] {
        (summary ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
