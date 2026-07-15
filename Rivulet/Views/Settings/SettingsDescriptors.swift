//
//  SettingsDescriptors.swift
//  Rivulet
//
//  Per-setting descriptors for the split settings left panel
//

import SwiftUI

// MARK: - Setting Descriptor

struct SettingDescriptor {
    let icon: String
    let iconColor: Color
    let description: String
}

// MARK: - Descriptor Store

enum SettingsDescriptorStore {
    static func descriptor(for id: String) -> SettingDescriptor? {
        descriptors[id]
    }

    private static let descriptors: [String: SettingDescriptor] = [
        // MARK: Root Categories
        "cat_appearance": SettingDescriptor(
            icon: "paintbrush.fill",
            iconColor: .purple,
            description: "Customize how Rivulet looks — display size, hero banners, sidebar libraries, and content discovery rows."
        ),
        "cat_playback": SettingDescriptor(
            icon: "play.fill",
            iconColor: .blue,
            description: "Configure audio, subtitles, skip behavior, and autoplay."
        ),
        "cat_liveTV": SettingDescriptor(
            icon: "tv.fill",
            iconColor: .green,
            description: "Manage Live TV sources, layout preferences, multiview settings, and channel display options."
        ),
        "cat_servers": SettingDescriptor(
            icon: "server.rack",
            iconColor: .orange,
            description: "Manage your Plex server connection and user profiles."
        ),
        "cat_about": SettingDescriptor(
            icon: "info.circle.fill",
            iconColor: .gray,
            description: "App version, changelog, and other information about Rivulet."
        ),

        // MARK: Appearance
        "libraries": SettingDescriptor(
            icon: "sidebar.squares.left",
            iconColor: .purple,
            description: "Choose which libraries appear in the sidebar and set their display order."
        ),
        "libraryRow": SettingDescriptor(
            icon: "sidebar.squares.left",
            iconColor: .purple,
            description: "Click to toggle sidebar visibility. Press and hold to reorder or configure Home screen visibility."
        ),
        "resetLibraries": SettingDescriptor(
            icon: "arrow.counterclockwise",
            iconColor: .orange,
            description: "Reset all library visibility, ordering, and Home screen preferences to their defaults."
        ),
        "displaySize": SettingDescriptor(
            icon: "textformat.size",
            iconColor: .orange,
            description: "Scale all interface elements up or down. Useful for different TV sizes and viewing distances."
        ),

        "homeHero": SettingDescriptor(
            icon: "sparkles.rectangle.stack",
            iconColor: .indigo,
            description: "Shows a large featured content banner at the top of the Home screen with artwork and quick actions."
        ),
        "libraryHero": SettingDescriptor(
            icon: "rectangle.stack",
            iconColor: .teal,
            description: "Shows a featured content banner at the top of each library with highlighted picks."
        ),
        "discoveryRows": SettingDescriptor(
            icon: "square.stack.3d.up",
            iconColor: .cyan,
            description: "Adds discovery rows like Top Rated, Rediscover, and Similar Items to help you find things to watch."
        ),
        "recentRows": SettingDescriptor(
            icon: "clock.arrow.trianglehead.counterclockwise.rotate.90",
            iconColor: .blue,
            description: "Shows Recently Added and Recently Released rows in each library."
        ),
        "personalizedRecs": SettingDescriptor(
            icon: "person.3",
            iconColor: .mint,
            description: "Uses TMDB metadata and your watch history to surface personalized recommendations of unwatched content."
        ),
        "showDiscoverTab": SettingDescriptor(
            icon: "safari",
            iconColor: .blue,
            description: "Shows the Discover tab in the sidebar for browsing Popular, Top Rated, Upcoming, and more from TMDB."
        ),
        "discoverAboveLibraries": SettingDescriptor(
            icon: "arrow.up.arrow.down",
            iconColor: .cyan,
            description: "Moves the Discover tab above your Media libraries in the sidebar for quicker access."
        ),
        "hideSpoilersForUnwatched": SettingDescriptor(
            icon: "eye.slash",
            iconColor: .indigo,
            description: "Blurs descriptions and thumbnails for unwatched movies and episodes. Press the info button on a detail page to read the full description."
        ),
        "hideTriviaSpoilers": SettingDescriptor(
            icon: "sparkles",
            iconColor: .indigo,
            description: "Hides spoiler-tagged trivia facts in the player's Insights panel so a later reveal never appears over what you're watching. On by default."
        ),

        // MARK: Playback
        "autoSkipIntro": SettingDescriptor(
            icon: "play.circle",
            iconColor: .green,
            description: "Automatically skips TV show intros when markers are available. No button press needed."
        ),
        "autoSkipCredits": SettingDescriptor(
            icon: "stop.circle",
            iconColor: .orange,
            description: "Automatically skips end credits when markers are available, going straight to the post-play screen."
        ),
        "autoSkipAds": SettingDescriptor(
            icon: "forward.frame",
            iconColor: .red,
            description: "Automatically skips advertisement segments when markers are available."
        ),
        "autoSkipRecap": SettingDescriptor(
            icon: "backward.end.circle",
            iconColor: .teal,
            description: "Automatically skips 'previously on' recaps. Recap markers come from the community intro database (introdb.app) when Plex has none."
        ),
        "autoSkipPreview": SettingDescriptor(
            icon: "forward.end.circle",
            iconColor: .purple,
            description: "Automatically skips next-episode previews when markers are available."
        ),
        "promptResumeOrRestart": SettingDescriptor(
            icon: "questionmark.circle",
            iconColor: .blue,
            description: "Off by default. When on, in-progress items show a Resume / Start from Beginning prompt before playing, like Apple TV."
        ),
        "autoplayCountdown": SettingDescriptor(
            icon: "forward.end.alt",
            iconColor: .purple,
            description: "How long to wait before automatically playing the next episode. Set to Off to disable autoplay."
        ),
        "showPostVideoUpNext": SettingDescriptor(
            icon: "rectangle.stack",
            iconColor: .purple,
            description: "When off, closing credits play uninterrupted and the player returns to Home at the end of the episode."
        ),

        // MARK: Live TV
        "liveTVAboveLibraries": SettingDescriptor(
            icon: "arrow.up.arrow.down",
            iconColor: .cyan,
            description: "Moves the Live TV section above your Media libraries in the sidebar for quicker access."
        ),
        "classicTVMode": SettingDescriptor(
            icon: "tv.fill",
            iconColor: .indigo,
            description: "Hides player controls during live TV for a traditional television experience. Swipe up to show controls."
        ),
        "combineSources": SettingDescriptor(
            icon: "square.stack.3d.down.right",
            iconColor: .purple,
            description: "Shows all Live TV sources in a single combined Channels view, or gives each source its own sidebar entry."
        ),
        "defaultLayout": SettingDescriptor(
            icon: "tv",
            iconColor: .green,
            description: "Choose between the channel grid layout or the TV guide layout as your default Live TV view."
        ),
        "confirmExitMultiview": SettingDescriptor(
            icon: "rectangle.split.2x2",
            iconColor: .blue,
            description: "Shows a confirmation dialog before closing multiview mode to prevent accidentally ending multiple streams."
        ),
        "allowFourStreams": SettingDescriptor(
            icon: "rectangle.split.2x2.fill",
            iconColor: .orange,
            description: "Enables 3 and 4 stream multiview layouts. Warning: 4 streams may cause instability on some devices."
        ),

        // MARK: Storage
        "cache": SettingDescriptor(
            icon: "internaldrive",
            iconColor: .gray,
            description: "View storage usage and manage cached images, metadata, and other temporary data."
        ),
        "forceRefresh": SettingDescriptor(
            icon: "arrow.clockwise",
            iconColor: .blue,
            description: "Clear metadata cache and reload all library content from your Plex server. Images will be kept."
        ),
        "clearAllCache": SettingDescriptor(
            icon: "trash",
            iconColor: .red,
            description: "Remove all cached images and metadata. Content will be re-downloaded as needed."
        ),

        // MARK: Servers
        "plexServer": SettingDescriptor(
            icon: "server.rack",
            iconColor: .orange,
            description: "Manage your Plex server connection, view server details, or sign out."
        ),
        "signOut": SettingDescriptor(
            icon: "rectangle.portrait.and.arrow.right",
            iconColor: .red,
            description: "Sign out of your Plex server and remove all saved credentials. You'll need to sign in again to access your media."
        ),
        "connectPlex": SettingDescriptor(
            icon: "link",
            iconColor: .blue,
            description: "Connect to your Plex server to browse and stream your media library."
        ),
        "userProfiles": SettingDescriptor(
            icon: "person.crop.circle",
            iconColor: .cyan,
            description: "Switch between Plex Home user profiles. Each profile has its own watch history and preferences."
        ),
        "profileRow": SettingDescriptor(
            icon: "person.crop.circle",
            iconColor: .cyan,
            description: "Select this profile to switch to it. PIN-protected profiles will require verification. Press and hold for more options."
        ),
        "profilePickerOnLaunch": SettingDescriptor(
            icon: "person.2.circle",
            iconColor: .purple,
            description: "Shows the profile picker each time Rivulet launches, allowing you to choose which profile to use."
        ),
        "liveTVSources": SettingDescriptor(
            icon: "tv.and.mediabox",
            iconColor: .blue,
            description: "Add and manage your own Live TV sources — your Plex server's Live TV, or an M3U/IPTV playlist from a provider you subscribe to. Rivulet does not provide any channels or content of its own."
        ),
        "plexLiveTVSource": SettingDescriptor(
            icon: "play.rectangle.fill",
            iconColor: .orange,
            description: "Plex Live TV source using your server's DVR tuners. Tap to view details or remove."
        ),
        "dispatcharrSource": SettingDescriptor(
            icon: "antenna.radiowaves.left.and.right",
            iconColor: .blue,
            description: "Dispatcharr source providing managed IPTV channels. Tap to view details or remove."
        ),
        "m3uSource": SettingDescriptor(
            icon: "list.bullet.rectangle",
            iconColor: .green,
            description: "M3U playlist source for IPTV channels. Tap to view details or remove."
        ),
        "addLiveTVSource": SettingDescriptor(
            icon: "plus.circle.fill",
            iconColor: .blue,
            description: "Connect a Live TV source you already have access to — your Plex server's Live TV, your own M3U server (Dispatcharr, Threadfin, etc.), or a playlist URL from an IPTV provider you subscribe to."
        ),
        "plexLiveTVHint": SettingDescriptor(
            icon: "tv.and.mediabox",
            iconColor: .orange,
            description: "Your Plex server has Live TV available. Tap to automatically add it as a source."
        ),
        "refreshChannels": SettingDescriptor(
            icon: "arrow.clockwise",
            iconColor: .blue,
            description: "Reload the channel list and EPG data from this source."
        ),
        "removeSource": SettingDescriptor(
            icon: "trash",
            iconColor: .red,
            description: "Remove this Live TV source and all its channels."
        ),
        "addPlexLiveTV": SettingDescriptor(
            icon: "play.rectangle.fill",
            iconColor: .orange,
            description: "Add Live TV channels from your Plex server's DVR tuners."
        ),
        "addDispatcharrSource": SettingDescriptor(
            icon: "server.rack",
            iconColor: .blue,
            description: "Connect to your own M3U server that provides playlists and EPG data, such as a self-hosted Dispatcharr or Threadfin instance. You supply the server address."
        ),
        "addM3USource": SettingDescriptor(
            icon: "list.bullet.rectangle",
            iconColor: .green,
            description: "Enter the M3U or M3U8 playlist URL provided by an IPTV service you subscribe to. Rivulet supplies no channels of its own."
        ),
        "addPlexConfirm": SettingDescriptor(
            icon: "play.rectangle.fill",
            iconColor: .orange,
            description: "Tap to add Live TV channels from your Plex server."
        ),
        "serverURL": SettingDescriptor(
            icon: "globe",
            iconColor: .blue,
            description: "The base URL of your own M3U server, for example a self-hosted Dispatcharr instance on your network."
        ),
        "displayNameField": SettingDescriptor(
            icon: "textformat",
            iconColor: .purple,
            description: "A display name for this source in the sidebar."
        ),
        "apiTokenField": SettingDescriptor(
            icon: "key",
            iconColor: .orange,
            description: "Optional API token for authenticated servers."
        ),
        "m3uURLField": SettingDescriptor(
            icon: "list.bullet.rectangle",
            iconColor: .green,
            description: "The M3U or M3U8 playlist URL from the IPTV provider you subscribe to."
        ),
        "epgURLField": SettingDescriptor(
            icon: "calendar",
            iconColor: .orange,
            description: "Optional XMLTV EPG URL for program guide data."
        ),
        "validateServer": SettingDescriptor(
            icon: "checkmark.circle",
            iconColor: .blue,
            description: "Test the connection to your server before adding."
        ),
        "addSourceConfirm": SettingDescriptor(
            icon: "plus.circle.fill",
            iconColor: .green,
            description: "Add this source and start loading channels."
        ),

        // MARK: About
        "changelog": SettingDescriptor(
            icon: "list.bullet.rectangle",
            iconColor: .blue,
            description: "Release notes for every version of Rivulet."
        ),
        "licensesLegal": SettingDescriptor(
            icon: "doc.text.fill",
            iconColor: .gray,
            description: "Rivulet's license and the open-source software it uses, including FFmpeg (LGPL), libdovi, and Sentry."
        ),
    ]

    // MARK: - Page Descriptors

    /// Icon and title for each settings page (shown in left panel header)
    static func pageInfo(for page: SettingsPage) -> (icon: String, color: Color) {
        switch page {
        case .root: return ("gearshape.fill", .gray)
        case .appearance: return ("paintbrush.fill", .purple)
        case .playback: return ("play.fill", .blue)
        case .music: return ("music.note", .pink)
        case .liveTV: return ("tv.fill", .green)
        case .servers: return ("server.rack", .orange)
        case .about: return ("info.circle.fill", .gray)
        case .plex: return ("server.rack", .orange)
        case .iptv: return ("tv.and.mediabox", .blue)
        case .libraries: return ("sidebar.squares.left", .purple)
        case .cache: return ("internaldrive", .gray)
        case .userProfiles: return ("person.crop.circle", .cyan)
        case .displaySizePicker: return ("textformat.size", .orange)
        case .autoplayCountdownPicker: return ("forward.end.alt", .purple)
        case .liveTVSourceDetail: return ("tv.and.mediabox", .blue)
        case .addLiveTVSource: return ("plus.circle.fill", .blue)
        case .addPlexLiveTV: return ("play.rectangle.fill", .orange)
        case .addDispatcharrSource: return ("server.rack", .blue)
        case .addM3USource: return ("list.bullet.rectangle", .green)
        }
    }
}
