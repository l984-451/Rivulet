import XCTest
@testable import Rivulet

@MainActor
final class SiloPlaybackPreferencesTests: XCTestCase {
    private func service(_ server: SiloAuthTestServer, owner: @escaping @Sendable () async -> Bool = { true }) -> SiloPlaybackPreferences {
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid")!, profileID: "profile-a", transport: server.transport)
        return SiloPlaybackPreferences(provider: SiloProvider(serverID: "server-a", displayName: "Synthetic",
            profileID: "profile-a", client: client), ownerIsCurrent: owner)
    }

    private func capability(_ server: SiloAuthTestServer, revision: Int = 23, available: Bool = true) async {
        await server.respond("GET", "/api/v2/settings/contract/capabilities", [.init(body:
            """
            {"state":"\(available ? "available" : "disabled")","allowed":true,
             "manifest_revision":\(revision),"supports_batched_effective":true}
            """)])
    }

    func testIndependentQualityAxesAndNarrowerScopeArePreserved() async throws {
        let server = SiloAuthTestServer()
        await capability(server)
        await server.respond("GET", "/api/v2/settings/values/effective", [.init(body: """
        {"revision":23,"items":[
          {"key":"playback.preferred_quality","value":"1080p","source":"profile_library",
           "scope":"profile_library","profile_id":"profile-a","library_id":"42"},
          {"key":"playback.max_bitrate_kbps","value":6000,"source":"profile_device",
           "scope":"profile_device","profile_id":"profile-a","device_id":"device-a",
           "stored_value":10000,"constrained":true},
          {"key":"playback.audio_language","value":"fr","source":"profile_device",
           "scope":"profile_device","profile_id":"profile-a"},
          {"key":"playback.buffering_quality_mode","value":"ask","source":"profile","scope":"profile"},
          {"key":"future.setting","value":true,"source":"default"}]}
        """)])
        let result = try await service(server).effective(libraryID: 42, seriesID: "series-a")
        guard case .resolved(let quality) = result.preferredQuality,
              case .resolved(let bitrate) = result.maxBitrateKbps,
              case .resolved(let audio) = result.audioLanguage,
              case .resolved(let buffering) = result.bufferingQualityMode else { return XCTFail("Expected resolved rows") }
        XCTAssertEqual(quality.value, "1080p")
        XCTAssertEqual(quality.source, .profileLibrary)
        XCTAssertEqual(quality.libraryId, "42")
        XCTAssertEqual(bitrate.value, 6000)
        XCTAssertEqual(bitrate.storedValue, .integer(10000))
        XCTAssertTrue(bitrate.constrained)
        XCTAssertEqual(audio.source, .profileDevice)
        XCTAssertEqual(buffering.value, .ask)
        let calls = await server.requests()
        let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(calls.last?.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first(where: { $0.name == "library_ids" })?.value, "42")
        XCTAssertEqual(query.first(where: { $0.name == "series_ids" })?.value, "series-a")
        XCTAssertFalse(query.contains { $0.value?.contains("theme") == true })
        XCTAssertTrue(calls.allSatisfy { $0.httpMethod == "GET" })
    }

    func testNullUnknownAndMissingRemainDistinct() async throws {
        let server = SiloAuthTestServer()
        await capability(server)
        await server.respond("GET", "/api/v2/settings/values/effective", [.init(body: """
        {"revision":23,"items":[
          {"key":"playback.subtitle_language","value":null,"source":"default"},
          {"key":"playback.subtitle_mode","value":"future_mode","source":"profile_series",
           "scope":"profile_series","series_id":"series-a","stored_value":null},
          {"key":"playback.buffering_quality_mode","value":"future_mode","source":"profile_device"}]}
        """)])
        let result = try await service(server).effective()
        guard case .resolved(let language) = result.subtitleLanguage,
              case .resolved(let mode) = result.subtitleMode,
              case .resolved(let buffering) = result.bufferingQualityMode else { return XCTFail("Rows disappeared") }
        XCTAssertNil(language.value)
        XCTAssertEqual(language.rawValue, .null)
        XCTAssertNil(mode.value)
        XCTAssertEqual(mode.storedValue, .null)
        XCTAssertEqual(mode.source, .profileSeries)
        XCTAssertNil(buffering.value)
        XCTAssertEqual(buffering.rawValue, .string("future_mode"))
        XCTAssertEqual(result.showForcedSubtitles, .unavailable)
    }

    func testDisabledAndOldContractDoNotClaimSyncedDefaults() async throws {
        let disabled = SiloAuthTestServer()
        await capability(disabled, available: false)
        let disabledValues = try await service(disabled).effective()
        XCTAssertEqual(disabledValues.preferredQuality, .unavailable)
        let disabledRequests = await disabled.requests()
        XCTAssertEqual(disabledRequests.count, 1)

        let old = SiloAuthTestServer()
        await capability(old, revision: 22)
        await old.respond("GET", "/api/v2/settings/values/effective", [.init(body: #"{"revision":22,"items":[]}"#)])
        let values = try await service(old).effective()
        XCTAssertEqual(values.bufferingQualityMode, .unavailable)
        let oldRequests = await old.requests()
        let query = URLComponents(url: try XCTUnwrap(oldRequests.last?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertFalse(query.contains { $0.value == SiloPlaybackSettingKey.bufferingQualityMode.rawValue })
    }

    func testOwnerChangeDuringReadDiscardsResponse() async throws {
        let server = SiloAuthTestServer()
        await capability(server)
        let gate = SiloAuthRequestGate()
        await server.respond("GET", "/api/v2/settings/values/effective", [.init(body: #"{"revision":23,"items":[]}"#, gate: gate)])
        let owner = OwnerFlag()
        let api = service(server, owner: { await owner.current })
        let task = Task { try await api.effective() }
        await fulfillment(of: [gate.entered], timeout: 2)
        await owner.expire()
        await gate.release()
        do { _ = try await task.value; XCTFail("Stale result escaped") }
        catch SiloPlaybackPreferencesError.staleAuthority { }
    }
}

private actor OwnerFlag {
    private(set) var current = true
    func expire() { current = false }
}

extension SiloPlaybackPreferencesTests {
    func testSchemaKeepsOnlyPlaybackDefinitions() async throws {
        let server = SiloAuthTestServer()
        await capability(server)
        await server.respond("GET", "/api/v2/settings/contract", [.init(body: """
        {"revision":23,"definitions":[
          {"key":"player.subtitle_sync_ms","introduced_in":1,
           "allowed_scopes":[{"scope":"profile","introduced_in":19},"profile_device"],
           "resolution_order":["profile_device","profile","default"],
           "value_schema":{"type":"integer"},"default_value":0},
          {"key":"ui.theme","introduced_in":1,"allowed_scopes":{"future":"shape"},
           "resolution_order":["profile","default"],"value_schema":{"type":"string"},"default_value":"light"},
          {"key":"playback.audio_language","introduced_in":1,
           "allowed_scopes":["profile_device","profile"],
           "resolution_order":["profile_device","profile","default"],
           "value_schema":{"type":"string"},"default_value":null},
          {"key":"playback.subtitle_mode","introduced_in":1,
           "allowed_scopes":[{"scope":"profile","introduced_in":1},"profile_device"],
           "resolution_order":["profile_device","profile","default"],
           "value_schema":{"type":"string"},"default_value":"auto"}]}
        """)])
        let fetchedSchema = try await service(server).schema()
        let schema = try XCTUnwrap(fetchedSchema)
        XCTAssertEqual(schema.definitions.count, 2)
        XCTAssertEqual(schema.definitions[.audioLanguage]?.resolutionOrder.first, "profile_device")
        XCTAssertEqual(schema.definitions[.audioLanguage]?.defaultValue, .null)
        XCTAssertEqual(schema.definitions[.subtitleMode]?.allowedScopes, ["profile", "profile_device"])
        XCTAssertEqual(schema.definitions[.subtitleMode]?.defaultValue, .string("auto"))
        XCTAssertEqual(schema.definitions[.subtitleMode]?.introducedIn, 1)
    }

    /// The contract's own language tags drive the picker, whatever spelling the
    /// snake-case key strategy gives the option set's name.
    func testSchemaPublishesContractLanguageTagsAtItsRevision() async throws {
        let server = SiloAuthTestServer()
        await capability(server)
        await server.respond("GET", "/api/v2/settings/contract", [.init(body: """
        {"revision":23,"option_sets":{"playback_subtitle_languages":{"type":"language_tag","options":[
           {"value":"nl","introduced_in":1},{"value":"en","introduced_in":1},
           {"value":"zh-Hans","introduced_in":8},{"value":"xx","introduced_in":24}]}},
         "definitions":[{"key":"playback.subtitle_language","introduced_in":1,
           "allowed_scopes":["profile"],"resolution_order":["profile","default"],
           "value_schema":{"type":"language_tag","nullable":true},"default_value":null}]}
        """)])
        let fetched = try await service(server).schema()
        let schema = try XCTUnwrap(fetched)
        XCTAssertEqual(schema.subtitleLanguages, ["nl", "en", "zh-Hans"])

        // An older contract must not offer tags it does not know yet.
        let older = SiloAuthTestServer()
        await capability(older, revision: 1)
        await older.respond("GET", "/api/v2/settings/contract", [.init(body: """
        {"revision":1,"option_sets":{"playback_subtitle_languages":{"type":"language_tag","options":[
           {"value":"nl","introduced_in":1},{"value":"zh-Hans","introduced_in":8}]}},
         "definitions":[]}
        """)])
        let fetchedOld = try await service(older).schema()
        let oldSchema = try XCTUnwrap(fetchedOld)
        XCTAssertEqual(oldSchema.subtitleLanguages, ["nl"])
    }

    func testMalformedSupportedScopeDoesNotClaimPlaybackSchema() async throws {
        let server = SiloAuthTestServer()
        await capability(server)
        await server.respond("GET", "/api/v2/settings/contract", [.init(body: """
        {"revision":23,"definitions":[
          {"key":"playback.audio_language","introduced_in":1,
           "allowed_scopes":[{"scope":"profile"}],
           "resolution_order":["profile","default"],
           "value_schema":{"type":"string"},"default_value":null}]}
        """)])
        do {
            _ = try await service(server).schema()
            XCTFail("Malformed supported definition was accepted")
        } catch SiloSignInError.invalidResponse { }
    }
}
