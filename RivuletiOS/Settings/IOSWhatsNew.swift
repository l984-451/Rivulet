// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// The iOS release notes. Keyed "<CFBundleShortVersionString> (<CFBundleVersion>)", newest
/// first; CI takes the build number from the `ios-vX.Y.Z-<build>` tag, so the key must match it.
/// A line starting with "## " is a heading; any other line is a bullet.
enum IOSChangelog {
    static let entries: [(version: String, lines: [String])] = [
        ("1.0.6 (77)", [
            "## Decided to give the iOS app some love",
            "Updated design to feel more Apple-esque",
            "Live TV support",
            "Download support",
            "PiP support",
            "Added ability to adjust stream quality",
            "Context menus",
        ]),
    ]

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

/// Shown once after an update whose build has notes.
struct IOSWhatsNewSheet: View {
    let version: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What's New")
                            .font(.largeTitle.bold())
                        Text("Version \(version)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    IOSChangelogLines(lines: IOSChangelog.lines(for: version) ?? [])
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 44)
            }
            Button {
                dismiss()
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
    }
}

/// Settings → About → Changelog: every release, newest first.
struct IOSChangelogView: View {
    var body: some View {
        List(IOSChangelog.entries, id: \.version) { entry in
            Section(entry.version) {
                IOSChangelogLines(lines: entry.lines)
                    .padding(.vertical, 4)
            }
        }
        .navigationTitle("Changelog")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct IOSChangelogLines: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("## ") {
                    Text(line.dropFirst(3))
                        .font(.headline)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\u{2022}").foregroundStyle(.tint)
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

