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
        return nil
    }

    private static let descriptors: [String: SettingDescriptor] = [
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
            description: "Choose which libraries appear in the sidebar and set their display order."
        ),
        "libraryRow": SettingDescriptor(
            icon: "sidebar.squares.left",
            description: "Click to toggle sidebar visibility. Press and hold to reorder or configure Home screen visibility."
        ),
        "resetLibraries": SettingDescriptor(
            icon: "arrow.counterclockwise",
            description: "Reset all library visibility, ordering, and Home screen preferences to their defaults."
        ),
        "displaySize": SettingDescriptor(
            icon: "textformat.size",
            description: "Scale all interface elements up or down. Useful for different TV sizes and viewing distances."
        ),

        "homeRows": SettingDescriptor(
            icon: "rectangle.grid.1x2",
            description: "Choose which rows appear on Home. The rows themselves, their titles and their order come from your Plex account, so they match the Plex app. Turn one off here to hide it on this Apple TV only."
        ),
        "showAllHomeRows": SettingDescriptor(
            icon: "eye",
            description: "Show every row your Plex account puts on Home again."
        ),
        "homeRowItem": SettingDescriptor(
            icon: "rectangle.grid.1x2",
            description: "Turn this row off to hide it on this Apple TV. Your Plex account is unchanged, so the row keeps showing in the Plex app and on your other devices."
        ),
        "homeHero": SettingDescriptor(
            icon: "sparkles.rectangle.stack",
            description: "Shows a large featured content banner at the top of the Home screen with artwork and quick actions."
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
        "showDiscoverTab": SettingDescriptor(
            icon: "safari",
            description: "Shows the Discover tab in the sidebar for browsing Popular, Top Rated, Upcoming, and more from TMDB."
        ),
        "discoverAboveLibraries": SettingDescriptor(
            icon: "arrow.up.arrow.down",
            description: "Moves the Discover tab above your Media libraries in the sidebar for quicker access."
        ),
        // MARK: Playback
        "autoSkipIntro": SettingDescriptor(
            icon: "play.circle",
            description: "Automatically skips TV show intros when markers are available. No button press needed."
        ),
        "autoSkipCredits": SettingDescriptor(
            icon: "stop.circle",
            description: "Automatically skips end credits when markers are available, going straight to the post-play screen."
        ),
        "autoSkipAds": SettingDescriptor(
            icon: "forward.frame",
            description: "Automatically skips advertisement segments when markers are available."
        ),
        "autoSkipRecap": SettingDescriptor(
            icon: "backward.end.circle",
            description: "Automatically skips 'previously on' recaps. Recap markers come from the community database below; turn that on for this to have anything to skip."
        ),
        "useIntroDB": SettingDescriptor(
            icon: "magnifyingglass",
            description: "Fills in missing intro, recap, and credits markers from the community database introdb.app, sending only the show's ID and episode number. Your own server's markers are always used first."
        ),
        "promptResumeOrRestart": SettingDescriptor(
            icon: "questionmark.circle",
            description: "In-progress items show a Resume / Start from Beginning prompt before playing, like Apple TV."
        ),
        "instantResume": SettingDescriptor(
            icon: "play.rectangle.on.rectangle",
            description: "Selecting a Continue Watching tile resumes it immediately. Turn this off to open the preview instead, the same as every other Home row, which also disables the Resume or Restart Prompt below."
        ),
        "autoplayCountdown": SettingDescriptor(
            icon: "forward.end.alt",
            description: "How long to wait before automatically playing the next episode. Set to Off to disable autoplay."
        ),
        "skipLength": SettingDescriptor(
            icon: "forward.fill",
            description: "How far a single Left or Right press skips during playback."
        ),
        "showPostVideoUpNext": SettingDescriptor(
            icon: "rectangle.stack",
            description: "When off, closing credits play uninterrupted and the player returns to Home at the end of the episode."
        ),

        // MARK: Live TV
        "liveTVAboveLibraries": SettingDescriptor(
            icon: "arrow.up.arrow.down",
            description: "Moves the Live TV section above your Media libraries in the sidebar for quicker access."
        ),
        "classicTVMode": SettingDescriptor(
            icon: "tv.fill",
            description: "Hides player controls during live TV for a traditional television experience. Swipe up to show controls."
        ),
        "combineSources": SettingDescriptor(
            icon: "square.stack.3d.down.right",
            description: "Shows all Live TV sources in a single combined Channels view, or gives each source its own sidebar entry."
        ),
        "defaultLayout": SettingDescriptor(
            icon: "tv",
            description: "Choose between the channel grid layout or the TV guide layout as your default Live TV view."
        ),
        "confirmExitMultiview": SettingDescriptor(
            icon: "rectangle.split.2x2",
            description: "Shows a confirmation dialog before closing multiview mode to prevent accidentally ending multiple streams."
        ),
        "allowFourStreams": SettingDescriptor(
            icon: "rectangle.split.2x2.fill",
            description: "Enables 3 and 4 stream multiview layouts. Warning: 4 streams may cause instability on some devices."
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
            description: "Manage your Plex server connection, view server details, or sign out."
        ),
        "signOut": SettingDescriptor(
            icon: "rectangle.portrait.and.arrow.right",
            description: "Sign out of your Plex server and remove all saved credentials. You'll need to sign in again to access your media."
        ),
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
            description: "Add and manage your own Live TV sources — your Plex server's Live TV, or an M3U/IPTV playlist from a provider you subscribe to. Rivulet does not provide any channels or content of its own."
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
            description: "Connect a Live TV source you already have access to: your Plex server's tuners, a server you run yourself, or a playlist URL from an IPTV provider."
        ),
        "refreshChannels": SettingDescriptor(
            icon: "arrow.clockwise",
            description: "Reload the channel list and EPG data from this source."
        ),
        "removeSource": SettingDescriptor(
            icon: "trash",
            description: "Remove this Live TV source and all its channels."
        ),
        "addPlexLiveTV": SettingDescriptor(
            icon: "play.rectangle.fill",
            description: "Add the tuners already set up on your Plex server. One press adds them and loads the channel list."
        ),
        "addPlexLiveTVError": SettingDescriptor(
            icon: "exclamationmark.triangle.fill",
            description: "Plex Live TV could not be added. Set up a DVR and tuners in your Plex server settings, then try again."
        ),
        "addOwnServer": SettingDescriptor(
            icon: "server.rack",
            description: "A server you run yourself that serves a playlist and a guide, such as Dispatcharr, Threadfin, xTeVe, ErsatzTV, or Cabernet. You give Rivulet the address and it finds the rest."
        ),
        "addPlaylistURL": SettingDescriptor(
            icon: "list.bullet.rectangle",
            description: "A playlist link from an IPTV provider you subscribe to. Rivulet supplies no channels of its own."
        ),
        "serverURL": SettingDescriptor(
            icon: "globe",
            description: "The address of your server on your network, including the port. Pick your app from the suggestions to fill in the usual one."
        ),
        "displayNameField": SettingDescriptor(
            icon: "textformat",
            description: "What this source is called in the sidebar and the guide."
        ),
        "apiTokenField": SettingDescriptor(
            icon: "key",
            description: "Only needed if your server asks for one. Leave it empty otherwise."
        ),
        "channelProfileField": SettingDescriptor(
            icon: "line.3.horizontal.decrease.circle",
            description: "Dispatcharr only. The name of a channel profile, to load just that set of channels. Leave it empty and you get every channel on the server."
        ),
        "m3uURLField": SettingDescriptor(
            icon: "list.bullet.rectangle",
            description: "The playlist link your IPTV provider gave you. It usually ends in .m3u or .m3u8."
        ),
        "epgURLField": SettingDescriptor(
            icon: "calendar",
            description: "Optional. An XMLTV guide link from the same provider, so channels show what is on."
        ),
        "addSourceConfirm": SettingDescriptor(
            icon: "plus.circle.fill",
            description: "Checks the connection and adds the source if it works. If it does not, the reason appears below."
        ),
        "addSourceError": SettingDescriptor(
            icon: "exclamationmark.triangle.fill",
            description: "The source was not added. Fix the field above and press Add Source again."
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
            description: "Show every remote button press on screen, with how long it was held and which remote sent it. Helpful when reporting a problem with a third-party remote. Leave this off for normal viewing."
        ),

        // MARK: Content Filtering
        "cat_contentFilter": SettingDescriptor(
            icon: "hand.raised.fill",
            description: "Mute strong language and skip scenes during playback, without ever changing the file. Language is detected live from the subtitle track; scene skips come from an imported filter list."
        ),
        "cf_master": SettingDescriptor(
            icon: "hand.raised.fill",
            description: "Turn the local content filter on. Rivulet then mutes and skips in real time based on the categories below."
        ),
        "cf_profanity": SettingDescriptor(
            icon: "exclamationmark.bubble.fill",
            description: "Mutes profane words as they appear in the subtitle line. Requires a subtitle track to be active. Use Profanity Strength to choose how much is filtered."
        ),
        "cf_strength": SettingDescriptor(
            icon: "dial.medium.fill",
            description: "How much profanity to mute: mild and up, moderate and up, or strong words only."
        ),
        "cf_blasphemy": SettingDescriptor(
            icon: "hands.clap.fill",
            description: "Mutes irreverent uses of religious names and phrases detected in the subtitle line. Ordinary dialogue is left alone."
        ),
        "cf_slur": SettingDescriptor(
            icon: "person.fill.xmark",
            description: "Mutes racial and other slurs detected in the subtitle line."
        ),
        "cf_sexualLanguage": SettingDescriptor(
            icon: "heart.slash.fill",
            description: "Mutes crude and sexual language detected in the subtitle line."
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
            description: "Optional. A location where per-title filter files live, in the open MCF (movie content filter) or EDL format. Use {id} for the Plex rating key, or point at a folder that holds <ratingKey>.mcf files. Rivulet loads the matching file when a title starts. It ships no filter data of its own."
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
        case .iptv: return ("tv.and.mediabox", .systemBlue)
        case .libraries: return ("sidebar.squares.left", .systemPurple)
        case .homeRows: return ("rectangle.grid.1x2", .systemTeal)
        case .cache: return ("internaldrive", .systemGray)
        case .displaySizePicker: return ("textformat.size", .systemOrange)
        case .autoplayCountdownPicker: return ("forward.end.alt", .systemPurple)
        case .skipIntervalPicker: return ("forward.fill", .systemBlue)
        case .contentFilter: return ("hand.raised.fill", .systemOrange)
        case .contentFilterStrength: return ("dial.medium.fill", .systemOrange)
        case .liveTVSourceDetail: return ("tv.and.mediabox", .systemBlue)
        case .addLiveTVSource: return ("plus.circle.fill", .systemBlue)
        case .addOwnServer: return ("server.rack", .systemBlue)
        case .addPlaylistURL: return ("list.bullet.rectangle", .systemGreen)
        }
    }
}
