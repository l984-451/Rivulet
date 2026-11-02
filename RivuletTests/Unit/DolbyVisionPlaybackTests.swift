// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class DolbyVisionPlaybackTests: XCTestCase {

    private func playback(_ profile: Int?, converted: Bool = false, dv: Bool = false, hdr: Bool = false) -> DolbyVisionPlayback? {
        DolbyVisionPlayback(sourceProfile: profile, convertedTo81: converted, presentsDolbyVision: dv, presentsHDR: hdr)
    }

    func test_notDolbyVision_hasNoLabel() {
        XCTAssertNil(playback(nil, dv: true, hdr: true))
    }

    func test_profile7_eachRoute() {
        XCTAssertEqual(playback(7, dv: true, hdr: true), .dualLayer)
        XCTAssertEqual(playback(7, converted: true, dv: true, hdr: true), .convertedTo81)
        XCTAssertEqual(playback(7, hdr: true), .hdr10BaseLayer)
    }

    func test_profile7_softwareRoute_isDualLayer() {
        let p = DolbyVisionPlayback(sourceProfile: 7, convertedTo81: false, onSoftwareRoute: true,
                                    presentsDolbyVision: false, presentsHDR: false)
        XCTAssertEqual(p, .dualLayer)
        XCTAssertEqual(DolbyVisionPlayback(sourceProfile: 8, convertedTo81: false, onSoftwareRoute: true,
                                           presentsDolbyVision: false, presentsHDR: false), .sdr)
    }

    func test_singleLayerProfiles() {
        XCTAssertEqual(playback(8, dv: true, hdr: true), .dolbyVision)
        XCTAssertEqual(playback(5, dv: true, hdr: true), .dolbyVision)
        XCTAssertEqual(playback(8), .sdr)
    }

    // #438: an unproven panel reads SDR in the engine; a Dolby Vision TV is "not confirmed" instead.
    func test_unprovenPanel_onDolbyVisionTV_isNotConfirmed() {
        func unproven(_ profile: Int, converted: Bool = false, panelDV: Bool) -> DolbyVisionPlayback? {
            DolbyVisionPlayback(sourceProfile: profile, convertedTo81: converted, presentsDolbyVision: false,
                                presentsHDR: false, panelSupportsDolbyVision: panelDV)
        }
        XCTAssertEqual(unproven(8, panelDV: true), .dolbyVisionUnconfirmed)
        XCTAssertEqual(unproven(7, converted: true, panelDV: true), .convertedTo81Unconfirmed)
        XCTAssertEqual(unproven(8, panelDV: false), .sdr)
        XCTAssertEqual(unproven(7, converted: true, panelDV: false), .sdr)
        XCTAssertEqual(DolbyVisionPlayback(sourceProfile: 7, convertedTo81: true, presentsDolbyVision: false,
                                           presentsHDR: true), .hdr10BaseLayer)
    }
}

final class DolbyVisionEnhancementLayerTests: XCTestCase {

    func test_readsTheEngineRouteLine() {
        let prefix = "[AetherEngine] DV P7 dual-layer route: "
        XCTAssertEqual(DolbyVisionEnhancementLayer(routeLine: prefix + "taken (el_type=FEL, 3840x2160@23.976, budget 80%)"), .full)
        XCTAssertEqual(DolbyVisionEnhancementLayer(routeLine: prefix + "not taken (el_type=MEL, nothing to compose), keeps the native route"), .minimal)
        XCTAssertEqual(DolbyVisionEnhancementLayer(routeLine: prefix + "not taken (over the real-time budget, 3840x2160@60 needs 160% of it), keeps the native route"), .full)
        XCTAssertNil(DolbyVisionEnhancementLayer(routeLine: prefix + "not taken (preferDualLayerDolbyVision is off), keeps the native route"))
    }
}
