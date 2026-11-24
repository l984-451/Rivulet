// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveListText.swift
//  Rivulet
//
//  The List layout's words, the same in every app: a channel's detail line
//  ("1080p · Stereo · 🇳🇱 Sport"), a programme's times and what follows it,
//  and the category column split into its source sections.
//

import Foundation

enum LiveListText {
    private static let timeFormat = Date.FormatStyle.dateTime.hour().minute()

    /// The picture and sound first: a long category is what the line cuts short, never the quality.
    static func detail(_ channel: UnifiedChannel, quality: LiveStreamQualityStore = .shared) -> String? {
        let labels = quality.quality(for: channel.id)?.labels ?? []
        let group = LiveGroupOrder.trimmed(channel.groupTitle).map(LiveGroupDisplay.name)
        let detail = (labels + [group].compactMap { $0 }).joined(separator: " · ")
        return detail.isEmpty ? nil : detail
    }

    /// "20:00 – 20:30".
    static func times(_ program: UnifiedProgram) -> String {
        "\(program.startTime.formatted(timeFormat)) – \(program.endTime.formatted(timeFormat))"
    }

    /// "Next: News at 20:30".
    static func next(_ program: UnifiedProgram) -> String {
        String(localized: "Next: \(program.displayTitle) at \(program.startTime.formatted(timeFormat))")
    }
}

/// A run of the category column under one source's header (none for the rows above the sections).
struct LiveCategorySection: Identifiable {
    let header: LiveCategory?
    let rows: [LiveCategory]
    var id: String { header?.id ?? "top" }
}

extension LiveCategoryList {
    /// The column as sections, for lists that draw a source's header as a section header.
    var sections: [LiveCategorySection] {
        var result: [LiveCategorySection] = []
        var header: LiveCategory?
        var rows: [LiveCategory] = []
        for category in categories {
            if category.kind == .sourceHeader {
                if header != nil || !rows.isEmpty { result.append(LiveCategorySection(header: header, rows: rows)) }
                header = category
                rows = []
            } else {
                rows.append(category)
            }
        }
        if header != nil || !rows.isEmpty { result.append(LiveCategorySection(header: header, rows: rows)) }
        return result
    }

    /// The row to open on: the remembered one while it exists, else the first with channels.
    func startingCategoryId(remembered: String?) -> String? {
        if let remembered, category(remembered) != nil { return remembered }
        return categories.first { $0.kind != .sourceHeader }?.id
    }
}
