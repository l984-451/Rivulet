import XCTest
@testable import Rivulet

@MainActor
final class PlexThemeMusicTests: XCTestCase {

    private final class StubNetwork: PlexNetworkManager, @unchecked Sendable {
        var metadata: [String: PlexMetadata] = [:]
        var calls: [String] = []

        override func getFullMetadata(serverURL: String, authToken: String, ratingKey: String) async throws -> PlexMetadata {
            calls.append(ratingKey)
            guard let meta = metadata[ratingKey] else { throw PlexAPIError.invalidURL }
            return meta
        }
    }

    private func meta(_ json: String) throws -> PlexMetadata {
        try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
    }

    private func provider(_ network: StubNetwork) -> PlexProvider {
        PlexProvider(machineIdentifier: "m1", displayName: "Plex", serverURL: "http://plex.test:32400",
                     authToken: "t", networkManager: network)
    }

    func test_aShowAnswersWithItsOwnTheme() async throws {
        let network = StubNetwork()
        network.metadata["10"] = try meta(#"{"ratingKey":"10","type":"show","theme":"/library/metadata/10/theme/123"}"#)
        let plex = provider(network)
        let url = try await plex.themeMusicURL(for: MediaItemRef(providerID: plex.id, itemID: "10"))
        XCTAssertEqual(url?.absoluteString, "http://plex.test:32400/library/metadata/10/theme/123?X-Plex-Token=t")
    }

    func test_aSeasonAndAnEpisodeAnswerWithTheirShows() async throws {
        let network = StubNetwork()
        network.metadata["11"] = try meta(#"{"ratingKey":"11","type":"season","parentTheme":"/library/metadata/10/theme/123"}"#)
        network.metadata["12"] = try meta(#"{"ratingKey":"12","type":"episode","grandparentTheme":"/library/metadata/10/theme/123"}"#)
        let plex = provider(network)
        let season = try await plex.themeMusicURL(for: MediaItemRef(providerID: plex.id, itemID: "11"))
        let episode = try await plex.themeMusicURL(for: MediaItemRef(providerID: plex.id, itemID: "12"))
        XCTAssertEqual(season?.path, "/library/metadata/10/theme/123")
        XCTAssertEqual(episode?.path, "/library/metadata/10/theme/123")
    }

    func test_noThemeIsNil() async throws {
        let network = StubNetwork()
        network.metadata["10"] = try meta(#"{"ratingKey":"10","type":"show"}"#)
        let plex = provider(network)
        let url = try await plex.themeMusicURL(for: MediaItemRef(providerID: plex.id, itemID: "10"))
        XCTAssertNil(url)
    }

    func test_anotherServersItemIsNilWithNoRequest() async throws {
        let network = StubNetwork()
        let plex = provider(network)
        let url = try await plex.themeMusicURL(for: MediaItemRef(providerID: "plex:other", itemID: "10"))
        XCTAssertNil(url)
        XCTAssertTrue(network.calls.isEmpty)
    }
}
