// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InsightsActorStaleLoadTests.swift
//  RivuletTests
//
//  End to end through `PersonFilmographyProviding`: a slow actor load that
//  resolves after the user backed out or switched actors never fills the view.
//

import XCTest
@testable import Rivulet

@MainActor
private final class ManuallyResolvableFilmographyProvider: PersonFilmographyProviding {
    private var continuations: [String: CheckedContinuation<PersonDetail, Error>] = [:]

    /// Resolves the in-flight `load(person:)` call for `person.id`, if one
    /// is currently awaited. No-op if none is pending (e.g. the call was
    /// never made, or was already resolved).
    func resolve(personID: String, with detail: PersonDetail) {
        continuations.removeValue(forKey: personID)?.resume(returning: detail)
    }

    /// Runs on the main actor (the caller's `Task {}` inherits it), so registering
    /// the continuation synchronously lets the test call `resolve(...)` right after
    /// with no race.
    nonisolated func load(person: MediaPerson) async throws -> PersonDetail {
        try await withCheckedThrowingContinuation { continuation in
            MainActor.assumeIsolated {
                self.continuations[person.id] = continuation
            }
        }
    }
}

private struct KnownForProvider: PersonFilmographyProviding {
    let onServer: FilmographyEntry
    let titles: [FilmographyEntry]

    func load(person: MediaPerson) async throws -> PersonDetail {
        PersonDetail(id: person.id, name: person.name, biography: nil, portraitURL: nil, movies: [onServer], shows: [])
    }

    func knownFor(person: MediaPerson) async -> [FilmographyEntry] { titles }
}

@MainActor
final class InsightsActorStaleLoadTests: XCTestCase {

    /// #462: Known For fills in behind the library's titles, less any on the server.
    func test_knownFor_addsTitlesNotOnTheServer() async throws {
        func entry(_ tmdbId: Int, _ isOnServer: Bool) -> FilmographyEntry {
            let item = PersonItemMapper.metadataOnlyItem(tmdbId: tmdbId, isMovie: true, title: "\(tmdbId)", year: nil,
                                                         posterURL: nil, overview: nil)
            return FilmographyEntry(item: item, isOnServer: isOnServer, guid: nil, tmdbId: tmdbId)
        }
        let person = makePerson("A")
        let provider = KnownForProvider(onServer: entry(1, true), titles: [entry(1, false), entry(2, false)])
        let container = InsightsPanelContainerView(cast: [person], provider: provider)

        container.crossfadeToActor(person)
        let actor = try XCTUnwrap(container.actorView)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNotNil(actor.detail)
        XCTAssertEqual(actor.knownForCount, 1)
    }

    private func makePerson(_ id: String) -> MediaPerson {
        MediaPerson(id: id, name: "Actor \(id)", role: nil, imageURL: nil)
    }

    private func makeDetail(for person: MediaPerson) -> PersonDetail {
        PersonDetail(id: person.id, name: person.name, biography: "Bio for \(person.name)",
                     portraitURL: nil, movies: [], shows: [])
    }

    /// A slow load that resolves AFTER the user has already backed out to
    /// the cast list must not populate the (now torn-down) actor view.
    func test_lateLoadAfterReturnToList_isDropped() async throws {
        let provider = ManuallyResolvableFilmographyProvider()
        let personA = makePerson("A")
        let container = InsightsPanelContainerView(cast: [personA], provider: provider)

        container.crossfadeToActor(personA)
        let actorViewForA = try XCTUnwrap(container.actorView)
        XCTAssertNil(actorViewForA.detail, "no result has resolved yet")

        // User backs out to the cast list before A's load resolves. Note:
        // `state`/`coordinator.cancel()` fire synchronously inside
        // `reverseCrossfadeToList`, but the actual `actorView = nil` teardown
        // is deferred to the 0.2s crossfade animation's completion block —
        // wait past that before asserting on it below.
        container.reverseCrossfadeToList()

        // A's slow load resolves now — late, after the user moved on.
        provider.resolve(personID: personA.id, with: makeDetail(for: personA))
        // Let the awaiting Task inside crossfadeToActor observe the
        // continuation's result and run its post-await guard.
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(actorViewForA.detail,
                      "a load that resolves after returning to the list must be dropped, not applied")

        // Wait past the reverse-crossfade's animation completion (0.2s) so
        // the deferred `actorView = nil` teardown has actually run.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(container.actorView, "the container should have torn down the actor view on return-to-list")
    }

    /// A slow load for the FIRST actor selected must not populate the
    /// SECOND actor's view when it resolves after the user switched.
    func test_lateLoadAfterSwitchingActors_isDroppedAndDoesNotLeakIntoNewActorView() async throws {
        let provider = ManuallyResolvableFilmographyProvider()
        let personA = makePerson("A")
        let personB = makePerson("B")
        let container = InsightsPanelContainerView(cast: [personA, personB], provider: provider)

        container.crossfadeToActor(personA)
        let actorViewForA = try XCTUnwrap(container.actorView)

        // User backs out and picks a different actor before A's load resolves.
        container.reverseCrossfadeToList()
        container.crossfadeToActor(personB)
        let actorViewForB = try XCTUnwrap(container.actorView)
        XCTAssertFalse(actorViewForA === actorViewForB, "switching actors must build a fresh actor view")

        // A's stale load resolves now.
        provider.resolve(personID: personA.id, with: makeDetail(for: personA))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(actorViewForA.detail, "the stale actor A view must never be populated")
        XCTAssertNil(actorViewForB.detail, "B's slow load hasn't resolved yet, so B must still be unpopulated")

        // B's load resolves — this one IS current and must apply normally.
        provider.resolve(personID: personB.id, with: makeDetail(for: personB))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(actorViewForB.detail?.name, personB.name, "the current actor's own load must still apply")
        XCTAssertNil(actorViewForA.detail, "the stale actor A view must still never be populated")
    }
}
