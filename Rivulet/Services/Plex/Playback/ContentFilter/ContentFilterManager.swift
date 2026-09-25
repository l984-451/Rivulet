// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ContentFilterManager.swift
//  Rivulet
//
//  Runtime for the local content filter. Owned by UniversalPlayerViewModel
//  (VOD only). Three sources feed it:
//
//    1. The title's own subtitle file — read in full when Plex has it as an
//       external text stream, and matched against ProfanityDictionary up
//       front. Mutes language with subtitles off, on either route.
//    2. The subtitles on screen — the active line is matched live. Covers
//       titles whose only subtitles are embedded in the file.
//    3. Imported time-coded lists (MCF/EDL) — precise mute + scene-skip
//       windows fetched per title from a user-configured source. This is the
//       only way to skip scenes (violence, nudity) that dialogue can't reveal.
//
//  Nothing here modifies the media. Muting sets the player volume to zero for
//  the window; skipping seeks past it. Both are undone the instant the window
//  ends — the client-side approach protected by the Family Movie Act of 2005.
//

import Foundation
import Combine

@MainActor
final class ContentFilterManager: ObservableObject {

    // MARK: - Published state

    /// True while the filter wants the audio silenced right now. The view model
    /// mirrors this onto the active player.
    @Published private(set) var isFilterMuting = false

    /// The master switch from Settings.
    @Published private(set) var isEnabled = false

    /// Filtering suspended for the current title from the player rail. Cleared
    /// on the next item, so a pause never outlives the title it was made on.
    @Published private(set) var isPaused = false

    // MARK: - Settings snapshot

    private var enabledCategories: Set<FilterCategory> = []
    private var profanityThreshold: FilterSeverity = .moderate
    private var listSourceURL: String = ""

    // MARK: - Per-item runtime

    /// Windows from the imported list.
    private var regions: [FilterRegion] = []
    /// Windows from the title's subtitle file.
    private var transcriptWindows: [LanguageWindow] = []
    /// Which Plex stream those windows came from, and the subtitle delay to
    /// apply to them (see `displayedSubtitleDidChange`).
    private var transcriptStreamKey: String?
    private var transcriptDelay: TimeInterval = 0
    private var skippedRegionIDs: Set<Int> = []
    private var currentTime: TimeInterval = 0
    private var subtitleMatched = false
    private var lastSubtitleTexts: [String] = []
    private var listTask: Task<Void, Never>?
    private var transcriptTask: Task<Void, Never>?

    /// Seek a hair past a skip window so the next tick doesn't re-enter it.
    private let skipEpsilon: TimeInterval = 0.25

    private var isActive: Bool { isEnabled && !isPaused }

    // MARK: - Lifecycle

    init() {
        refreshSettings()
    }

    /// Re-read the persisted settings (call when playback starts and whenever
    /// the user may have changed them). Recomputes the active mute state.
    func refreshSettings() {
        let s = Settings.load()
        isEnabled = s.enabled
        profanityThreshold = s.profanityThreshold
        listSourceURL = s.listSourceURL

        var categories: Set<FilterCategory> = []
        if s.enabled {
            for category in FilterCategory.userToggleable where s.isCategoryEnabled(category) {
                categories.insert(category)
            }
            // `.other` (uncategorized imported regions) rides the master switch.
            categories.insert(.other)
        }
        enabledCategories = categories
        // Force the next subtitle feed to re-evaluate (categories/strength or the
        // master switch may have just changed mid-cue). Drop any current match
        // too — under the new rules it may no longer apply, and holding it
        // would keep audio muted until the next cue change re-evaluates.
        lastSubtitleTexts = []
        subtitleMatched = false
        recomputeMute()
    }

    /// Begin filtering a new item. Clears prior state, restores any cached list
    /// for it, then refreshes the list and reads the subtitle file in the
    /// background. Call once full metadata is known: the list lookup keys on
    /// the file name and external ids, and the subtitle file is a Plex stream.
    func beginItem(_ item: ContentFilterItem) {
        reset()
        refreshSettings()
        guard isEnabled else { return }
        transcriptStreamKey = item.transcript?.streamKey
        loadList(for: item)
        loadTranscript(for: item)
    }

    /// Tear down per-item state (call on stop / item change).
    func reset() {
        listTask?.cancel()
        listTask = nil
        transcriptTask?.cancel()
        transcriptTask = nil
        regions = []
        transcriptWindows = []
        transcriptStreamKey = nil
        transcriptDelay = 0
        skippedRegionIDs = []
        subtitleMatched = false
        lastSubtitleTexts = []
        currentTime = 0
        if isPaused { isPaused = false }
        if isFilterMuting { isFilterMuting = false }
    }

    // MARK: - Playback hooks

    /// Feed the playhead. Returns a seek target when the playhead should jump
    /// past a scene-skip window, otherwise nil. Always recomputes muting.
    /// `allowSkip` is false while the user is scrubbing, so we keep muting in
    /// sync without consuming (or fighting) a scene skip they're seeking through.
    func timeDidUpdate(_ time: TimeInterval, allowSkip: Bool = true) -> TimeInterval? {
        currentTime = time

        // Rewind reset: any skip window now ahead of the playhead is armed
        // again. Runs while paused too, so a rewind made then still counts.
        if !skippedRegionIDs.isEmpty {
            for region in regions where skippedRegionIDs.contains(region.id) && time < region.start {
                skippedRegionIDs.remove(region.id)
            }
        }

        guard isActive else {
            if isFilterMuting { isFilterMuting = false }
            return nil
        }

        guard allowSkip else {
            recomputeMute()
            return nil
        }

        // Jump past every window containing the playhead, then past any that
        // contain the landing point, so back-to-back annotations ("violence"
        // then "gore") cost one seek instead of a visible stutter per window.
        var skipTarget: TimeInterval?
        var probe = time
        var extended = true
        while extended {
            extended = false
            for region in regions where region.action == .skip && acts(on: region) {
                guard !skippedRegionIDs.contains(region.id), region.contains(probe) else { continue }
                skippedRegionIDs.insert(region.id)
                let target = region.end + skipEpsilon
                if target > (skipTarget ?? 0) {
                    skipTarget = target
                }
                extended = true
            }
            if let skipTarget { probe = skipTarget }
        }

        recomputeMute()
        return skipTarget
    }

    /// Feed the currently-visible subtitle text (one entry per active cue).
    /// A match mutes for as long as the cue stays active. Cheap to call every
    /// tick: it early-outs when the on-screen text hasn't changed.
    func activeSubtitlesDidChange(texts: [String]) {
        guard isActive, !enabledCategories.isEmpty else {
            lastSubtitleTexts = texts
            if subtitleMatched { subtitleMatched = false; recomputeMute() }
            return
        }
        if texts == lastSubtitleTexts { return }
        lastSubtitleTexts = texts
        let match = texts.contains { text in
            ProfanityDictionary.shouldMute(
                text: text,
                enabledCategories: enabledCategories,
                profanityThreshold: profanityThreshold)
        }
        if match != subtitleMatched {
            subtitleMatched = match
            recomputeMute()
        }
    }

    /// Tell the filter which external subtitle file is on screen (its Plex
    /// stream key, nil for none or an embedded track) and the user's delay for
    /// it. The delay shifts the subtitle-file windows only when that file is
    /// the one the filter read: the one case where the user's adjustment is
    /// known to describe it. Cheap to call every tick.
    func displayedSubtitleDidChange(streamKey: String?, delay: TimeInterval) {
        let applied = streamKey != nil && streamKey == transcriptStreamKey ? delay : 0
        guard applied != transcriptDelay else { return }
        transcriptDelay = applied
        recomputeMute()
    }

    // MARK: - Pause (rail)

    /// Suspend or resume filtering for the current title only (the player
    /// rail's toggle). The Settings switch is untouched, so the next title is
    /// filtered again.
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        // Re-judge the line on screen from scratch when filtering resumes.
        lastSubtitleTexts = []
        subtitleMatched = false
        recomputeMute()
    }

    /// Install an imported list as this item's regions and re-evaluate the
    /// mute state. The application step for both the disk cache and the fetch.
    func applyList(_ list: ContentFilterList) {
        regions = list.regions
        skippedRegionIDs = []
        recomputeMute()
    }

    /// Install the language windows read from the title's subtitle file.
    func applyTranscript(_ windows: [LanguageWindow]) {
        transcriptWindows = windows
        recomputeMute()
    }

    // MARK: - Decisions

    /// Whether an imported region applies under the current settings.
    /// Profanity Strength governs profanity wherever it's found, so a list's
    /// low-severity swearing is kept exactly like the dictionary's mild words.
    private func acts(on region: FilterRegion) -> Bool {
        guard enabledCategories.contains(region.category) else { return false }
        return region.category != .profanity || region.severity >= profanityThreshold
    }

    private func recomputeMute() {
        guard isActive else {
            if isFilterMuting { isFilterMuting = false }
            return
        }
        let time = currentTime
        // A positive delay shows each cue later, exactly as SubtitleModel does.
        let transcriptTime = time - transcriptDelay
        let shouldMute = subtitleMatched
            || regions.contains { $0.action == .mute && $0.contains(time) && acts(on: $0) }
            || transcriptWindows.contains {
                $0.contains(transcriptTime)
                    && $0.hits.mutes(enabledCategories: enabledCategories, profanityThreshold: profanityThreshold)
            }
        if shouldMute != isFilterMuting {
            isFilterMuting = shouldMute
        }
    }

    // MARK: - Loading

    /// Restore the cached list for this title, then refresh it from the source.
    private func loadList(for item: ContentFilterItem) {
        let candidates = ContentFilterSources.listURLs(template: listSourceURL, item: item)
        guard !candidates.isEmpty else { return }
        let cacheKey = ContentFilterSources.cacheKey(for: candidates)
        if let cached = ContentFilterSources.loadCachedList(key: cacheKey) {
            applyList(cached)
        }

        listTask = Task { [weak self] in
            let outcome = await ContentFilterSources.fetchList(from: candidates, mediaDuration: item.duration)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .found(let list):
                ContentFilterSources.cacheList(list, key: cacheKey)
                self?.applyList(list)
            case .absent:
                // The source no longer has a list for this title: drop the
                // cached copy rather than keep acting on a deleted file.
                ContentFilterSources.removeCachedList(key: cacheKey)
                self?.applyList(.empty)
            case .unreachable:
                break  // offline: the cached list stands
            }
        }
    }

    /// Read the title's subtitle file for language windows.
    private func loadTranscript(for item: ContentFilterItem) {
        guard let source = item.transcript else { return }
        transcriptTask = Task { [weak self] in
            guard let windows = await ContentFilterSources.loadTranscript(source),
                  !Task.isCancelled else { return }
            self?.applyTranscript(windows)
        }
    }
}

// MARK: - Settings

extension ContentFilterManager {

    /// UserDefaults keys shared with the Settings surface. Kept here so the
    /// manager and the Settings page can never drift apart.
    enum Keys {
        static let enabled = "contentFilter.enabled"
        static let profanityStrength = "contentFilter.profanityStrength"
        static let listSourceURL = "contentFilter.listSourceURL"
    }

    /// A snapshot of the persisted settings.
    struct Settings {
        var enabled: Bool
        var profanityThreshold: FilterSeverity
        var listSourceURL: String

        static func load() -> Settings {
            let d = UserDefaults.standard
            let enabled = d.object(forKey: Keys.enabled) == nil ? false : d.bool(forKey: Keys.enabled)
            let rawStrength = d.object(forKey: Keys.profanityStrength) == nil
                ? FilterSeverity.moderate.rawValue
                : d.integer(forKey: Keys.profanityStrength)
            let threshold = FilterSeverity(rawValue: rawStrength) ?? .moderate
            let source = d.string(forKey: Keys.listSourceURL) ?? ""
            return Settings(enabled: enabled, profanityThreshold: threshold, listSourceURL: source)
        }

        func isCategoryEnabled(_ category: FilterCategory) -> Bool {
            let d = UserDefaults.standard
            let key = category.enabledDefaultsKey
            return d.object(forKey: key) == nil ? category.defaultEnabled : d.bool(forKey: key)
        }
    }
}
