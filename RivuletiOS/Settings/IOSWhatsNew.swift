// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// The iOS release notes. Keyed "<CFBundleShortVersionString> (<CFBundleVersion>)", newest
/// first; CI takes the build number from the `ios-vX.Y.Z-<build>` tag, so the key must match it.
/// A line starting with "## " is a heading; any other line is a bullet.
enum IOSChangelog {
    static let entries: [(version: String, lines: [String])] = [
        // confirm build number at release
        ("1.0.7 (82)", [
            "New Tvheadend support in Live TV, with channels, guide and recording",
            "Add Source in Live TV lists Dispatcharr, Tvheadend and Threadfin by name",
            "Updated AetherEngine to 7.52.0",
        ]),
        ("1.0.7 (81)", [
            "New video playlists: play, shuffle, add titles, reorder, rename and delete",
            "Each skip marker can now show a button, skip automatically, or stay off",
            "Videos now start in your Plex account's preferred audio language",
            "What's On in Live TV now has a row for each source when you have several",
            "Updated AetherEngine to 7.47.0",
        ]),
        ("1.0.7 (80)", [
            "New App Icon setting in Account, with three new icons by @tresby",
            "Captions now match the system player's size and placement (@tresby)",
            "Live TV now includes every Plex server on your account",
        ]),
        ("1.0.7 (79)", [
            "Every Plex server on your account now shows in Home, Library and Search",
            "Continue Watching is now one row across all your servers, without duplicates",
            "Add Xtream Codes IPTV sources in Live TV settings",
            "Your Plex server's Live TV now shows up automatically",
            "Live TV guide now loads days ahead and stays up to date",
            "Fixed PIN-protected Plex Home profiles not opening",
            "Updated AetherEngine to 7.44.0",
            "Fixed the Plex Live TV guide failing to load on slower servers",
            "Fixed a managed profile briefly showing the owner's library at launch",
            "Fixed libraries not loading when one is missing details",
        ]),
        ("1.0.7 (78)", [
            "Fixed videos and Live TV failing with a security certificate error on some server connections",
            "Fixed the blank Retry button on the playback error card",
            "Plex Live TV channel names no longer repeat the channel number",
        ]),
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

