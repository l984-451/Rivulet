// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  AudioLanguageGate.swift
//  Rivulet
//
//  Settings > Playback > Only My Audio Language: Continue Watching and Favorites leave out titles
//  with no audio track in the Audio Language chosen beside it. A show counts by its next unwatched
//  episode, so it comes back once that episode has the language. Off by default, and off while the
//  Audio Language is Original or unset. A title whose tracks its server does not report stays.
//
//  Answers are kept across launches so a list shows at once: only a title never asked waits for its
//  server. An answer older than `lifetime` is still used, and asked again behind it.
//

import Foundation

@MainActor
enum AudioLanguageGate {
    static let enabledKey = "onlyPreferredAudioLanguage"
    static let storageKey = "audioLanguageGate.answers"
    /// An answer older than this is asked again, behind the list that used it.
    static let lifetime: TimeInterval = 30 * 60
    /// An answer older than this is dropped, so titles long gone from every list do not pile up.
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    typealias ProviderLookup = @MainActor (String) -> (any MediaProvider)?

    private struct Answer: Codable { let has: Bool; let at: Date }

    private static var answers: [String: Answer] = stored()

    /// The language titles must have (a `TrackLanguage.normalize` code), or nil while the gate is off.
    static var language: String? {
        guard UserDefaults.standard.bool(forKey: enabledKey),
              let raw = TrackIntentStore.audioIntent?.language else { return nil }
        let code = TrackLanguage.normalize(raw)
        return code.isEmpty || code == TrackLanguage.original ? nil : code
    }

    /// `items` without the titles known to lack the chosen language. Waits only for titles never asked.
    static func filter(_ items: [MediaItem]) async -> [MediaItem] {
        await filter(items, language: language)
    }

    /// `filter` for a given language (nil keeps everything).
    static func filter(
        _ items: [MediaItem],
        language: String?,
        now: Date = Date(),
        providerFor: @escaping ProviderLookup = { MediaProviderRegistry.shared.provider(for: $0) }
    ) async -> [MediaItem] {
        guard let language, !items.isEmpty else { return items }
        let unknown = items.filter { answers[key($0.ref, language)] == nil }
        let stale = items.filter { answers[key($0.ref, language)].map { now.timeIntervalSince($0.at) > lifetime } ?? false }
        if !unknown.isEmpty { await ask(unknown, language: language, now: now, providerFor: providerFor) }
        if !stale.isEmpty { Task { await ask(stale, language: language, now: Date(), providerFor: providerFor) } }
        return items.filter { answers[key($0.ref, language)]?.has ?? true }
    }

    /// Forgets every answer. Tests.
    static func forgetAnswers() {
        answers = [:]
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private static func ask(_ items: [MediaItem], language: String, now: Date, providerFor: ProviderLookup) async {
        for (providerID, group) in Dictionary(grouping: items, by: \.ref.providerID) {
            guard let provider = providerFor(providerID) else { continue }
            for (ref, has) in await provider.audioLanguageAvailability(language, for: group) {
                answers[key(ref, language)] = Answer(has: has, at: now)
            }
        }
        answers = answers.filter { now.timeIntervalSince($0.value.at) < retention }
        if let data = try? JSONEncoder().encode(answers) { UserDefaults.standard.set(data, forKey: storageKey) }
    }

    private static func key(_ ref: MediaItemRef, _ language: String) -> String {
        "\(language)|\(ref.providerID)|\(ref.itemID)"
    }

    private static func stored() -> [String: Answer] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let answers = try? JSONDecoder().decode([String: Answer].self, from: data) else { return [:] }
        return answers
    }
}
