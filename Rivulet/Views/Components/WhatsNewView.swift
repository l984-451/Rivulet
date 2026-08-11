// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

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
        ("1.0.5 (78)", [
            "A show's page now shows each season's poster, episode count and summary",
            "The episode row now marks where each season starts",
            "Selecting a season opens its own page, with only its episodes and extras",
            "A season's page now leads with its poster",
            "A caption placed left or right now sits at that edge instead of drifting in",
            "Discover no longer hides loaded rows behind a No Content message",
            "Changing your sidebar libraries now applies right away, with no reload prompt",
        ]),
        ("1.0.4 (77)", [
            "Search now moves down from the keyboard into your results",
            "Moving up from a row of results no longer skips the row above it",
            "Search results scroll into view instead of sitting under the keyboard",
            "Recent searches move left and right smoothly again",
            "Search starts fresh each time you open the tab",
            "Removed diagnostic logging that shipped in the last build",
        ]),
        ("1.0.4 (76)", [
            "Fixed Search and Discover, where no button press did anything after opening them",
            "The playback controls now hide on their own again after a few seconds",
            "A title's Play button now shows the time left, matching its Continue Watching tile",
            "The player's Description tab no longer floats the summary in the middle of the panel",
            "Home row titles now come from your Plex server and appear in your language",
            "Home now shows the rows you have promoted on your Plex server",
            "Continue Watching and On Deck now show as one row instead of two",
            "New Rows page in Settings under Home lets you hide Home rows",
            "Live TV guide times are now correct for guides that set a time zone",
            "Music can now move back to the sidebar with a left press",
            "Updated AetherEngine to 6.5.5",
        ]),
        ("1.0.4 (75)", [
            "Top Shelf artwork on the Apple TV Home screen now includes the title logo",
            "Moving between the playback controls no longer skips the video",
            "The controls stay open while an info popup is showing",
            "Pressing Select opens the controls without pausing or resuming",
            "Closing an info popup returns you to the button you opened it from",
            "Fast forward and rewind now step down into the other direction",
            "Menu now works every time inside popups and full screen pages",
            "The player info panel no longer resizes while you are reading it",
        ]),
        ("1.0.4 (74)", [
            "Testing remote control fixes. If this breaks for you, please install an older build and submit a bug. Thanks.",
            "Updated AetherEngine to 6.4.0",
            "Subtitles now match the text size, background box and position Apple TV uses for its own captions",
            "Subtitles keep the styling the content asked for, including bold, italic, underline, colour and size",
            "Captions a broadcaster places away from the bottom of the picture now appear where they were put",
            "Subtitles lift clear of the playback controls while they are showing and drop back when they hide",
            "The subtitle height adjustment is now remembered per title and per channel, like the delay",
            "Marking an item as watched now updates the Play button instead of saying Resume",
            "Marking an item as watched now updates Home and Continue Watching right away",
            "Pausing now registers on your Plex server instead of showing as still playing",
            "Music marks a song as a favorite only when you rate it above three stars",
            "Swiping now moves between the buttons on a title's details page",
            "Swiping the touch surface now skips back and forward in Live TV",
            "Info popups on the details page now scroll with a swipe",
            "New Input Diagnostics toggle in Settings helps track down remote issues",
            "The player's INFO and cast panels now move between sections with a swipe",
        ]),
        ("1.0.4 (72)", [
            "Updated AetherEngine to 6.1.3",
            "The progress bar no longer jumps back after a seek on a slow server",
            "Reaching the end of a movie or a show's last episode now closes the player",
            "The player's INFO panel now opens on a Description tab with the title and summary",
            "Leaving the player now fades to black while your TV switches display modes",
            "Season rows now scroll, so shows with more than eight seasons are reachable",
            "The Recent Rows and Discovery Rows settings hide those rows again",
            "New Instant Resume setting in Playback, on by default. Turn it off and Continue Watching tiles open the preview like every other Home row instead of playing right away",
        ]),
        ("1.0.4 (71)", [
            "Updated AetherEngine to 5.23.11",
            "Playback starts and seeks more reliably",
            "Fixed picture and colour problems on several kinds of file",
            "Live TV is steadier and recovers on its own when a channel drops",
            "Subtitles are more reliable, and external .sup files now load",
            "The Play button on the remote starts or resumes whatever is focused",
            "You can now set the skip length for a single Left or Right press in Playback settings",
            "Trailers and extras now play reliably",
        ]),
        ("1.0.4 (69)", [
            "New Content Filtering in Playback settings can mute strong language and skip scenes during playback, with per category controls and a quick toggle in the player",
            "Language muting works on any title with subtitles, and scene skipping uses filter lists in the MCF or EDL format from a URL you provide, without ever changing your files",
            "The backdrop that appears while paused now waits ten seconds instead of five, so you have more time to look at the paused frame",
            "Pressing Back while the paused backdrop is showing now brings back the paused frame instead of closing the player",
            "Fixed playback getting stuck after leaving the app and coming back, the video now picks up right where you left off",
            "The player's INFO panel now responds to swipes on the remote, so you can move through and scroll its sections without clicking",
            "Fixed Live TV channels on DVB tuners with cloud based guide data failing to start",
            "Live TV streams no longer cut out after a few minutes because the server thought nobody was watching",
            "The Live TV player now shows how far into the current program you are",
            "The Live TV guide now loads program data as you scroll, so large channel lineups open faster",
            "Fixed channel logos sometimes showing on the wrong channels while scrolling the Live TV guide",
            "Teletext subtitles now start on the page used in your region",
            "Fixed connecting to a Plex server failing on some home networks, with a retry and an unlink option if connecting still fails",
        ]),
        ("1.0.3 (67)", [
            "Choosing forced subtitles now sticks: the next title no longer switches you to full captions",
            "Redesigned Live TV guide with a full channel grid, program details, and instant playback",
            "Show and movie pages opened from Top Shelf or Siri now match the pages you get inside the app",
            "Removing an item from Continue Watching no longer leaves focus in the wrong place",
            "The INFO panel in the player now shows the streaming mode for video, audio, and subtitles, so you can confirm Direct Play without checking the server dashboard",
            "The player's INFO panel now has an Advanced tab with live playback stats like bitrate, frame rate, buffer, and network throughput",
            "Updated AetherEngine to 5.8.4. Adds teletext subtitles and much smoother audio and video on broadcast Live TV channels, closed captions on more US broadcast and cable channels, faster startup on slower sources, fewer stalls when resuming after a pause, and a fix for rare freezes during 4K HDR playback",
            "Tuning into a live channel mid-broadcast no longer shows a green flash or a channel that never starts, and switching between similar channels is faster",
            "Interlaced broadcast channels now play with smoother motion using hardware deinterlacing",
            "Videos in unusual formats that used to show a black screen now play using a software decoder",
            "HDR Live TV channels no longer fail to start",
            "The TV no longer drops to SDR and back when one Dolby Vision title starts after another",
            "Skipping on a slow or stalling source no longer leaves the player hanging",
            "Live TV subtitles now show broadcaster colours following your system caption settings, and rolling captions no longer flicker",
            "New Delay and Height adjustments in the player's subtitle menu. Delay is remembered per movie, episode, and channel; height applies everywhere",
            "The skip button now fills up as the auto skip counts down",
            "In Live TV, the Menu button now closes an open menu or the controls one step at a time before leaving the channel",
            "Redesigned the Add Source flow in Live TV to match the rest of the app, with choices named for what you have instead of technical terms",
            "Fixed sources and servers on plain http addresses failing to connect",
            "New optional Community Marker Database in Playback settings fills in missing intro, recap, and credits markers when your server has none, with a new Auto-Skip Recap option",
            "Playing from a server that reaches you only through Plex Relay now works instead of failing, at a lower 480p quality the relay's limited bandwidth can sustain",
            "Pressing Back while the Up Next screen is showing now returns you to the video instead of closing the player",
            "A single left or right press now skips 30 seconds, and holding fast forwards or rewinds at increasing speed, the same way whether the controls are visible or not",
            "Bringing up the player controls now places focus on the progress bar, so you can skip or scrub right away",
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
