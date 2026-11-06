import XCTest
@testable import Rivulet

final class SiloBufferingQualityTests: XCTestCase {
    private let high = MediaQuality(id: "high", displayName: nil, height: 1080, bitrateKbps: 8_000, preservesSource: false)
    private let low = MediaQuality(id: "low", displayName: nil, height: 720, bitrateKbps: 4_000, preservesSource: false)

    private func status(limit: Int? = nil, active: String = "high", unavailable: Bool = false) -> MediaNegotiatedStatus {
        MediaNegotiatedStatus(delivery: .hlsTranscode, availableQualities: [high, low],
            activeQualityID: active, effectiveRecipe: nil, decisionReason: nil,
            degradationWarnings: unavailable ? [.init(code: "quality_reduction_unavailable", message: "Unavailable")] : [], bandwidthLimit: limit.map { .init(kbps: $0, source: "observed_rebuffer", expiresAt: nil) },
            headerRefreshURL: nil)
    }

    func testAskOffersOnceAndDeclineSuppressesRepeatedStalls() {
        var policy = SiloBufferingQuality(policy: .ask)
        policy.playing(atMs: 0)
        policy.stallBegan(atMs: 10_000)
        XCTAssertEqual(policy.stallEnded(atMs: 11_500, status: status(), deliveredKbps: 8_000), .none)
        policy.stallBegan(atMs: 12_000)
        guard case .ask(let offer) = policy.stallEnded(atMs: 13_500, status: status(), deliveredKbps: 8_000) else {
            return XCTFail("Expected consent request")
        }
        XCTAssertEqual(offer.quality, .automatic)
        XCTAssertEqual(offer.bandwidthEstimateKbps, 5_600)
        policy.stallBegan(atMs: 14_000)
        XCTAssertEqual(policy.stallContinues(atMs: 20_000, status: status(), deliveredKbps: 8_000), .none)
        XCTAssertEqual(policy.answer(accept: false), .none)
        XCTAssertEqual(policy.answer(accept: true), .none)
        policy.stallBegan(atMs: 21_000)
        XCTAssertEqual(policy.stallContinues(atMs: 27_000, status: status(), deliveredKbps: 8_000), .none)
    }

    func testAutomaticManualPickRequiresConsentAndRestoreKeepsManualChoice() {
        var policy = SiloBufferingQuality(policy: .automatically, requestedQuality: .offered(id: "high"))
        policy.playing(atMs: 0)
        policy.stallBegan(atMs: 10_000)
        guard case .ask(let offer) = policy.stallContinues(atMs: 16_000, status: status(), deliveredKbps: 8_000) else {
            return XCTFail("Manual quality must be asked")
        }
        XCTAssertEqual(offer.quality, .offered(id: "low"))
        XCTAssertEqual(policy.answer(accept: true), .lower(offer))
        policy.adopt(status: status(limit: 5_000))
        XCTAssertEqual(policy.restore(status: status(limit: 5_000)), .init(quality: .offered(id: "high"), clearLearnedLimit: true))
        policy.didRequestRestore()
        XCTAssertNil(policy.restore(status: status()))
    }

    func testNeverAndManualChangeCancelPendingWork() {
        var never = SiloBufferingQuality(policy: .never)
        never.playing(atMs: 0)
        never.stallBegan(atMs: 10_000)
        XCTAssertEqual(never.stallContinues(atMs: 17_000, status: status(), deliveredKbps: 8_000), .none)
        var ask = SiloBufferingQuality(policy: .ask)
        ask.playing(atMs: 0)
        ask.stallBegan(atMs: 10_000)
        guard case .ask = ask.stallContinues(atMs: 17_000, status: status(), deliveredKbps: 8_000) else {
            return XCTFail("Expected offer")
        }
        ask.manualQualityChanged(to: .offered(id: "low"))
        XCTAssertEqual(ask.answer(accept: true), .none)
        XCTAssertNil(ask.restore(status: status()))
    }

    func testLearnedLimitBlocksIneffectiveEstimate() {
        var policy = SiloBufferingQuality(policy: .automatically)
        policy.playing(atMs: 0)
        policy.stallBegan(atMs: 10_000)
        XCTAssertEqual(policy.stallContinues(atMs: 16_000, status: status(limit: 5_000), deliveredKbps: 8_000), .none)
        XCTAssertEqual(policy.restore(status: status(limit: 5_000)), .init(quality: .automatic, clearLearnedLimit: true))
    }

    func testStoreFollowsTheProfileByDefaultAndHonorsAnOptOut() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = SiloPlaybackPolicyStore(defaults: defaults)
        let first = SiloPlaybackAuthority(providerID: "silo:server-a", accountID: "account-a", profileID: "profile-a")
        let second = SiloPlaybackAuthority(providerID: "silo:server-a", accountID: "account-a", profileID: "profile-b")
        let context = SiloPlaybackOverrideContext(authority: first, libraryID: "library-a", seriesID: "series-a")
        // What the profile stores on Silo: preferred subtitle language.
        let language = SiloResolvedSetting<String>(value: "nl", rawValue: .string("nl"), source: .profile,
            scope: .profile, profileId: "profile-a", libraryId: nil, seriesId: nil, deviceId: nil,
            clientFamily: nil, storedValue: nil, constrained: false)
        let server = SiloEffectivePlaybackPreferences(preferredQuality: .unavailable,
            maxBitrateKbps: .unavailable, subtitleLanguage: .resolved(language), subtitleMode: .unavailable,
            showForcedSubtitles: .unavailable, audioLanguage: .unavailable, bufferingQualityMode: .unavailable)
        // A profile that saved nothing follows the profile's Silo settings.
        let defaultFollows = await store.followsSilo(for: first)
        XCTAssertTrue(defaultFollows)
        let resolved = await store.resolve(context: context, server: server)
        XCTAssertTrue(resolved.followsSilo)
        XCTAssertEqual(resolved.subtitleLanguage, .value("nl"))
        let foreign = await store.resolve(context: .init(authority: second, libraryID: "library-a", seriesID: "series-a"), server: server)
        XCTAssertEqual(foreign.quality, .unavailable)
        // An opt-out is remembered for that authority alone.
        await store.setFollowsSilo(false, for: first)
        let optedOut = await store.resolve(context: context, server: server)
        XCTAssertFalse(optedOut.followsSilo)
        XCTAssertEqual(optedOut.subtitleLanguage, .unavailable)
        let secondFollows = await store.followsSilo(for: second)
        XCTAssertTrue(secondFollows)
    }

    /// Data written before following was the default must still load, and it
    /// reads as following so an untouched install adopts the profile.
    func testStoredRecordWithoutFollowFlagFollowsAndKeepsItsData() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let payload = #"[{"authority":{"providerID":"silo:server-a","accountID":"account-a","profileID":"profile-a"},"# +
                      #""record":{"overrides":[]}}]"#
        defaults.set(Data(payload.utf8), forKey: "silo.localPlaybackPolicy.v2")
        let store = SiloPlaybackPolicyStore(defaults: defaults)
        let authority = SiloPlaybackAuthority(providerID: "silo:server-a", accountID: "account-a", profileID: "profile-a")
        let follows = await store.followsSilo(for: authority)
        XCTAssertTrue(follows)
        // Its record survives a write and a fresh read.
        await store.setFollowsSilo(false, for: authority)
        let optOut = await SiloPlaybackPolicyStore(defaults: defaults).followsSilo(for: authority)
        XCTAssertFalse(optOut)
    }
    func testWarmUpDoesNotCountUntilFirstFrameAndGraceEnds() {
        var policy = SiloBufferingQuality(policy: .automatically)
        policy.stallBegan(atMs: 0)
        XCTAssertEqual(policy.stallContinues(atMs: 20_000, status: status(), deliveredKbps: 8_000), .none)
        policy.playing(atMs: 20_000)
        policy.stallBegan(atMs: 21_000)
        XCTAssertEqual(policy.stallContinues(atMs: 29_999, status: status(), deliveredKbps: 8_000), .none)
        XCTAssertEqual(policy.stallContinues(atMs: 35_999, status: status(), deliveredKbps: 8_000), .none)
        guard case .lower = policy.stallContinues(atMs: 36_000, status: status(), deliveredKbps: 8_000) else {
            return XCTFail("Expected long stall after grace")
        }
        policy.warmUpBegan()
        policy.stallBegan(atMs: 40_000)
        XCTAssertEqual(policy.stallContinues(atMs: 50_000, status: status(), deliveredKbps: 8_000), .none)
    }

    func testEarlyContinuousStallRecoversAtGraceAdjustedDeadline() throws {
        var policy = SiloBufferingQuality(policy: .automatically)
        policy.playing(atMs: 0)
        policy.stallBegan(atMs: 2_000)
        let deadline = try XCTUnwrap(policy.continuousStallDeadlineMs)
        XCTAssertEqual(deadline, 16_000)
        XCTAssertEqual(policy.stallContinues(atMs: 8_000, status: status(), deliveredKbps: 8_000), .none)
        XCTAssertEqual(policy.stallContinues(atMs: deadline - 1, status: status(), deliveredKbps: 8_000), .none)
        guard case .lower(let request) = policy.stallContinues(atMs: deadline, status: status(), deliveredKbps: 8_000) else {
            return XCTFail("Expected recovery without another playback-state transition")
        }
        XCTAssertEqual(request.quality, .automatic)
        XCTAssertEqual(request.bandwidthEstimateKbps, 5_600)
        XCTAssertEqual(policy.stallContinues(atMs: deadline + 1, status: status(), deliveredKbps: 8_000), .none)
    }

    func testEarlyStallEndingBeforeGraceDoesNotRecoverAtCancelledDeadline() throws {
        var policy = SiloBufferingQuality(policy: .automatically)
        policy.playing(atMs: 0)
        policy.stallBegan(atMs: 2_000)
        let deadline = try XCTUnwrap(policy.continuousStallDeadlineMs)
        XCTAssertEqual(policy.stallEnded(atMs: 8_000, status: status(), deliveredKbps: 8_000), .none)
        XCTAssertNil(policy.continuousStallDeadlineMs)
        XCTAssertEqual(policy.stallContinues(atMs: deadline, status: status(), deliveredKbps: 8_000), .none)
    }

    func testNewPlanCannotRecoverAtPreviousStallDeadline() throws {
        var policy = SiloBufferingQuality(policy: .automatically)
        policy.playing(atMs: 0)
        policy.stallBegan(atMs: 2_000)
        let previousDeadline = try XCTUnwrap(policy.continuousStallDeadlineMs)
        policy.adopt(status: status())
        XCTAssertNil(policy.continuousStallDeadlineMs)
        policy.playing(atMs: 6_000)
        policy.stallBegan(atMs: 7_000)
        let deadline = try XCTUnwrap(policy.continuousStallDeadlineMs)
        XCTAssertEqual(deadline, 22_000)
        XCTAssertEqual(policy.stallContinues(atMs: previousDeadline, status: status(), deliveredKbps: 8_000), .none)
        guard case .lower = policy.stallContinues(atMs: deadline, status: status(), deliveredKbps: 8_000) else {
            return XCTFail("Expected recovery only after the new plan's grace and stall evidence")
        }
    }

    func testUnchangedOrUnavailableAdoptionDoesNotEnableRestore() {
        var policy = SiloBufferingQuality(policy: .automatically)
        policy.playing(atMs: 0)
        policy.stallBegan(atMs: 10_000)
        guard case .lower = policy.stallContinues(atMs: 16_000, status: status(), deliveredKbps: 8_000) else {
            return XCTFail("Expected lowering request")
        }
        policy.adopt(status: status(unavailable: true))
        XCTAssertFalse(policy.hasLowered)
        XCTAssertNil(policy.keptEstimateKbps)
        XCTAssertNil(policy.restore(status: status()))
    }

    func testNullClearPrecedenceAndSharedStoreVisibility() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = SiloPlaybackPolicyStore(defaults: defaults)
        let authority = SiloPlaybackAuthority(providerID: "silo:server.test", accountID: "a", profileID: "p")
        let profile = SiloPlaybackOverrideContext(authority: authority, libraryID: nil, seriesID: nil)
        let library = SiloPlaybackOverrideContext(authority: authority, libraryID: "l", seriesID: nil)
        let series = SiloPlaybackOverrideContext(authority: authority, libraryID: "l", seriesID: "s")
        let nullQuality = SiloResolvedSetting<String>(value: nil, rawValue: .null, source: .profile,
            scope: .profile, profileId: "p", libraryId: nil, seriesId: nil, deviceId: nil,
            clientFamily: nil, storedValue: nil, constrained: false)
        let server = SiloEffectivePlaybackPreferences(preferredQuality: .resolved(nullQuality),
            maxBitrateKbps: .unavailable, subtitleLanguage: .unavailable, subtitleMode: .unavailable,
            showForcedSubtitles: .unavailable, audioLanguage: .unavailable, bufferingQualityMode: .unavailable)
        await store.setFollowsSilo(true, for: authority)
        let nullResult = await store.resolve(context: series, server: server)
        XCTAssertEqual(nullResult.quality, .clear)
        XCTAssertEqual(nullResult.maxBitrateKbps, .unavailable)
        var broad = SiloLocalPlaybackOverrides()
        broad.quality = .value(.offered(id: "high"))
        broad.maxBitrateKbps = .value(8_000)
        await store.setOverrides(broad, for: profile)
        var narrow = SiloLocalPlaybackOverrides()
        narrow.quality = .clear
        await store.setOverrides(narrow, for: library)
        let resolved = await store.resolve(context: series, server: server)
        XCTAssertEqual(resolved.quality, .clear)
        XCTAssertEqual(resolved.maxBitrateKbps, .value(8_000))
        let secondReader = SiloPlaybackPolicyStore(defaults: defaults)
        let persisted = await secondReader.resolve(context: series, server: server)
        XCTAssertEqual(persisted.quality, .clear)
        XCTAssertEqual(persisted.maxBitrateKbps, .value(8_000))
    }

}
