// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley
//
//  StackedParts.swift
//  Rivulet
//
//  A title Plex stacks from several files (`pt1`, `pt2`, #399), played back to
//  back on one timeline. Plex keeps the title's duration, resume offset,
//  chapters and markers on that timeline; only each file starts at zero.
//

import Foundation

struct StackedParts<File> {
    let files: [File]
    /// Where each file begins on the title's timeline, in seconds.
    let starts: [TimeInterval]
    let duration: TimeInterval

    /// nil for a single file, and when any file has no length: without every
    /// boundary, title time cannot be placed in a file.
    init?(_ parts: [(file: File, duration: TimeInterval?)]) {
        guard parts.count > 1 else { return nil }
        var starts: [TimeInterval] = []
        var end: TimeInterval = 0
        for part in parts {
            guard let length = part.duration, length > 0 else { return nil }
            starts.append(end)
            end += length
        }
        files = parts.map(\.file)
        self.starts = starts
        duration = end
    }

    /// The file holding title time `time`, and the time within that file.
    /// Before the title is the first file; past its end, the last.
    func locate(_ time: TimeInterval) -> (index: Int, offset: TimeInterval) {
        let index = starts.lastIndex { $0 <= time } ?? 0
        return (index, max(0, time - starts[index]))
    }
}
