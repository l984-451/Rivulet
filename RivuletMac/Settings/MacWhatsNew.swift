// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// The Mac release notes, keyed "<CFBundleShortVersionString> (<CFBundleVersion>)", newest first.
/// A line starting with "## " is a heading; any other line is a bullet. Empty until the first release.
enum MacChangelog {
    static let entries: [(version: String, lines: [String])] = []

    static func lines(for version: String) -> [String]? {
        entries.first { $0.version == version }?.lines
    }

    static var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// Shown once after an update whose build has notes, and from Help > What's New.
struct MacWhatsNewView: View {
    let version: String
    var showsContinue = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What's New").font(.largeTitle.bold())
            Text("Version \(version)").font(.subheadline).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array((MacChangelog.lines(for: version) ?? []).enumerated()), id: \.offset) { _, line in
                        if line.hasPrefix("## ") {
                            Text(line.dropFirst(3)).font(.headline).padding(.top, 8)
                        } else {
                            Label { Text(line) } icon: { Image(systemName: "circle.fill").font(.system(size: 5)) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showsContinue {
                Button("Continue") { dismiss() }.keyboardShortcut(.defaultAction).frame(maxWidth: .infinity)
            }
        }
        .padding(28)
        .frame(width: 440, height: 420)
    }
}
