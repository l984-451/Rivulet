// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// The request each server wants for its original file, measured on Jellyfin 12.1 and Emby 4.10:
/// Jellyfin takes the file only with the Authorization header (api_key answers 401) and Emby with
/// api_key in the query; neither answers HEAD, both honor Range, and a user with downloading off gets 403.
@MainActor
final class ProviderDownloadSourceTests: XCTestCase {
    private let jelly = FakeJellyfinServer()
    private let emby = FakeEmbyServer()
    private let embyUser = "u-emby"

    private func jellyfin() -> JellyfinProvider {
        JellyfinProvider(serverID: "srv", displayName: "NAS", userID: "user-1",
                         client: JellyfinClient(baseURL: JellyfinFixtures.baseURL, token: "jf-token", transport: jelly.transport))
    }

    private func embyProvider() -> EmbyProvider {
        EmbyProvider(serverID: "srv", displayName: "Emby", userID: embyUser, policy: EmbySession.Policy(),
                     client: EmbyClient(baseURL: EmbyBrowseFixtures.baseURL, token: "em-token", transport: emby.transport))
    }

    private func ref(_ kind: String, _ id: String) -> MediaItemRef { MediaItemRef(providerID: "\(kind):srv", itemID: id) }

    // MARK: - Jellyfin

    func test_jellyfin_sourceIsTheDownloadRouteWithTheHeaderAndNoKeyInTheURL() async throws {
        let source = try await jellyfin().downloadSource(for: ref("jellyfin", "m1"), sourceID: nil)
        XCTAssertEqual(source.url.path, "/Items/m1/Download")
        XCTAssertNil(source.url.query)
        let header = try XCTUnwrap(source.headers["Authorization"])
        XCTAssertTrue(header.hasPrefix("MediaBrowser "))
        XCTAssertTrue(header.contains(#"Token="jf-token""#))
        XCTAssertFalse(source.url.absoluteString.contains("jf-token"))
        XCTAssertEqual(source.request.value(forHTTPHeaderField: "Authorization"), header)
        XCTAssertEqual(source.request.httpMethod, "GET")
    }

    func test_jellyfin_aChosenVersionIsItsOwnItem() async throws {
        let source = try await jellyfin().downloadSource(for: ref("jellyfin", "m1"), sourceID: "m1-4k")
        XCTAssertEqual(source.url.path, "/Items/m1-4k/Download")
    }

    func test_jellyfin_canDownload_followsThePolicyFlag() async {
        jelly.respond("/Users/Me", body: #"{"Policy":{"IsAdministrator":false,"EnableContentDownloading":true}}"#)
        let allowed = try? await jellyfin().canDownloadMedia()
        XCTAssertEqual(allowed, true)
    }

    func test_jellyfin_canDownload_falseWhenTheFlagIsOff() async {
        jelly.respond("/Users/Me", body: #"{"Policy":{"IsAdministrator":false,"EnableContentDownloading":false}}"#)
        let allowed = try? await jellyfin().canDownloadMedia()
        XCTAssertEqual(allowed, false)
    }

    func test_jellyfin_canDownload_anAdministratorPasses() async {
        jelly.respond("/Users/Me", body: #"{"Policy":{"IsAdministrator":true,"EnableContentDownloading":false}}"#)
        let allowed = try? await jellyfin().canDownloadMedia()
        XCTAssertEqual(allowed, true)
    }

    func test_jellyfin_canDownload_unreadablePolicyThrowsAndIsNotRemembered() async throws {
        let provider = jellyfin()
        do {
            _ = try await provider.canDownloadMedia()
            XCTFail("an unread policy is not an answer")
        } catch MediaProviderError.unreachable {
        } catch {
            XCTFail("\(error)")
        }
        jelly.respond("/Users/Me", body: #"{"Policy":{"IsAdministrator":false,"EnableContentDownloading":true}}"#)
        let second = try await provider.canDownloadMedia()
        XCTAssertTrue(second)
    }

    // MARK: - Emby

    func test_emby_sourceCarriesTheKeyAndTheVersionInTheQuery() async throws {
        let source = try await embyProvider().downloadSource(for: ref("emby", "813"), sourceID: "mediasource_813")
        XCTAssertEqual(source.url.path, "/Items/813/Download")
        let query = URLComponents(url: source.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "api_key" }?.value, "em-token")
        XCTAssertEqual(query.first { $0.name == "MediaSourceId" }?.value, "mediasource_813")
        XCTAssertEqual(source.request.httpMethod, "GET")
    }

    func test_emby_noVersionLeavesTheParameterOut() async throws {
        let source = try await embyProvider().downloadSource(for: ref("emby", "813"), sourceID: nil)
        let query = URLComponents(url: source.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertNil(query.first { $0.name == "MediaSourceId" })
        XCTAssertNotNil(query.first { $0.name == "api_key" })
    }

    func test_emby_canDownload_followsThePolicyFlag() async {
        emby.respond("/Users/\(embyUser)", body: #"{"Id":"u","Policy":{"IsAdministrator":false,"EnableContentDownloading":true}}"#)
        let allowed = try? await embyProvider().canDownloadMedia()
        XCTAssertEqual(allowed, true)
    }

    func test_emby_canDownload_falseWhenTheFlagIsOff() async {
        emby.respond("/Users/\(embyUser)", body: #"{"Id":"u","Policy":{"IsAdministrator":false,"EnableContentDownloading":false}}"#)
        let allowed = try? await embyProvider().canDownloadMedia()
        XCTAssertEqual(allowed, false)
    }

    func test_emby_canDownload_aFlagTheServerOmitsMeansYes() async {
        emby.respond("/Users/\(embyUser)", body: #"{"Id":"u","Policy":{"IsAdministrator":false}}"#)
        let allowed = try? await embyProvider().canDownloadMedia()
        XCTAssertEqual(allowed, true)
    }

    // MARK: - Plex and the default

    func test_plex_saysYesAndHasNoDirectSource() async {
        let plex = PlexProvider(machineIdentifier: "m", displayName: "P", serverURL: "http://p:32400", authToken: "t")
        let allowed = try? await plex.canDownloadMedia()
        XCTAssertEqual(allowed, true)
        do {
            _ = try await plex.downloadSource(for: ref("plex", "1"), sourceID: nil)
            XCTFail("Plex downloads through its conversion queue")
        } catch is MediaProviderError {
        } catch {
            XCTFail("\(error)")
        }
    }

    func test_aProviderThatAdoptsNothingCannotDownload() async {
        let stub = StubMediaProvider()
        let allowed = try? await stub.canDownloadMedia()
        XCTAssertEqual(allowed, false)
        do {
            _ = try await stub.downloadSource(for: ref("stub", "1"), sourceID: nil)
            XCTFail("unsupported")
        } catch is MediaProviderError {
        } catch {
            XCTFail("\(error)")
        }
    }
}
