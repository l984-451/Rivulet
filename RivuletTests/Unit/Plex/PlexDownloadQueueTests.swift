// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Fixtures are bodies measured on PMS 1.43.4 (trimmed, no tokens).
@MainActor
final class PlexDownloadQueueTests: XCTestCase {
    private let manager = PlexNetworkManager.shared
    private let server = "https://192-168-1-140.abc.plex.direct:32400"
    private let token = "secret-token-value"

    // MARK: - Requests

    private func assertNoTokenInURL(_ request: URLRequest?, file: StaticString = #filePath, line: UInt = #line) {
        guard let request, let url = request.url?.absoluteString else { return XCTFail("nil request", file: file, line: line) }
        XCTAssertFalse(url.contains(token), file: file, line: line)
        XCTAssertFalse(url.contains("X-Plex-Token"), file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Token"), token, file: file, line: line)
        for header in ["X-Plex-Platform", "X-Plex-Product", "X-Plex-Version", "X-Plex-Client-Identifier"] {
            XCTAssertNotNil(request.value(forHTTPHeaderField: header), header, file: file, line: line)
        }
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Plex-Client-Profile-Name"), file: file, line: line)
    }

    func test_addRequest_postsKeysBitrateAndProfileExtra() throws {
        let request = manager.addToDownloadQueueRequest(
            serverURL: server, authToken: token, queueID: 11,
            ratingKey: "971", mediaIndex: 1, maxVideoBitrateKbps: 2000)
        assertNoTokenInURL(request)
        let r = try XCTUnwrap(request)
        XCTAssertEqual(r.httpMethod, "POST")
        let components = try XCTUnwrap(URLComponents(url: r.url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/downloadQueue/11/add")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(query["keys"], "/library/metadata/971")
        XCTAssertEqual(query["mediaIndex"], "1")
        XCTAssertEqual(query["maxVideoBitrate"], "2000")
        XCTAssertEqual(
            r.value(forHTTPHeaderField: "X-Plex-Client-Profile-Extra"),
            "append-transcode-target-codec(type=videoProfile&context=static&protocol=http&videoCodec=hevc)")
    }

    func test_addRequest_omitsMediaIndexWhenNil() throws {
        let r = try XCTUnwrap(manager.addToDownloadQueueRequest(
            serverURL: server, authToken: token, queueID: 11,
            ratingKey: "971", mediaIndex: nil, maxVideoBitrateKbps: 720))
        XCTAssertFalse(r.url!.absoluteString.contains("mediaIndex"))
    }

    func test_queueRequests_pathsAndMethods() throws {
        let create = try XCTUnwrap(manager.createDownloadQueueRequest(serverURL: server, authToken: token))
        XCTAssertEqual(create.httpMethod, "POST")
        XCTAssertEqual(create.url?.path, "/downloadQueue")
        assertNoTokenInURL(create)

        let item = try XCTUnwrap(manager.downloadQueueItemRequest(serverURL: server, authToken: token, queueID: 11, itemID: 134))
        XCTAssertEqual(item.httpMethod, "GET")
        XCTAssertEqual(item.url?.path, "/downloadQueue/11/items/134")
        XCTAssertEqual(item.value(forHTTPHeaderField: "Accept"), "application/json")
        assertNoTokenInURL(item)

        let items = try XCTUnwrap(manager.downloadQueueItemsRequest(serverURL: server, authToken: token, queueID: 11))
        XCTAssertEqual(items.url?.path, "/downloadQueue/11/items")
        assertNoTokenInURL(items)

        let decision = try XCTUnwrap(manager.downloadQueueDecisionRequest(serverURL: server, authToken: token, queueID: 11, itemID: 134))
        XCTAssertEqual(decision.url?.path, "/downloadQueue/11/item/134/decision")

        let delete = try XCTUnwrap(manager.removeDownloadQueueItemRequest(serverURL: server, authToken: token, queueID: 11, itemID: 134))
        XCTAssertEqual(delete.httpMethod, "DELETE")
        XCTAssertEqual(delete.url?.path, "/downloadQueue/11/items/134")

        let identity = try XCTUnwrap(manager.identityRequest(serverURL: server, authToken: token))
        XCTAssertEqual(identity.url?.path, "/identity")
        assertNoTokenInURL(identity)
    }

    func test_mediaRequest() throws {
        let r = try XCTUnwrap(manager.downloadQueueMediaRequest(serverURL: server, authToken: token, queueID: 11, itemID: 134))
        XCTAssertEqual(r.httpMethod, "GET")
        XCTAssertEqual(r.url?.absoluteString, "\(server)/downloadQueue/11/item/134/media")
        assertNoTokenInURL(r)
        XCTAssertNil(r.value(forHTTPHeaderField: "Range"))
    }

    func test_partRequest_addsDownloadFlagAndKeepsTokenInHeader() throws {
        let r = try XCTUnwrap(manager.partDownloadRequest(
            serverURL: server, authToken: token, partKey: "/library/parts/162800/1697172081/file.mkv"))
        XCTAssertEqual(r.url?.absoluteString, "\(server)/library/parts/162800/1697172081/file.mkv?download=1")
        assertNoTokenInURL(r)
    }

    // MARK: - Decoding

    private func data(_ json: String) -> Data { Data(json.utf8) }

    func test_parseIdentityQueueAndAdd() throws {
        XCTAssertEqual(try PlexNetworkManager.parseMachineIdentifier(data(DownloadQueueFixtures.identity)), "0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(try PlexNetworkManager.parseQueueID(data(DownloadQueueFixtures.createQueue)), 11)
        XCTAssertEqual(try PlexNetworkManager.parseAddedItemID(data(DownloadQueueFixtures.addKeysOnly)), 124)
        XCTAssertThrowsError(try PlexNetworkManager.parseAddedItemID(data(#"{"MediaContainer":{"size":0}}"#)))
    }

    func test_parseItem_deciding() throws {
        let item = try PlexNetworkManager.parseDownloadQueueItem(data(DownloadQueueFixtures.pollDeciding), itemID: 134)
        XCTAssertEqual(item, PlexDownloadQueueItem(id: 134, status: .deciding, progress: nil, errorText: nil))
    }

    func test_parseItem_processingCarriesProgress() throws {
        let item = try PlexNetworkManager.parseDownloadQueueItem(data(DownloadQueueFixtures.pollProcessing), itemID: 134)
        XCTAssertEqual(item.status, .processing)
        XCTAssertEqual(item.progress, 5.5)
        XCTAssertNil(item.errorText)
    }

    func test_parseItem_available() throws {
        let item = try PlexNetworkManager.parseDownloadQueueItem(data(DownloadQueueFixtures.pollAvailable), itemID: 134)
        XCTAssertEqual(item, PlexDownloadQueueItem(id: 134, status: .available, progress: nil, errorText: nil))
    }

    func test_parseItems_listPicksRequestedItem() throws {
        let error = try PlexNetworkManager.parseDownloadQueueItem(data(DownloadQueueFixtures.items), itemID: 135)
        XCTAssertEqual(error.status, .error)
        XCTAssertEqual(error.errorText, "Could not construct decision request")

        let processing = try PlexNetworkManager.parseDownloadQueueItem(data(DownloadQueueFixtures.items), itemID: 137)
        XCTAssertEqual(processing.status, .processing)
        XCTAssertEqual(processing.progress ?? 0, 10.4, accuracy: 0.001)

        let waiting = try PlexNetworkManager.parseDownloadQueueItem(data(DownloadQueueFixtures.items), itemID: 138)
        XCTAssertEqual(waiting.status, .waiting)
        XCTAssertNil(waiting.errorText)

        XCTAssertThrowsError(try PlexNetworkManager.parseDownloadQueueItem(data(DownloadQueueFixtures.items), itemID: 999))
    }

    func test_parseLiveItemIDs_matchesKeyAndSkipsFailed() throws {
        XCTAssertEqual(try PlexNetworkManager.parseLiveItemIDs(data(DownloadQueueFixtures.items), ratingKey: "972"), [137])
        XCTAssertEqual(try PlexNetworkManager.parseLiveItemIDs(data(DownloadQueueFixtures.items), ratingKey: "127971"), [])
        XCTAssertEqual(try PlexNetworkManager.parseLiveItemIDs(data(DownloadQueueFixtures.items), ratingKey: "97"), [])
        XCTAssertEqual(try PlexNetworkManager.parseLiveItemIDs(data(#"{"MediaContainer":{"size":0}}"#), ratingKey: "1"), [])
    }

    func test_parseItem_genericProfileErrorShowsServerText() throws {
        let item = try PlexNetworkManager.parseDownloadQueueItem(data(DownloadQueueFixtures.genericError), itemID: 145)
        XCTAssertEqual(item.status, .error)
        XCTAssertEqual(item.errorText, "Neither direct play nor conversion is available.")
    }

    func test_parseItem_jobErrorAfterGoodDecisionShowsJobError() throws {
        let json = #"{"MediaContainer":{"size":1,"DownloadQueueItem":[{"id":7,"queueId":11,"key":"/library/metadata/1","status":"error","error":"diskFull","DecisionResult":{"generalDecisionCode":1001,"generalDecisionText":"Direct play not available; Conversion OK."}}]}}"#
        let item = try PlexNetworkManager.parseDownloadQueueItem(data(json), itemID: 7)
        XCTAssertEqual(item.errorText, "diskFull")
    }

    func test_parseItem_expiredAndUnknownStatus() throws {
        let expired = #"{"MediaContainer":{"size":1,"DownloadQueueItem":[{"id":9,"queueId":11,"key":"/library/metadata/1","status":"expired","DecisionResult":{}}]}}"#
        XCTAssertEqual(try PlexNetworkManager.parseDownloadQueueItem(data(expired), itemID: 9).status, .expired)
        let odd = expired.replacingOccurrences(of: "expired", with: "paused")
        XCTAssertEqual(try PlexNetworkManager.parseDownloadQueueItem(data(odd), itemID: 9).status, .unknown("paused"))
    }

    func test_parseDecision_readsSelectedMediaAndEstimatesSize() throws {
        let decision = try PlexNetworkManager.parseDownloadDecision(data(DownloadQueueFixtures.decision124))
        XCTAssertEqual(decision.width, 1920)
        XCTAssertEqual(decision.height, 1080)
        XCTAssertEqual(decision.bitrateKbps, 4695)
        // No Part size on a conversion: 4695 kbps over 67669 ms.
        XCTAssertEqual(decision.sizeBytes, 4695 * 67669 / 8)
    }

    func test_parseDecision_prefersPartSize() throws {
        let json = #"{"MediaContainer":{"Metadata":[{"Media":[{"id":"1","bitrate":"4000","duration":1000,"width":1280,"height":720,"Part":[{"id":2,"size":38113931}]}]}]}}"#
        let decision = try PlexNetworkManager.parseDownloadDecision(data(json))
        XCTAssertEqual(decision.sizeBytes, 38113931)
        XCTAssertEqual(decision.bitrateKbps, 4000)
    }
}

/// Token-free bodies copied from `dl-research/pms/`.
private enum DownloadQueueFixtures {
    // /identity was not captured; this is its documented shape with a fake id.
    static let identity = #"{"MediaContainer":{"size":0,"claimed":true,"machineIdentifier":"0123456789abcdef0123456789abcdef01234567","version":"1.43.4.10903"}}"#

    // 03_post_queue
    static let createQueue = #"{"MediaContainer":{"size":1,"DownloadQueue":[{"id":11,"owner":1,"clientIdentifier":"rivulet-dl-probe","itemCount":0,"status":"done"}]}}"#

    // 04_add_keysonly
    static let addKeysOnly = #"{"MediaContainer":{"size":1,"AddedQueueItems":[{"key":"/library/metadata/127984","id":124}]}}"#

    // 15_poll_971 (15_item_1, 15_item_2, 15_item_21)
    static let pollDeciding = #"{"MediaContainer":{"size":1,"DownloadQueueItem":[{"id":134,"queueId":11,"key":"/library/metadata/971","status":"deciding","DecisionResult":{}}]}}"#
    static let pollProcessing = #"{"MediaContainer":{"size":1,"DownloadQueueItem":[{"id":134,"queueId":11,"key":"/library/metadata/971","status":"processing","DecisionResult":{"generalDecisionCode":1001,"generalDecisionText":"Direct play not available; Conversion OK.","directPlayDecisionCode":3000,"directPlayDecisionText":"App cannot direct play this item. No direct play video profile exists for protocol http, with container mkv, and video codec hevc.","transcodeDecisionCode":1001,"transcodeDecisionText":"Direct play not available; Conversion OK."},"TranscodeSession":{"key":"/transcode/sessions/96afa1cd-8004-45f3-9a13-6dc2f0d703e4","throttled":false,"complete":false,"progress":5.5,"size":9961520,"speed":72.0,"error":false,"duration":1320778,"remaining":24,"context":"static","sourceVideoCodec":"hevc","sourceAudioCodec":"aac","videoDecision":"transcode","audioDecision":"transcode","protocol":"http","container":"mp4","videoCodec":"h264","audioCodec":"aac","audioChannels":2,"transcodeHwRequested":true,"transcodeHwFullPipeline":true,"offlineTranscode":false}}]}}"#
    static let pollAvailable = #"{"MediaContainer":{"size":1,"DownloadQueueItem":[{"id":134,"queueId":11,"key":"/library/metadata/971","status":"available","DecisionResult":{"generalDecisionCode":1001,"generalDecisionText":"Direct play not available; Conversion OK.","directPlayDecisionCode":3000,"directPlayDecisionText":"App cannot direct play this item. No direct play video profile exists for protocol http, with container mkv, and video codec hevc.","transcodeDecisionCode":1001,"transcodeDecisionText":"Direct play not available; Conversion OK."}}]}}"#

    // 17_items (TranscodeSession trimmed)
    static let items = #"{"MediaContainer":{"size":4,"DownloadQueueItem":[{"id":135,"queueId":11,"key":"/library/metadata/99999999","status":"error","error":"decisionError","DecisionResult":{"generalDecisionCode":2004,"generalDecisionText":"Could not construct decision request"}},{"id":136,"queueId":11,"key":"/library/metadata/127971","status":"error","error":"decisionError","DecisionResult":{"generalDecisionCode":2004,"generalDecisionText":"Could not construct decision request"}},{"id":137,"queueId":11,"key":"/library/metadata/972","status":"processing","DecisionResult":{"generalDecisionCode":1001,"generalDecisionText":"Direct play not available; Conversion OK.","transcodeDecisionCode":1001,"transcodeDecisionText":"Direct play not available; Conversion OK."},"TranscodeSession":{"key":"/transcode/sessions/ba01c4a4-e7ac-48f9-a0a1-966e176f0d91","throttled":false,"complete":false,"progress":10.399999618530274,"size":6815792,"speed":26.600000381469728,"error":false,"duration":1282823,"remaining":32,"context":"static","protocol":"http","container":"mp4"}},{"id":138,"queueId":11,"key":"/library/metadata/973","status":"waiting","DecisionResult":{"generalDecisionCode":1001,"generalDecisionText":"Direct play not available; Conversion OK.","directPlayDecisionCode":3000,"directPlayDecisionText":"App cannot direct play this item. No direct play video profile exists for protocol http, with container mkv, and video codec hevc.","transcodeDecisionCode":1001,"transcodeDecisionText":"Direct play not available; Conversion OK."}}]}}"#

    // 21_generic_error
    static let genericError = #"{"MediaContainer":{"size":1,"DownloadQueueItem":[{"id":145,"queueId":11,"key":"/library/metadata/127984","status":"error","error":"decisionError","DecisionResult":{"generalDecisionCode":2000,"generalDecisionText":"Neither direct play nor conversion is available.","directPlayDecisionCode":3000,"directPlayDecisionText":"App cannot direct play item. No direct play video profile exists for protocol http, with container mkv, and video codec h264.","transcodeDecisionCode":4005,"transcodeDecisionText":"Cannot convert this item. No conversion profile found for protocol http."}}]}}"#

    // 08_decision_124 (Metadata trimmed to Media; Streams and file path removed)
    static let decision124 = #"{"MediaContainer":{"size":1,"directPlayDecisionCode":3000,"generalDecisionCode":1001,"generalDecisionText":"Direct play not available; Conversion OK.","transcodeDecisionCode":1001,"Metadata":[{"ratingKey":"127984","key":"/library/metadata/127984","type":"episode","title":"The One","duration":67669,"Media":[{"audioProfile":"lc","id":"161091","videoProfile":"high","audioChannels":2,"audioCodec":"aac","bitrate":4695,"container":"mp4","duration":67669,"height":1080,"optimizedForStreaming":true,"videoCodec":"h264","videoFrameRate":"24p","videoResolution":"1080p","width":1920,"selected":true,"Part":[{"id":"162800","bitrate":4695,"container":"mp4","duration":67669,"height":1080,"width":1920,"decision":"transcode","selected":true}]}]}]}}"#
}
