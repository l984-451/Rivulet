// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SettingsPageModels.swift
//  Rivulet
//
//  Data model for the UIKit Settings rows + the per-page row builders.
//  Reads/writes the SAME UserDefaults keys and shared managers the SwiftUI
//  Settings used — no new keys, no new source of truth. The builders are
//  the UIKit equivalent of SettingsView's per-page ViewBuilders.
//

import Combine
import Foundation
import UIKit

/// Small UserDefaults helpers that honor the SwiftUI `@AppStorage` default
/// for a key (which is NOT written to UserDefaults until first change).
enum SettingsStore {
    static func bool(_ key: String, default def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? def : UserDefaults.standard.bool(forKey: key)
    }
    static func setBool(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }
    static func string(_ key: String, default def: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? def
    }
    static func setString(_ key: String, _ value: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
    static func int(_ key: String, default def: Int) -> Int {
        UserDefaults.standard.object(forKey: key) == nil ? def : UserDefaults.standard.integer(forKey: key)
    }
    static func setInt(_ key: String, _ value: Int) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

/// One settings row. `id` is the `focusedSettingId` used to drive the left
/// description panel (keys match `SettingsDescriptorStore`).
@MainActor
struct SettingsRowItem {
    enum Kind {
        case navigation(SettingsPage)
        case navigationValue(SettingsPage, value: () -> String)
        /// A chevron row that runs `prepare` (e.g. stash the tapped item) then
        /// pushes `target`. For per-item detail pages (Live TV source → detail).
        case navigationAction(SettingsPage, value: (() -> String)?, prepare: () -> Void)
        /// `didChange` runs after the flip, with the page, for a toggle that
        /// follows up with a question (Suggestions: erase what was learned?).
        case toggle(get: () -> Bool, set: (Bool) -> Void,
                    didChange: ((Bool, UIViewController) -> Void)? = nil)
        case cycle(value: () -> String, next: () -> Void)
        /// Handler receives the presenting VC so it can present a modal /
        /// confirmation (sign-in, clear-cache alert, etc.).
        case action(destructive: Bool, handler: (UIViewController) -> Void)
        case info(value: () -> String)
        /// A selectable option on a picker page: shows a checkmark when
        /// selected, sets the value + pops back when chosen.
        case option(isSelected: () -> Bool, select: () -> Void)
        /// Like `option` but stays on the page (no pop) and runs a VC-aware
        /// handler (which may present a modal, e.g. a profile PIN). Shows a
        /// checkmark when selected + an optional trailing value. The list is
        /// reloaded after the tap so the checkmark moves. For profile rows.
        case selectable(isSelected: () -> Bool, value: () -> String?, handler: (UIViewController) -> Void)
        /// A text field row: shows the current value (or the placeholder when
        /// empty) and presents `TextEntryViewController` on select. `set` is
        /// called with the final text on commit only — a Menu cancel leaves the
        /// value untouched. Reads/writes draft or persisted state through the
        /// closures, mirroring how `.toggle` rows read/write `SettingsStore`.
        /// `isSecure` masks the text while typing and shows "Set" on the row.
        case textEntry(value: () -> String, placeholder: String, hint: String?,
                       suggestions: [(label: String, value: String)],
                       keyboardType: UIKeyboardType, isSecure: Bool = false,
                       contentType: UITextContentType? = nil, set: (String) -> Void)
    }

    let id: String
    let title: String
    let kind: Kind
    /// Non-nil = this row can be grabbed and reordered (hold Select → move
    /// mode). Called with `up` to move it one slot and persist the new order.
    var onReorder: ((_ up: Bool) -> Void)?
    var isReorderable: Bool { onReorder != nil }
    /// Reorder only slides between rows of the same group (each server's
    /// libraries, ordered within its own server). nil == nil as before.
    var reorderGroup: String? = nil
    /// A row whose meaning depends on another row's state renders dimmed and
    /// unfocusable while that state is off. Evaluated live (not cached at build
    /// time) so flipping the row it depends on takes effect without a rebuild.
    var isEnabled: () -> Bool = { true }
    /// Shows a spinner in place of the value while the row's change runs.
    var isBusy: () -> Bool = { false }
    /// True = this "row" is really a group caption (see `header(_:)`).
    var isHeader = false

    /// A literal `title` is extracted to the string catalog; text that is not ours
    /// (server, library, channel names) goes through `verbatim:`.
    init(id: String, title: String.LocalizationValue, kind: Kind, onReorder: ((_ up: Bool) -> Void)? = nil,
         reorderGroup: String? = nil, isEnabled: @escaping () -> Bool = { true },
         isBusy: @escaping () -> Bool = { false }, isHeader: Bool = false) {
        self.init(id: id, verbatim: String(localized: title), kind: kind, onReorder: onReorder,
                  reorderGroup: reorderGroup, isEnabled: isEnabled, isBusy: isBusy, isHeader: isHeader)
    }

    init(id: String, verbatim title: String, kind: Kind, onReorder: ((_ up: Bool) -> Void)? = nil,
         reorderGroup: String? = nil, isEnabled: @escaping () -> Bool = { true },
         isBusy: @escaping () -> Bool = { false }, isHeader: Bool = false) {
        self.id = id
        self.title = title
        self.kind = kind
        self.onReorder = onReorder
        self.reorderGroup = reorderGroup
        self.isEnabled = isEnabled
        self.isBusy = isBusy
        self.isHeader = isHeader
    }

    /// A group caption between row runs, Apple TV Settings style: small
    /// uppercase gray text, no capsule, never focusable. Deliberately NOT a
    /// `Kind` case — it reuses `.info`, which is already unfocusable and
    /// chevron-less, so every existing `switch kind` keeps working untouched.
    /// The id keeps the English key, so it holds in every language.
    static func header(_ title: LocalizedStringResource) -> SettingsRowItem {
        SettingsRowItem(id: "hdr_\(title.key)", verbatim: String(localized: title), kind: .info(value: { "" }), isHeader: true)
    }

    static func header(verbatim title: String) -> SettingsRowItem {
        SettingsRowItem(id: "hdr_\(title)", verbatim: title, kind: .info(value: { "" }), isHeader: true)
    }

    var isFocusable: Bool {
        if case .info = kind { return false }
        return isEnabled()
    }
    var showsChevron: Bool {
        switch kind {
        case .navigation, .navigationValue, .navigationAction: return true
        default: return false
        }
    }
    var isDestructive: Bool {
        if case .action(let destructive, _) = kind { return destructive }
        return false
    }
    /// True for a selected picker option / profile (→ show checkmark).
    var showsCheckmark: Bool {
        switch kind {
        case .option(let isSelected, _): return isSelected()
        case .selectable(let isSelected, _, _): return isSelected()
        default: return false
        }
    }
    var isOption: Bool {
        if case .option = kind { return true }
        return false
    }
    /// Trailing value text, if any (toggle On/Off, cycle/nav value, info value).
    var valueText: String? {
        switch kind {
        case .navigationValue(_, let value): return value()
        case .navigationAction(_, let value, _): return value?()
        case .toggle(let get, _, _): return get() ? String(localized: "On") : String(localized: "Off")
        case .cycle(let value, _): return value()
        case .info(let value): return value()
        case .selectable(_, let value, _): return value()
        // Show the current value; fall back to the placeholder (or "Not set")
        // when empty.
        case .textEntry(let value, let placeholder, _, _, _, let isSecure, _, _):
            let current = value()
            if current.isEmpty { return placeholder.isEmpty ? String(localized: "Not set") : placeholder }
            return isSecure ? String(localized: "Set") : current
        case .navigation, .action, .option: return nil
        }
    }
}

/// Per-page row builders. The UIKit equivalent of SettingsView's per-page
/// ViewBuilders. Pages not yet ported (separate sub-views, picker pages)
/// return an empty list and render a placeholder.
@MainActor
enum SettingsContent {

    /// The run headers when several servers are listed (Home Rows, Sidebar
    /// Libraries). Two servers with one name would read as the same server
    /// twice, so then each also names its server type.
    static func serverRunHeaders(_ runs: [(name: String, kind: MediaProviderKind)]) -> [String] {
        runs.map { run in
            runs.filter { $0.name == run.name }.count > 1 ? "\(run.name) (\(run.kind.displayName))" : run.name
        }
    }

    /// Every server's run, the selected Plex server first: its name, kind and provider id
    /// (nil for the selected Plex server, whose rows and libraries are PlexDataStore's).
    private static var serverRuns: [(name: String, kind: MediaProviderKind, providerID: String?)] {
        [(PlexAuthManager.shared.savedServerName ?? "Plex", .plex, nil)]
            + ServerDataStore.shared.sources.map { source in
                (source.name, MediaProviderRegistry.shared.kind(of: source.providerID) ?? .plex, source.providerID)
            }
    }

    /// Rows a restricted (managed) Plex profile does not get: other servers,
    /// sources, sign-out, and the parental controls themselves.
    static let ownerOnlyRowIDs: Set<String> = ["cat_servers", "liveTVSources", "hdr_Filtering", "cat_contentFilter", "profilePickerOnLaunch", "iCloudSync"]

    static func rows(for page: SettingsPage) -> [SettingsRowItem] {
        let rows = allRows(for: page)
        guard PlexUserProfileManager.shared.isRestrictedProfile else { return rows }
        return rows.filter { !ownerOnlyRowIDs.contains($0.id) }
    }

    private static func allRows(for page: SettingsPage) -> [SettingsRowItem] {
        switch page {
        case .root:        return root
        case .appearance:  return appearance
        case .playback:    return playback
        case .liveTV:      return liveTV
        case .photos:      return photos
        case .music:       return music
        case .servers:     return servers
        case .plex:        return plex
        case .plexServerDetail: return plexServerDetail
        case .jellyfin:    return jellyfin
        case .emby:        return emby
        case .libraries:   return libraries
        case .homeRows:    return homeRows
        case .cache:       return cache
        case .iptv:        return iptv
        case .liveTVSourceDetail: return liveTVSourceDetail
        case .liveTVFavorites: return liveTVFavorites
        case .addLiveTVSource:  return addLiveTVSource
        case .addXtream:        return addXtream
        case .addDispatcharr:   return addDispatcharr
        case .addTvheadend:     return addTvheadend
        case .addThreadfin:     return addThreadfin
        case .addPlaylistURL:   return addPlaylistURL
        case .about:       return about
        case .appIconPicker:          return appIconPicker
        case .homeHeroPicker:         return homeHeroPicker
        case .detailRatingPicker:     return detailRatingPicker
        case .autoplayCountdownPicker: return autoplayCountdownPicker
        case .skipIntervalPicker:     return skipIntervalPicker
        case .skipBackIntervalPicker: return skipBackIntervalPicker
        case .subtitleModePicker:     return subtitleModePicker
        case .autoplayLimitPicker:    return autoplayLimitPicker
        case .homeQualityPicker:      return qualityPicker(home: true)
        case .awayQualityPicker:      return qualityPicker(home: false)
        case .audioLanguagePicker:    return audioLanguagePicker
        case .subtitleLanguagePicker: return subtitleLanguagePicker
        case .contentFilter:          return contentFilter
        case .contentFilterStrength:  return contentFilterStrength
        case .contentFilterWords:     return contentFilterWords
        }
    }

    // MARK: Picker pages (checkmark option rows; select-and-pop)

    private static var appIconPicker: [SettingsRowItem] {
        AppIcon.allCases.map { icon in
            SettingsRowItem(id: "ai_\(icon.rawValue)", verbatim: icon.title, kind: .option(
                isSelected: { AppIcon.current == icon },
                select: { icon.apply() }))
        }
    }

    private static func heroTitle(_ source: HeroSources.Source) -> String {
        switch source {
        case .trending: String(localized: "Trending")
        case .continueWatching: String(localized: "Continue Watching")
        case .recentlyAdded: String(localized: "Recently Added")
        case .watchlist: String(localized: "Watchlist")
        case .favoriteMovies: String(localized: "Favorite Movies")
        case .favoriteShows: String(localized: "Favorite TV Shows")
        }
    }

    /// What the hero shows (`HeroSources`): a toggle per list, then per
    /// playlist. Several are mixed; none turns the hero off.
    private static var homeHeroPicker: [SettingsRowItem] {
        let sources = HeroSources.Source.allCases.filter { source in
            ![.favoriteMovies, .favoriteShows].contains(source) || PersonalHomeRows.offersFavorites
        }
        var rows = [SettingsRowItem(id: "resetHomeHero", title: "Reset", kind: .action(destructive: true, handler: { vc in
            presentConfirm(on: vc, title: "Reset the Hero?",
                           message: "The hero shows Trending only, with no playlists.",
                           confirmTitle: "Reset", destructive: true) {
                HeroSources.reset()
                (vc as? SettingsPageViewController)?.reloadRows()
            }
        }))]
        rows += sources.map { source in
            SettingsRowItem(id: "hh_\(source.rawValue)", verbatim: heroTitle(source), kind: .toggle(
                get: { HeroSources.isOn(source) },
                set: { HeroSources.set(source, on: $0) }))
        }
        let playlists = homePlaylists()
        if !playlists.isEmpty { rows.append(.header("Playlists")) }
        for entry in playlists {
            let ref = MediaItemRef(providerID: entry.providerID, itemID: entry.playlistID)
            rows.append(SettingsRowItem(id: "hh_playlist_\(entry.providerID)/\(entry.playlistID)",
                                        verbatim: serverLabeled(entry.title, providerID: entry.providerID), kind: .toggle(
                get: { HomePlaylistPins.isPinned(ref, in: .hero) },
                set: { shown in
                    if shown {
                        HomePlaylistPins.pin(.init(providerID: entry.providerID, playlistID: entry.playlistID,
                                                   title: entry.title), in: .hero)
                    } else {
                        HomePlaylistPins.unpin(ref, in: .hero)
                    }
                })))
        }
        return rows
    }

    /// The Home section's value: Off, the one source, or Mixed.
    private static var homeHeroTitle: String {
        let titles = HeroSources.Source.allCases.filter(HeroSources.isOn).map(heroTitle)
            + HomePlaylistPins.pins(in: .hero).map(\.title)
        switch titles.count {
        case 0: return String(localized: "Off")
        case 1: return titles[0]
        default: return String(localized: "Mixed")
        }
    }

    /// With more than one server, a row names its own.
    private static func serverLabeled(_ title: String, providerID: String?) -> String {
        guard ServerDataStore.shared.labelsServers, let providerID else { return title }
        let kind = MediaProviderRegistry.shared.kind(of: providerID) ?? .plex
        return "\(title) (\(PlexHomeViewController.serverName(providerID: providerID, kind: kind)))"
    }

    private static var detailRatingPicker: [SettingsRowItem] {
        MediaRating.Source.allCases.filter { $0 != .unknown }.map { source in
            SettingsRowItem(id: "dr_\(source.rawValue)", verbatim: source.name, kind: .option(
                isSelected: { MediaRating.detailSource == source },
                select: { UserDefaults.standard.set(source.rawValue, forKey: MediaRating.detailSourceKey) }))
        }
    }

    private static var autoplayCountdownPicker: [SettingsRowItem] {
        AutoplayCountdown.allCases.map { opt in
            SettingsRowItem(id: "ac_\(opt.rawValue)", verbatim: opt.description, kind: .option(
                isSelected: { SettingsStore.int("autoplayCountdown", default: AutoplayCountdown.fiveSeconds.rawValue) == opt.rawValue },
                select: { SettingsStore.setInt("autoplayCountdown", opt.rawValue) }))
        }
    }

    private static var skipIntervalPicker: [SettingsRowItem] {
        SkipInterval.allCases.map { opt in
            SettingsRowItem(id: "si_\(opt.rawValue)", verbatim: opt.description, kind: .option(
                isSelected: { SettingsStore.int(SkipInterval.storageKey, default: SkipInterval.defaultValue.rawValue) == opt.rawValue },
                select: { SettingsStore.setInt(SkipInterval.storageKey, opt.rawValue) }))
        }
    }

    private static var skipBackIntervalPicker: [SettingsRowItem] {
        SkipInterval.allCases.map { opt in
            SettingsRowItem(id: "sbi_\(opt.rawValue)", verbatim: opt.description, kind: .option(
                isSelected: { Int(InputConfig.tapSeekBackSeconds) == opt.rawValue },
                select: { SettingsStore.setInt(SkipInterval.backStorageKey, opt.rawValue) }))
        }
    }

    /// Forced Only is set only by a player pick, so it is listed only while it is current.
    private static var subtitleModePicker: [SettingsRowItem] {
        SubtitleMode.choices.map { mode in
            SettingsRowItem(id: "sm_\(mode)", verbatim: mode.title, kind: .option(
                isSelected: { SubtitleMode.current == mode },
                select: { TrackIntentStore.setSubtitles(mode: mode) }))
        }
    }

    private static var autoplayLimitPicker: [SettingsRowItem] {
        AutoplayLimit.allCases.map { opt in
            SettingsRowItem(id: "alim_\(opt.rawValue)", verbatim: opt.description, kind: .option(
                isSelected: { AutoplayLimit.current == opt },
                select: { SettingsStore.setInt(AutoplayLimit.storageKey, opt.rawValue) }))
        }
    }

    /// Read at play time by the player (`StreamingQuality.setting`).
    private static func qualityPicker(home: Bool) -> [SettingsRowItem] {
        let key = home ? StreamingQuality.homeKey : StreamingQuality.awayKey
        return StreamingQuality.allChoices.map { choice in
            SettingsRowItem(id: "sq_\(choice.rawValue)", verbatim: choice.label, kind: .option(
                isSelected: { StreamingQuality.setting(home: home) == choice },
                select: { SettingsStore.setString(key, choice.rawValue) }))
        }
    }

    private static var audioLanguagePicker: [SettingsRowItem] {
        let languages = TrackLanguage.sortedChoices
        // No stored intent follows the Plex account's audio language (#382).
        let account = SettingsRowItem(id: "al_account", verbatim: TrackLanguage.audioSettingName(nil), kind: .option(
            isSelected: { TrackIntentStore.audioIntent == nil },
            select: { TrackIntentStore.audioIntent = nil }))
        return [account] + ([TrackLanguage.original] + languages).map { code in
            SettingsRowItem(id: "al_\(code)", verbatim: TrackLanguage.audioSettingName(code), kind: .option(
                isSelected: { TrackIntentStore.audioIntent.map { TrackLanguage.normalize($0.language) } == code },
                select: { TrackIntentStore.audioIntent = AudioIntent(language: code) }))
        }
    }

    private static var subtitleLanguagePicker: [SettingsRowItem] {
        TrackLanguage.sortedChoices.map { code in
            SettingsRowItem(id: "sl_\(code)", verbatim: TrackLanguage.displayName(code), kind: .option(
                isSelected: { TrackLanguage.normalize(TrackIntentStore.subtitleLanguage) == code },
                select: { TrackIntentStore.setSubtitles(language: code) }))
        }
    }

    // MARK: Root

    private static var root: [SettingsRowItem] {
        [
            SettingsRowItem(id: "cat_appearance", title: "Appearance", kind: .navigation(.appearance)),
            SettingsRowItem(id: "cat_playback",   title: "Playback",   kind: .navigation(.playback)),
            // Music settings withdrawn until the audio features behind them
            // exist — all three rows were no-ops (see the `music` builder).
            // Music BROWSING is unaffected: the sidebar still shows the
            // Music library for every visible Plex music library.
//            SettingsRowItem(id: "cat_music",      title: "Music",      kind: .navigation(.music)),
            SettingsRowItem(id: "cat_liveTV",     title: "Live TV",    kind: .navigation(.liveTV)),
            SettingsRowItem(id: "cat_photos",     title: "Photos",     kind: .navigation(.photos)),
            SettingsRowItem(id: "cat_servers",    title: "Servers",    kind: .navigation(.servers)),
            SettingsRowItem(id: "cache",          title: "Cache & Storage", kind: .navigation(.cache)),
            SettingsRowItem(id: "iCloudSync",     title: "iCloud Sync",
                            kind: .cycle(value: { iCloudSyncValue },
                                         next: { CloudSync.shared.setEnabled(!CloudSync.shared.isEnabled) })),
            SettingsRowItem(id: "cat_about",      title: "About",      kind: .navigation(.about))
        ]
    }

    private static var iCloudSyncValue: String {
        if CloudSync.shared.status == .on, CloudSync.shared.blockedAccountIDs.contains(PlexAuthManager.syncID) {
            return String(localized: "iCloud has a different Plex account")
        }
        switch CloudSync.shared.status {
        case .on: return String(localized: "On")
        case .off: return String(localized: "Off")
        case .noAccount: return String(localized: "Sign in to iCloud on this device")
        }
    }

    // MARK: Photos

    private static var photos: [SettingsRowItem] {
        [
            SettingsRowItem(id: PhotoPreferences.intervalKey, title: "Slideshow Interval", kind: .cycle(
                value: { String(localized: "\(Int(PhotoPreferences.slideInterval)) s") },
                next: {
                    let all = PhotoPreferences.intervals
                    let i = all.firstIndex(of: PhotoPreferences.slideInterval) ?? 0
                    PhotoPreferences.slideInterval = all[(i + 1) % all.count]
                })),
            SettingsRowItem(id: PhotoPreferences.transitionKey, title: "Transition", kind: .cycle(
                value: {
                    PhotoPreferences.transition == .dissolve
                        ? String(localized: "Dissolve") : String(localized: "Pan and Zoom")
                },
                next: { PhotoPreferences.transition = PhotoPreferences.transition == .dissolve ? .panAndZoom : .dissolve })),
            SettingsRowItem(id: PhotoPreferences.playsClipsKey, title: "Play Clips in Slideshow", kind: .toggle(
                get: { PhotoPreferences.playsClips }, set: { PhotoPreferences.playsClips = $0 })),
        ]
    }

    // MARK: Appearance

    private static var appearance: [SettingsRowItem] {
        var rows: [SettingsRowItem] = [
            // Leading block is unheaded, like an Apple TV Settings page's first
            // group: it sits directly under the page title.
            SettingsRowItem(id: "libraries", title: "Sidebar", kind: .navigation(.libraries)),
            // App Icon row withheld on tvOS: App Store Connect rejects the alternate icons (ITMS-90471).
            // Profiles themselves are switched from the sidebar now, so this is
            // all that is left of the retired User Profiles page.
            SettingsRowItem(id: "profilePickerOnLaunch", title: "Profile Picker on Launch",
                            kind: .toggle(
                                get: { PlexUserProfileManager.shared.showProfilePickerOnLaunch },
                                set: { PlexUserProfileManager.shared.showProfilePickerOnLaunch = $0 })),
            SettingsRowItem(id: "topShelfStyle", title: "Top Shelf",
                            kind: .cycle(value: { TopShelfCache.shared.fullScreen ? String(localized: "Full Screen") : String(localized: "Posters") },
                                         next: { TopShelfCache.shared.fullScreen.toggle() })),
            toggle("skipPreview", "Skip Preview", key: "skipPreviewCarousel", default: false),

            // Titles drop whatever their caption already says ("Home Hero" under
            // HOME reads as "Home Home Hero"), the way Apple TV Settings puts a
            // bare "Siri" row under SIRI.
            .header("Home"),
            SettingsRowItem(id: "homeRows", title: "Rows", kind: .navigation(.homeRows)),
            SettingsRowItem(id: "homeHero", title: "Hero",
                            kind: .navigationValue(.homeHeroPicker, value: { homeHeroTitle })),
            toggle("personalizedRecs", "Personalized Recommendations", key: "enablePersonalizedRecommendations", default: false)
        ]
        rows += [
            .header("Library"),
            toggle("libraryHero", "Hero", key: "showLibraryHero", default: true),
            toggle("discoveryRows", "Discovery Rows", key: "showLibraryRecommendations", default: true),
            toggle("recentRows", "Recent Rows", key: "showLibraryRecentRows", default: true),

            .header("Details"),
            SettingsRowItem(id: "detailRating", title: "Rating",
                            kind: .navigationValue(.detailRatingPicker, value: { MediaRating.detailSource.name })),

            .header("Live TV"),
        ] + liveTVLookRows + [
            .header("Extras"),
            toggle("easterEggs", "Easter Eggs", key: EasterEggs.key, default: true)
        ]
        return rows
    }

    /// How Live TV looks and where it sits, on both Appearance and the Live TV
    /// page: someone after the guide or What's On looks under Live TV. Same
    /// keys in both places, and each page reads them when it opens.
    private static var liveTVLookRows: [SettingsRowItem] {
        [
            SettingsRowItem(id: "defaultLayout", title: "Default Layout",
                            kind: .cycle(value: { (LiveTVLayout(rawValue: SettingsStore.string("liveTVLayout", default: LiveTVLayout.fallback.rawValue)) ?? .fallback).description },
                                         next: { cycleLiveTVLayout() }))
        ]
    }

    // MARK: Playback

    private static var playback: [SettingsRowItem] {
        let subtitlesOn = { SubtitleMode.current != .off }
        // Grouped under headers whose titles the rows then drop ("Intro" under AUTO-SKIP).
        return [
            .header("Audio & Subtitles"),
            SettingsRowItem(id: "audioLanguage", title: "Audio Language",
                            kind: .navigationValue(.audioLanguagePicker, value: {
                                TrackLanguage.audioSettingName(TrackIntentStore.audioIntent.map { TrackLanguage.normalize($0.language) })
                            })),
            SettingsRowItem(id: "subtitleMode", title: "Subtitles",
                            kind: .navigationValue(.subtitleModePicker, value: { SubtitleMode.current.title })),
            SettingsRowItem(id: "subtitleLanguage", title: "Subtitle Language",
                            kind: .navigationValue(.subtitleLanguagePicker, value: {
                                TrackLanguage.displayName(TrackLanguage.normalize(TrackIntentStore.subtitleLanguage))
                            }), isEnabled: subtitlesOn),
            SettingsRowItem(id: "subtitleSDH", title: "SDH Subtitles",
                            kind: .toggle(get: { TrackIntentStore.subtitleSDH },
                                          set: { TrackIntentStore.setSubtitles(sdh: $0) }),
                            isEnabled: subtitlesOn),
            // Turning it on fetches the speech model that writes them; the value shows its download.
            SettingsRowItem(id: "generatedSubtitles", title: "Generated Subtitles (English)", kind: .selectable(
                isSelected: { false },
                value: { generatedSubtitlesValue },
                handler: { vc in
                    let key = UniversalPlayerViewModel.generatedSubtitlesFallbackKey
                    let on = !SettingsStore.bool(key, default: false)
                    SettingsStore.setBool(key, on)
                    if on { SpeechModelStore.shared.prepare() }
                    (vc as? SettingsPageViewController)?.reloadRows()
                })),
            .header("Resume"),
            toggle("instantResume", "Instant Resume", key: "continueWatchingInstantResume", default: true),
            // The prompt only has anything to interrupt while a Continue
            // Watching tile plays on Select, so it dims with Instant Resume off.
            toggle("promptResumeOrRestart", "Resume or Restart Prompt", key: "promptResumeOrRestart", default: false,
                   enabledWhen: { SettingsStore.bool("continueWatchingInstantResume", default: true) }),
            .header("Streaming Quality"),
            SettingsRowItem(id: "homeStreamingQuality", verbatim: String(localized: "streaming.home", defaultValue: "Home"),
                            kind: .navigationValue(.homeQualityPicker, value: {
                                StreamingQuality.setting(home: true).label
                            })),
            SettingsRowItem(id: "awayStreamingQuality", title: "Away",
                            kind: .navigationValue(.awayQualityPicker, value: {
                                StreamingQuality.setting(home: false).label
                            })),
            .header("Remote"),
            SettingsRowItem(id: "skipLength", title: "Skip Forward",
                            kind: .navigationValue(.skipIntervalPicker, value: {
                                SkipInterval(rawValue: SettingsStore.int(SkipInterval.storageKey, default: SkipInterval.defaultValue.rawValue))?.description ?? ""
                            })),
            SettingsRowItem(id: "skipBackLength", title: "Skip Back",
                            kind: .navigationValue(.skipBackIntervalPicker, value: {
                                SkipInterval(rawValue: Int(InputConfig.tapSeekBackSeconds))?.description ?? ""
                            })),
            .header("Skip Buttons"),
            skipModeRow("autoSkipIntro", "Intro", marker: "intro"),
            skipModeRow("autoSkipAds", "Ads", marker: "commercial"),
            skipModeRow("autoSkipRecap", "Recap", marker: "recap"),
            toggle("useIntroDB", "Community Marker Database", key: "useIntroDB", default: false),
            .header("Autoplay"),
            SettingsRowItem(id: "autoplayCountdown", title: "Countdown",
                            kind: .navigationValue(.autoplayCountdownPicker, value: {
                                AutoplayCountdown(rawValue: SettingsStore.int("autoplayCountdown", default: AutoplayCountdown.fiveSeconds.rawValue))?.description ?? ""
                            })),
            SettingsRowItem(id: "autoplayLimit", title: "Limit",
                            kind: .navigationValue(.autoplayLimitPicker, value: { AutoplayLimit.current.description })),
            SettingsRowItem(id: "atTheCredits", title: "Credits", kind: .cycle(
                value: { CreditsBehavior.current().label },
                next: {
                    let all = CreditsBehavior.allCases
                    let i = all.firstIndex(of: CreditsBehavior.current()) ?? 0
                    CreditsBehavior.set(all[(i + 1) % all.count])
                })),
            SettingsRowItem(id: "cinemaTrailers", title: "Trailers Before Movies",
                            kind: .cycle(value: { CinemaExtras.count == 0 ? String(localized: "Off") : "\(CinemaExtras.count)" },
                                         next: {
                                             SettingsStore.setInt(CinemaExtras.countKey,
                                                                  CinemaExtras.count == CinemaExtras.countOptions.upperBound
                                                                      ? 0 : CinemaExtras.count + 1)
                                         })),
            .header("Home Theater"),
            toggle("upscaleLowResolution", "Upscale SD and 720p", key: AetherPlayer.upscaleKey, default: false),
            .header("Filtering"),
            SettingsRowItem(id: "cat_contentFilter", title: "Content Filtering",
                            kind: .navigationValue(.contentFilter, value: {
                                SettingsStore.bool(ContentFilterManager.Keys.enabled, default: false) ? String(localized: "On") : String(localized: "Off")
                            })),
        ]
    }

    private static var generatedSubtitlesValue: String {
        guard SettingsStore.bool(UniversalPlayerViewModel.generatedSubtitlesFallbackKey, default: false) else { return String(localized: "Off") }
        return SpeechModelStore.shared.statusText
    }

    // MARK: Content Filtering

    /// VidAngel/ClearPlay-style local filter. Language categories are found in
    /// the title's subtitles; scene categories need an imported filter list
    /// (see the source URL row).
    private static var contentFilter: [SettingsRowItem] {
        var rows: [SettingsRowItem] = [
            // Turning the filter on fetches the speech model that times each muted word.
            SettingsRowItem(id: "cf_master", title: "Content Filter", kind: .toggle(
                get: { SettingsStore.bool(ContentFilterManager.Keys.enabled, default: false) },
                set: { SettingsStore.setBool(ContentFilterManager.Keys.enabled, $0) },
                didChange: { on, _ in if on { SpeechModelStore.shared.prepare() } }),
                isBusy: {
                    guard case .downloading = SpeechModelStore.shared.state else { return false }
                    return SettingsStore.bool(ContentFilterManager.Keys.enabled, default: false)
                })
        ]

        // Language categories (auto-detected from subtitles)
        rows.append(.header("Audio"))
        rows.append(SettingsRowItem(id: "cf_profanity", title: "Profanity",
                                    kind: .navigationValue(.contentFilterStrength, value: {
                                        profanityOn ? strengthLabel(currentProfanityStrength()) : String(localized: "Off")
                                    })))
        rows.append(categoryToggle(.blasphemy, id: "cf_blasphemy"))
        rows.append(categoryToggle(.slur, id: "cf_slur"))
        rows.append(categoryToggle(.sexualLanguage, id: "cf_sexualLanguage"))
        rows.append(SettingsRowItem(id: "cf_customWords", title: "Custom Words",
                                    kind: .navigationValue(.contentFilterWords, value: {
                                        let count = ContentFilterManager.customWords.count
                                        return count == 0 ? String(localized: "None") : "\(count)"
                                    })))

        // Scene categories (require an imported filter list)
        rows.append(.header("Visual"))
        rows.append(categoryToggle(.violence, id: "cf_violence"))
        rows.append(categoryToggle(.sexNudity, id: "cf_sexNudity"))
        rows.append(categoryToggle(.frightening, id: "cf_frightening"))
        rows.append(categoryToggle(.substances, id: "cf_substances"))

        // Imported list source
        rows.append(SettingsRowItem(id: "cf_sourceURL", title: "Filter List URL",
                                    kind: .textEntry(
                                        value: { SettingsStore.string(ContentFilterManager.Keys.listSourceURL, default: "") },
                                        placeholder: String(localized: "Optional"),
                                        hint: String(localized: "A folder or URL with per-title MCF or EDL files. A folder is searched by video file name, IMDb id, then Plex rating key. A URL can use {file}, {imdb}, {tmdb}, {tvdb} or {id}."),
                                        suggestions: [],
                                        keyboardType: .URL,
                                        set: { SettingsStore.setString(ContentFilterManager.Keys.listSourceURL, $0) })))
        // Everything below the master toggle dims until the filter is on.
        for i in rows.indices.dropFirst() {
            rows[i].isEnabled = { SettingsStore.bool(ContentFilterManager.Keys.enabled, default: false) }
        }
        return rows
    }

    /// The user's own words (#404): an Add row, then one row per word; selecting a word removes it.
    private static var contentFilterWords: [SettingsRowItem] {
        var rows = [SettingsRowItem(id: "cfw_add", title: "Add Word", kind: .textEntry(
            value: { "" },
            placeholder: String(localized: "Word or Phrase"),
            hint: nil,
            suggestions: [],
            keyboardType: .default,
            set: { ContentFilterManager.addCustomWord($0) }))]
        rows += ContentFilterManager.customWords.map { word in
            SettingsRowItem(id: "cfw_\(word)", verbatim: word, kind: .action(destructive: false, handler: { vc in
                presentConfirm(on: vc, title: "Remove \"\(word)\"?",
                               message: "The filter will stop muting this word.",
                               confirmTitle: "Remove", destructive: true) {
                    ContentFilterManager.customWords.removeAll { $0 == word }
                    (vc as? SettingsPageViewController)?.reloadRows()
                }
            }))
        }
        return rows
    }

    /// Off, then the strengths: picking one turns the profanity category on.
    private static var contentFilterStrength: [SettingsRowItem] {
        let key = FilterCategory.profanity.enabledDefaultsKey
        let off = SettingsRowItem(id: "cfs_off", title: "Off", kind: .option(
            isSelected: { !profanityOn },
            select: { SettingsStore.setBool(key, false) }))
        return [off] + FilterSeverity.allCases.map { severity in
            SettingsRowItem(id: "cfs_\(severity.rawValue)", verbatim: strengthLabel(severity),
                            kind: .option(
                                isSelected: { profanityOn && currentProfanityStrength() == severity },
                                select: {
                                    SettingsStore.setBool(key, true)
                                    SettingsStore.setInt(ContentFilterManager.Keys.profanityStrength, severity.rawValue)
                                }))
        }
    }

    private static var profanityOn: Bool {
        SettingsStore.bool(FilterCategory.profanity.enabledDefaultsKey, default: FilterCategory.profanity.defaultEnabled)
    }

    private static func currentProfanityStrength() -> FilterSeverity {
        FilterSeverity(rawValue: SettingsStore.int(ContentFilterManager.Keys.profanityStrength,
                                                    default: FilterSeverity.moderate.rawValue)) ?? .moderate
    }

    /// The stored value is the *minimum* severity that gets muted.
    private static func strengthLabel(_ severity: FilterSeverity) -> String {
        switch severity {
        case .mild: return String(localized: "Mild and up")
        case .moderate: return String(localized: "Moderate and up")
        case .strong: return String(localized: "Strong only")
        }
    }

    private static func categoryToggle(_ category: FilterCategory, id: String) -> SettingsRowItem {
        SettingsRowItem(id: id, verbatim: category.displayName, kind: .toggle(
            get: { SettingsStore.bool(category.enabledDefaultsKey, default: category.defaultEnabled) },
            set: { SettingsStore.setBool(category.enabledDefaultsKey, $0) }))
    }

    // MARK: Live TV

    /// Sidebar placement and Default Layout moved to the
    /// Appearance page's "Live TV" group; this page keeps sources and playback.
    private static var liveTV: [SettingsRowItem] {
        [
            SettingsRowItem(id: "liveTVSources", title: "Live TV Sources", kind: .navigation(.iptv)),
            SettingsRowItem(id: "liveTVFavorites", title: "Favorites", kind: .navigation(.liveTVFavorites)),
        ] + liveTVLookRows + [
            toggle("combineSources", "Combine Sources", key: "combineLiveTVSources", default: true),
            toggle("keepPlayingInGuide", "Keep Playing in Guide", key: "liveTVKeepPlayingInGuide", default: true),
            SettingsRowItem(id: "liveTVSuggestions", title: "Suggestions", kind: .toggle(
                get: { SettingsStore.bool(LiveTVDataStore.suggestionsKey, default: true) },
                set: { SettingsStore.setBool(LiveTVDataStore.suggestionsKey, $0) },
                didChange: { isOn, vc in
                    guard !isOn else { return }
                    vc.present(ConfirmationPopupViewController(
                        title: String(localized: "Erase What For You Learned?"),
                        message: String(localized: "Suggestions are off. Erase what Rivulet learned from what you watch, or keep it for if you turn them back on."),
                        confirmTitle: String(localized: "Erase"), cancelTitle: String(localized: "Keep"), destructive: true,
                        onConfirm: { LiveTVDataStore.shared.forgetViewings() }), animated: true)
                })),
            toggle("confirmExitMultiview", "Confirm Exit Multiview", key: "confirmExitMultiview", default: true)
        ]
    }

    /// Rivulet's favourite channels in order: hold Select to move one, Select
    /// asks before removing it (the Pinned Collections pattern). A removed row
    /// goes at once, so a move never passes a channel that is no longer a
    /// favourite.
    private static var liveTVFavorites: [SettingsRowItem] {
        let store = LiveTVDataStore.shared
        let byId = Dictionary(store.channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let favorites = store.favoriteIds.compactMap { byId[$0] }
        guard !favorites.isEmpty else {
            return [SettingsRowItem(id: "noLiveTVFavorites", title: "No Favorites Yet", kind: .info(value: { "" }))]
        }
        // The same channel can come from two sources, so name the source
        // when there is more than one.
        let sourceNames = Set(favorites.map(\.sourceId)).count > 1
            ? Dictionary(store.sources.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
            : [:]
        return favorites.map { channel in
            let title = [channel.channelNumber.map(String.init), channel.name, sourceNames[channel.sourceId].map { "· \($0)" }]
                .compactMap { $0 }
                .joined(separator: " ")
            return SettingsRowItem(id: "fav_\(channel.id)", verbatim: title,
                                   kind: .action(destructive: false, handler: { vc in
                presentConfirm(on: vc, title: "Remove \"\(channel.name)\"?",
                               message: "This removes the channel from your favorites. You can add it again by holding Select on it in What's On or the guide.",
                               confirmTitle: "Remove", destructive: true) {
                    if store.isFavorite(channel) { store.toggleFavorite(channel) }
                    (vc as? SettingsPageViewController)?.reloadRows()
                }
            }), onReorder: { up in store.moveFavorite(channel.id, up: up) })
        }
    }

    private static func cycleLiveTVLayout() {
        let all = LiveTVLayout.allCases
        let cur = LiveTVLayout(rawValue: SettingsStore.string("liveTVLayout", default: LiveTVLayout.fallback.rawValue)) ?? .fallback
        let i = all.firstIndex(of: cur) ?? 0
        SettingsStore.setString("liveTVLayout", all[(i + 1) % all.count].rawValue)
    }

    // MARK: Music

    /// Withdrawn: loudness, crossfade and quality-badge keys had no reader.
    /// Add a row back only with its reader. `MusicAudioProcessor` reads
    /// crossfade under a different key and type than the old row wrote.
    private static var music: [SettingsRowItem] {
        []
    }

    // MARK: Servers

    private static var servers: [SettingsRowItem] {
        [
            SettingsRowItem(id: "plexServer", title: "Plex", kind: .navigation(.plex)),
            SettingsRowItem(
                id: "jellyfinServer", title: "Jellyfin Server",
                kind: .navigationAction(.jellyfin,
                                        value: { JellyfinSession.account?.serverName ?? "" },
                                        prepare: { addSourceDraft = AddSourceDraft() })),
            SettingsRowItem(
                id: "embyServer", title: "Emby Server",
                kind: .navigationAction(.emby,
                                        value: { EmbySession.account?.serverName ?? "" },
                                        prepare: { addSourceDraft = AddSourceDraft() }))
        ]
    }

    // MARK: Plex (sign-in / sign-out)

    private static var plex: [SettingsRowItem] {
        let auth = PlexAuthManager.shared
        guard auth.isAuthenticated else {
            return [
                SettingsRowItem(id: "connectPlex", title: "Connect to Plex",
                                kind: .action(destructive: false, handler: { presenter in
                    presenter.present(PlexSignInViewController { [weak presenter] in
                        // Connect becomes the server list, which loads on its own.
                        guard let page = presenter as? SettingsPageViewController else { return }
                        page.reloadRows()
                        loadPlexServers { [weak page] in page?.reloadRows() }
                    }, animated: true)
                }))
            ]
        }
        return plexServerRows + [
            SettingsRowItem(id: "signOut", title: "Sign Out",
                            kind: .action(destructive: true, handler: { vc in
                let page = vc as? SettingsPageViewController
                if CloudSync.shared.isSynced(accountID: PlexAuthManager.syncID) {
                    presentSignOutChoice(
                        on: vc, title: String(localized: "Sign Out of Plex?"),
                        message: String(localized: "Your Plex sign-in is shared through iCloud. Sign out of this device only, or of every device?"),
                        thisDevice: { PlexAuthManager.shared.signOut(scope: .thisDevice); page?.reloadRows() },
                        everywhere: { PlexAuthManager.shared.signOut(scope: .everywhere); page?.reloadRows() })
                    return
                }
                // Ask first. An accidental Select must not sign out.
                presentConfirm(on: vc, title: "Sign Out of Plex?",
                               message: "This signs out of every Plex server on your account.",
                               confirmTitle: "Sign Out", destructive: true) {
                    PlexAuthManager.shared.signOut()
                    // Sign Out is in place, so nothing else rebuilds the page.
                    (vc as? SettingsPageViewController)?.reloadRows()
                }
            }))
        ]
    }

    // MARK: Plex servers

    /// The servers on the account. The page loads them each time it opens.
    /// The value is nil until they arrive.
    private static var plexServers: [PlexDevice]?
    private static var plexServersFailed = false
    /// The server whose page is open, stashed by its row's `prepare`.
    private static var pendingPlexServer: PlexDevice?

    private static var plexServerRows: [SettingsRowItem] {
        // This row can get focus. The container sets focus only on push.
        // If no row can get focus, focus is lost when the servers arrive.
        guard let servers = plexServers, !servers.isEmpty else {
            if plexServersFailed || plexServers != nil {
                return [SettingsRowItem(id: "plexServersRetry",
                                        title: plexServersFailed ? "Couldn’t Load Servers" : "No Servers Found",
                                        kind: .action(destructive: false, handler: { vc in
                    loadPlexServers { [weak vc] in (vc as? SettingsPageViewController)?.reloadRows() }
                }))]
            }
            return [SettingsRowItem(id: "plexServersLoading", title: "Loading Servers…",
                                    kind: .action(destructive: false, handler: { _ in }))]
        }
        return servers.map { server in
            SettingsRowItem(id: "plexServer_\(server.clientIdentifier)", verbatim: server.name,
                            kind: .navigationAction(.plexServerDetail,
                                                    value: { isPlexServerEnabled(server) ? (server.owned == false ? server.sourceTitle ?? "" : "") : String(localized: "Off") },
                                                    prepare: { pendingPlexServer = server }))
        }
    }

    private static var plexServerDetail: [SettingsRowItem] {
        guard let server = pendingPlexServer else { return [] }
        let auth = PlexAuthManager.shared
        let url = auth.isCurrentServer(server) ? auth.selectedServerURL
            : PlexExtraServers.shared.current.first { $0.machineID == server.machineIdentifier }?.url
        let connection = url.flatMap { url in server.connections?.first { url.contains($0.address) || url == $0.uri } }
        let liveTV = url.flatMap { url in LiveTVDataStore.shared.sources.first { $0.id == "plex:\(url)" } }
        var rows: [SettingsRowItem] = [
            SettingsRowItem(id: "plexServerEnabled", title: "Use This Server", kind: .selectable(
                isSelected: { false },
                value: { isPlexServerEnabled(server) ? String(localized: "On") : String(localized: "Off") },
                handler: { vc in togglePlexServer(server, on: vc) }),
                isBusy: { busyPlexServerID == server.clientIdentifier }),
            info("plexServerStatus", "Status", server.presence == false ? String(localized: "Offline") : String(localized: "Online")),
            info("plexServerOwner", "Owner", server.owned == false ? (server.sourceTitle ?? String(localized: "Shared")) : String(localized: "You")),
            info("plexServerVersion", "Version", server.productVersion)
        ]
        if let platform = server.platform {
            rows.append(info("plexServerPlatform", "Platform", [platform, server.platformVersion].compactMap { $0 }.joined(separator: " ")))
        }
        if let connection {
            let kind = connection.relay ? String(localized: "Relay") : connection.local ? String(localized: "Local") : String(localized: "connection.remote", defaultValue: "Remote")
            rows.append(info("plexServerConnection", "Connection", connection.protocolType == "https" ? String(localized: "\(kind), Secure") : kind))
        }
        let ds = LiveTVDataStore.shared
        if let id = server.machineIdentifier, ds.plexMachineIDs.values.contains(id) {
            rows.insert(plexLiveTVToggle(id: "plexServerLiveTV", machineID: id), at: 1)
            if let liveTV { rows.append(info("plexServerChannels", "Channels", "\(liveTV.channelCount)")) }
        } else {
            rows.append(info("plexServerLiveTV", "Live TV", String(localized: "No DVR")))
        }
        if let created = ISO8601DateFormatter().date(from: server.createdAt) {
            rows.append(info("plexServerCreated", "On Plex Since", created.formatted(date: .abbreviated, time: .omitted)))
        }
        // The page needs one focusable row, or focus has nowhere to land.
        rows.append(SettingsRowItem(id: "plexServerRefresh", title: "Refresh", kind: .action(destructive: false, handler: { vc in
            loadPlexServers { [weak vc] in
                if let fresh = plexServers?.first(where: { $0.clientIdentifier == server.clientIdentifier }) {
                    pendingPlexServer = fresh
                }
                (vc as? SettingsPageViewController)?.reloadRows()
            }
        })))
        return rows
    }

    /// Shows or hides a Plex server's DVR in Live TV (#406), from either settings page.
    private static func plexLiveTVToggle(id: String, machineID: String) -> SettingsRowItem {
        SettingsRowItem(id: id, title: "Show in Live TV", kind: .toggle(
            get: { !LiveTVDataStore.shared.isPlexLiveTVHidden(machineID: machineID) },
            set: { LiveTVDataStore.shared.setPlexLiveTVHidden(!$0, machineID: machineID) },
            didChange: { _, vc in
                Task {
                    await LiveTVDataStore.shared.plexSourcesSynced()
                    (vc as? SettingsPageViewController)?.reloadRows()
                }
            }))
    }

    /// The Jellyfin server's counterpart of `plexLiveTVToggle`.
    static func jellyfinLiveTVToggle(id: String) -> SettingsRowItem {
        serverLiveTVToggle(id: id, hiddenKey: JellyfinLiveTVProvider.hiddenKey, setHidden: JellyfinLiveTVProvider.setHidden)
    }

    /// The Emby server's counterpart.
    static func embyLiveTVToggle(id: String) -> SettingsRowItem {
        serverLiveTVToggle(id: id, hiddenKey: EmbyLiveTVProvider.hiddenKey, setHidden: EmbyLiveTVProvider.setHidden)
    }

    private static func serverLiveTVToggle(
        id: String, hiddenKey: String, setHidden: @escaping @MainActor (Bool) -> Task<Void, Never>?
    ) -> SettingsRowItem {
        var sync: Task<Void, Never>?
        return SettingsRowItem(id: id, title: "Show in Live TV", kind: .toggle(
            get: { !UserDefaults.standard.bool(forKey: hiddenKey) },
            set: { sync = setHidden(!$0) },
            didChange: { _, vc in
                Task {
                    await sync?.value
                    (vc as? SettingsPageViewController)?.reloadRows()
                }
            }))
    }

    /// The server whose Use This Server change is still loading.
    private static var busyPlexServerID: String?

    private static func isPlexServerEnabled(_ server: PlexDevice) -> Bool {
        server.machineIdentifier.map { PlexExtraServers.shared.isEnabled(machineID: $0) } ?? true
    }

    /// Turning off the selected server first moves the selected role to another
    /// server that is on; the last server in use can only be signed out. The row
    /// spins until the servers' content has reloaded.
    private static func togglePlexServer(_ server: PlexDevice, on vc: UIViewController) {
        guard busyPlexServerID == nil, let id = server.machineIdentifier else { return }
        let turningOff = isPlexServerEnabled(server)
        let others = (plexServers ?? []).filter { $0.clientIdentifier != server.clientIdentifier && isPlexServerEnabled($0) }
        let isSelected = PlexAuthManager.shared.isCurrentServer(server)
        if turningOff, isSelected, others.isEmpty {
            vc.present(ConfirmationPopupViewController(
                title: String(localized: "Only Server in Use"),
                message: String(localized: "Turn on another server first, or sign out of Plex."),
                confirmTitle: String(localized: "OK"), cancelTitle: nil, onConfirm: {}), animated: true)
            return
        }
        busyPlexServerID = server.clientIdentifier
        (vc as? SettingsPageViewController)?.reloadRows()
        Task { @MainActor [weak vc] in
            // Let the spinner draw before the reload's main-thread work.
            try? await Task.sleep(for: .milliseconds(50))
            var changed = true
            if turningOff, isSelected {
                changed = false
                for other in others where await PlexDataStore.shared.switchServer(to: other) {
                    changed = true
                    break
                }
            }
            if changed {
                PlexExtraServers.shared.setEnabled(!turningOff, machineID: id)
                for await loading in ServerDataStore.shared.$isLoading.values where !loading { break }
            }
            busyPlexServerID = nil
            guard let page = vc as? SettingsPageViewController else { return }
            page.reloadRows()
            if !changed {
                page.present(ConfirmationPopupViewController(
                    title: String(localized: "Couldn’t Turn Off"),
                    message: String(localized: "No other server is reachable right now, so \(server.name) stays on."),
                    confirmTitle: String(localized: "OK"), cancelTitle: nil, onConfirm: {}), animated: true)
            }
        }
    }

    private static func info(_ id: String, _ title: String.LocalizationValue, _ value: String) -> SettingsRowItem {
        SettingsRowItem(id: id, title: title, kind: .info(value: { value }))
    }

    private static func loadPlexServers(reload: @escaping () -> Void) {
        plexServers = nil
        plexServersFailed = false
        reload()
        Task { @MainActor in
            if let token = PlexAuthManager.shared.authToken,
               let servers = try? await PlexNetworkManager.shared.getServers(authToken: token) {
                plexServers = servers
            } else {
                plexServersFailed = true
            }
            reload()
        }
    }

    // MARK: Home Rows (local subtractive filter over the server's row set)

    /// Every row Home can draw, hidden ones included, in Home's order: one per
    /// `HomeRowOrder` key, so every server's Continue Watching is one row and a
    /// kind's favorites rows are one. Pinned collections have their own group.
    static func orderedHomeRows() -> [(row: CachedHomeHub, kind: MediaProviderKind)] {
        let rail = PlexHomeViewController.homeRail(
            plex: plexHomeRows.filter { !($0.hubIdentifier ?? "").hasPrefix("rivulet.pin.") },
            otherServers: ServerDataStore.shared.homeRowsInSidebarOrder,
            personal: PersonalHomeRows.shared.homeRows,
            libraryOrder: PlexHomeViewController.sidebarLibraryOrder(),
            kindOf: { MediaProviderRegistry.shared.kind(of: $0) })
        var seen = Set<String>()
        return HomeRowOrder.arrange(rail, key: { HomeRowOrder.key(for: $0.row) })
            .filter { seen.insert(HomeRowOrder.key(for: $0.row)).inserted }
    }

    /// The selected Plex server's rows, hidden ones included (only the visible
    /// ones before the first projection after a warm launch).
    private static var plexHomeRows: CachedHomeRail {
        let store = PlexDataStore.shared
        return store.allHomeItems.isEmpty ? store.homeItems : store.allHomeItems
    }

    /// The Home Rows list: every row that is on, in Home's order (hold Select
    /// to move one), then, under "Hidden from Home", every row that is off. A toggle
    /// moves its row across at once.
    private static var homeRows: [SettingsRowItem] {
        let ordered = orderedHomeRows()
        let pinRows = pinnedCollectionRows(store: PlexDataStore.shared)
        guard !ordered.isEmpty || PlexAuthManager.shared.hasCredentials || ServerDataStore.shared.isSignedIn else {
            // A pin can outlive every Plex row (its library taken off Home),
            // and this page is the only place left to unpin it.
            guard pinRows.isEmpty else { return pinRows }
            return [SettingsRowItem(id: "noHomeRows",
                                    title: "Connect a server to manage Home rows",
                                    kind: .info(value: { "" }))]
        }

        let move = { (key: String) -> (Bool) -> Void in
            { up in HomeRowOrder.move(key, up: up, among: shownHomeRowKeys()) }
        }
        let labelsServers = ServerDataStore.shared.labelsServers

        var on: [SettingsRowItem] = []
        var off: [SettingsRowItem] = []
        var listedFavorites: Set<MediaLibrary.LibraryKind> = []
        var listedPlaylists: Set<String> = []
        func add(_ item: SettingsRowItem, isOn: Bool) {
            if isOn { on.append(item) } else { off.append(item) }
        }
        for (row, kind) in ordered {
            let key = HomeRowOrder.key(for: row)
            let isOn = isHomeRowOn(row)
            if row.isContinueWatching {
                let ids = continueWatchingIDs
                add(SettingsRowItem(
                    id: "homeRow_\(key)", title: "Continue Watching", kind: .toggle(
                        get: { ids.contains { !HomeRowSettings.isHidden($0) } },
                        set: { shown in
                            if shown { HomeRowOrder.placeLast(key, among: shownHomeRowKeys()) }
                            ids.forEach { HomeRowSettings.setHidden(!shown, for: $0) }
                        },
                        didChange: reloadPage),
                    onReorder: isOn ? move(key) : nil, reorderGroup: isOn ? "homeRows" : nil), isOn: isOn)
            } else if let favoriteKind = PersonalRows.favoriteKinds.first(where: {
                PersonalRows.favoritesIdentifier($0) == key
            }) {
                listedFavorites.insert(favoriteKind)
                add(favoritesRow(favoriteKind, onReorder: isOn ? move(key) : nil), isOn: isOn)
            } else if row.id.hasPrefix(PersonalRows.playlistRowPrefix) {
                // A playlist just switched off can outlive its pin for a moment:
                // it is listed with the others under "Hidden from Home".
                guard let pin = HomePlaylistPins.pins.first(where: {
                    PersonalRows.playlistRowID(providerID: $0.providerID, playlistID: $0.playlistID) == row.id
                }) else { continue }
                listedPlaylists.insert(pin.id)
                on.append(playlistToggle(providerID: pin.providerID, playlistID: pin.playlistID,
                                         title: row.title, label: serverLabeled(row.title, providerID: pin.providerID),
                                         onReorder: move(key)))
            } else if let id = row.hubIdentifier {
                let server = PlexHomeViewController.serverName(providerID: row.items.first?.ref.providerID, kind: kind)
                add(SettingsRowItem(
                    id: "homeRow_\(id)", verbatim: labelsServers ? "\(row.title) (\(server))" : row.title,
                    kind: .toggle(
                        get: { !HomeRowSettings.isHidden(id) },
                        set: { shown in
                            if shown { HomeRowOrder.placeLast(key, among: shownHomeRowKeys()) }
                            HomeRowSettings.setHidden(!shown, for: id)
                        },
                        didChange: reloadPage),
                    onReorder: isOn ? move(key) : nil, reorderGroup: isOn ? "homeRows" : nil), isOn: isOn)
            }
        }
        // A favorites kind or playlist that is on but has no row yet (still
        // loading, or nothing in it) sits at the end of the on rows, unmovable.
        // Favorites are offered only where a server has them.
        for kind in PersonalRows.favoriteKinds
        where PersonalHomeRows.offersFavorites && !listedFavorites.contains(kind) {
            add(favoritesRow(kind, onReorder: nil), isOn: PersonalRows.showsFavorites(kind))
        }
        for entry in homePlaylists() where !listedPlaylists.contains("\(entry.providerID)/\(entry.playlistID)") {
            add(playlistToggle(providerID: entry.providerID, playlistID: entry.playlistID,
                               title: entry.title, label: serverLabeled(entry.title, providerID: entry.providerID), onReorder: nil),
                isOn: HomePlaylistPins.isPinned(MediaItemRef(providerID: entry.providerID, itemID: entry.playlistID)))
        }

        let reset = SettingsRowItem(id: "resetHomeRows", title: "Reset",
                                    kind: .action(destructive: true, handler: { vc in
            presentConfirm(on: vc, title: "Reset Home Rows?",
                           message: "Every row from your servers comes back in the original order. Favorites and playlists are turned off.",
                           confirmTitle: "Reset", destructive: true) {
                HomeRowSettings.showAll()
                HomeRowOrder.reset()
                PersonalRows.favoriteKinds.forEach { PersonalRows.setShowsFavorites(false, $0) }
                HomePlaylistPins.removeAll()
                (vc as? SettingsPageViewController)?.reloadRows()
            }
        }))
        return [reset] + on + (off.isEmpty ? [] : [.header("Hidden from Home")] + off) + pinRows
    }

    /// The page's rows as `HomeRowOrder` keys: those that are on, as listed,
    /// then the hidden ones. A move swaps with a neighbour that is on, never a
    /// hidden row between them.
    private static func shownHomeRowKeys() -> [String] {
        let keys = orderedHomeRows().map(\.row).map { (key: HomeRowOrder.key(for: $0), isOn: isHomeRowOn($0)) }
        return keys.filter(\.isOn).map(\.key) + keys.filter { !$0.isOn }.map(\.key)
    }

    /// Every server's Continue Watching is one row here, as on Home: its toggle covers them all.
    private static var continueWatchingIDs: [String] {
        Array(Set((plexHomeRows + ServerDataStore.shared.homeRowsInSidebarOrder)
            .filter(\.isContinueWatching).compactMap(\.hubIdentifier)))
    }

    /// Whether a row of `orderedHomeRows` is on, which puts it above "Hidden from Home".
    private static func isHomeRowOn(_ row: CachedHomeHub) -> Bool {
        if row.isContinueWatching { return continueWatchingIDs.contains { !HomeRowSettings.isHidden($0) } }
        if let kind = PersonalRows.favoriteKinds.first(where: { PersonalRows.favoritesIdentifier($0) == row.hubIdentifier }) {
            return PersonalRows.showsFavorites(kind)
        }
        if row.id.hasPrefix(PersonalRows.playlistRowPrefix) {
            return HomePlaylistPins.pins.contains {
                PersonalRows.playlistRowID(providerID: $0.providerID, playlistID: $0.playlistID) == row.id
            }
        }
        return row.hubIdentifier.map { !HomeRowSettings.isHidden($0) } ?? false
    }

    /// Moves a toggled row across the "Hidden from Home" line.
    private static let reloadPage: (Bool, UIViewController) -> Void = { _, vc in
        (vc as? SettingsPageViewController)?.reloadRows()
    }

    private static func favoritesRow(_ kind: MediaLibrary.LibraryKind, onReorder: ((Bool) -> Void)?) -> SettingsRowItem {
        SettingsRowItem(id: kind == .shows ? "homeFavoriteShows" : "homeFavoriteMovies",
                        title: kind == .shows ? "Favorite TV Shows" : "Favorite Movies", kind: .toggle(
            get: { PersonalRows.showsFavorites(kind) },
            set: { shown in
                if shown { HomeRowOrder.placeLast(PersonalRows.favoritesIdentifier(kind), among: shownHomeRowKeys()) }
                PersonalRows.setShowsFavorites(shown, kind)
            },
            didChange: reloadPage),
            onReorder: onReorder, reorderGroup: onReorder == nil ? nil : "homeRows")
    }

    /// `title` is the playlist's own, stored with the pin; `label` may add its server.
    private static func playlistToggle(providerID: String, playlistID: String, title: String, label: String,
                                       onReorder: ((Bool) -> Void)?) -> SettingsRowItem {
        let ref = MediaItemRef(providerID: providerID, itemID: playlistID)
        return SettingsRowItem(id: "homePlaylist_\(providerID)/\(playlistID)", verbatim: label, kind: .toggle(
            get: { HomePlaylistPins.isPinned(ref) },
            set: { shown in
                if shown {
                    HomeRowOrder.placeLast(PersonalRows.playlistRowID(providerID: providerID, playlistID: playlistID),
                                           among: shownHomeRowKeys())
                    HomePlaylistPins.pin(.init(providerID: providerID, playlistID: playlistID, title: title))
                } else {
                    HomePlaylistPins.unpin(ref)
                }
            },
            didChange: reloadPage),
            onReorder: onReorder, reorderGroup: onReorder == nil ? nil : "homeRows")
    }

    /// Every server's video playlists, plus any pin whose playlist is no longer
    /// listed, so it can still be switched off.
    private static func homePlaylists() -> [(providerID: String, playlistID: String, title: String)] {
        let listed = PlaylistAvailability.shared.playlistsByProvider
        let providerIDs = ([MediaProviderRegistry.shared.plexProvider?.id].compactMap { $0 }
            + ServerDataStore.shared.sources.map(\.providerID)).filter { listed[$0] != nil }
        var entries = providerIDs.flatMap { id in
            (listed[id] ?? []).map { (providerID: id, playlistID: $0.item.ref.itemID, title: $0.item.title) }
        }
        for pin in HomePlaylistPins.pins
        where !entries.contains(where: { $0.providerID == pin.providerID && $0.playlistID == pin.playlistID }) {
            entries.append((pin.providerID, pin.playlistID, pin.title))
        }
        return entries
    }

    /// The Pinned Collections group: every pin on the current server, not only
    /// the rows Home or a library page draws, so an emptied pin, or one whose
    /// library was taken off Home, can still be unpinned. Omitted when there
    /// are none. Show All never touches pins. Home Rows lists the Home pins,
    /// Libraries the library-page pins.
    private static func pinnedCollectionRows(store: PlexDataStore,
                                             in destination: HomeCollectionPins.Destination = .home) -> [SettingsRowItem] {
        let serverLibraries = Set(store.libraries.map(\.uuid))
        let pins = HomeCollectionPins.pins(in: destination).filter { serverLibraries.contains($0.libraryUUID) }
        guard !pins.isEmpty else { return [] }
        var rows: [SettingsRowItem] = [.header("Pinned Collections")]
        for pin in pins {
            // Same as the sidebar libraries: hold Select to reorder, Select
            // asks before unpinning.
            rows.append(SettingsRowItem(id: "pinnedCollection_\(destination)_\(pin.id)", verbatim: pin.title,
                                        kind: .action(destructive: false, handler: { vc in
                presentConfirm(on: vc, title: "Unpin \"\(pin.title)\"?",
                               message: destination == .home
                                ? "This removes the row from Home. You can pin it again from the collection in its library."
                                : "This removes the row from its library. You can pin it again from the collection in its library.",
                               confirmTitle: "Unpin", destructive: true) {
                    HomeCollectionPins.unpin(ratingKey: pin.ratingKey, libraryUUID: pin.libraryUUID, in: destination)
                    (vc as? SettingsPageViewController)?.reloadRows()
                }
            }), onReorder: { up in HomeCollectionPins.move(pin, up: up, in: destination) }))
        }
        return rows
    }

    // MARK: Sidebar (order and visibility)

    /// Every arrangeable sidebar row, hidden ones included, in the sidebar's order.
    private static func sidebarSettingsRows() -> [ShellSidebarModel.Row] {
        let rows = ShellSidebarModel.arrangeableRows(
            libraries: SidebarLibrary.current(includeHidden: true),
            liveTVSources: LiveTVDataStore.shared.sources,
            combineLiveTV: SettingsStore.bool("combineLiveTVSources", default: true),
            showDiscover: PlexAuthManager.shared.hasCredentials, showWatchlist: PlexAuthManager.shared.hasCredentials,
            showFavorites: PersonalHomeRows.offersFavorites,
            playlistServers: PlaylistServer.current(PlaylistAvailability.shared.providerIDs))
        let byKey = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return SidebarArrangement.arrange(rows.map(\.key), order: LibrarySettingsManager.shared.libraryOrder)
            .compactMap { byKey[$0] }
    }

    private static var libraries: [SettingsRowItem] {
        let mgr = LibrarySettingsManager.shared
        let entries = sidebarSettingsRows()
        let libraryKeys = entries.map(\.key).filter { !SidebarArrangement.isAppRow($0) }
        let playlistKeys = entries.map(\.key).filter { SidebarArrangement.server(ofKey: $0) != nil && SidebarArrangement.isAppRow($0) }
        // Reset, then Add All / Remove All (libraries only), at the top.
        var rows: [SettingsRowItem] = entries.isEmpty ? [] : [
            SettingsRowItem(id: "resetSidebar", title: "Reset", kind: .action(destructive: true, handler: { vc in
                presentConfirm(on: vc, title: "Reset the Sidebar?",
                               message: "Every row comes back in the original order. Home follows the library order.",
                               confirmTitle: "Reset", destructive: true) {
                    LibrarySettingsManager.shared.resetSidebar()
                    SettingsStore.setBool("showDiscoverTab", true)
                    SettingsStore.setBool("showWatchlistTab", true)
                    SettingsStore.setBool("showFavoritesTab", false)
                    (vc as? SettingsPageViewController)?.reloadRows()
                }
            }))
        ]
        rows += libraryKeys.isEmpty ? [] : [
            SettingsRowItem(id: "addAllLibraries", title: "Add All",
                            kind: .action(destructive: false, handler: { vc in
                LibrarySettingsManager.shared.showAllLibraries()
                (vc as? SettingsPageViewController)?.reloadRows()
            })),
            SettingsRowItem(id: "removeAllLibraries", title: "Remove All",
                            kind: .action(destructive: true, handler: { vc in
                LibrarySettingsManager.shared.hideAllLibraries(libraryKeys)
                (vc as? SettingsPageViewController)?.reloadRows()
            }))
        ]
        // With several servers each title names its server, since no header
        // could stay true once they mix.
        let namesServer = Set(entries.compactMap(\.serverName)).count > 1
        rows += entries.map { entry in
            let key = entry.key
            var title = entry.item.title
            if namesServer, let server = entry.serverName { title += " (\(server))" }
            if let badge = entry.item.badge, entry.serverName == nil { title += " (\(badge))" }
            let kind: SettingsRowItem.Kind
            switch key {
            case SidebarArrangement.discover:
                kind = .toggle(get: { SettingsStore.bool("showDiscoverTab", default: true) },
                               set: { SettingsStore.setBool("showDiscoverTab", $0) })
            case SidebarArrangement.watchlist:
                kind = .toggle(get: { SettingsStore.bool("showWatchlistTab", default: true) },
                               set: { SettingsStore.setBool("showWatchlistTab", $0) })
            case SidebarArrangement.favorites:
                kind = .toggle(get: { SettingsStore.bool("showFavoritesTab", default: false) },
                               set: { SettingsStore.setBool("showFavoritesTab", $0) })
            case _ where SidebarArrangement.isLiveTV(key):
                // Live TV leaves the sidebar only with its sources: no toggle, nothing
                // to open, but focusable so it can be held and moved.
                kind = .action(destructive: false, handler: { _ in })
            case _ where SidebarArrangement.isAppRow(key):
                kind = .toggle(get: { LibrarySettingsManager.shared.isPlaylistsRowVisible(key) },
                               set: { LibrarySettingsManager.shared.setPlaylistsRow(key, visible: $0, allKeys: playlistKeys) })
            default:
                kind = .toggle(get: { LibrarySettingsManager.shared.isLibraryVisible(key) },
                               set: { _ in LibrarySettingsManager.shared.toggleVisibility(for: key) })
            }
            // Hold Select to grab + reorder (Apple-Home style). The page VC
            // animates the slot change; this persists it, over the list as it is now.
            return SettingsRowItem(id: SidebarArrangement.isAppRow(key) ? "sb_\(key)" : "lib_\(key)", verbatim: title, kind: kind,
                                   onReorder: { up in
                                       mgr.moveSidebarRow(key: key, up: up, visible: sidebarSettingsRows().map(\.key))
                                   }, reorderGroup: "sidebar")
        }
        guard !rows.isEmpty else {
            return [SettingsRowItem(id: "noLibraries", title: "Connect a server to manage the sidebar",
                                    kind: .info(value: { "" }))]
        }
        return rows + pinnedCollectionRows(store: PlexDataStore.shared, in: .library)
    }

    // MARK: Cache & Storage

    private static var cache: [SettingsRowItem] {
        [
            SettingsRowItem(id: "forceRefresh", title: "Force Refresh Libraries",
                            kind: .action(destructive: false, handler: { vc in
                presentConfirm(on: vc, title: "Force Refresh Libraries?",
                               message: "This clears the metadata cache and reloads your libraries from all your servers.",
                               confirmTitle: "Refresh", destructive: false) {
                    Task {
                        await CacheManager.shared.clearAllCache()
                        await reloadFromServer()
                    }
                }
            })),
            SettingsRowItem(id: "clearAllCache", title: "Clear All Cache",
                            kind: .action(destructive: true, handler: { vc in
                presentConfirm(on: vc, title: "Clear All Cache?",
                               message: "Removes all cached images and metadata. Content will be re-downloaded.",
                               confirmTitle: "Clear Cache", destructive: true) {
                    Task {
                        await ImageCacheManager.shared.clearAll()
                        ContinueWatchingCardCompositor.clearDisk()
                        ArtworkTitleCheck.clearDisk()
                        await CacheManager.shared.clearAllCache()
                        await reloadFromServer()
                    }
                }
            }))
        ]
    }

    /// Refetches libraries and Home rows, then tells every surface to repaint.
    private static func reloadFromServer() async {
        await PlexDataStore.shared.refreshLibraries()
        await PlexDataStore.shared.refreshHubs()
        await PlexDataStore.shared.refreshLibraryHubs()
        NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
    }

    /// Canonical confirm/cancel prompt: the Liquid-Glass card
    /// (`ConfirmationPopupViewController`) shared with the rest of the app, not a
    /// system `UIAlertController`. Use this for every Settings confirmation.
    private static func presentConfirm(on vc: UIViewController, title: String.LocalizationValue,
                                       message: String.LocalizationValue,
                                       confirmTitle: String.LocalizationValue, destructive: Bool, action: @escaping () -> Void) {
        let popup = ConfirmationPopupViewController(
            title: String(localized: title), message: String(localized: message),
            confirmTitle: String(localized: confirmTitle),
            cancelTitle: String(localized: "Cancel"), destructive: destructive, onConfirm: action)
        vc.present(popup, animated: true)
    }

    /// The sign-out question when the item is shared through iCloud: this device only, or all of them.
    /// Menu and Cancel do nothing.
    static func presentSignOutChoice(on vc: UIViewController, title: String, message: String,
                                     thisDevice: @escaping () -> Void, everywhere: @escaping () -> Void) {
        vc.present(ConfirmationPopupViewController(
            title: title, message: message, confirmTitle: String(localized: "All Devices"),
            alternateTitle: String(localized: "This Device Only"), onAlternate: thisDevice,
            destructive: true, width: 1160, onConfirm: everywhere), animated: true)
    }

    // MARK: Live TV Sources

    /// The source whose detail page is currently being shown. Set by a source
    /// row's `prepare` before pushing `.liveTVSourceDetail`, read by the detail
    /// builder (SettingsPage can't carry associated data — it's CaseIterable).
    static var pendingSourceDetail: LiveTVDataStore.LiveTVSourceInfo?

    private static var iptv: [SettingsRowItem] {
        let ds = LiveTVDataStore.shared
        let hiddenSources = ds.hiddenPlexSources + [JellyfinLiveTVProvider.hiddenSource, EmbyLiveTVProvider.hiddenSource].compactMap { $0 }
        let hidden = Set(hiddenSources.map(\.id))
        var rows: [SettingsRowItem] = (ds.sources + hiddenSources).sorted { $0.displayName < $1.displayName }.map { source in
            SettingsRowItem(id: "src_\(source.id)", verbatim: source.displayName,
                            kind: .navigationAction(.liveTVSourceDetail,
                                                    value: { hidden.contains(source.id) ? String(localized: "Off") : source.isConnected ? String(localized: "\(source.channelCount) ch") : String(localized: "Offline") },
                                                    prepare: { pendingSourceDetail = source }))
        }
        rows.append(SettingsRowItem(id: "addLiveTVSource", title: "Add Live TV Source",
                                    kind: .navigation(.addLiveTVSource)))
        return rows
    }

    /// Set while Refresh Channels runs, so the row says so and ignores a second press.
    private static var refreshingSourceID: String?

    private static var liveTVSourceDetail: [SettingsRowItem] {
        guard let pending = pendingSourceDetail else { return [] }
        // Read live: the snapshot taken when the page opened goes stale on a refresh.
        let source = LiveTVDataStore.shared.sources.first { $0.id == pending.id } ?? pending
        let machineID = LiveTVDataStore.shared.plexMachineIDs[source.id]
        let plexToggle = machineID.map { plexLiveTVToggle(id: "src_showInLiveTV", machineID: $0) }
        // A hidden server has nothing to show but the way back.
        if let plexToggle, let machineID, LiveTVDataStore.shared.isPlexLiveTVHidden(machineID: machineID) {
            return [plexToggle]
        }
        let serverToggle: (row: SettingsRowItem, isHidden: Bool)? = switch source.sourceType {
        case .jellyfin: (jellyfinLiveTVToggle(id: "src_showInLiveTV"), JellyfinLiveTVProvider.hiddenSource != nil)
        case .emby: (embyLiveTVToggle(id: "src_showInLiveTV"), EmbyLiveTVProvider.hiddenSource != nil)
        default: nil
        }
        if let serverToggle, serverToggle.isHidden { return [serverToggle.row] }
        var rows: [SettingsRowItem] = plexToggle.map { [$0] } ?? serverToggle.map { [$0.row] } ?? []
        rows += [
            SettingsRowItem(id: "src_status", title: "Status",
                            kind: .info(value: { source.isConnected ? String(localized: "Connected") : String(localized: "Disconnected") })),
            SettingsRowItem(id: "src_channels", title: "Channels",
                            kind: .info(value: { "\(source.channelCount)" }))
        ]
        // Only shown when a profile is actually set, so the common all-channels
        // source keeps the page as short as it is today.
        if let profile = source.channelProfile {
            rows.append(SettingsRowItem(id: "src_channelProfile", title: "Channel Profile",
                                        kind: .info(value: { profile })))
        }
        if let lastSync = source.lastSync {
            rows.append(SettingsRowItem(id: "src_lastSync", title: "Last Synced",
                                        kind: .info(value: { lastSync.formatted(date: .abbreviated, time: .shortened) })))
        }
        let refreshing = refreshingSourceID == source.id
        rows.append(SettingsRowItem(id: "refreshChannels", title: refreshing ? "Refreshing Channels…" : "Refresh Channels",
                                    kind: .action(destructive: false, handler: { vc in
            guard refreshingSourceID == nil else { return }
            refreshingSourceID = source.id
            (vc as? SettingsPageViewController)?.reloadRows()
            Task {
                await LiveTVDataStore.shared.refreshChannels()
                await LiveTVDataStore.shared.loadEPG()
                refreshingSourceID = nil
                (vc as? SettingsPageViewController)?.reloadRows()
            }
        })))
        // A server's own Live TV leaves with its sign-in; removed here it would come straight back.
        guard !source.sourceType.followsServer else { return rows }
        rows.append(SettingsRowItem(id: "removeSource", title: "Remove Source",
                                    kind: .action(destructive: true, handler: { vc in
            let page = vc as? SettingsPageViewController
            if CloudSync.shared.isSynced(accountID: LiveTVDataStore.syncID(forSource: source.id)) {
                func remove(_ scope: SignOutScope) {
                    Task { @MainActor in
                        await LiveTVDataStore.shared.removeSource(id: source.id, scope: scope)
                        page?.onPop?()
                    }
                }
                presentSignOutChoice(
                    on: vc, title: String(localized: "Remove Source?"),
                    message: String(localized: "\"\(source.displayName)\" is shared through iCloud. Remove it from this device only, or from every device?"),
                    thisDevice: { remove(.thisDevice) }, everywhere: { remove(.everywhere) })
                return
            }
            presentConfirm(on: vc, title: "Remove Source?",
                           message: "This will remove \"\(source.displayName)\" and all its channels from Live TV.",
                           confirmTitle: "Remove", destructive: true) {
                Task {
                    await LiveTVDataStore.shared.removeSource(id: source.id)
                    (vc as? SettingsPageViewController)?.onPop?()
                }
            }
        })))
        return rows
    }

    // MARK: Async page preparation

    /// Kick off any background loads a page needs the first time it appears
    /// (e.g. fetch Plex Home users). Calls `reload` when fresh data arrives.
    static func prepareAsync(for page: SettingsPage, reload: @escaping () -> Void) {
        switch page {
        case .addLiveTVSource:
            // The picker VC is created fresh on every entry, so this is the
            // flow's entry point: start blank. Draft state and any previous
            // failure text must not survive leaving the flow.
            resetAddSourceFlow()
            reload()
        case .plex where PlexAuthManager.shared.isAuthenticated:
            loadPlexServers(reload: reload)
        case .liveTVFavorites where LiveTVDataStore.shared.channels.isEmpty:
            // Settings can open before Live TV has loaded its channels.
            Task { @MainActor in
                await LiveTVDataStore.shared.loadChannels()
                reload()
            }
        default:
            break
        }
    }

    // MARK: About

    private static var about: [SettingsRowItem] {
        let short = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
        let version = "\(short) (\(build))"
        return [
            SettingsRowItem(id: "about_version", title: "Version", kind: .info(value: { version })),
            SettingsRowItem(id: "changelog", title: "Changelog", kind: .action(destructive: false, handler: { vc in
                presentChangelog(on: vc)
            })),
            SettingsRowItem(id: "licensesLegal", title: "Licenses & Legal", kind: .action(destructive: false, handler: { vc in
                presentAcknowledgements(on: vc)
            })),
            // Writes through InputProbe rather than SettingsStore directly so
            // the HUD appears and disappears with the toggle.
            SettingsRowItem(id: "inputDiagnostics", title: "Input Diagnostics", kind: .toggle(
                get: { InputProbe.isEnabled },
                set: { InputProbe.setEnabled($0) }
            )),
            // Runs whether or not the toggle above is on: the test is the
            // supported way to report a remote problem, so it must not need a
            // second switch flipped first.
            SettingsRowItem(id: "inputTest", title: "Run Input Test", kind: .action(destructive: false, handler: { vc in
                vc.present(InputTestViewController(), animated: true)
            })),
            SettingsRowItem(id: "sendDiagnostics", title: "Send Diagnostics", kind: .action(destructive: false, handler: { vc in
                guard !DiagnosticsReport.isSending else { return }
                let page = vc as? SettingsPageViewController
                Task { @MainActor in
                    let outcome = await DiagnosticsReport.send(window: vc.view.window, onStart: { page?.reloadRows() })
                    page?.reloadRows()
                    let popup: ConfirmationPopupViewController
                    switch outcome {
                    case .server(let code):
                        popup = ConfirmationPopupViewController(
                            title: String(localized: "Diagnostics Sent"),
                            message: String(localized: "Your code is \(code). Include it in your GitHub issue or message so the report can be found."),
                            confirmTitle: String(localized: "OK"), cancelTitle: nil, onConfirm: {})
                    case .failed:
                        popup = ConfirmationPopupViewController(
                            title: String(localized: "Couldn't Send Diagnostics"),
                            message: String(localized: "The report is saved and will be sent with your next attempt."),
                            confirmTitle: String(localized: "OK"), cancelTitle: nil, onConfirm: {})
                    }
                    vc.present(popup, animated: true)
                }
            }), isBusy: { DiagnosticsReport.isSending })
        ]
    }

    /// Settings → Changelog shows the FULL release history (every entry in
    /// `WhatsNewView.changelogs`, newest first), unlike the fresh-launch
    /// "What's New" which stays scoped to the current build.
    private static func presentChangelog(on vc: UIViewController) {
        let popup = InfoPopupViewController(
            content: InfoPopupContent.changelogHistory(WhatsNewView.changelogs),
            width: 1000, height: 920, scrollable: true)
        vc.present(popup, animated: true)
    }

    /// The fresh-launch "What's New": every build in `versions` (those since the last one
    /// seen), or the newest entry if empty, so it's never blank. Select/Menu dismiss.
    static func makeChangelogPopup(versions: [String]) -> InfoPopupViewController {
        let entries = versions.isEmpty
            ? Array(WhatsNewView.changelogs.prefix(1))
            : WhatsNewView.changelogs.filter { versions.contains($0.version) }
        return InfoPopupViewController(content: InfoPopupContent.changelog(entries), width: 1000, scrollable: true)
    }

    /// Licenses & Legal renders into the app's contained glass popup (not a
    /// full-screen modal) — Up/Down pages the long license text, Menu dismisses.
    private static func presentAcknowledgements(on vc: UIViewController) {
        let popup = InfoPopupViewController(content: InfoPopupContent.acknowledgements(),
                                            width: 1200, height: 920, scrollable: true)
        vc.present(popup, animated: true)
    }

    // MARK: Helpers

    /// `enabledWhen` marks the row as depending on another setting: while it
    /// returns false the row renders dimmed and cannot be focused or toggled.
    /// Cycles one marker kind through Button, Automatic and Off (#381).
    private static func skipModeRow(_ id: String, _ title: String.LocalizationValue, marker: String) -> SettingsRowItem {
        SettingsRowItem(id: id, title: title, kind: .cycle(
            value: { MarkerSkipMode.current(for: marker).label },
            next: {
                let all = MarkerSkipMode.allCases
                let i = all.firstIndex(of: MarkerSkipMode.current(for: marker)) ?? 0
                MarkerSkipMode.set(all[(i + 1) % all.count], for: marker)
            }))
    }

    private static func toggle(_ id: String, _ title: String.LocalizationValue, key: String, default def: Bool,
                               enabledWhen: (() -> Bool)? = nil) -> SettingsRowItem {
        SettingsRowItem(id: id, title: title, kind: .toggle(
            get: { SettingsStore.bool(key, default: def) },
            set: { SettingsStore.setBool(key, $0) }
        ), isEnabled: enabledWhen ?? { true })
    }
}
