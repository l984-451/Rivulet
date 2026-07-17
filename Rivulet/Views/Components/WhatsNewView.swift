//
//  WhatsNewView.swift
//  Rivulet
//
//  Shows a one-time "What's New" overlay when the app updates
//  to a version with a changelog entry.
//

import SwiftUI


struct WhatsNewView: View {
    @Binding var isPresented: Bool
    let version: String

    @FocusState private var focusedItem: FocusItem?

    private enum FocusItem: Hashable {
        case feature(Int)
        case continueButton
    }

    private var features: [String] {
        Self.features(for: version) ?? []
    }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            card
            Spacer(minLength: 0)
        }
        .onAppear {
            focusedItem = .continueButton
        }
        .onExitCommand {
            isPresented = false
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            // Header (fixed above the scroll area)
            VStack(spacing: 8) {
                Text("What's New")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(.white)

                Text("Version \(version)")
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.top, 40)
            .padding(.bottom, 24)

            // Scrollable feature list. Each row is focusable so the
            // tvOS focus engine auto-scrolls the ScrollView when the
            // user navigates up/down through the items.
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                        featureRow(text: feature, isFocused: focusedItem == .feature(index))
                            .focusable(true)
                            .focused($focusedItem, equals: .feature(index))
                            .focusEffectDisabled()
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: 460)

            // Continue button (fixed below the scroll area) — always
            // visible and receives initial focus.
            Button {
                isPresented = false
            } label: {
                Text("Continue")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(focusedItem == .continueButton ? .black : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(focusedItem == .continueButton ? .white : .white.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                focusedItem == .continueButton ? .clear : .white.opacity(0.15),
                                lineWidth: 1
                            )
                    )
            }
            .buttonStyle(.plain)
            .focused($focusedItem, equals: .continueButton)
            .focusEffectDisabled()
            .scaleEffect(focusedItem == .continueButton ? 1.04 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: focusedItem)
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 36)
        }
        .frame(width: 620)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(.black.opacity(0.3))
        )
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
    }

    private func featureRow(text: String, isFocused: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Circle()
                .fill(.white.opacity(isFocused ? 0.9 : 0.5))
                .frame(width: 8, height: 8)
                .padding(.top, 13)

            Text(text)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white.opacity(isFocused ? 1.0 : 0.85))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isFocused ? .white.opacity(0.14) : .clear)
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isFocused)
    }

    // MARK: - Changelog Data

    static let changelogs: [(version: String, features: [String])] = [
        ("1.0.3 (67)", [
            "Redesigned Live TV guide with a full channel grid, program details, and instant playback",
            "Show and movie pages opened from Top Shelf or Siri now match the pages you get inside the app",
            "Removing an item from Continue Watching no longer leaves focus in the wrong place",
            "The INFO panel in the player now shows the streaming mode for video, audio, and subtitles, so you can confirm Direct Play without checking the server dashboard",
            "The featured carousel on Home and Discover now advances on its own, with a countdown shown on the page dots",
            "New Skip Recap and Skip Preview options in Playback settings, with a community database filling in markers your server does not have",
            "Live TV subtitles now show broadcaster colours (following your system caption settings) and rolling captions no longer flicker",
            "Updated AetherEngine to 5.5.0. Fixes audio cutting in and out on broadcast Live TV channels, adds teletext subtitles, faster startup on slower sources, and fewer stalls when resuming after a pause",
        ]),
        ("1.0.3 (66)", [
            "Removing an item from Continue Watching is now instant and no longer clears your watch progress",
            "New Go to Show option in the Continue Watching menu opens the show page right at your current episode",
            "Watch from Beginning now actually starts playback from the beginning",
            "Reorganized the long press menus on Home rows",
            "Fixed old items reappearing at the far end of the Continue Watching row",
        ]),
        ("1.0.3 (65)", [
            "Updated AetherEngine to 5.0.5. Fixes duplicate subtitles after rewinding, subtitle timing during fast skipping, and playback resuming on its own when skipping while paused",
            "The changelog in Settings now shows the full release history",
            "Security improvements for Rivulet's online features",
        ]),
        ("1.0.3 (64)", [
            "Continue Watching now stays up to date after you finish watching and when you return to the app",
            "You can now pick any subtitle track, not just the first one for each language",
        ]),
        ("1.0.3 (63)", [
            "Fixed duplicate subtitle lines stacking up after rewinding",
            "Rivulet now remembers your audio and subtitle choices, including forced subtitles, and applies them to the next thing you watch",
            "Removed the audio and subtitle language settings. The player now learns your preference from what you pick",
            "You can now swipe through the Home carousel",
            "The ambient glow on Home now follows the featured artwork",
            "Better diagnostics when playback fails",
        ]),
        ("1.0.3 (62)", [
            "Major playback engine update (AetherEngine 5.0)",
            "Releases are now also published on GitHub",
        ]),
        ("1.0.3 (61)", [
            "Pressing Back in the sidebar now returns you to Home",
            "The preview carousel now shows series info",
            "Insights now works on TV episodes",
        ]),
        ("1.0.2 (59)", [
            "Insights (work in progress): while watching, open Insights to see the cast and trivia for the current movie or show. Coverage and accuracy will keep improving",
            "Redesigned the player controls: a cleaner glass control bar with subtitles, audio, info, and Up Next, plus smoother scrubbing with thumbnail previews",
            "Redesigned the paused screen with full quality backdrop art and the title logo",
            "The Apple TV top shelf now shows Continue Watching as full bleed artwork with the title logo",
            "New Home hero that highlights trending movies and shows",
            "Playback fixes: subtitles keep their selection when you change the audio track, trick play thumbnails line up with the right moment, and fast forward and rewind speeds are steadier",
            "Bug fixes",
        ]),
        ("1.0.1 (56)", [
            "Watchlist items you own now show proper artwork and a Play button",
            "Playback now resumes correctly after leaving and returning to the app",
            "Fixed subtitle language names in the track picker",
            "Fixed the Home hero sometimes loading late",
            "Refreshed the app icon",
        ]),
        ("1.0.0 (53)", [
            "Fixed the Aether player not playing any content (black screen, no audio) for some users",
        ]),
        ("1.0.0 (52)", [
            "Actor detail pages now work. Tap any cast member to see their bio and the movies and shows they're in",
            "Skip Intro and Skip Credits markers now work in the Aether player",
            "The Aether player now plays the next episode and updates Continue Watching when a show finishes",
            "Fixed connecting to your Plex server when you're away from home",
            "Updated AetherEngine to the latest version",
            "Bug fixes",
        ]),
        ("1.0.0 (51)", [
            "Subtitles now work in the Aether player, both text and image-based, styled to your system caption settings",
            "More reliable sidebar, including a fix for it getting stuck after sign-in or changing libraries",
            "Smoother first-time sign-in",
            "Home hero is now shown by default",
            "Improved library sorting",
            "Bug fixes",
        ]),
        ("1.0.0 (50)", [
            "Refactored most views to UIKit. Performance should be much better.",
            "Added AetherEngine as a third video player option.",
            "Bug fixes.",
            "Live TV fixes coming soon!",
        ]),
        ("1.0.0 (48)", [
            "Added Discover and Watchlist tabs",
            "Added Music browsing",
            "Added pre-play audio and subtitle track pickers",
            "Added a Resume or Restart prompt setting (off by default)",
            "A bare touchpad tap surfaces the timeline overlay",
            "Fixed focus on player error screens",
            "Auto-transcodes codecs Apple TV can't decode (MPEG-2, VC-1, VP9, AV1)",
            "Fixed a freeze when resuming after a paused scrub",
            "Fixed audio flutter on AAC, FLAC, and PCM tracks",
            "Fixed 401 errors on multi-server Plex accounts",
            "Thanks to @rrgomes for PR contributions in this release",
        ]),
        ("1.0.0 (47)", [
            "New Discover page: browse Popular, Top Rated, Now Playing, and Upcoming content from TMDB",
            "Plex Watchlist integration: saved items appear on Home and you can add or remove from anywhere",
            "Hero bookmark button now toggles your Plex Watchlist. Mark Watched moved to the detail page",
        ]),
        ("1.0.0 (46)", [
            "Fixed watched episodes not automatically playing",
            "Fixed some animation jank",
            "Updated heroes to be more Apple TV+ style. Not perfect yet",
            "Fixed library sorting",
        ]),
        ("1.0.0 (44)", [
            "Built a completely custom video player using ffmpeg and internal tvOS tools. The end goal is playback as smooth as Infuse. It's working well in all my tests, but please open any issues if you experience them",
            "Re-styled many GUI elements to match Apple TV+ style and functionality",
            "Apple's built-in player (AVPlayer) can be used if desired. Toggle in settings",
            "Currently re-working the music library style to match the Apple Music app, with functionality to match PlexAmp. It's a work in progress but wanted to get something out",
        ]),
        ("1.0.0 (43)", [
            "Refined the GUI to be more Apple TV+ style",
            "Removed MPVKit. Defaulting to AVPlayer while the custom player is in development",
        ]),
        ("1.0.0 (40)", [
            "Fun depth effects on posters, because why not",
            "Redesigned season and episode navigation for TV shows",
            "Sort libraries by title, date added, rating, and more",
            "Option to hide recently added from library views",
            "Smoother video playback when Match Content is off",
            "Continuing Dolby Vision improvements",
            "General performance and stability improvements",
        ]),
        ("1.0.0 (38)", [
            "Faster video startup",
            "Default sizing is slightly larger",
            "Display Size setting now affects all sizes",
            "Improved Dolby Vision support for more video formats",
            "Playback now integrates with Apple's Now Playing for control from other Apple devices",
            "Scroll down an episode details page to get to Seasons and episode list",
        ]),
        ("1.0.0 (37)", [
            "You can now save your PIN for Plex Home profiles",
            "Live TV is more reliable with automatic stream recovery",
            "Support for more controller types",
            "PIP now works in Live TV",
            "Better multiview handling in Live TV",
            "Live TV scrubbing controls",
            "Continuing efforts to fix audio buffering on HomePods",
            "Only show Post Video screen on tv shows with a next up episode",
        ]),
        ("1.0.0 (36)", [
            "Trying an experimental Dolby Vision player; If DV does not work, or works well, let me know",
            "Added Plex Home Account support. Enable it in settings",
            "Added shuffle buttons to Seasons and Series",
            "Library sections now appear individually on Home - Long-press libraries to toggle Home visibility",
            "Fixed navigation bugs",
            "Fixed some Add Live TV GUI issues",
            "Fixed some Live TV endpoint issues and added more error logging to pinpoint more",
            "Fixed audio not stopping",
            "Added Changelog popup and section in settings",
            "Removed percentage from Post Video summary",
            "Added background to post video summary"
        ]),
    ]

    static func features(for version: String) -> [String]? {
        changelogs.first(where: { $0.version == version })?.features
    }
}
