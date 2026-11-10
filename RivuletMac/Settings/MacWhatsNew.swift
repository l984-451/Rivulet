// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// The Mac release notes, keyed "<CFBundleShortVersionString> (<CFBundleVersion>)", newest first;
/// CI takes the build number from the shared `vX.Y.Z-<build>` tag.
/// A line starting with "## " is a heading; any other line is a bullet.
enum MacChangelog {
    static let entries: [(version: String, lines: [String])] = [
        ("1.3.0 (126)", [
            "Photos, with favorites, slideshows, photo info, a map and a memories row",
            "Improved search to find more matches, genres, and people",
            "Subtitle search in the player. Jellyfin and Emby should work (please test)",
            "Plex home profiles now see their own watchlist",
            "Hidden libraries stay off Home and the hero",
            "Direct Play buffers as far ahead as storage allows",
            "Added delete option in more long press menus",
        ]),
        ("1.0.0 (1)", [
            "Rivulet now has a native Mac app",
            "Plex, Jellyfin and Emby in one place, with Continue Watching merged across servers",
            "Home, libraries, search, playlists and favorites, with right-click menus on every title",
            "Live TV with a guide and What's On, from Plex, Dispatcharr, Tvheadend, Threadfin, Xtream Codes or any M3U playlist",
            "Pick your audio and subtitle languages, skip intros and credits, and choose a streaming quality",
            "Switch Plex profiles and servers from Settings",
            "Sync settings, servers and Live TV sources with your Apple TV, iPhone and iPad through iCloud",
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

/// Shown once after an update whose build has notes, and from Help > What's New.
struct MacWhatsNewView: View {
    /// Newest first: every build since the last one seen, or one from Help.
    let versions: [String]
    var showsContinue = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What's New").font(.largeTitle.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(versions, id: \.self) { version in
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Version \(version)").font(.subheadline).foregroundStyle(.secondary)
                            MacChangelogLines(lines: MacChangelog.lines(for: version) ?? [])
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

/// Release-note lines: "## " is a heading, anything else a bullet.
struct MacChangelogLines: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("## ") {
                    Text(line.dropFirst(3)).font(.headline).padding(.top, 4)
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
