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

    /// A literal `description` is extracted to the string catalog.
    init(icon: String, description: String.LocalizationValue) {
        self.icon = icon
        self.description = String(localized: description)
    }
}

// MARK: - Descriptor Store

enum SettingsDescriptorStore {
    private static let embyName = MediaProviderKind.emby.displayName

    static func descriptor(for id: String) -> SettingDescriptor? {
        if let exact = descriptors[id] { return exact }
        // Rows built per item at runtime carry the item's identity in their id,
        // so they cannot have their own entry. Fall back on the row KIND, which
        // is what the panel wants to explain anyway.
        if id.hasPrefix("homeRow_") { return descriptors["homeRowItem"] }
        if id.hasPrefix("pinnedCollection_") { return descriptors["pinnedCollection"] }
        if id.hasPrefix("homePlaylist_") { return descriptors["homePlaylist"] }
        if id.hasPrefix("fav_") { return descriptors["liveTVFavoriteRow"] }
        if id.hasPrefix("cfw_"), id != "cfw_add" { return descriptors["customWordRow"] }
        if id.hasPrefix("sq_") { return descriptors["streamingQualityOption"] }
        if id.hasPrefix("al_") { return descriptors["audioLanguage"] }
        if id.hasPrefix("sl_") { return descriptors["subtitleLanguage"] }
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
            description: "Customize how Rivulet looks: the sidebar, Top Shelf, hero banners, Home and library rows, and ratings."
        ),
        "cat_playback": SettingDescriptor(
            icon: "play.fill",
            description: "Quality, audio, subtitles, skipping and autoplay."
        ),
        "cat_liveTV": SettingDescriptor(
            icon: "tv.fill",
            description: "Manage Live TV sources, layout preferences, multiview settings, and channel display options."
        ),
        "cat_photos": SettingDescriptor(
            icon: "photo.on.rectangle",
            description: "Choose how slideshows in your photo libraries play."
        ),
        "photoSlideInterval": SettingDescriptor(
            icon: "timer",
            description: "How long each photo stays on screen during a slideshow."
        ),
        "photoSlideTransition": SettingDescriptor(
            icon: "sparkles.rectangle.stack",
            description: "Dissolve fades from one photo to the next. Pan and Zoom also drifts slowly across each photo."
        ),
        "photoSlidePlaysClips": SettingDescriptor(
            icon: "video",
            description: "Plays each video clip in full when a slideshow reaches it, then carries on with the next photo. When off, slideshows skip them."
        ),
        "cat_servers": SettingDescriptor(
            icon: "server.rack",
            description: "Manage your Plex, Jellyfin and Emby server connections and user profiles."
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
            description: "Select to show or hide this row in the sidebar. Hold Select to move it up or down."
        ),
        "sidebarLiveTVRow": SettingDescriptor(
            icon: "tv",
            description: "Hold Select to move Live TV up or down. It leaves the sidebar when its sources are removed."
        ),
        "libraryRow": SettingDescriptor(
            icon: "sidebar.squares.left",
            description: "Select to show or hide this library in the sidebar and on Home. Hold Select to move it up or down."
        ),
        "appIcon": SettingDescriptor(
            icon: "app.badge",
            description: "Choose the Rivulet icon on the Apple TV Home Screen."
        ),

        "homeRows": SettingDescriptor(
            icon: "rectangle.grid.1x2",
            description: "Choose what appears on Home and in what order."
        ),
        "resetHomeRows": SettingDescriptor(
            icon: "arrow.counterclockwise",
            description: "Put every Home row back in its original order and show the ones you hid. Favorites and playlists are turned off; pinned collections stay."
        ),
        "homeRowItem": SettingDescriptor(
            icon: "rectangle.grid.1x2",
            description: "Select to show or hide this row on Home. Hold Select to move it up or down."
        ),
        "pinnedCollection": SettingDescriptor(
            icon: "pin",
            description: "A collection you pinned from its tile menu. Hold Select to reorder, or Select to unpin it."
        ),
        "homePlaylist": SettingDescriptor(
            icon: "music.note.list",
            description: "Select to show or hide this playlist on Home. Once it is shown, hold Select to move it up or down."
        ),
        "homeFavoriteMovies": SettingDescriptor(
            icon: "star",
            description: "Select to show or hide your favorite movies on Home. Once they are shown, hold Select to move them up or down."
        ),
        "homeFavoriteShows": SettingDescriptor(
            icon: "star",
            description: "Select to show or hide your favorite TV shows on Home. Once they are shown, hold Select to move them up or down."
        ),
        "resetHomeHero": SettingDescriptor(
            icon: "arrow.counterclockwise",
            description: "Put the hero back to Trending only, with no playlists."
        ),
        "homeHero": SettingDescriptor(
            icon: "sparkles.rectangle.stack",
            description: "Choose what the hero shows. Pick more than one to mix them. Turn all off to hide the hero."
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
            description: "Shows a banner of featured titles at the top of each library."
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
            description: "Recommends unwatched titles based on your watch history and TMDB data."
        ),
        // MARK: Playback
        "autoSkipIntro": SettingDescriptor(
            icon: "play.circle",
            description: "What happens when an intro starts. Manual shows Skip Intro, Automatic skips it after a short countdown, and Off never shows the button."
        ),
        "autoSkipAds": SettingDescriptor(
            icon: "forward.frame",
            description: "What happens when an ad break starts. Manual shows Skip Ad, Automatic skips it after a short countdown, and Off never shows the button."
        ),
        "autoSkipRecap": SettingDescriptor(
            icon: "backward.end.circle",
            description: "What happens when a recap starts. Manual shows Skip Recap, Automatic skips it, and Off never shows the button. Markers come from the community database below."
        ),
        "useIntroDB": SettingDescriptor(
            icon: "magnifyingglass",
            description: "Fills in missing intro, recap and credits markers from introdb.app."
        ),
        "promptResumeOrRestart": SettingDescriptor(
            icon: "questionmark.circle",
            description: "Before playing something you have started, asks whether to resume or start from the beginning, like the Apple TV app."
        ),
        "instantResume": SettingDescriptor(
            icon: "play.rectangle.on.rectangle",
            description: "Selecting a Continue Watching tile resumes it at once. Off opens the preview instead and turns off the Resume or Restart Prompt."
        ),
        "homeStreamingQuality": SettingDescriptor(
            icon: "house.fill",
            description: "Quality on your home network. Original plays the file untouched."
        ),
        "awayStreamingQuality": SettingDescriptor(
            icon: "antenna.radiowaves.left.and.right",
            description: "Quality away from home. Auto converts only when your connection needs it."
        ),
        "streamingQualityOption": SettingDescriptor(
            icon: "dial.medium",
            description: "Original plays the file as is. Auto converts only when needed. A fixed rate converts anything above it, without HDR or Atmos."
        ),
        "audioLanguage": SettingDescriptor(
            icon: "waveform",
            description: "The audio track to play when a title has several. Original keeps the file's main track. Picking a track in the player also changes this."
        ),
        "subtitleMode": SettingDescriptor(
            icon: "captions.bubble",
            description: "Foreign Audio shows subtitles only when a title isn't in your language. Always shows them on everything."
        ),
        "subtitleLanguage": SettingDescriptor(
            icon: "globe",
            description: "The language subtitles are shown in."
        ),
        "subtitleSDH": SettingDescriptor(
            icon: "ear",
            description: "Subtitles that also describe sounds and name who is speaking."
        ),
        "generatedSubtitles": SettingDescriptor(
            icon: "captions.bubble",
            description: "English only for now. With Subtitles set to Always, a title with no subtitles in your language gets them written from its dialogue. Downloads 230 MB."
        ),
        "upscaleLowResolution": SettingDescriptor(
            icon: "sparkles.tv",
            description: "Sharpens SD and 720p video with Apple's machine learning upscaler. Uses more power, and stops if the Apple TV can't keep up. HDR, Dolby Vision and Live TV are not changed."
        ),
        "autoplayCountdown": SettingDescriptor(
            icon: "forward.end.alt",
            description: "How long to wait before automatically playing the next episode. Set to Off to disable autoplay."
        ),
        "autoplayLimit": SettingDescriptor(
            icon: "moon.zzz",
            description: "How many more episodes play on their own after the one you picked."
        ),
        "skipLength": SettingDescriptor(
            icon: "forward.fill",
            description: "How far a single Right press skips ahead during playback."
        ),
        "skipBackLength": SettingDescriptor(
            icon: "backward.fill",
            description: "How far a single Left press skips back during playback."
        ),
        "cinemaTrailers": SettingDescriptor(
            icon: "film.stack",
            description: "On Plex, plays trailers and your server's pre-roll video before a movie you start from the beginning. Your server's Cinema Trailers settings choose what plays."
        ),
        "atTheCredits": SettingDescriptor(
            icon: "rectangle.stack",
            description: "When the credits start, Up Next opens the next episode card, Skip Button shows only Skip Credits, and Nothing waits for the end. Countdown decides whether the next episode autoplays."
        ),

        // MARK: Live TV
        "combineSources": SettingDescriptor(
            icon: "square.stack.3d.down.right",
            description: "Shows all Live TV sources together under one sidebar entry."
        ),
        "defaultLayout": SettingDescriptor(
            icon: "tv",
            description: "The Guide lists every channel against the time. What's On shows rows of what is on now, with multiview, like the Apple TV app."
        ),
        "liveTVFavorites": SettingDescriptor(
            icon: "star.fill",
            description: "Set the order of your favorite channels. To add one, hold Select on a channel in What's On or the guide."
        ),
        "liveTVFavoriteRow": SettingDescriptor(
            icon: "star.fill",
            description: "Hold Select to move this channel, then Select to drop it. Select on its own removes it. Favorites you set in Plex come after these, in Plex's order."
        ),
        "noLiveTVFavorites": SettingDescriptor(
            icon: "star",
            description: "Hold Select on a channel in What's On or the guide and choose Add to Favorites. Favorites from every source share one list."
        ),
        "liveTVSuggestions": SettingDescriptor(
            icon: "sparkles",
            description: "Adds a For You row to What's On, with channels picked from what you watch. It learns on this Apple TV only."
        ),
        "keepPlayingInGuide": SettingDescriptor(
            icon: "pip",
            description: "When you go back from a live channel, it keeps playing with its sound in the corner of the Guide or What's On. Select it again to return to full screen."
        ),
        "confirmExitMultiview": SettingDescriptor(
            icon: "rectangle.split.2x2",
            description: "Asks before closing multiview, so one press can't end every stream."
        ),

        // MARK: Storage
        "cache": SettingDescriptor(
            icon: "internaldrive",
            description: "See how much Rivulet has cached, and clear it."
        ),
        "iCloudSync": SettingDescriptor(
            icon: "icloud",
            description: "Keeps your settings, servers and Live TV sources the same on every Apple TV, iPhone, iPad and Mac on your Apple Account. Sign-ins are encrypted in iCloud. Watch progress stays with your servers."
        ),
        "forceRefresh": SettingDescriptor(
            icon: "arrow.clockwise",
            description: "Reloads your libraries from all your servers. Cached images are kept."
        ),
        "clearAllCache": SettingDescriptor(
            icon: "trash",
            description: "Removes all cached images and metadata. They download again as needed."
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
            description: "Off hides this server's channels from Live TV. Its libraries stay."
        ),
        "jellyfinLiveTV": SettingDescriptor(
            icon: "tv.and.mediabox",
            description: "Off hides this server's channels from Live TV. Its libraries stay."
        ),
        "embyLiveTV": SettingDescriptor(
            icon: "tv.and.mediabox",
            description: "Off hides this server's channels from Live TV. Its libraries stay."
        ),
        "src_showInLiveTV": SettingDescriptor(
            icon: "tv.and.mediabox",
            description: "Off hides this server's channels from Live TV. Its libraries stay."
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
            description: "Your Jellyfin server's address with its port, like http://192.168.1.100:8096."
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
        "jellyfinQuickConnect": SettingDescriptor(
            icon: "qrcode",
            description: "Sign in without typing a password: Rivulet shows a code to approve from a device already signed in to Jellyfin. Quick Connect has to be on in the server's dashboard."
        ),
        "jellyfinRefresh": SettingDescriptor(
            icon: "arrow.clockwise",
            description: "Reload this server's libraries and Home rows now."
        ),
        "jellyfinSignOut": SettingDescriptor(
            icon: "rectangle.portrait.and.arrow.right",
            description: "Sign out of this Jellyfin server and remove its saved credentials."
        ),
        "embyServer": SettingDescriptor(
            icon: "server.rack",
            description: "Sign in to your \(embyName) server."
        ),
        "embyServerInfo": SettingDescriptor(
            icon: "server.rack",
            description: "The \(embyName) server you are signed in to."
        ),
        "embyUserInfo": SettingDescriptor(
            icon: "person",
            description: "The \(embyName) user you are signed in as."
        ),
        "embyURL": SettingDescriptor(
            icon: "globe",
            description: "Your \(embyName) server's address with its port, like http://192.168.1.100:8096."
        ),
        "embyUsername": SettingDescriptor(
            icon: "person",
            description: "Your \(embyName) username."
        ),
        "embyPassword": SettingDescriptor(
            icon: "key",
            description: "Used once, to sign in. Rivulet keeps the access token \(embyName) returns, not the password. Leave it empty if your user has none."
        ),
        "embySignIn": SettingDescriptor(
            icon: "link",
            description: "Check the server and sign in."
        ),
        "embyRefresh": SettingDescriptor(
            icon: "arrow.clockwise",
            description: "Reload this server's libraries and Home rows now."
        ),
        "embySignOut": SettingDescriptor(
            icon: "rectangle.portrait.and.arrow.right",
            description: "Sign out of this \(embyName) server and remove its saved credentials."
        ),
        "connectPlex": SettingDescriptor(
            icon: "link",
            description: "Sign in to Plex to browse and play your libraries."
        ),
        "profilePickerOnLaunch": SettingDescriptor(
            icon: "person.2.circle",
            description: "Shows the profile picker each time Rivulet opens, and when you come back after more than 30 seconds away: on the Home Screen, in another app or on the screensaver."
        ),
        "liveTVSources": SettingDescriptor(
            icon: "tv.and.mediabox",
            description: "Add your own Live TV sources: your Plex server's Live TV or an IPTV playlist from your provider. Rivulet provides no channels of its own."
        ),
        "plexLiveTVSource": SettingDescriptor(
            icon: "play.rectangle.fill",
            description: "Your Plex server's tuners. Select to see details or remove it."
        ),
        "dispatcharrSource": SettingDescriptor(
            icon: "antenna.radiowaves.left.and.right",
            description: "Channels from your Dispatcharr server. Select to see details or remove it."
        ),
        "m3uSource": SettingDescriptor(
            icon: "list.bullet.rectangle",
            description: "Channels from an M3U playlist. Select to see details or remove it."
        ),
        "addLiveTVSource": SettingDescriptor(
            icon: "plus.circle.fill",
            description: "Connect a Live TV source you already have access to: your Plex server's tuners, a login or playlist from an IPTV provider, or a server you run yourself."
        ),
        "refreshChannels": SettingDescriptor(
            icon: "arrow.clockwise",
            description: "Reloads this source's channels and guide."
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
            description: "Dispatcharr only. Needed to record from the guide. Leave it empty to just watch."
        ),
        "passwordField": SettingDescriptor(
            icon: "key",
            description: "Used once, to fetch your Dispatcharr API key. Rivulet keeps the key, not the password."
        ),
        "channelProfileField": SettingDescriptor(
            icon: "line.3.horizontal.decrease.circle",
            description: "Dispatcharr only. A channel profile name, to load just those channels. Leave it empty for every channel."
        ),
        "m3uURLField": SettingDescriptor(
            icon: "list.bullet.rectangle",
            description: "The playlist link your IPTV provider gave you, like http://provider.example/playlist.m3u."
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
            description: "Shows every remote press on screen, how long it was held and which remote sent it."
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
            description: "Mutes swearing at the strength you pick. Also applies to imported filter lists."
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
            description: "Skips violent and gory scenes. Needs a filter list: set Filter List URL below."
        ),
        "cf_sexNudity": SettingDescriptor(
            icon: "eye.slash.fill",
            description: "Skips scenes with sex or nudity. Needs a filter list: set Filter List URL below."
        ),
        "cf_frightening": SettingDescriptor(
            icon: "theatermasks.fill",
            description: "Skips frightening or intense scenes. Needs a filter list: set Filter List URL below."
        ),
        "cf_substances": SettingDescriptor(
            icon: "pills.fill",
            description: "Skips scenes with drug, alcohol or tobacco use. Needs a filter list: set Filter List URL below."
        ),
        "cf_sourceURL": SettingDescriptor(
            icon: "link",
            description: "Optional. A folder or address with per-title MCF or EDL filter files. From moviecontentfilter.com, download the EDL with your copy's times."
        ),
    ]

    // MARK: - Page Descriptors

    /// A group's own panel icon on pages whose icon follows focus between groups,
    /// keyed by the group's header id. Nil keeps the page icon.
    static func sectionIcon(for page: SettingsPage, section: String?) -> String? {
        guard page == .appearance else { return nil }
        switch section {
        case "hdr_Home": return "house.fill"
        case "hdr_Library": return "books.vertical.fill"
        case "hdr_Details": return "star.leadinghalf.filled"
        case "hdr_Live TV": return "tv.fill"
        case "hdr_Extras": return "sparkles"
        default: return nil
        }
    }

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
        case .photos: return ("photo.on.rectangle", .systemYellow)
        case .servers: return ("server.rack", .systemOrange)
        case .about: return ("info.circle.fill", .systemGray)
        case .plex: return ("server.rack", .systemOrange)
        case .plexServerDetail: return ("server.rack", .systemOrange)
        case .jellyfin: return ("server.rack", .systemPurple)
        case .emby: return ("server.rack", .systemGreen)
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
