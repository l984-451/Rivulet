// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class ContentRouterQualityTests: XCTestCase {
    private func metadata() throws -> PlexMetadata {
        let json = #"{"ratingKey":"1","type":"movie","Media":[{"id":1,"container":"mkv","bitrate":40000,"# +
            #""Part":[{"id":2,"key":"/library/parts/2/file.mkv"}]}]}"#
        return try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
    }

    private func plan(step: QualityStep?) throws -> PlaybackPlan {
        var context = ContentRoutingContext(
            metadata: try metadata(),
            serverURL: URL(string: "http://192.168.1.140:32400")!,
            authToken: "t",
            playbackPolicy: .directPlayFirst
        )
        context.transcodeStep = step
        return ContentRouter.plan(for: context)
    }

    func test_step_routesToHLSOnly() throws {
        let plan = try plan(step: QualityStep.step(kbps: 8000))
        guard case .hls = plan.primary else { return XCTFail("expected hls, got \(plan.primary)") }
        XCTAssertTrue(plan.fallbacks.isEmpty)
    }

    func test_noStep_isUnchanged() throws {
        let plan = try plan(step: nil)
        guard case .aether = plan.primary else { return XCTFail("expected aether, got \(plan.primary)") }
        XCTAssertEqual(plan.fallbacks.count, 1)
        guard case .hls = plan.fallbacks.first else { return XCTFail("expected hls fallback") }
    }
}

final class ServerOrderTests: XCTestCase {
    private func media(_ id: Int, _ res: String, kbps: Int) -> PlexMedia {
        PlexMedia(id: id, duration: nil, bitrate: kbps, width: nil, height: nil, aspectRatio: nil,
                  audioChannels: nil, audioCodec: nil, videoCodec: nil, videoResolution: res,
                  container: nil, videoFrameRate: nil, Part: nil)
    }

    func test_serverOrder_undoesSelect() {
        let server = [media(1, "sd", kbps: 1500), media(2, "4k", kbps: 60000), media(3, "1080", kbps: 10000)]
        for (choice, cap) in [(VersionChoice.best, nil), (.best, 15000), (.source("1"), nil), (.source("3"), 1500)] as [(VersionChoice, Int?)] {
            let picked = VersionRanking.select(choice, in: server, capKbps: cap)
            let restored = UniversalPlayerViewModel.serverOrder(picked.media, playingIndex: picked.serverIndex)
            XCTAssertEqual(restored.map(\.id), [1, 2, 3], "\(choice) cap \(String(describing: cap))")
        }
    }
}
