// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
import UIKit
@testable import Rivulet

@MainActor
final class SiloDescriptionTranslationTests: XCTestCase {
    func testCapabilityFailsClosedForUnknownModesMissingRevisionAndUnavailableServer() {
        for mode in ["auto", "button", "off", "future"] {
            for state in ["available", "disabled", "not_configured", "unsupported", "future"] {
                for allowed in [true, false] {
                    for revision in ["r1", "", "  "] {
                        let capability = SiloMetadataAICapability(allowed: allowed, state: state,
                                                               revision: revision, onView: mode)
                        XCTAssertEqual(capability.canTranslate,
                                       allowed && state == "available" && revision == "r1"
                                        && (mode == "auto" || mode == "button"))
                    }
                }
            }
        }
    }

    func testOnlyOverviewProvenanceMarksCardsEpisodesAndDetails() throws {
        let provider = makeProvider()
        for type in ["movie", "series", "season", "episode"] {
            for fields in [[], ["tagline"], ["overview"], ["overview", "tagline"]] {
                let detail = try makeDetail(provider, type: type, fields: fields)
                XCTAssertEqual(detail.item.overviewIsMachineTranslated, fields.contains("overview"), type)
                XCTAssertEqual(detail.pendingDescriptionTranslationLanguage, "nl")
            }
        }
        let original = try makeDetail(provider, pending: nil)
        XCTAssertEqual(original.item.overview, "Original description")
        XCTAssertNil(original.pendingDescriptionTranslationLanguage)
    }

    func testSavedItemsWithoutProvenanceDecodeAndTranslatedItemsRoundTrip() throws {
        let item = try makeDetail(makeProvider(), fields: ["overview"]).item
        let data = try JSONEncoder().encode(item)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "overviewIsMachineTranslated")
        let legacy = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.overviewIsMachineTranslated)
        XCTAssertEqual(legacy.overview, item.overview)
        XCTAssertEqual(try JSONDecoder().decode(MediaItem.self, from: data).overviewIsMachineTranslated, true)
    }

    func testNativeDirectJobBodyEscapesContentIDAndUsesExactProfileLanguage() async throws {
        let server = SiloAuthTestServer()
        let contentID = "episode/a?b#c%"
        let path = "/proxy/api/v2/catalog/items/episode%2Fa%3Fb%23c%25/translate-description"
        let body = #"{"id":"42","content_id":"episode/a?b#c%","target_language":"nl-BE","status":"pending"}"#
        await server.respond("POST", URL(string: "https://silo.invalid" + path)!.path, [.init(status: 202, body: body)])
        let provider = makeProvider(transport: server.transport)
        let job = try await provider.translateDescription(contentID: contentID, language: "nl-BE")
        XCTAssertEqual(job.id, "42")
        let requests = await server.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.url?.absoluteString, "https://silo.invalid" + path)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Id"), "profile-a")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(object, ["target_language": "nl-BE"])
    }

    func testJobsAreBoundToItemLanguageAndKnownNonfailureStatus() throws {
        for status in ["pending", "running", "completed", "failed", "canceled", "cancelled", "future"] {
            for contentID in ["movie-a", "movie-b"] {
                for language in ["nl", "fr"] {
                    let job = SiloDescriptionTranslationJob(id: "42", contentId: contentID,
                                                            targetLanguage: language, status: status, errorMessage: nil)
                    if contentID == "movie-a", language == "nl", ["pending", "running", "completed"].contains(status) {
                        XCTAssertNoThrow(try job.validate(contentID: "movie-a", language: "nl"))
                    } else {
                        XCTAssertThrowsError(try job.validate(contentID: "movie-a", language: "nl"))
                    }
                }
            }
        }
        let envelope = Data(#"{"job":{"id":"42","content_id":"movie-a","target_language":"nl","status":"pending"}}"#.utf8)
        XCTAssertThrowsError(try SiloJSON.decoder().decode(SiloDescriptionTranslationJob.self, from: envelope))
    }

    func testUncertainNativePostIsSentOnlyOnce() async {
        let server = SiloAuthTestServer()
        await server.respond("POST", "/proxy/api/v2/catalog/items/movie-a/translate-description", [
            .init(status: 202, body: "", error: .networkConnectionLost)
        ])
        do {
            _ = try await makeProvider(transport: server.transport).translateDescription(contentID: "movie-a", language: "nl")
            XCTFail("An uncertain write must fail without replay")
        } catch { }
        let requests = await server.requests()
        XCTAssertEqual(requests.count, 1)
    }

    func testAutoHonorsHostPermissionAndBenignReconfigurationDoesNotRepost() async throws {
        let provider = makeProvider()
        let original = try makeDetail(provider)
        let translated = try makeDetail(provider, pending: nil, overview: "Vertaalde beschrijving", fields: ["overview"])
        let gate = DescriptionReadGate()
        var capabilityReads = 0
        var posts = 0
        var dependencies = SiloDescriptionTranslationController.Dependencies()
        dependencies.capability = { _ in
            capabilityReads += 1
            return self.capability("auto")
        }
        dependencies.translate = { _, contentID, language in
            posts += 1
            XCTAssertEqual(language, "nl")
            return self.job(contentID: contentID, language: language)
        }
        dependencies.sleep = { _ in }
        dependencies.fetch = { _, _ in await gate.wait(); return translated }
        let controller = SiloDescriptionTranslationController(dependencies: dependencies)
        defer { controller.stop(); gate.open() }
        controller.configure(provider: provider, detail: original, allowAutomatic: false)
        await eventually { capabilityReads == 1 }
        XCTAssertEqual(posts, 0)
        XCTAssertFalse(controller.isTranslating)
        XCTAssertFalse(controller.canTranslate)
        controller.configure(provider: provider, detail: original, allowAutomatic: true)
        await eventually { gate.isWaiting }
        XCTAssertEqual(posts, 1)
        XCTAssertTrue(controller.isTranslating)
        XCTAssertEqual(controller.detail?.item.overview, "Original description")
        controller.configure(provider: provider, detail: original, allowAutomatic: true)
        XCTAssertEqual(posts, 1)
        XCTAssertTrue(controller.isTranslating)
        gate.open()
        await eventually { !controller.isTranslating }
        XCTAssertEqual(controller.detail?.item.overview, "Vertaalde beschrijving")
        XCTAssertEqual(controller.detail?.item.overviewIsMachineTranslated, true)
        XCTAssertNil(controller.errorMessage)
        XCTAssertFalse(controller.canTranslate)
        controller.stop()
        XCTAssertEqual(controller.detail?.item.overview, "Vertaalde beschrijving")
        XCTAssertEqual(controller.detail?.item.overviewIsMachineTranslated, true)
    }

    func testButtonNeverStartsAutomaticallyButAllowsExplicitActionWithoutAutomaticPermission() async throws {
        let provider = makeProvider()
        let detail = try makeDetail(provider)
        var posts = 0
        var dependencies = SiloDescriptionTranslationController.Dependencies()
        dependencies.capability = { _ in self.capability("button") }
        dependencies.translate = { _, contentID, language in posts += 1; return self.job(contentID: contentID, language: language) }
        dependencies.sleep = { _ in }
        dependencies.fetch = { _, _ in detail }
        let controller = SiloDescriptionTranslationController(dependencies: dependencies, maximumPolls: 1)
        defer { controller.stop() }
        controller.configure(provider: provider, detail: detail, allowAutomatic: false)
        await eventually { controller.canTranslate }
        XCTAssertEqual(posts, 0)
        XCTAssertFalse(controller.isTranslating)
        controller.translate()
        await eventually { controller.errorMessage != nil }
        XCTAssertEqual(posts, 1)
        XCTAssertTrue(controller.canTranslate)
        XCTAssertEqual(controller.detail?.item.overview, "Original description")
    }

    func testOffAndFailedCapabilityDiscoveryNeverCreateJobsOrOfferAction() async throws {
        for failDiscovery in [false, true] {
            let provider = makeProvider()
            let detail = try makeDetail(provider)
            var reads = 0
            var posts = 0
            var dependencies = SiloDescriptionTranslationController.Dependencies()
            dependencies.capability = { _ in
                reads += 1
                if failDiscovery { throw SiloDescriptionTranslationError.unavailable }
                return self.capability("off")
            }
            dependencies.translate = { _, contentID, language in posts += 1; return self.job(contentID: contentID, language: language) }
            let controller = SiloDescriptionTranslationController(dependencies: dependencies)
            controller.configure(provider: provider, detail: detail, allowAutomatic: true)
            await eventually { reads == 1 }
            controller.translate()
            XCTAssertEqual(posts, 0)
            XCTAssertFalse(controller.canTranslate)
            XCTAssertFalse(controller.isTranslating)
            XCTAssertEqual(controller.detail?.item.overview, detail.item.overview)
            controller.stop()
        }
    }

    func testFailedAndUnknownJobsDoNotPollOrClaimTranslation() async throws {
        for status in ["failed", "canceled", "future"] {
            let provider = makeProvider()
            let detail = try makeDetail(provider)
            var reads = 0
            var posts = 0
            var sleeps = 0
            var dependencies = SiloDescriptionTranslationController.Dependencies()
            dependencies.capability = { _ in self.capability("auto") }
            dependencies.translate = { _, contentID, language in
                posts += 1
                return self.job(contentID: contentID, language: language, status: status)
            }
            dependencies.fetch = { _, _ in reads += 1; return detail }
            dependencies.sleep = { _ in sleeps += 1 }
            let controller = SiloDescriptionTranslationController(dependencies: dependencies)
            controller.configure(provider: provider, detail: detail, allowAutomatic: true)
            await eventually { controller.errorMessage != nil }
            XCTAssertEqual(posts, 1)
            XCTAssertEqual(reads, 1, "Only a fresh-detail recovery read is allowed")
            XCTAssertEqual(sleeps, 0)
            XCTAssertFalse(controller.isTranslating)
            XCTAssertTrue(controller.canTranslate)
            XCTAssertEqual(controller.detail?.item.overviewIsMachineTranslated, false)
            controller.configure(provider: provider, detail: detail, allowAutomatic: true)
            XCTAssertEqual(posts, 1, "Failure does not silently replay auto work")
            controller.stop()
        }
    }

    func testPollingIsBoundedAndRetryIsExplicitAfterUncertainWrite() async throws {
        let provider = makeProvider()
        let detail = try makeDetail(provider)
        var posts = 0
        var reads = 0
        var sleeps = 0
        var dependencies = SiloDescriptionTranslationController.Dependencies()
        dependencies.capability = { _ in self.capability("auto") }
        dependencies.translate = { _, contentID, language in
            posts += 1
            if posts == 1 { throw MediaProviderError.unreachable }
            return self.job(contentID: contentID, language: language)
        }
        dependencies.fetch = { _, _ in reads += 1; return detail }
        dependencies.sleep = { interval in XCTAssertEqual(interval, .seconds(2)); sleeps += 1 }
        let controller = SiloDescriptionTranslationController(dependencies: dependencies, maximumPolls: 3)
        defer { controller.stop() }
        controller.configure(provider: provider, detail: detail, allowAutomatic: true)
        await eventually { controller.errorMessage != nil }
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(reads, 1)
        controller.configure(provider: provider, detail: detail, allowAutomatic: true)
        XCTAssertEqual(posts, 1)
        controller.translate()
        await eventually { controller.errorMessage != nil }
        XCTAssertEqual(posts, 2)
        XCTAssertEqual(reads, 4)
        XCTAssertEqual(sleeps, 3)
        XCTAssertEqual(controller.detail?.item.overview, "Original description")
        XCTAssertTrue(controller.canTranslate)
    }

    func testLateOldItemReadCannotPublishOrClearNewOperation() async throws {
        let provider = makeProvider()
        let first = try makeDetail(provider, contentID: "movie-a")
        let second = try makeDetail(provider, contentID: "movie-b")
        let translatedFirst = try makeDetail(provider, contentID: "movie-a", pending: nil, overview: "Old translated")
        let translatedSecond = try makeDetail(provider, contentID: "movie-b", pending: nil, overview: "New translated")
        let oldGate = DescriptionReadGate()
        let newGate = DescriptionReadGate()
        var oldReturned = false
        var dependencies = SiloDescriptionTranslationController.Dependencies()
        dependencies.capability = { _ in self.capability("auto") }
        dependencies.translate = { _, contentID, language in self.job(contentID: contentID, language: language) }
        dependencies.sleep = { _ in }
        dependencies.fetch = { _, ref in
            if ref.itemID == "movie-a" {
                await oldGate.wait()
                oldReturned = true
                return translatedFirst
            }
            await newGate.wait()
            return translatedSecond
        }
        let controller = SiloDescriptionTranslationController(dependencies: dependencies)
        defer { controller.stop(); oldGate.open(); newGate.open() }
        controller.configure(provider: provider, detail: first, allowAutomatic: true)
        await eventually { oldGate.isWaiting }
        controller.configure(provider: provider, detail: second, allowAutomatic: true)
        await eventually { newGate.isWaiting }
        oldGate.open()
        await eventually { oldReturned }
        XCTAssertEqual(controller.detail?.item.ref, second.item.ref)
        XCTAssertEqual(controller.detail?.item.overview, "Original description")
        XCTAssertTrue(controller.isTranslating, "Old cleanup must not clear the new operation")
        newGate.open()
        await eventually { !controller.isTranslating }
        XCTAssertEqual(controller.detail?.item.overview, "New translated")
    }

    func testStopAndProfileReplacementRejectUncancellableLateResults() async throws {
        let firstProvider = makeProvider()
        let secondProvider = makeProvider(profile: "profile-b")
        let first = try makeDetail(firstProvider)
        let second = try makeDetail(secondProvider)
        let oldTranslation = try makeDetail(firstProvider, pending: nil, overview: "Wrong profile")
        let gate = DescriptionReadGate()
        var returned = false
        var dependencies = SiloDescriptionTranslationController.Dependencies()
        dependencies.capability = { _ in self.capability("auto") }
        dependencies.translate = { _, contentID, language in self.job(contentID: contentID, language: language) }
        dependencies.sleep = { _ in }
        dependencies.fetch = { _, _ in await gate.wait(); returned = true; return oldTranslation }
        let controller = SiloDescriptionTranslationController(dependencies: dependencies)
        defer { controller.stop(); gate.open() }
        controller.configure(provider: firstProvider, detail: first, allowAutomatic: true)
        await eventually { gate.isWaiting }
        controller.stop()
        XCTAssertEqual(controller.detail?.item.ref, first.item.ref)
        XCTAssertEqual(controller.detail?.item.overview, first.item.overview)
        XCTAssertFalse(controller.isTranslating)
        controller.configure(provider: secondProvider, detail: second, allowAutomatic: false)
        gate.open()
        await eventually { returned }
        XCTAssertEqual(controller.detail?.item.ref.providerID, secondProvider.id)
        XCTAssertEqual(controller.detail?.item.overview, "Original description")
        XCTAssertFalse(controller.isTranslating)
    }

    func testChangedPendingLanguageEndsObservationWithoutPostingForAnotherLanguage() async throws {
        let provider = makeProvider()
        let original = try makeDetail(provider)
        let changed = try makeDetail(provider, pending: "fr", overview: "Server profile changed")
        var languages: [String] = []
        var dependencies = SiloDescriptionTranslationController.Dependencies()
        dependencies.capability = { _ in self.capability("auto") }
        dependencies.translate = { _, contentID, language in
            languages.append(language)
            return self.job(contentID: contentID, language: language)
        }
        dependencies.sleep = { _ in }
        dependencies.fetch = { _, _ in changed }
        let controller = SiloDescriptionTranslationController(dependencies: dependencies)
        defer { controller.stop() }
        controller.configure(provider: provider, detail: original, allowAutomatic: true)
        await eventually { controller.detail?.pendingDescriptionTranslationLanguage == "fr" }
        XCTAssertFalse(controller.isTranslating)
        XCTAssertFalse(controller.canTranslate)
        XCTAssertEqual(languages, ["nl"])
        XCTAssertEqual(controller.detail?.item.overview, "Server profile changed")
    }

    func testUncertainPostCanRecoverOnlyFromFreshTranslatedDetail() async throws {
        let provider = makeProvider()
        let original = try makeDetail(provider)
        let fresh = try makeDetail(provider, pending: nil, overview: "Actual translated text", fields: ["overview"])
        var posts = 0
        var reads = 0
        var dependencies = SiloDescriptionTranslationController.Dependencies()
        dependencies.capability = { _ in self.capability("auto") }
        dependencies.translate = { _, _, _ in posts += 1; throw MediaProviderError.unreachable }
        dependencies.fetch = { _, _ in reads += 1; return fresh }
        dependencies.sleep = { _ in XCTFail("A recovery read must not start a polling loop") }
        let controller = SiloDescriptionTranslationController(dependencies: dependencies)
        defer { controller.stop() }
        controller.configure(provider: provider, detail: original, allowAutomatic: true)
        await eventually { controller.detail?.item.overviewIsMachineTranslated == true }
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(controller.detail?.item.overview, "Actual translated text")
        XCTAssertFalse(controller.isTranslating)
        XCTAssertNil(controller.errorMessage)
    }

    func testLanguageReconfigurationInvalidatesAnInFlightPostWithoutReplayingIt() async throws {
        let provider = makeProvider()
        let dutch = try makeDetail(provider)
        let french = try makeDetail(provider, pending: "fr")
        let gate = DescriptionReadGate()
        var languages: [String] = []
        var oldReturned = false
        var dependencies = SiloDescriptionTranslationController.Dependencies()
        dependencies.capability = { _ in self.capability("auto") }
        dependencies.translate = { _, contentID, language in
            languages.append(language)
            await gate.wait()
            oldReturned = true
            return self.job(contentID: contentID, language: language)
        }
        dependencies.fetch = { _, _ in XCTFail("The old POST must not start polling"); return dutch }
        let controller = SiloDescriptionTranslationController(dependencies: dependencies)
        defer { controller.stop(); gate.open() }
        controller.configure(provider: provider, detail: dutch, allowAutomatic: true)
        await eventually { gate.isWaiting }
        controller.configure(provider: provider, detail: french, allowAutomatic: false)
        gate.open()
        await eventually { oldReturned }
        XCTAssertEqual(languages, ["nl"])
        XCTAssertEqual(controller.detail?.pendingDescriptionTranslationLanguage, "fr")
        XCTAssertFalse(controller.isTranslating)
        XCTAssertFalse(controller.canTranslate)
    }

    func testNativeCapabilityResponseUsesCapturedProfileAndAllServerGates() async throws {
        let server = SiloAuthTestServer()
        await server.respond("GET", "/proxy/api/v2/capabilities/metadata-ai", [
            .init(body: #"{"allowed":true,"state":"available","revision":"current","on_view":"button"}"#),
            .init(body: #"{"allowed":false,"state":"available","revision":"current","on_view":"auto"}"#),
            .init(body: #"{"allowed":true,"state":"not_configured","revision":"current","on_view":"auto"}"#),
            .init(body: #"{"allowed":true,"state":"available","revision":"","on_view":"auto"}"#)
        ])
        let provider = makeProvider(transport: server.transport)
        let available = try await provider.descriptionTranslationCapability()
        XCTAssertTrue(available.canTranslate)
        XCTAssertEqual(available.onView, "button")
        for _ in 0..<3 {
            let unavailable = try await provider.descriptionTranslationCapability()
            XCTAssertFalse(unavailable.canTranslate)
        }
        let requests = await server.requests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Profile-Id") == provider.profileID })
    }

    func testStillPendingOrForeignDetailCannotReplaceOriginalOnPollingFailure() async throws {
        let provider = makeProvider()
        let original = try makeDetail(provider)
        let stillPending = try makeDetail(provider, overview: "")
        let foreign = try makeDetail(provider, contentID: "another-item", pending: nil, overview: "Wrong title",
                                     fields: ["overview"])
        var reads = 0
        var dependencies = SiloDescriptionTranslationController.Dependencies()
        dependencies.capability = { _ in self.capability("auto") }
        dependencies.translate = { _, contentID, language in self.job(contentID: contentID, language: language) }
        dependencies.sleep = { _ in }
        dependencies.fetch = { _, _ in
            reads += 1
            if reads == 1 { return stillPending }
            if reads == 2 { throw MediaProviderError.unreachable }
            return foreign
        }
        let controller = SiloDescriptionTranslationController(dependencies: dependencies, maximumPolls: 3)
        defer { controller.stop() }
        controller.configure(provider: provider, detail: original, allowAutomatic: true)
        await eventually { controller.errorMessage != nil }
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(controller.detail?.item.ref, original.item.ref)
        XCTAssertEqual(controller.detail?.item.overview, "Original description")
        XCTAssertEqual(controller.detail?.item.overviewIsMachineTranslated, false)
        XCTAssertFalse(controller.isTranslating)
        XCTAssertTrue(controller.canTranslate)
    }

    func testWallClockTimeoutInvalidatesAnUncancellableRequestAndKeepsRetryExplicit() async throws {
        let provider = makeProvider()
        let original = try makeDetail(provider)
        let gate = DescriptionReadGate()
        var posts = 0
        var returned = false
        var dependencies = SiloDescriptionTranslationController.Dependencies()
        dependencies.capability = { _ in self.capability("auto") }
        dependencies.translate = { _, contentID, language in
            posts += 1
            await gate.wait()
            returned = true
            return self.job(contentID: contentID, language: language)
        }
        dependencies.fetch = { _, _ in XCTFail("An expired operation cannot start polling"); return original }
        let controller = SiloDescriptionTranslationController(dependencies: dependencies, operationTimeout: .zero)
        defer { controller.stop(); gate.open() }
        controller.configure(provider: provider, detail: original, allowAutomatic: true)
        await eventually { controller.errorMessage != nil }
        XCTAssertEqual(posts, 1)
        XCTAssertFalse(controller.isTranslating)
        XCTAssertTrue(controller.canTranslate)
        XCTAssertEqual(controller.detail?.item.overview, "Original description")
        controller.configure(provider: provider, detail: original, allowAutomatic: true)
        XCTAssertEqual(posts, 1)
        gate.open()
        await eventually { returned }
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.isTranslating)
    }

    func testOpenedMovieTranslatesBeforeExpansionWithoutStartingJobsForAdjacentPosters() async throws {
        let server = SiloAuthTestServer()
        let translationResponse = SiloAuthRequestGate()
        let translatedRead = SiloAuthRequestGate()
        let provider = makeProvider(profile: "visible-movie-\(UUID().uuidString)", transport: server.transport)
        let original = #"{"content_id":"movie-a","type":"movie","title":"A Movie","overview":"Original description","pending_translation_language":"nl"}"#
        let translated = #"{"content_id":"movie-a","type":"movie","title":"A Movie","overview":"Vertaalde beschrijving","machine_translated_fields":["overview"]}"#
        await server.respond("GET", "/proxy/api/v2/catalog/items/movie-a",
                             [.init(body: original), .init(body: translated, gate: translatedRead)])
        await server.respond("GET", "/proxy/api/v2/catalog/items/movie-b", [.init(body: """
        {"content_id":"movie-b","type":"movie","title":"Adjacent Movie","overview":"Adjacent description","pending_translation_language":"nl"}
        """)])
        await server.respond("GET", "/proxy/api/v2/capabilities/metadata-ai", [.init(body: """
        {"allowed":true,"state":"available","revision":"r1","on_view":"auto"}
        """)])
        await server.respond("POST", "/proxy/api/v2/catalog/items/movie-a/translate-description", [.init(status: 202, body: """
        {"id":"42","content_id":"movie-a","target_language":"nl","status":"pending"}
        """, gate: translationResponse)])
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        MediaProviderRegistry.shared.register(provider)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let host = UIViewController()
        host.view.backgroundColor = .black
        window.rootViewController = host
        let movie = PreviewCardView(frame: window.bounds.insetBy(dx: 80, dy: 80))
        let adjacent = PreviewCardView(frame: CGRect(x: 1840, y: 80, width: 1760, height: 920))
        host.view.addSubview(movie)
        host.view.addSubview(adjacent)
        window.makeKeyAndVisible()
        defer {
            movie.prepareForReuse()
            adjacent.prepareForReuse()
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
            MediaProviderRegistry.shared.unregister(providerID: provider.id)
            Task { await translationResponse.release(); await translatedRead.release() }
        }
        movie.item = try makeDetail(provider).item
        adjacent.item = try makeDetail(provider, contentID: "movie-b").item
        let detailsLoaded = expectation(description: "Both visible poster details have loaded")
        detailsLoaded.expectedFulfillmentCount = 2
        movie.whenChromeReady { detailsLoaded.fulfill() }
        adjacent.whenChromeReady { detailsLoaded.fulfill() }
        await fulfillment(of: [detailsLoaded], timeout: 5)
        var requests = await server.requests()
        XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })

        movie.setIsCurrent(true, animated: false)
        await fulfillment(of: [translationResponse.entered], timeout: 5)
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        func waitForUI(_ condition: () -> Bool) async {
            for _ in 0..<100 {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Expected the visible description to update")
        }
        let indicator = try XCTUnwrap(descendants(movie).compactMap { $0 as? DescriptionTranslationView }.first)
        await waitForUI { !indicator.isHidden }
        let summaryLabel = try XCTUnwrap(descendants(movie).compactMap { $0 as? UILabel }
            .first { $0.text == "Original description" })
        let translatingAlpha = summaryLabel.alpha
        XCTAssertLessThan(translatingAlpha, 1)
        func attachSurface(_ name: String) {
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        attachSurface("Opened movie translating without expansion")
        movie.setExpanded(true)
        movie.setExpanded(false)
        XCTAssertFalse(indicator.isHidden)
        await translationResponse.release()
        await fulfillment(of: [translatedRead.entered], timeout: 5)
        await translatedRead.release()
        await waitForUI {
            descendants(movie).contains { ($0 as? UILabel)?.text == "Vertaalde beschrijving" }
        }
        XCTAssertFalse(indicator.isHidden, "The translated overview retains its provenance icon")
        XCTAssertGreaterThan(summaryLabel.alpha, translatingAlpha)
        attachSurface("Opened movie translated without expansion")
        requests = await server.requests()
        let posts = requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.map { $0.url?.path }, ["/proxy/api/v2/catalog/items/movie-a/translate-description"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(posts.first?.httpBody)) as? [String: String])
        XCTAssertEqual(body["target_language"], "nl")
    }

    private func makeProvider(profile: String = "profile-a", transport: SiloClient.Transport? = nil) -> SiloProvider {
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid/proxy")!, profileID: profile,
                                transport: transport ?? { _ in throw MediaProviderError.unreachable })
        return SiloProvider(serverID: "server-a", displayName: "Silo", profileID: profile, client: client)
    }

    private func capability(_ mode: String) -> SiloMetadataAICapability {
        SiloMetadataAICapability(allowed: true, state: "available", revision: "r1", onView: mode)
    }

    private func job(contentID: String, language: String, status: String = "pending") -> SiloDescriptionTranslationJob {
        SiloDescriptionTranslationJob(id: "42", contentId: contentID, targetLanguage: language,
                                     status: status, errorMessage: nil)
    }

    private func makeDetail(_ provider: SiloProvider, contentID: String = "movie-a", type: String = "movie",
                            pending: String? = "nl", overview: String = "Original description",
                            fields: [String] = []) throws -> MediaItemDetail {
        var object: [String: Any] = ["content_id": contentID, "type": type, "title": "A title",
                                     "overview": overview, "machine_translated_fields": fields]
        if let pending { object["pending_translation_language"] = pending }
        let dto = try SiloJSON.decoder().decode(SiloItem.self, from: JSONSerialization.data(withJSONObject: object))
        return SiloMediaMapper.detail(dto, providerID: provider.id, baseURL: provider.client.baseURL)
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Expected asynchronous state transition", file: file, line: line)
    }
}

/// Intentionally ignores cancellation to exercise late callbacks from a host
/// that stopped or reconfigured while a server response was already underway.
@MainActor
private final class DescriptionReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    var isWaiting: Bool { continuation != nil }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
