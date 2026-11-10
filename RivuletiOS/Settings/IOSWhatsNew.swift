// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// The iOS release notes. Keyed "<CFBundleShortVersionString> (<CFBundleVersion>)", newest
/// first; CI takes the build number from the shared `vX.Y.Z-<build>` tag, so the key must match it.
/// A line starting with "## " is a heading; any other line is a bullet.
enum IOSChangelog {
    static let entries: [(version: String, lines: [String])] = [
        ("1.3.0 (125)", [
            "Photos, with favorites, slideshows, photo info, a map and a memories row",
            "Improved search to find more matches, genres, and people",
            "Cast and crew on a title open their page, with their movies and shows",
            "Subtitle search in the player. Jellyfin and Emby should work (please test)",
            "Plex home profiles now see their own watchlist",
            "Hide libraries from Home in Settings > Library",
            "Direct Play buffers as far ahead as storage allows",
            "Added delete option in more long press menus",
        ]),
        ("1.0.7 (87)", [
            "On a Dolby Vision display, Profile 7 FEL keeps most of its enhancement layer",
            "Play from several Plex servers at once",
            "Filter libraries by genre, decade or unwatched. @DennisR-git",
            "A title's page shows its ratings and Rotten Tomatoes critic reviews",
            "Move subtitles up or down, even into the black bars",
            "Movies split into several files play straight through",
            "A show's page includes the extras for the season you pick",
            "A new At the Credits setting chooses what shows when credits start",
            "Jellyfin trickplay previews show while you scrub",
            "Updated AetherEngine to 7.61.0",
            "Other small changes and fixes",
        ]),
        ("1.0.7 (85)", [
            "Jellyfin and Emby: sign in, browse, play, download and watch Live TV",
            "Libraries open on a Recommended page with a hero",
            "Arrange Home rows, add favorites and playlists, and mix hero sources",
            "Mark favorites on any server, with an optional Favorites page",
            "Runs on Apple silicon Macs, with iPad keyboard and pointer support",
            "Theme videos play behind Jellyfin and Emby titles",
            "Scrubbing shows previews, including on downloads",
            "Rivulet is now available in German and Greek",
            "Shuffle libraries and shows, and delete from long-press menus",
            "Updated AetherEngine to 7.57.0",
            "Other small changes and fixes",
        ]),
        ("1.0.7 (84)", [
            "Continue Watching no longer adds a title to artwork that already shows one",
            "Live TV guides now show film release years and mark new airings from Plex",
            "Home and detail pages now sit on a soft blur of the artwork",
            "Downloads can be paused and show their progress as a Live Activity",
            "At home, Rivulet now prefers your Plex server's local connection",
        ]),
        ("1.0.7 (83)", [
            "iPhone Duo optimization",
        ]),
        ("1.0.7 (82)", [
            "New Tvheadend support in Live TV, with channels, guide and recording",
            "Add Source in Live TV lists Dispatcharr, Tvheadend and Threadfin by name",
            "Live TV channels now start in a few seconds",
            "New Audio Delay control in the player's audio and subtitles menu",
            "New Upscale SD and 720p setting in Playback",
            "Posters now show the edition, such as Director's Cut",
            "Plex's dashboard now shows bandwidth for Direct Play",
            "The player stops and shows the reason when Plex ends your session",
            "New Audio & Subtitles settings in Playback, saved for each Plex profile",
            "Audio tracks are listed by language and format, and audio description tracks are no longer picked on their own",
            "New Chapters list in the player, with a picture for each chapter",
            "The Home hero can show Trending, Continue Watching, Recently Added or your Watchlist",
            "Updated AetherEngine to 7.53.0",
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
    /// Every build since the last one seen, newest first.
    let versions: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("What's New")
                        .font(.largeTitle.bold())
                    ForEach(versions, id: \.self) { version in
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Version \(version)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            IOSChangelogLines(lines: IOSChangelog.lines(for: version) ?? [])
                        }
                    }
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
        // On iPad a sheet is a page otherwise, with the notes at the top and Continue far below.
        .presentationSizing(.form)
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

