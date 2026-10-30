// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SettingsDescriptors.swift
//  Rivulet
//
//  Per-setting descriptors for the split settings left panel
//

import UIKit

// MARK: - Setting Descriptor

struct SettingDescriptor {
    let icon: String
    let description: String
}

// MARK: - Descriptor Store

enum SettingsDescriptorStore {
    static func descriptor(for id: String) -> SettingDescriptor? {
        if let exact = descriptors[id] { return exact }
        // Rows built per item at runtime carry the item's identity in their id,
        // so they cannot have their own entry. Fall back on the row KIND, which
        // is what the panel wants to explain anyway.
        if id.hasPrefix("homeRow_") { return descriptors["homeRowItem"] }
        if id.hasPrefix("pinnedCollection_") { return descriptors["pinnedCollection"] }
        if id.hasPrefix("fav_") { return descriptors["liveTVFavoriteRow"] }
        if id.hasPrefix("cfw_"), id != "cfw_add" { return descriptors["customWordRow"] }
        if id.hasPrefix("sq_") { return descriptors["streamingQualityOption"] }
        if id.hasPrefix("al_") { return descriptors["audioLanguage"] }
        if id.hasPrefix("sl_") { return descriptors["subtitleLanguage"] }
        if id.hasPrefix("siloSL_") { return descriptors["siloSubtitleLanguageOption"] }
        if id.hasPrefix("hs_") { return descriptors["heightSpeakers"] }
        if id.hasPrefix("sm_") { return descriptors["subtitleMode"] }
        if id.hasPrefix("ai_") { return descriptors["appIcon"] }
        if id.hasPrefix("hh_") { return descriptors["homeHero"] }
        if id.hasPrefix("dr_") { return descriptors["detailRating"] }
        if id.hasPrefix("alim_") { return descriptors["autoplayLimit"] }
        if id.hasPrefix("plexServer_") { return descriptors["plexServerOption"] }
        if id.hasPrefix("lib_") { return descriptors["libraryRow"] }
        if id.hasPrefix("sb_#livetv") { return descriptors["sidebarLiveTVRow"] }
        if id.hasPrefix("sb_") { return descriptors["sidebarAppRow"] }
        return nil
    }

    static let descriptors: [String: SettingDescriptor] = [
        // MARK: Root Categories
        "cat_appearance": SettingDescriptor(
            icon: "paintbrush.fill",
            description: "Customize how Rivulet looks — display size, hero banners, sidebar libraries, and content discovery rows."
        ),
        "cat_playback": SettingDescriptor(
            icon: "play.fill",
            description: "Configure audio, subtitles, skip behavior, and autoplay."
        ),
        "cat_liveTV": SettingDescriptor(
            icon: "tv.fill",
            description: "Manage Live TV sources, layout preferences, multiview settings, and channel display options."
        ),
        "cat_servers": SettingDescriptor(
            icon: "server.rack",
            description: "Manage your Plex server connection and user profiles."
        ),
        "cat_about": SettingDescriptor(
            icon: "info.circle.fill",
            description: "App version, changelog, and other information about Rivulet."
        ),

        // MARK: Appearance
        "libraries": SettingDescriptor(
            icon: "sidebar.squares.left",
            description: "Choose what appears in the sidebar and in what order. Home follows it: a library turned off here loses its Home rows."
        ),
        "resetSidebar": SettingDescriptor(
            icon: "arrow.counterclockwise",
            description: "Put every sidebar row back in its original order and show the ones you hid. Home's rows follow the library order."
        ),
        "sidebarAppRow": SettingDescriptor(
            icon: "sidebar.squares.left",
            description: "Click to show or hide this row in the sidebar. Press and hold to move it up or down."
        ),
        "sidebarLiveTVRow": SettingDescriptor(
            icon: "tv",
            description: "Press and hold to move Live TV up or down. It leaves the sidebar when its sources are removed."
        ),
        "libraryRow": SettingDescriptor(
            icon: "sidebar.squares.left",
            description: "Click to show or hide this library in the sidebar and on Home. Press and hold to move it up or down."
        ),
        "appIcon": SettingDescriptor(
            icon: "app.badge",
            description: "Choose the Rivulet icon on the Apple TV Home Screen."
        ),

        "homeRows": SettingDescriptor(
            icon: "rectangle.grid.1x2",
            description: "Turn Home rows off on this Apple TV. Rows come from your Plex account; a library shows here once it is pinned to Home in Plex."
        ),
        "showAllHomeRows": SettingDescriptor(
            icon: "eye",
            description: "Show every row your Plex account puts on Home again."
        ),
        "homeRowItem": SettingDescriptor(
            icon: "rectangle.grid.1x2",
            description: "Turn this row off to hide it on this Apple TV. Your Plex account is unchanged, so the row keeps showing in the Plex app and on your other devices."
        ),
        "pinnedCollection": SettingDescriptor(
            icon: "pin",
            description: "A collection you pinned from its tile menu. Hold Select to reorder, or Select to unpin it."
        ),
        "homeHero": SettingDescriptor(
            icon: "sparkles.rectangle.stack",
            description: "The large banner at the top of the Home screen. Trending features popular titles from your library. Or pick one of your Home lists: Continue Watching, Recently Added or your Watchlist."
        ),
        "topShelfStyle": SettingDescriptor(
            icon: "tv",
            description: "The top row of the Apple TV Home Screen. Posters shows a row of posters. Full Screen fills it with artwork from what you are watching."
        ),
        "skipPreview": SettingDescriptor(
            icon: "rectangle.expand.vertical",
            description: "Selecting a movie or show opens its full details at once, skipping the preview card. Off keeps the preview, where you can browse the row."
        ),
        "detailRating": SettingDescriptor(
            icon: "star.leadinghalf.filled",
            description: "Choose the one rating shown at the top of a movie or show's details. If a title doesn't have the rating you choose, Rotten Tomatoes is shown instead."
        ),
        "libraryHero": SettingDescriptor(
            icon: "rectangle.stack",
            description: "Shows a featured content banner at the top of each library with highlighted picks."
        ),
        "discoveryRows": SettingDescriptor(
            icon: "square.stack.3d.up",
            description: "Adds discovery rows like Top Rated, Rediscover, and Similar Items to help you find things to watch."
        ),
        "recentRows": SettingDescriptor(
            icon: "clock.arrow.trianglehead.counterclockwise.rotate.90",
            description: "Shows Recently Added and Recently Released rows in each library."
        ),
        "personalizedRecs": SettingDescriptor(
            icon: "person.3",
            description: "Uses TMDB metadata and your watch history to surface personalized recommendations of unwatched content."
        ),
        // MARK: Playback
        "autoSkipIntro": SettingDescriptor(
            icon: "play.circle",
            description: "What happens when an intro starts. Manual shows Skip Intro, Automatic skips it after a short countdown, and Off never shows the button."
        ),
        "autoSkipCredits": SettingDescriptor(
            icon: "stop.circle",
            description: "What happens when the credits start. Manual shows Skip Credits, Automatic skips straight to the post-play screen, and Off never shows the button."
        ),
        "autoSkipAds": SettingDescriptor(
            icon: "forward.frame",
            description: "What happens when an ad break starts. Manual shows Skip Ad, Automatic skips it after a short countdown, and Off never shows the button."
        ),
        "autoSkipRecap": SettingDescriptor(
            icon: "backward.end.circle",
            description: "When a recap starts. Manual shows Skip Recap, Automatic skips it, Off shows nothing. Recap markers come from the community database below."
        ),
        "useIntroDB": SettingDescriptor(
            icon: "magnifyingglass",
            description: "Fills in missing intro, recap and credits markers from introdb.app, sending only the show ID and episode number. Your server's markers come first."
        ),
        "promptResumeOrRestart": SettingDescriptor(
            icon: "questionmark.circle",
            description: "In-progress items show a Resume / Start from Beginning prompt before playing, like Apple TV."
        ),
        "instantResume": SettingDescriptor(
            icon: "play.rectangle.on.rectangle",
            description: "Selecting a Continue Watching tile resumes it at once. Off opens the preview instead and turns off the Resume or Restart Prompt."
        ),
        "homeStreamingQuality": SettingDescriptor(
            icon: "house.fill",
            description: "Quality when the server is on your home network. Original plays the file untouched, with HDR, Dolby Vision and Atmos."
        ),
        "awayStreamingQuality": SettingDescriptor(
            icon: "antenna.radiowaves.left.and.right",
            description: "Quality on cellular, a hotspot, Low Data Mode or a remote connection. Auto measures your connection and converts only when the file will not fit."
        ),
        "streamingQualityOption": SettingDescriptor(
            icon: "dial.medium",
            description: "Original plays the file as is. Auto converts only when your connection needs it. A fixed rate converts anything above it, dropping HDR and Atmos."
        ),
        "audioLanguage": SettingDescriptor(
            icon: "waveform",
            description: "The audio track to play when a title has several. Original keeps the file's main track. Picking a track in the player also changes this."
        ),
        "subtitleMode": SettingDescriptor(
            icon: "captions.bubble",
            description: "Foreign Audio shows subtitles when the audio is not in your language, otherwise forced ones only. Always shows them on every title."
        ),
        "subtitleLanguage": SettingDescriptor(
            icon: "globe",
            description: "The language subtitles are shown in."
        ),
        "subtitleSDH": SettingDescriptor(
            icon: "ear",
            description: "Prefers subtitles for the deaf and hard of hearing, which also describe sounds and name who is speaking."
        ),
        "generatedSubtitles": SettingDescriptor(
            icon: "captions.bubble",
            description: "English only for now. With Subtitles set to Always, a title with no subtitles in your language gets them written from its dialogue. Downloads 230 MB."
        ),
        "heightSpeakers": SettingDescriptor(
            icon: "hifispeaker.2",
            description: "Keeps the height channels of object-based soundtracks, lossless over HDMI. Off plays 7.1 without them. Some soundtracks need 7.1.4 or 9.1.6."
        ),
        "dolbyVisionFEL": SettingDescriptor(
            icon: "4k.tv",
            description: "Plays the full Dolby Vision Profile 7 layer on a Dolby Vision TV, without AirPlay or Picture in Picture. Off plays it as 8.1."
        ),
        "autoplayCountdown": SettingDescriptor(
            icon: "forward.end.alt",
            description: "How long to wait before automatically playing the next episode. Set to Off to disable autoplay."
        ),
        "autoplayLimit": SettingDescriptor(
            icon: "moon.zzz",
            description: "After this many episodes play in a row, the next one waits for you instead of starting on its own."
        ),
        "skipLength": SettingDescriptor(
            icon: "forward.fill",
            description: "How far a single Right press skips ahead during playback."
        ),
        "skipBackLength": SettingDescriptor(
            icon: "backward.fill",
            description: "How far a single Left press skips back during playback."
        ),
        "showPostVideoUpNext": SettingDescriptor(
            icon: "rectangle.stack",
            description: "When off, closing credits play uninterrupted and the player returns to Home at the end of the episode."
        ),

        // MARK: Live TV
        "combineSources": SettingDescriptor(
            icon: "square.stack.3d.down.right",
            description: "Shows all Live TV sources together under one sidebar entry, or gives each source its own."
        ),
        "defaultLayout": SettingDescriptor(
            icon: "tv",
            description: "Choose your default Live TV view: the TV guide, or What's On, with rows of what is on now and multiview like the Apple TV app."
        ),
        "liveTVFavorites": SettingDescriptor(
            icon: "star.fill",
            description: "Set the order of your favorite channels, from every source. To add one, hold Select on a channel in What's On or the guide."
        ),
        "liveTVFavoriteRow": SettingDescriptor(
            icon: "star.fill",
            description: "Hold Select to move this channel, then press Select to drop it. Select to remove it. Favorites you set in Plex come after these, in Plex's order."
        ),
        "noLiveTVFavorites": SettingDescriptor(
            icon: "star",
            description: "Hold Select on a channel in What's On or the guide and choose Add to Favorites. Favorites from every source share one list."
        ),
        "liveTVSuggestions": SettingDescriptor(
            icon: "sparkles",
            description: "A For You row in What's On, suggesting what is on now like what you watch. It learns on this Apple TV only. Off hides the row."
        ),
        "keepPlayingInGuide": SettingDescriptor(
            icon: "pip",
            description: "When you go back from a live channel, it keeps playing with its sound in the corner of the Guide or What's On. Select it again to return to full screen."
        ),
        "confirmExitMultiview": SettingDescriptor(
            icon: "rectangle.split.2x2",
            description: "Shows a confirmation dialog before closing multiview mode to prevent accidentally ending multiple streams."
        ),

        // MARK: Storage
        "cache": SettingDescriptor(
            icon: "internaldrive",
            description: "View storage usage and manage cached images, metadata, and other temporary data."
        ),
        "forceRefresh": SettingDescriptor(
            icon: "arrow.clockwise",
            description: "Clear metadata cache and reload all library content from your Plex server. Images will be kept."
        ),
        "clearAllCache": SettingDescriptor(
            icon: "trash",
            description: "Remove all cached images and metadata. Content will be re-downloaded as needed."
        ),

        // MARK: Servers
        "plexServer": SettingDescriptor(
            icon: "server.rack",
            description: "Every Plex server on your account. Select one to see its details."
        ),
        "plexServerOption": SettingDescriptor(
            icon: "server.rack",
            description: "See this server's details. A server shared with you shows who owns it."
        ),
        "plexServerEnabled": SettingDescriptor(
            icon: "power",
            description: "Turn off to remove this server from Rivulet: its libraries, Home rows, Continue Watching and Live TV. Your account stays signed in."
        ),
        "plexServerLiveTV": SettingDescriptor(
            icon: "tv.and.mediabox",
            description: "Off hides this server's channels from Live TV, for when the same channels come from another source. Its libraries stay."
        ),
        "jellyfinLiveTV": SettingDescriptor(
            icon: "tv.and.mediabox",
            description: "Off hides this server's channels from Live TV, for when the same channels come from another source. Its libraries stay."
        ),
        "src_showInLiveTV": SettingDescriptor(
            icon: "tv.and.mediabox",
            description: "Off hides this server's channels from Live TV, for when the same channels come from another source. Its libraries stay."
        ),
        "plexServerRefresh": SettingDescriptor(
            icon: "arrow.clockwise",
            description: "Ask Plex for this server's latest status."
        ),
        "plexServersLoading": SettingDescriptor(
            icon: "server.rack",
            description: "Finding the servers on your Plex account."
        ),
        "plexServersRetry": SettingDescriptor(
            icon: "arrow.clockwise",
            description: "Plex didn't return your servers. Check your network, then select to try again."
        ),
        "signOut": SettingDescriptor(
            icon: "rectangle.portrait.and.arrow.right",
            description: "Sign out of your Plex account. Every Plex server on it leaves Rivulet until you sign in again."
        ),
        "jellyfinServer": SettingDescriptor(
            icon: "server.rack",
            description: "Sign in to your Jellyfin server."
        ),
        "jellyfinURL": SettingDescriptor(
            icon: "globe",
            description: "Your Jellyfin server's address, including the port, for example http://192.168.1.100:8096. You can paste the address from your browser."
        ),
        "jellyfinUsername": SettingDescriptor(
            icon: "person",
            description: "Your Jellyfin username."
        ),
        "jellyfinPassword": SettingDescriptor(
            icon: "key",
            description: "Used once, to sign in. Rivulet keeps the access token Jellyfin returns, not the password."
        ),
        "jellyfinSignIn": SettingDescriptor(
            icon: "link",
            description: "Check the server and sign in."
        ),
        "jellyfinSignOut": SettingDescriptor(
            icon: "rectangle.portrait.and.arrow.right",
            description: "Sign out of this Jellyfin server and remove its saved credentials."
        ),
        "siloServer": SettingDescriptor(
            icon: "externaldrive.fill",
            description: "Connect to Silo to browse your libraries, curated lists and recommendations."
        ),
        "siloURL": SettingDescriptor(
            icon: "globe",
            description: "Your Silo web address, including its port or reverse-proxy path. Use the native Silo address, not its Jellyfin-compatible address."
        ),
        "siloUsername": SettingDescriptor(icon: "person", description: "Your Silo account username."),
        "siloPassword": SettingDescriptor(
            icon: "key",
            description: "Used only to sign in. Rivulet saves the server's session credentials securely, not your password."
        ),
        "siloSignIn": SettingDescriptor(icon: "link", description: "Check the Silo server and sign in, then choose a profile."),
        "siloDeviceSignIn": SettingDescriptor(icon: "qrcode", description: "Sign in on your phone using Silo's device code, then choose a profile."),
        "siloFollowPlayback": SettingDescriptor(icon: "play.rectangle", description: "Use Silo's own playback preferences for this profile, subtitles included. On by default; local choices on this page still take precedence."),
        "siloBufferingPolicy": SettingDescriptor(icon: "wifi", description: "Choose whether buffering may lower quality: never, ask first, or automatically."),
        "siloQualityOverride": SettingDescriptor(icon: "slider.horizontal.3", description: "Use Auto or an exact quality ID offered by Silo. Clear stops inherited quality; empty inherits."),
        "siloBitrateOverride": SettingDescriptor(icon: "speedometer", description: "Set a local maximum bitrate in kbps. This is a bitrate limit, not a guaranteed resolution."),
        "siloAudioLanguageOverride": SettingDescriptor(icon: "waveform", description: "Prefer an audio language for Silo playback on this profile."),
        "siloSubtitleLanguageOverride": SettingDescriptor(icon: "globe", description: "The language Silo's profile prefers for subtitles. Pick another to override it on this Apple TV only."),
        "siloSubtitleLanguageOption": SettingDescriptor(icon: "globe", description: "Which subtitle language Silo should prefer. Follow Silo uses the language set on the profile; None leaves it unset."),
        "siloSubtitleModeOverride": SettingDescriptor(icon: "captions.bubble", description: "Silo's own behavior for this profile: Auto shows subtitles when you need them, Always on shows them on every title, Off turns them off. A title's explicit choice still wins."),
        "siloForcedSubtitleOverride": SettingDescriptor(icon: "captions.bubble", description: "Choose whether forced subtitles are shown when Silo selects subtitles."),
        "siloThemeMusicEnabled": SettingDescriptor(icon: "music.note", description: "Play a selected Silo title's theme music when its page is visible. Off by default."),
        "siloThemeMusicLoop": SettingDescriptor(icon: "repeat", description: "Repeat optional Silo title theme music while its page remains active."),
        "siloSignOut": SettingDescriptor(
            icon: "rectangle.portrait.and.arrow.right",
            description: "Sign out of Silo and remove this account's saved credentials from Rivulet."
        ),
        "siloProfiles": SettingDescriptor(icon: "person.2", description: "Choose the Silo profile whose libraries, Home and watch state you want to use."),
        "siloProfilePIN": SettingDescriptor(icon: "lock", description: "Enter this Silo profile's PIN. The PIN is not saved."),
        "connectPlex": SettingDescriptor(
            icon: "link",
            description: "Connect to your Plex server to browse and stream your media library."
        ),
        "profilePickerOnLaunch": SettingDescriptor(
            icon: "person.2.circle",
            description: "Shows the profile picker each time Rivulet launches, allowing you to choose which profile to use."
        ),
        "liveTVSources": SettingDescriptor(
            icon: "tv.and.mediabox",
            description: "Add your own Live TV sources: your Plex server's Live TV or an IPTV playlist from your provider. Rivulet provides no channels of its own."
        ),
        "plexLiveTVSource": SettingDescriptor(
            icon: "play.rectangle.fill",
            description: "Plex Live TV source using your server's DVR tuners. Tap to view details or remove."
        ),
        "dispatcharrSource": SettingDescriptor(
            icon: "antenna.radiowaves.left.and.right",
            description: "Dispatcharr source providing managed IPTV channels. Tap to view details or remove."
        ),
        "m3uSource": SettingDescriptor(
            icon: "list.bullet.rectangle",
            description: "M3U playlist source for IPTV channels. Tap to view details or remove."
        ),
        "addLiveTVSource": SettingDescriptor(
            icon: "plus.circle.fill",
            description: "Connect a Live TV source you already have access to: your Plex server's tuners, a login or playlist from an IPTV provider, or a server you run yourself."
        ),
        "refreshChannels": SettingDescriptor(
            icon: "arrow.clockwise",
            description: "Reload the channel list and EPG data from this source."
        ),
        "removeSource": SettingDescriptor(
            icon: "trash",
            description: "Remove this Live TV source and all its channels."
        ),
        "addXtream": SettingDescriptor(
            icon: "person.badge.key",
            description: "Sign in with the server, username and password from your IPTV provider (an Xtream Codes login). Rivulet loads the channels and guide."
        ),
        "xtreamServerField": SettingDescriptor(
            icon: "globe",
            description: "Your provider's server address with its port, like http://provider.example:8080. A single link with your login in it works too."
        ),
        "xtreamUsernameField": SettingDescriptor(
            icon: "person",
            description: "The username your provider gave you."
        ),
        "xtreamPasswordField": SettingDescriptor(
            icon: "key",
            description: "The password your provider gave you. Rivulet keeps it in the Keychain."
        ),
        "addDispatcharr": SettingDescriptor(
            icon: "antenna.radiowaves.left.and.right",
            description: "Your Dispatcharr server. Rivulet loads its channels and guide, and records through it if you sign in."
        ),
        "addTvheadend": SettingDescriptor(
            icon: "tv",
            description: "Your Tvheadend server. Rivulet loads its channels and guide, and records through it if you sign in."
        ),
        "addThreadfin": SettingDescriptor(
            icon: "server.rack",
            description: "Your Threadfin server. Rivulet loads its playlist and guide from the address."
        ),
        "tvhServerField": SettingDescriptor(
            icon: "globe",
            description: "Your Tvheadend server's address on your network, with its port. Tvheadend uses 9981 unless you changed it."
        ),
        "tvhUsernameField": SettingDescriptor(
            icon: "person",
            description: "A Tvheadend user. Needed if your server asks for a login, and to record. Leave it empty to watch without one."
        ),
        "tvhPasswordField": SettingDescriptor(
            icon: "key",
            description: "That user's password. Rivulet keeps it in the Keychain."
        ),
        "threadfinServerField": SettingDescriptor(
            icon: "globe",
            description: "Your Threadfin server's address on your network, with its port. Threadfin uses 34400 unless you changed it."
        ),
        "addPlaylistURL": SettingDescriptor(
            icon: "list.bullet.rectangle",
            description: "An M3U playlist link from an IPTV provider you subscribe to, with an optional guide link. Rivulet supplies no channels of its own."
        ),
        "serverURL": SettingDescriptor(
            icon: "globe",
            description: "Your Dispatcharr server's address on your network, with its port. Dispatcharr uses 9191 unless you changed it."
        ),
        "displayNameField": SettingDescriptor(
            icon: "textformat",
            description: "What this source is called in Live TV. Optional."
        ),
        "usernameField": SettingDescriptor(
            icon: "person",
            description: "Dispatcharr only. Sign in with your Dispatcharr user so Rivulet can schedule recordings and series from the guide. Leave it empty to just watch."
        ),
        "passwordField": SettingDescriptor(
            icon: "key",
            description: "Used once, to fetch your Dispatcharr API key. Rivulet keeps the key, not the password."
        ),
        "channelProfileField": SettingDescriptor(
            icon: "line.3.horizontal.decrease.circle",
            description: "Dispatcharr only. The name of a channel profile, to load just that set of channels. Leave it empty and you get every channel on the server."
        ),
        "m3uURLField": SettingDescriptor(
            icon: "list.bullet.rectangle",
            description: "The playlist link your IPTV provider gave you, for example http://provider.example/playlist.m3u. It usually ends in .m3u or .m3u8."
        ),
        "epgURLField": SettingDescriptor(
            icon: "calendar",
            description: "Optional. An XMLTV guide link from the same provider, so channels show what is on. Leave it empty if the playlist names its own guide."
        ),
        "addSourceConfirm": SettingDescriptor(
            icon: "plus.circle.fill",
            description: "Checks the connection and adds the source if it works. If it does not, Rivulet tells you why."
        ),

        // MARK: About
        "changelog": SettingDescriptor(
            icon: "list.bullet.rectangle",
            description: "Release notes for every version of Rivulet."
        ),
        "licensesLegal": SettingDescriptor(
            icon: "doc.text.fill",
            description: "Rivulet's license and the open-source software it uses, including FFmpeg (LGPL), libdovi, and Sentry."
        ),
        "inputDiagnostics": SettingDescriptor(
            icon: "dot.radiowaves.left.and.right",
            description: "Shows every remote press on screen, how long it was held and which remote sent it. Useful when reporting a remote problem."
        ),
        "inputTest": SettingDescriptor(
            icon: "checklist",
            description: "Asks you to press a few buttons and records what your remote sent, for Rivulet's diagnostics. Nothing about what you watch is included."
        ),

        "sendDiagnostics": SettingDescriptor(
            icon: "stethoscope",
            description: "Sends a snapshot of Rivulet's setup and recent logs, and gives you a code to quote in a report. No titles, servers, addresses or passwords."
        ),

        // MARK: Content Filtering
        "cat_contentFilter": SettingDescriptor(
            icon: "hand.raised.fill",
            description: "Mute language and skip scenes during playback without changing the file. Language comes from English subtitles; skips from a filter list."
        ),
        "cf_master": SettingDescriptor(
            icon: "hand.raised.fill",
            description: "Turns the content filter on, muting and skipping by the categories below. A player button pauses it for the current title."
        ),
        "cf_profanity": SettingDescriptor(
            icon: "exclamationmark.bubble.fill",
            description: "Mutes profane words: mild and up, moderate and up, or strong only. Also applies to profanity in imported filter lists."
        ),
        "cf_blasphemy": SettingDescriptor(
            icon: "hands.clap.fill",
            description: "Mutes religious names used as exclamations, such as \"oh my god\". The word god on its own is never muted."
        ),
        "cf_slur": SettingDescriptor(
            icon: "person.fill.xmark",
            description: "Mutes racial, homophobic and other slurs in the dialogue."
        ),
        "cf_sexualLanguage": SettingDescriptor(
            icon: "heart.slash.fill",
            description: "Mutes crude and sexual language in the dialogue."
        ),
        "cf_customWords": SettingDescriptor(
            icon: "text.badge.plus",
            description: "Your own words to mute, such as \"shut up\". Muted whenever the filter is on. A word matches only on its own, never inside another."
        ),
        "cfw_add": SettingDescriptor(
            icon: "plus.circle.fill",
            description: "Type a word or a short phrase to mute. Capitals and punctuation don't matter."
        ),
        "customWordRow": SettingDescriptor(
            icon: "text.badge.minus",
            description: "Select to stop muting this word."
        ),
        "cf_violence": SettingDescriptor(
            icon: "burst.fill",
            description: "Skips violent and gory scenes. Requires an imported filter list — set the Filter List URL below. Dialogue text alone can't detect these scenes."
        ),
        "cf_sexNudity": SettingDescriptor(
            icon: "eye.slash.fill",
            description: "Skips scenes with sex or nudity. Requires an imported filter list — set the Filter List URL below."
        ),
        "cf_frightening": SettingDescriptor(
            icon: "theatermasks.fill",
            description: "Skips frightening or intense scenes. Requires an imported filter list — set the Filter List URL below."
        ),
        "cf_substances": SettingDescriptor(
            icon: "pills.fill",
            description: "Skips scenes featuring drug, alcohol, or tobacco use. Requires an imported filter list — set the Filter List URL below."
        ),
        "cf_sourceURL": SettingDescriptor(
            icon: "link",
            description: "Optional. A folder or address with per-title MCF or EDL filter files. From moviecontentfilter.com, download the EDL with your copy's times."
        ),
    ]

    // MARK: - Page Descriptors

    /// Icon and title for each settings page (shown in left panel header).
    /// `UIColor` rather than SwiftUI `Color`: the only consumer is the UIKit
    /// left panel, and vending a `Color` forced it to import SwiftUI just to
    /// call `UIColor(_:)`. These are the same system colors either way.
    static func pageInfo(for page: SettingsPage) -> (icon: String, color: UIColor) {
        switch page {
        case .root: return ("gearshape.fill", .systemGray)
        case .appearance: return ("paintbrush.fill", .systemPurple)
        case .playback: return ("play.fill", .systemBlue)
        case .music: return ("music.note", .systemPink)
        case .liveTV: return ("tv.fill", .systemGreen)
        case .servers: return ("server.rack", .systemOrange)
        case .about: return ("info.circle.fill", .systemGray)
        case .plex: return ("server.rack", .systemOrange)
        case .plexServerDetail: return ("server.rack", .systemOrange)
        case .jellyfin: return ("server.rack", .systemPurple)
        case .silo: return ("externaldrive.fill", .systemTeal)
        case .siloProfiles: return ("person.2.fill", .systemTeal)
        case .siloProfilePIN: return ("lock.fill", .systemTeal)
        case .siloSubtitleLanguagePicker: return ("captions.bubble", .systemTeal)
        case .iptv: return ("tv.and.mediabox", .systemBlue)
        case .libraries: return ("sidebar.squares.left", .systemPurple)
        case .homeRows: return ("rectangle.grid.1x2", .systemTeal)
        case .cache: return ("internaldrive", .systemGray)
        case .appIconPicker: return ("app.badge", .systemPurple)
        case .homeHeroPicker: return ("sparkles.rectangle.stack", .systemPurple)
        case .detailRatingPicker: return ("star.leadinghalf.filled", .systemYellow)
        case .autoplayCountdownPicker: return ("forward.end.alt", .systemPurple)
        case .skipIntervalPicker: return ("forward.fill", .systemBlue)
        case .skipBackIntervalPicker: return ("backward.fill", .systemBlue)
        case .heightSpeakersPicker: return ("hifispeaker.2", .systemCyan)
        case .subtitleModePicker: return ("captions.bubble", .systemYellow)
        case .autoplayLimitPicker: return ("moon.zzz", .systemPurple)
        case .homeQualityPicker: return ("house.fill", .systemBlue)
        case .awayQualityPicker: return ("antenna.radiowaves.left.and.right", .systemBlue)
        case .audioLanguagePicker: return ("waveform", .systemCyan)
        case .subtitleLanguagePicker: return ("captions.bubble", .systemYellow)
        case .contentFilter: return ("hand.raised.fill", .systemOrange)
        case .contentFilterStrength: return ("dial.medium.fill", .systemOrange)
        case .contentFilterWords: return ("text.badge.plus", .systemOrange)
        case .liveTVSourceDetail: return ("tv.and.mediabox", .systemBlue)
        case .liveTVFavorites: return ("star.fill", .systemYellow)
        case .addLiveTVSource: return ("plus.circle.fill", .systemBlue)
        case .addXtream: return ("person.badge.key.fill", .systemIndigo)
        case .addDispatcharr: return ("antenna.radiowaves.left.and.right", .systemBlue)
        case .addTvheadend: return ("tv", .systemBlue)
        case .addThreadfin: return ("server.rack", .systemBlue)
        case .addPlaylistURL: return ("list.bullet.rectangle", .systemGreen)
        }
    }
}
