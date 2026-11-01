// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  Runtime for the local content filter (VOD), owned by UniversalPlayerViewModel.
//  Sources: CLAUDE.md, "Content Filter (VOD)". Muting zeroes the volume and skipping
//  seeks; the media is never modified.
//

import Foundation
import Combine
import Sentry

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

    /// Whether this title has language to mute from with subtitles off: its
    /// subtitle file, or an imported list with mute windows.
    @Published private(set) var hasLanguageSource = false

    /// Whether the imported list has scene skips that apply under the current settings.
    @Published private(set) var hasSceneSkips = false

    // MARK: - Settings snapshot

    private var enabledCategories: Set<FilterCategory> = []
    private var profanityThreshold: FilterSeverity = .moderate
    private var listSourceURL: String = ""
    private var customWords: [String] = []

    // MARK: - Per-item runtime

    /// Windows from the imported list.
    private var regions: [FilterRegion] = []
    /// Every cue of the title's subtitle file, and the ones the settings mute.
    private var transcriptWindows: [LanguageWindow] = []
    private var transcriptMutes: [CueMute] = []
    /// Cues near the playhead from the track the engine is reading, already
    /// on the audio's axis, and the ones the settings mute.
    private var lastLines: [SubtitleLine] = []
    private var liveMutes: [CueMute] = []
    /// Words the speech model heard, and each cue's spans once placed.
    private var spokenWords = SpokenWordStore()
    private var spanMemo: [String: [ClosedRange<Double>]] = [:]
    /// With no subtitles to read, words the model hears are matched directly.
    private var speechOnly = false
    private var speechSpans: [ClosedRange<Double>] = []
    /// Which Plex stream those windows came from, and the subtitle delay to
    /// apply to them (see `displayedSubtitleDidChange`).
    private var transcriptStreamKey: String?
    /// The title has a subtitle file to read; cleared if it can't be read.
    private var hasTranscript = false
    private var transcriptDelay: TimeInterval = 0
    private var skippedRegionIDs: Set<Int> = []
    private var currentTime: TimeInterval = 0
    private var listTask: Task<Void, Never>?
    private(set) var transcriptTask: Task<Void, Never>?

    /// Seek a hair past a skip window so the next tick doesn't re-enter it.
    private let skipEpsilon: TimeInterval = 0.25

    private var isActive: Bool { isEnabled && !isPaused }

    /// Whether any enabled category can be matched from subtitle text.
    var readsSubtitleText: Bool { enabledCategories.contains(where: \.isTextDetectable) }

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
        customWords = s.customWords

        var categories: Set<FilterCategory> = []
        if s.enabled {
            for category in FilterCategory.userToggleable where s.isCategoryEnabled(category) {
                categories.insert(category)
            }
            // `.other` (uncategorized imported regions) rides the master switch.
            categories.insert(.other)
        }
        enabledCategories = categories
        // Categories, strength or the word list may have just changed mid-cue:
        // re-judge every cue under the new rules.
        rebuildMutes()
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
        hasTranscript = item.transcript != nil
        refreshLanguageSource()
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
        transcriptMutes = []
        lastLines = []
        liveMutes = []
        spokenWords = SpokenWordStore()
        spanMemo = [:]
        speechSpans = []
        transcriptStreamKey = nil
        hasTranscript = false
        if hasLanguageSource { hasLanguageSource = false }
        if hasSceneSkips { hasSceneSkips = false }
        transcriptDelay = 0
        skippedRegionIDs = []
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
        // A tick sampled just before a timed mute edge must not undo it.
        if !(time < currentTime && currentTime - time < Self.clockJitter) { currentTime = time }

        // Re-arm a consumed skip window once the playhead is outside it: it
        // stays consumed only while inside, where stale ticks from the seek
        // still in flight would otherwise trigger it twice. Landing past it
        // re-arms it, so a skip back into the scene is skipped again. Runs
        // while paused too, so a seek made then still counts.
        if !skippedRegionIDs.isEmpty {
            for region in regions where skippedRegionIDs.contains(region.id) && !region.contains(time) {
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

    /// Feed the subtitle cues near the playhead from the track the engine is
    /// reading. A muted cue silences its words once the speech model has
    /// placed them, and the whole cue until then. Cheap to call every tick: it
    /// early-outs when the lines haven't changed.
    func subtitleLinesDidChange(_ lines: [SubtitleLine]) {
        guard lines != lastLines else { return }
        lastLines = lines
        liveMutes = lines.compactMap { cueMute(key: "l\($0.id)", start: $0.start, end: $0.end, text: $0.text) }
        recomputeMute()
    }

    /// Words the speech model heard in `range` of the source axis.
    func wordsHeard(_ words: [SpokenWord], covering range: ClosedRange<Double>) {
        spokenWords.add(words, covering: range)
        if speechOnly {
            speechSpans = SpokenWordAlignment.merged(speechSpans + spans(spokenIn: words))
        }
        recomputeMute()
    }

    /// Whether words heard with no subtitles behind them are filtered.
    func setSpeechOnly(_ on: Bool) {
        guard on != speechOnly else { return }
        speechOnly = on
        speechSpans = on ? spans(spokenIn: spokenWords.words) : []
        recomputeMute()
    }

    /// The next time the mute decision changes after `time`, within a second,
    /// so the player can act on it between ticks.
    func nextMuteEdge(after time: TimeInterval) -> TimeInterval? {
        guard isActive else { return nil }
        let horizon = time + 1
        var edges = regions.filter { $0.action == .mute && acts(on: $0) }.flatMap { [$0.start, $0.end] }
        edges += muteSpans(near: time...horizon).flatMap { [$0.lowerBound, $0.upperBound] }
        return edges.filter { $0 > time && $0 <= horizon }.min()
    }

    /// Re-judge at `time`, reached between ticks by the player's own clock.
    func clockDidReach(_ time: TimeInterval) {
        currentTime = time
        recomputeMute()
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
        recomputeMute()
    }

    /// Install an imported list as this item's regions and re-evaluate the
    /// mute state. The application step for both the disk cache and the fetch.
    func applyList(_ list: ContentFilterList) {
        regions = list.regions
        skippedRegionIDs = []
        refreshLanguageSource()
        recomputeMute()
    }

    /// Install the language windows read from the title's subtitle file.
    func applyTranscript(_ windows: [LanguageWindow]) {
        transcriptWindows = windows
        rebuildMutes()
        hasTranscript = true
        refreshLanguageSource()
        recomputeMute()
    }

    private func refreshLanguageSource() {
        // A muted scene (violence=audio) is no language source; uncategorised EDL mutes are.
        let has = hasTranscript || regions.contains {
            $0.action == .mute && ($0.category.isTextDetectable || $0.category == .other) && acts(on: $0)
        }
        if has != hasLanguageSource { hasLanguageSource = has }
        let skips = regions.contains { $0.action == .skip && acts(on: $0) }
        if skips != hasSceneSkips { hasSceneSkips = skips }
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
        let shouldMute = regions.contains { $0.action == .mute && $0.contains(time) && acts(on: $0) }
            || muteSpans(near: time...time).contains { $0.lowerBound <= time && time < $0.upperBound }
        if shouldMute != isFilterMuting {
            isFilterMuting = shouldMute
        }
    }

    // MARK: - Word timing

    /// A cue the settings mute, with the positions of the words to silence.
    private struct CueMute {
        let key: String
        let start: TimeInterval
        let end: TimeInterval
        let tokens: [String]
        let flagged: Set<Int>
    }

    /// Ticks that land this close behind a timed edge are stale, not a seek.
    private static let clockJitter: TimeInterval = 0.25
    /// Words heard with no subtitles must be this sure before they mute.
    private static let speechOnlyConfidence: Float = 0.6

    private func cueMute(key: String, start: TimeInterval, end: TimeInterval, text: String) -> CueMute? {
        let flagged = ProfanityDictionary.matches(in: text, customTerms: customWords)
            .filter { $0.mutes(enabledCategories: enabledCategories, profanityThreshold: profanityThreshold) }
            .flatMap { Array($0.tokens) }
        guard !flagged.isEmpty else { return nil }
        return CueMute(key: key, start: start, end: end,
                       tokens: ProfanityDictionary.tokens(of: text), flagged: Set(flagged))
    }

    private func rebuildMutes() {
        spanMemo = [:]
        transcriptMutes = transcriptWindows.enumerated().compactMap { index, window in
            cueMute(key: "t\(index)", start: window.start, end: window.end, text: window.text)
        }
        liveMutes = lastLines.compactMap { cueMute(key: "l\($0.id)", start: $0.start, end: $0.end, text: $0.text) }
        speechSpans = speechOnly ? spans(spokenIn: spokenWords.words) : []
    }

    /// Every mute span from language that could touch `range`: a cue's placed
    /// words, or the whole cue while the speech model hasn't covered it.
    private func muteSpans(near range: ClosedRange<Double>) -> [ClosedRange<Double>] {
        let margin = SpokenWordAlignment.searchMargin
        var spans = speechSpans.filter { $0.overlaps(range) }
        for (cue, shift) in transcriptMutes.map({ ($0, transcriptDelay) }) + liveMutes.map({ ($0, 0.0) })
        where cue.start + shift - margin <= range.upperBound && cue.end + shift + margin >= range.lowerBound {
            spans += self.spans(for: cue, shift: shift)
        }
        return spans
    }

    private func spans(for cue: CueMute, shift: TimeInterval) -> [ClosedRange<Double>] {
        let start = cue.start + shift, end = cue.end + shift
        let search = SpokenWordAlignment.searchRange(cueStart: start, cueEnd: end)
        let key = "\(cue.key)@\(start)"
        if let memo = spanMemo[key] { return memo }
        guard let heardUntil = spokenWords.heardUntil(from: search.lowerBound), heardUntil > start else {
            return [start...end]
        }
        let placed = SpokenWordAlignment.muteSpans(
            cueStart: start, cueEnd: end, tokens: cue.tokens, flagged: cue.flagged,
            words: spokenWords.words(in: search.lowerBound...min(search.upperBound, heardUntil)))
        if heardUntil >= search.upperBound {
            let result = placed ?? [start...end]
            spanMemo[key] = result
            return result
        }
        // Part of the line is still unheard: act on a placement only when every
        // muted word sits inside what was heard, else hold the whole cue.
        guard let placed, placed.allSatisfy({ $0.upperBound <= heardUntil + SpokenWordAlignment.tailPad }) else {
            return [start...end]
        }
        return placed
    }

    /// Mute spans for filtered words among `words`, matched on their own
    /// (phrases across words included) rather than against a subtitle line.
    private func spans(spokenIn words: [SpokenWord]) -> [ClosedRange<Double>] {
        let sure = words.filter { $0.confidence >= Self.speechOnlyConfidence }
        var owner: [Int] = []   // token index -> word index
        for (index, word) in sure.enumerated() {
            owner += Array(repeating: index, count: ProfanityDictionary.tokens(of: word.text).count)
        }
        let text = sure.map(\.text).joined(separator: " ")
        let spans = ProfanityDictionary.matches(in: text, customTerms: customWords)
            .filter { $0.mutes(enabledCategories: enabledCategories, profanityThreshold: profanityThreshold) }
            .compactMap { match -> ClosedRange<Double>? in
                guard match.tokens.upperBound <= owner.count else { return nil }
                let first = sure[owner[match.tokens.lowerBound]], last = sure[owner[match.tokens.upperBound - 1]]
                return SpokenWordAlignment.padded(first.start...last.end)
            }
        return SpokenWordAlignment.merged(spans)
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
            let windows = await ContentFilterSources.loadTranscript(source)
            guard !Task.isCancelled, let self else { return }
            guard let windows else {
                // The rail says so; the URL carries a token and is never logged.
                self.hasTranscript = false
                self.refreshLanguageSource()
                SentryBridge.log(.warn, "Content filter: subtitle file unavailable")
                return
            }
            self.applyTranscript(windows)
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
        static let customWords = "contentFilter.customWords"
    }

    /// A snapshot of the persisted settings.
    struct Settings {
        var enabled: Bool
        var profanityThreshold: FilterSeverity
        var listSourceURL: String
        var customWords: [String] = []

        static func load() -> Settings {
            let d = UserDefaults.standard
            let enabled = d.object(forKey: Keys.enabled) == nil ? false : d.bool(forKey: Keys.enabled)
            let rawStrength = d.object(forKey: Keys.profanityStrength) == nil
                ? FilterSeverity.moderate.rawValue
                : d.integer(forKey: Keys.profanityStrength)
            let threshold = FilterSeverity(rawValue: rawStrength) ?? .moderate
            let source = d.string(forKey: Keys.listSourceURL) ?? ""
            let words = d.stringArray(forKey: Keys.customWords) ?? []
            return Settings(enabled: enabled, profanityThreshold: threshold, listSourceURL: source,
                            customWords: words)
        }

        func isCategoryEnabled(_ category: FilterCategory) -> Bool {
            let d = UserDefaults.standard
            let key = category.enabledDefaultsKey
            return d.object(forKey: key) == nil ? category.defaultEnabled : d.bool(forKey: key)
        }
    }

    /// The user's own words to mute, in the order they were added.
    static var customWords: [String] {
        get { UserDefaults.standard.stringArray(forKey: Keys.customWords) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.customWords) }
    }

    /// Add a word or phrase as typed; ignores blanks and repeats.
    static func addCustomWord(_ raw: String) {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !word.isEmpty, !customWords.contains(word) else { return }
        customWords.append(word)
    }
}
