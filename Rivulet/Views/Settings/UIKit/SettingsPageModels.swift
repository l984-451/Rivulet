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

import Foundation
import UIKit
import SwiftUI

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
        case toggle(get: () -> Bool, set: (Bool) -> Void)
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
        case textEntry(value: () -> String, placeholder: String, hint: String?,
                       suggestions: [(label: String, value: String)],
                       keyboardType: UIKeyboardType, set: (String) -> Void)
    }

    let id: String
    let title: String
    let kind: Kind
    /// Non-nil = this row can be grabbed and reordered (hold Select → move
    /// mode). Called with `up` to move it one slot and persist the new order.
    var onReorder: ((_ up: Bool) -> Void)?
    var isReorderable: Bool { onReorder != nil }
    /// A row whose meaning depends on another row's state renders dimmed and
    /// unfocusable while that state is off. Evaluated live (not cached at build
    /// time) so flipping the row it depends on takes effect without a rebuild.
    var isEnabled: () -> Bool = { true }
    /// True = this "row" is really a group caption (see `header(_:)`).
    var isHeader = false

    /// A group caption between row runs, Apple TV Settings style: small
    /// uppercase gray text, no capsule, never focusable. Deliberately NOT a
    /// `Kind` case — it reuses `.info`, which is already unfocusable and
    /// chevron-less, so every existing `switch kind` keeps working untouched.
    static func header(_ title: String) -> SettingsRowItem {
        SettingsRowItem(id: "hdr_\(title)", title: title, kind: .info(value: { "" }), isHeader: true)
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
        case .toggle(let get, _): return get() ? "On" : "Off"
        case .cycle(let value, _): return value()
        case .info(let value): return value()
        case .selectable(_, let value, _): return value()
        // Show the current value; fall back to the placeholder (or "Not set")
        // when empty.
        case .textEntry(let value, let placeholder, _, _, _, _):
            let current = value()
            return current.isEmpty ? (placeholder.isEmpty ? "Not set" : placeholder) : current
        case .navigation, .action, .option: return nil
        }
    }
}

/// Per-page row builders. The UIKit equivalent of SettingsView's per-page
/// ViewBuilders. Pages not yet ported (separate sub-views, picker pages)
/// return an empty list and render a placeholder.
@MainActor
enum SettingsContent {

    static func rows(for page: SettingsPage) -> [SettingsRowItem] {
        switch page {
        case .root:        return root
        case .appearance:  return appearance
        case .playback:    return playback
        case .liveTV:      return liveTV
        case .music:       return music
        case .servers:     return servers
        case .plex:        return plex
        case .libraries:   return libraries
        case .homeRows:    return homeRows
        case .cache:       return cache
        case .iptv:        return iptv
        case .liveTVSourceDetail: return liveTVSourceDetail
        case .addLiveTVSource:  return addLiveTVSource
        case .addOwnServer:     return addOwnServer
        case .addPlaylistURL:   return addPlaylistURL
        case .about:       return about
        case .displaySizePicker:      return displaySizePicker
        case .autoplayCountdownPicker: return autoplayCountdownPicker
        case .skipIntervalPicker:     return skipIntervalPicker
        case .contentFilter:          return contentFilter
        case .contentFilterStrength:  return contentFilterStrength
        }
    }

    // MARK: Picker pages (checkmark option rows; select-and-pop)

    private static var displaySizePicker: [SettingsRowItem] {
        DisplaySize.allCases.map { opt in
            SettingsRowItem(id: "ds_\(opt.rawValue)", title: opt.description, kind: .option(
                isSelected: { SettingsStore.string("displaySize", default: DisplaySize.normal.rawValue) == opt.rawValue },
                select: { SettingsStore.setString("displaySize", opt.rawValue) }))
        }
    }

    private static var autoplayCountdownPicker: [SettingsRowItem] {
        AutoplayCountdown.allCases.map { opt in
            SettingsRowItem(id: "ac_\(opt.rawValue)", title: opt.description, kind: .option(
                isSelected: { SettingsStore.int("autoplayCountdown", default: AutoplayCountdown.fiveSeconds.rawValue) == opt.rawValue },
                select: { SettingsStore.setInt("autoplayCountdown", opt.rawValue) }))
        }
    }

    private static var skipIntervalPicker: [SettingsRowItem] {
        SkipInterval.allCases.map { opt in
            SettingsRowItem(id: "si_\(opt.rawValue)", title: opt.description, kind: .option(
                isSelected: { SettingsStore.int(SkipInterval.storageKey, default: SkipInterval.defaultValue.rawValue) == opt.rawValue },
                select: { SettingsStore.setInt(SkipInterval.storageKey, opt.rawValue) }))
        }
    }

    // MARK: Root

    private static var root: [SettingsRowItem] {
        [
            SettingsRowItem(id: "cat_appearance", title: "Appearance", kind: .navigation(.appearance)),
            SettingsRowItem(id: "cat_playback",   title: "Playback",   kind: .navigation(.playback)),
            // Music settings withdrawn until the audio features behind them
            // exist — all three rows were no-ops (see the `music` builder).
            // Music BROWSING is unaffected: the sidebar still shows
            // MusicHomeView for every visible Plex music library.
//            SettingsRowItem(id: "cat_music",      title: "Music",      kind: .navigation(.music)),
            SettingsRowItem(id: "cat_liveTV",     title: "Live TV",    kind: .navigation(.liveTV)),
            SettingsRowItem(id: "cat_servers",    title: "Servers",    kind: .navigation(.servers)),
            SettingsRowItem(id: "cache",          title: "Cache & Storage", kind: .navigation(.cache)),
            SettingsRowItem(id: "cat_about",      title: "About",      kind: .navigation(.about))
        ]
    }

    // MARK: Appearance

    private static var appearance: [SettingsRowItem] {
        var rows: [SettingsRowItem] = [
            // Leading block is unheaded, like an Apple TV Settings page's first
            // group: it sits directly under the page title.
            SettingsRowItem(id: "libraries", title: "Sidebar Libraries", kind: .navigation(.libraries)),
            SettingsRowItem(id: "displaySize", title: "Display Size",
                            kind: .navigationValue(.displaySizePicker, value: {
                                DisplaySize(rawValue: SettingsStore.string("displaySize", default: DisplaySize.normal.rawValue))?.description ?? ""
                            })),
            // Discover is a sidebar tab, not a Home row, so it sits in the
            // unheaded block with the other whole-app placement rows.
            toggle("showDiscoverTab", "Show Discover Tab", key: "showDiscoverTab", default: true),
            // Nothing to place when there is no Discover tab, so this dims with
            // it rather than vanishing (a toggle only re-dims the visible rows,
            // it does not rebuild the list).
            toggle("discoverAboveLibraries", "Discover Above Libraries", key: "discoverAboveLibraries", default: true,
                   enabledWhen: { SettingsStore.bool("showDiscoverTab", default: true) }),
            // Profiles themselves are switched from the sidebar now, so this is
            // all that is left of the retired User Profiles page.
            SettingsRowItem(id: "profilePickerOnLaunch", title: "Profile Picker on Launch",
                            kind: .toggle(
                                get: { PlexUserProfileManager.shared.showProfilePickerOnLaunch },
                                set: { PlexUserProfileManager.shared.showProfilePickerOnLaunch = $0 })),

            // Titles drop whatever their caption already says ("Home Hero" under
            // HOME reads as "Home Home Hero"), the way Apple TV Settings puts a
            // bare "Siri" row under SIRI.
            .header("Home"),
            SettingsRowItem(id: "homeRows", title: "Rows", kind: .navigation(.homeRows)),
            toggle("homeHero", "Hero", key: "showHomeHero", default: true),
            toggle("personalizedRecs", "Personalized Recommendations", key: "enablePersonalizedRecommendations", default: false)
        ]
        rows += [
            .header("Library"),
            toggle("libraryHero", "Hero", key: "showLibraryHero", default: true),
            toggle("discoveryRows", "Discovery Rows", key: "showLibraryRecommendations", default: true),
            toggle("recentRows", "Recent Rows", key: "showLibraryRecentRows", default: true),

            // The look of Live TV lives here; what it plays stays on the Live TV
            // page. Same ids and keys as before the move, so the description
            // panel entries carry over untouched.
            .header("Live TV"),
            toggle("liveTVAboveLibraries", "Above Libraries", key: "liveTVAboveLibraries", default: false),
            SettingsRowItem(id: "defaultLayout", title: "Default Layout",
                            kind: .cycle(value: { LiveTVLayout(rawValue: SettingsStore.string("liveTVLayout", default: LiveTVLayout.guide.rawValue))?.description ?? "" },
                                         next: { cycleLiveTVLayout() })),
            toggle("classicTVMode", "Classic TV Mode", key: "classicTVMode", default: false)
        ]
        return rows
    }

    // MARK: Playback

    private static var playback: [SettingsRowItem] {
        [
            toggle("autoSkipIntro", "Auto-Skip Intro", key: "autoSkipIntro", default: false),
            toggle("autoSkipCredits", "Auto-Skip Credits", key: "autoSkipCredits", default: false),
            toggle("autoSkipAds", "Auto-Skip Ads", key: "autoSkipAds", default: false),
            toggle("autoSkipRecap", "Auto-Skip Recap", key: "autoSkipRecap", default: false),
            toggle("useIntroDB", "Community Marker Database", key: "useIntroDB", default: false),
            toggle("instantResume", "Instant Resume", key: "continueWatchingInstantResume", default: true),
            // The prompt only has anything to interrupt while a Continue
            // Watching tile plays on Select, so it dims with Instant Resume off.
            toggle("promptResumeOrRestart", "Resume or Restart Prompt", key: "promptResumeOrRestart", default: false,
                   enabledWhen: { SettingsStore.bool("continueWatchingInstantResume", default: true) }),
            SettingsRowItem(id: "autoplayCountdown", title: "Autoplay Countdown",
                            kind: .navigationValue(.autoplayCountdownPicker, value: {
                                AutoplayCountdown(rawValue: SettingsStore.int("autoplayCountdown", default: AutoplayCountdown.fiveSeconds.rawValue))?.description ?? ""
                            })),
            SettingsRowItem(id: "skipLength", title: "Skip Length",
                            kind: .navigationValue(.skipIntervalPicker, value: {
                                SkipInterval(rawValue: SettingsStore.int(SkipInterval.storageKey, default: SkipInterval.defaultValue.rawValue))?.description ?? ""
                            })),
            toggle("showPostVideoUpNext", "Show Up Next Panel", key: "showPostVideoUpNext", default: true),
            SettingsRowItem(id: "cat_contentFilter", title: "Content Filtering",
                            kind: .navigationValue(.contentFilter, value: {
                                SettingsStore.bool(ContentFilterManager.Keys.enabled, default: false) ? "On" : "Off"
                            }))
        ]
    }

    // MARK: Content Filtering

    /// VidAngel/ClearPlay-style local filter. Language categories are detected
    /// live from the subtitle track; scene categories need an imported filter
    /// list (see the source URL row).
    private static var contentFilter: [SettingsRowItem] {
        var rows: [SettingsRowItem] = [
            toggle("cf_master", "Content Filter",
                   key: ContentFilterManager.Keys.enabled, default: false)
        ]

        // Language categories (auto-detected from subtitles)
        rows.append(categoryToggle(.profanity, id: "cf_profanity"))
        rows.append(SettingsRowItem(id: "cf_strength", title: "Profanity Strength",
                                    kind: .navigationValue(.contentFilterStrength, value: {
                                        strengthLabel(currentProfanityStrength())
                                    })))
        rows.append(categoryToggle(.blasphemy, id: "cf_blasphemy"))
        rows.append(categoryToggle(.slur, id: "cf_slur"))
        rows.append(categoryToggle(.sexualLanguage, id: "cf_sexualLanguage"))

        // Scene categories (require an imported filter list)
        rows.append(categoryToggle(.violence, id: "cf_violence"))
        rows.append(categoryToggle(.sexNudity, id: "cf_sexNudity"))
        rows.append(categoryToggle(.frightening, id: "cf_frightening"))
        rows.append(categoryToggle(.substances, id: "cf_substances"))

        // Imported list source
        rows.append(SettingsRowItem(id: "cf_sourceURL", title: "Filter List URL",
                                    kind: .textEntry(
                                        value: { SettingsStore.string(ContentFilterManager.Keys.listSourceURL, default: "") },
                                        placeholder: "Optional",
                                        hint: "A URL where per-title MCF or EDL filter files are hosted. Use {id} for the Plex rating key, or a folder that contains <ratingKey>.mcf files.",
                                        suggestions: [],
                                        keyboardType: .URL,
                                        set: { SettingsStore.setString(ContentFilterManager.Keys.listSourceURL, $0) })))
        return rows
    }

    private static var contentFilterStrength: [SettingsRowItem] {
        FilterSeverity.allCases.map { severity in
            SettingsRowItem(id: "cfs_\(severity.rawValue)", title: strengthLabel(severity),
                            kind: .option(
                                isSelected: { currentProfanityStrength() == severity },
                                select: { SettingsStore.setInt(ContentFilterManager.Keys.profanityStrength, severity.rawValue) }))
        }
    }

    private static func currentProfanityStrength() -> FilterSeverity {
        FilterSeverity(rawValue: SettingsStore.int(ContentFilterManager.Keys.profanityStrength,
                                                    default: FilterSeverity.moderate.rawValue)) ?? .moderate
    }

    /// The stored value is the *minimum* severity that gets muted.
    private static func strengthLabel(_ severity: FilterSeverity) -> String {
        switch severity {
        case .mild: return "Mild and up"
        case .moderate: return "Moderate and up"
        case .strong: return "Strong only"
        }
    }

    private static func categoryToggle(_ category: FilterCategory, id: String) -> SettingsRowItem {
        SettingsRowItem(id: id, title: category.displayName, kind: .toggle(
            get: { SettingsStore.bool(category.enabledDefaultsKey, default: category.defaultEnabled) },
            set: { SettingsStore.setBool(category.enabledDefaultsKey, $0) }))
    }

    // MARK: Live TV

    /// Sidebar placement, Default Layout and Classic TV Mode moved to the
    /// Appearance page's "Live TV" group; this page keeps sources and playback.
    private static var liveTV: [SettingsRowItem] {
        [
            SettingsRowItem(id: "liveTVSources", title: "Live TV Sources", kind: .navigation(.iptv)),
            toggle("combineSources", "Combine Sources", key: "combineLiveTVSources", default: true),
            toggle("confirmExitMultiview", "Confirm Exit Multiview", key: "confirmExitMultiview", default: true),
            toggle("allowFourStreams", "Allow 3 or 4 Streams", key: "allowFourStreams", default: false)
        ]
    }

    private static func cycleLiveTVLayout() {
        let all = LiveTVLayout.allCases
        let cur = LiveTVLayout(rawValue: SettingsStore.string("liveTVLayout", default: LiveTVLayout.guide.rawValue)) ?? all.first!
        let i = all.firstIndex(of: cur) ?? 0
        SettingsStore.setString("liveTVLayout", all[(i + 1) % all.count].rawValue)
    }

    // MARK: Music

    /// Withdrawn: every row here was a no-op, and not merely unread. Each key
    /// had no reader at all, and the implementation each one was supposed to
    /// gate has no caller either:
    ///   - Crossfade wrote `musicCrossfadeDuration` as a `CrossfadeOption`
    ///     string, while `MusicAudioProcessor.crossfadeDuration` reads
    ///     `music_crossfade_duration` as a `CrossfadeDuration` Int — different
    ///     key AND different type — and nothing calls that getter, so music
    ///     playback has no crossfade to configure.
    ///   - Loudness Normalization gated `MusicAudioProcessor.adjustedVolume(for:)`,
    ///     which has no callers.
    ///   - Audio Quality Badges gated `AudioQualityBadge`, a view that is never
    ///     instantiated anywhere.
    /// Restore the rows below once one of those is actually wired up, and fix
    /// the crossfade key/type mismatch when you do.
    private static var music: [SettingsRowItem] {
        []
//        [
//            toggle("musicLoudness", "Loudness Normalization", key: "musicLoudnessNormalization", default: false),
//            SettingsRowItem(id: "musicCrossfade", title: "Crossfade",
//                            kind: .cycle(value: { CrossfadeOption(rawValue: SettingsStore.string("musicCrossfadeDuration", default: CrossfadeOption.off.rawValue))?.description ?? "" },
//                                         next: {
//                                             let all = CrossfadeOption.allCases
//                                             let cur = CrossfadeOption(rawValue: SettingsStore.string("musicCrossfadeDuration", default: CrossfadeOption.off.rawValue)) ?? all.first!
//                                             let i = all.firstIndex(of: cur) ?? 0
//                                             SettingsStore.setString("musicCrossfadeDuration", all[(i + 1) % all.count].rawValue)
//                                         })),
//            toggle("musicQualityBadges", "Audio Quality Badges", key: "musicShowQualityBadges", default: true)
//        ]
    }

    // MARK: Servers

    private static var servers: [SettingsRowItem] {
        [
            SettingsRowItem(id: "plexServer", title: "Plex Server", kind: .navigation(.plex))
        ]
    }

    // MARK: Plex (sign-in / sign-out)

    private static var plex: [SettingsRowItem] {
        let auth = PlexAuthManager.shared
        if auth.isAuthenticated {
            var rows: [SettingsRowItem] = []
            if let name = auth.savedServerName {
                rows.append(SettingsRowItem(id: "plexServerInfo", title: "Server",
                                            kind: .info(value: { name })))
            }
            rows.append(SettingsRowItem(id: "signOut", title: "Sign Out",
                                        kind: .action(destructive: true, handler: { vc in
                PlexAuthManager.shared.signOut()
                // Rebuild the page in place so it flips to "Connect to Plex"
                // immediately (Sign Out is an in-place action — unlike the
                // sign-in modal, nothing else triggers viewWillAppear here).
                (vc as? SettingsPageViewController)?.reloadRows()
            })))
            return rows
        } else {
            return [
                SettingsRowItem(id: "connectPlex", title: "Connect to Plex",
                                kind: .action(destructive: false, handler: { presenter in
                    let auth = UIHostingController(rootView: PlexAuthView())
                    auth.modalPresentationStyle = .fullScreen
                    presenter.present(auth, animated: true)
                }))
            ]
        }
    }

    // MARK: Home Rows (local subtractive filter over the server's row set)

    /// One toggle per row Plex currently offers Home, in the order Home draws
    /// them.
    ///
    /// Built from `PlexDataStore.homeItems`, the SAME projection Home renders,
    /// rather than from a list assembled here. That is what keeps the page
    /// honest: the titles are the server's own (so they are localized, and they
    /// say "Recently Added in Movies-demo" exactly as the shelf does), and a row
    /// can never be listed here that Home would not draw.
    ///
    /// Hidden rows still appear in this list — they are what you come here to
    /// switch back on — so the list is the projection plus whatever is currently
    /// filtered out of it.
    private static var homeRows: [SettingsRowItem] {
        let store = PlexDataStore.shared
        let visible = store.homeItems
        // Hidden rows are absent from the projection by definition, so recover
        // them from the hubs the projection was built from.
        let hiddenRows: [(id: String, title: String)] = store.librariesPinnedToHome
            .flatMap { store.libraryHubs[$0.key] ?? [] }
            .filter { $0.promoted == true && HomeRowSettings.isHidden($0.hubIdentifier) }
            .compactMap { hub in
                guard let id = hub.hubIdentifier else { return nil }
                return (id, hub.title ?? id)
            }
        let continueWatching: [(id: String, title: String)] = {
            guard let cw = store.continueWatchingHub, let id = cw.hubIdentifier,
                  HomeRowSettings.isHidden(id) else { return [] }
            return [(id, cw.title ?? id)]
        }()

        let entries: [(id: String, title: String)] =
            continueWatching
            + visible.compactMap { row in
                guard let id = row.hubIdentifier else { return nil }
                return (id, row.title)
            }
            + hiddenRows

        guard !entries.isEmpty else {
            return [SettingsRowItem(id: "noHomeRows",
                                    title: "Connect to a Plex server to manage Home rows",
                                    kind: .info(value: { "" }))]
        }

        var rows: [SettingsRowItem] = [
            SettingsRowItem(id: "showAllHomeRows", title: "Show All",
                            kind: .action(destructive: false, handler: { vc in
                HomeRowSettings.showAll()
                (vc as? SettingsPageViewController)?.reloadRows()
            }))
        ]
        // De-dupe defensively: Continue Watching can be reported by both the
        // dedicated hub and the projection.
        var seen = Set<String>()
        for entry in entries where seen.insert(entry.id).inserted {
            rows.append(SettingsRowItem(id: "homeRow_\(entry.id)", title: entry.title, kind: .toggle(
                get: { !HomeRowSettings.isHidden(entry.id) },
                set: { shown in HomeRowSettings.setHidden(!shown, for: entry.id) })))
        }
        return rows
    }

    // MARK: Libraries (sidebar visibility)

    private static var libraries: [SettingsRowItem] {
        let mgr = LibrarySettingsManager.shared
        let libs = mgr.sortLibraries(PlexDataStore.shared.libraries.filter { $0.isVideoLibrary || $0.isMusicLibrary })
        guard !libs.isEmpty else {
            return [SettingsRowItem(id: "noLibraries",
                                    title: "Connect to a Plex server to manage libraries",
                                    kind: .info(value: { "" }))]
        }
        let keys = libs.map { $0.key }
        // Add All / Remove All live at the TOP of the list, above the per-library
        // toggles, so the bulk actions are the first thing the user lands on.
        var rows: [SettingsRowItem] = [
            SettingsRowItem(id: "addAllLibraries", title: "Add All",
                            kind: .action(destructive: false, handler: { vc in
                LibrarySettingsManager.shared.showAllLibraries(keys)
                (vc as? SettingsPageViewController)?.reloadRows()
            })),
            SettingsRowItem(id: "removeAllLibraries", title: "Remove All",
                            kind: .action(destructive: true, handler: { vc in
                LibrarySettingsManager.shared.hideAllLibraries(keys)
                (vc as? SettingsPageViewController)?.reloadRows()
            }))
        ]
        rows += libs.map { lib in
            // Hold Select to grab + reorder (Apple-Home style). The page VC
            // animates the slot change; this just persists the new order.
            SettingsRowItem(id: "lib_\(lib.key)", title: lib.title, kind: .toggle(
                get: { LibrarySettingsManager.shared.isLibraryVisible(lib.key) },
                set: { _ in LibrarySettingsManager.shared.toggleVisibility(for: lib.key) }),
                onReorder: { up in moveMediaLibrary(key: lib.key, up: up) })
        }
        return rows
    }

    /// Move a media library one slot up/down in the sidebar order. Reorders by
    /// KEY (not the index-based `moveLibrary`, whose indices are into the raw
    /// `libraryOrder` and don't line up with the displayed list), then rewrites
    /// `libraryOrder` as [new media order] + [any non-media ordered keys], so
    /// every shown library is explicitly ordered and nothing else is dropped.
    private static func moveMediaLibrary(key: String, up: Bool) {
        let mgr = LibrarySettingsManager.shared
        let mediaLibs = mgr.sortLibraries(
            PlexDataStore.shared.libraries.filter { $0.isVideoLibrary || $0.isMusicLibrary })
        var mediaKeys = mediaLibs.map { $0.key }
        guard let i = mediaKeys.firstIndex(of: key) else { return }
        let j = up ? i - 1 : i + 1
        guard j >= 0, j < mediaKeys.count else { return }
        mediaKeys.swapAt(i, j)
        let nonMedia = mgr.libraryOrder.filter { !mediaKeys.contains($0) }
        mgr.libraryOrder = mediaKeys + nonMedia
    }

    // MARK: Cache & Storage

    private static var cache: [SettingsRowItem] {
        [
            SettingsRowItem(id: "forceRefresh", title: "Force Refresh Libraries",
                            kind: .action(destructive: false, handler: { vc in
                presentConfirm(on: vc, title: "Force Refresh Libraries?",
                               message: "This clears the metadata cache and reloads library content from your Plex server.",
                               confirmTitle: "Refresh", destructive: false) {
                    Task { await CacheManager.shared.clearAllCache() }
                }
            })),
            SettingsRowItem(id: "clearAllCache", title: "Clear All Cache",
                            kind: .action(destructive: true, handler: { vc in
                presentConfirm(on: vc, title: "Clear All Cache?",
                               message: "Removes all cached images and metadata. Content will be re-downloaded.",
                               confirmTitle: "Clear Cache", destructive: true) {
                    Task {
                        await ImageCacheManager.shared.clearAll()
                        await CacheManager.shared.clearAllCache()
                    }
                }
            }))
        ]
    }

    /// Canonical confirm/cancel prompt: the Liquid-Glass card
    /// (`ConfirmationPopupViewController`) shared with the rest of the app, not a
    /// system `UIAlertController`. Use this for every Settings confirmation.
    private static func presentConfirm(on vc: UIViewController, title: String, message: String,
                                       confirmTitle: String, destructive: Bool, action: @escaping () -> Void) {
        let popup = ConfirmationPopupViewController(
            title: title, message: message, confirmTitle: confirmTitle,
            cancelTitle: "Cancel", destructive: destructive, onConfirm: action)
        vc.present(popup, animated: true)
    }

    // MARK: Live TV Sources

    /// The source whose detail page is currently being shown. Set by a source
    /// row's `prepare` before pushing `.liveTVSourceDetail`, read by the detail
    /// builder (SettingsPage can't carry associated data — it's CaseIterable).
    static var pendingSourceDetail: LiveTVDataStore.LiveTVSourceInfo?

    private static var iptv: [SettingsRowItem] {
        let ds = LiveTVDataStore.shared
        var rows: [SettingsRowItem] = ds.sources.map { source in
            SettingsRowItem(id: "src_\(source.id)", title: source.displayName,
                            kind: .navigationAction(.liveTVSourceDetail,
                                                    value: { source.isConnected ? "\(source.channelCount) ch" : "Offline" },
                                                    prepare: { pendingSourceDetail = source }))
        }
        rows.append(SettingsRowItem(id: "addLiveTVSource", title: "Add Live TV Source",
                                    kind: .navigation(.addLiveTVSource)))
        return rows
    }

    private static var liveTVSourceDetail: [SettingsRowItem] {
        guard let source = pendingSourceDetail else { return [] }
        var rows: [SettingsRowItem] = [
            SettingsRowItem(id: "src_status", title: "Status",
                            kind: .info(value: { source.isConnected ? "Connected" : "Disconnected" })),
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
        rows.append(SettingsRowItem(id: "refreshChannels", title: "Refresh Channels",
                                    kind: .action(destructive: false, handler: { vc in
            Task {
                await LiveTVDataStore.shared.refreshChannels()
                (vc as? SettingsPageViewController)?.reloadRows()
            }
        })))
        rows.append(SettingsRowItem(id: "removeSource", title: "Remove Source",
                                    kind: .action(destructive: true, handler: { vc in
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
            SettingsRowItem(id: "about_app", title: "App", kind: .info(value: { "Rivulet" })),
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
            ))
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

    /// Builds the current-build changelog glass popup (or the most recent
    /// changelog entry if this build has none, so it's never blank). Used by
    /// the fresh-launch "What's New". Select/Menu dismiss; content-sized.
    static func makeChangelogPopup() -> InfoPopupViewController {
        // The changelog is keyed on the build-qualified version ("1.0.0 (50)").
        let short = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
        let qualified = "\(short) (\(build))"
        let version = WhatsNewView.features(for: qualified) != nil
            ? qualified
            : (WhatsNewView.changelogs.first?.version ?? qualified)
        let features = WhatsNewView.features(for: version) ?? []
        return InfoPopupViewController(content: InfoPopupContent.changelog(version: version, features: features),
                                       width: 1000, scrollable: true)
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
    private static func toggle(_ id: String, _ title: String, key: String, default def: Bool,
                               enabledWhen: (() -> Bool)? = nil) -> SettingsRowItem {
        SettingsRowItem(id: id, title: title, kind: .toggle(
            get: { SettingsStore.bool(key, default: def) },
            set: { SettingsStore.setBool(key, $0) }
        ), isEnabled: enabledWhen ?? { true })
    }
}
