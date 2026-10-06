// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexDownloadQueue.swift
//  Rivulet
//
//  Plex download endpoints: the original part file and the server download
//  queue for converted sizes. Shapes measured on PMS 1.43.4.
//

import Foundation

/// One item in a PMS download queue.
nonisolated struct PlexDownloadQueueItem: Sendable, Equatable {
    nonisolated enum Status: Sendable, Equatable {
        case deciding, waiting, processing, available, error, expired
        case unknown(String)

        init(_ raw: String) {
            switch raw {
            case "deciding": self = .deciding
            case "waiting": self = .waiting
            case "processing": self = .processing
            case "available": self = .available
            case "error": self = .error
            case "expired": self = .expired
            default: self = .unknown(raw)
            }
        }
    }

    let id: Int
    let status: Status
    /// Server transcode progress, 0 to 100, present only while processing.
    let progress: Double?
    /// The server's reason, set only when status is error.
    let errorText: String?
}

/// What a queued conversion produces, from its decision.
nonisolated struct PlexDownloadDecision: Sendable, Equatable {
    let width: Int?
    let height: Int?
    let bitrateKbps: Int?
    /// The part size when reported, else bitrate times duration.
    let sizeBytes: Int?
}

extension PlexNetworkManager {

    /// Lets low-bitrate HEVC sources remux instead of re-encoding to H.264.
    static let downloadProfileExtra =
        "append-transcode-target-codec(type=videoProfile&context=static&protocol=http&videoCodec=hevc)"

    // MARK: - Calls

    /// The server's machineIdentifier, the stable key for stored downloads.
    func serverIdentity(serverURL: String, authToken: String) async throws -> String {
        try Self.parseMachineIdentifier(await send(identityRequest(serverURL: serverURL, authToken: authToken)))
    }

    /// The queue for this client. PMS keys it by client identifier, so repeats return the same id.
    func downloadQueueID(serverURL: String, authToken: String) async throws -> Int {
        try Self.parseQueueID(await send(createDownloadQueueRequest(serverURL: serverURL, authToken: authToken)))
    }

    /// Queues one item for conversion and returns the queue item id.
    func addToDownloadQueue(
        serverURL: String,
        authToken: String,
        queueID: Int,
        ratingKey: String,
        mediaIndex: Int?,
        maxVideoBitrateKbps: Int
    ) async throws -> Int {
        let request = addToDownloadQueueRequest(
            serverURL: serverURL, authToken: authToken, queueID: queueID,
            ratingKey: ratingKey, mediaIndex: mediaIndex, maxVideoBitrateKbps: maxVideoBitrateKbps)
        return try Self.parseAddedItemID(await send(request))
    }

    func downloadQueueItem(serverURL: String, authToken: String, queueID: Int, itemID: Int) async throws -> PlexDownloadQueueItem {
        let request = downloadQueueItemRequest(serverURL: serverURL, authToken: authToken, queueID: queueID, itemID: itemID)
        return try Self.parseDownloadQueueItem(await send(request), itemID: itemID)
    }

    func downloadQueueDecision(serverURL: String, authToken: String, queueID: Int, itemID: Int) async throws -> PlexDownloadDecision {
        let request = downloadQueueDecisionRequest(serverURL: serverURL, authToken: authToken, queueID: queueID, itemID: itemID)
        return try Self.parseDownloadDecision(await send(request))
    }

    /// Deletes the queue item, which also stops its transcode.
    func removeDownloadQueueItem(serverURL: String, authToken: String, queueID: Int, itemID: Int) async throws {
        _ = try await send(removeDownloadQueueItemRequest(serverURL: serverURL, authToken: authToken, queueID: queueID, itemID: itemID))
    }

    /// The queue's items for `ratingKey` that have not failed or expired.
    func liveDownloadQueueItemIDs(serverURL: String, authToken: String, queueID: Int, ratingKey: String) async throws -> [Int] {
        let request = downloadQueueItemsRequest(serverURL: serverURL, authToken: authToken, queueID: queueID)
        return try Self.parseLiveItemIDs(await send(request), ratingKey: ratingKey)
    }

    // MARK: - Requests (token in headers only)

    func identityRequest(serverURL: String, authToken: String) -> URLRequest? {
        downloadAPIRequest(serverURL, "/identity", authToken: authToken)
    }

    func createDownloadQueueRequest(serverURL: String, authToken: String) -> URLRequest? {
        downloadAPIRequest(serverURL, "/downloadQueue", method: "POST", authToken: authToken)
    }

    func addToDownloadQueueRequest(
        serverURL: String, authToken: String, queueID: Int,
        ratingKey: String, mediaIndex: Int?, maxVideoBitrateKbps: Int
    ) -> URLRequest? {
        var query = [URLQueryItem(name: "keys", value: "/library/metadata/\(ratingKey)")]
        if let mediaIndex { query.append(URLQueryItem(name: "mediaIndex", value: String(mediaIndex))) }
        query.append(URLQueryItem(name: "maxVideoBitrate", value: String(maxVideoBitrateKbps)))
        var request = downloadAPIRequest(serverURL, "/downloadQueue/\(queueID)/add", method: "POST", query: query, authToken: authToken)
        request?.setValue(Self.downloadProfileExtra, forHTTPHeaderField: "X-Plex-Client-Profile-Extra")
        return request
    }

    func downloadQueueItemsRequest(serverURL: String, authToken: String, queueID: Int) -> URLRequest? {
        downloadAPIRequest(serverURL, "/downloadQueue/\(queueID)/items", authToken: authToken)
    }

    func downloadQueueItemRequest(serverURL: String, authToken: String, queueID: Int, itemID: Int) -> URLRequest? {
        downloadAPIRequest(serverURL, "/downloadQueue/\(queueID)/items/\(itemID)", authToken: authToken)
    }

    func downloadQueueDecisionRequest(serverURL: String, authToken: String, queueID: Int, itemID: Int) -> URLRequest? {
        downloadAPIRequest(serverURL, "/downloadQueue/\(queueID)/item/\(itemID)/decision", authToken: authToken)
    }

    func removeDownloadQueueItemRequest(serverURL: String, authToken: String, queueID: Int, itemID: Int) -> URLRequest? {
        downloadAPIRequest(serverURL, "/downloadQueue/\(queueID)/items/\(itemID)", method: "DELETE", authToken: authToken)
    }

    /// The finished conversion. 503 until the item is available.
    func downloadQueueMediaRequest(serverURL: String, authToken: String, queueID: Int, itemID: Int) -> URLRequest? {
        guard let url = URL(string: "\(serverURL)/downloadQueue/\(queueID)/item/\(itemID)/media") else { return nil }
        return downloadRequest(url, authToken: authToken)
    }

    /// The original part file. Send single ranges only: PMS answers a multi-range with the whole file.
    func partDownloadRequest(serverURL: String, authToken: String, partKey: String) -> URLRequest? {
        guard var components = URLComponents(string: "\(serverURL)\(partKey)") else { return nil }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "download", value: "1")]
        guard let url = components.url else { return nil }
        return downloadRequest(url, authToken: authToken)
    }

    // MARK: - Parsing

    nonisolated static func parseMachineIdentifier(_ data: Data) throws -> String {
        nonisolated struct Response: Decodable { nonisolated struct C: Decodable { let machineIdentifier: String? }; let MediaContainer: C }
        guard let id = try decodeRepairingUTF8(Response.self, from: data).MediaContainer.machineIdentifier, !id.isEmpty else {
            throw PlexAPIError.parsingError
        }
        return id
    }

    nonisolated static func parseQueueID(_ data: Data) throws -> Int {
        nonisolated struct Response: Decodable {
            nonisolated struct Q: Decodable { let id: Int }
            nonisolated struct C: Decodable { let DownloadQueue: [Q]? }
            let MediaContainer: C
        }
        guard let id = try decodeRepairingUTF8(Response.self, from: data).MediaContainer.DownloadQueue?.first?.id else {
            throw PlexAPIError.parsingError
        }
        return id
    }

    nonisolated static func parseAddedItemID(_ data: Data) throws -> Int {
        nonisolated struct Response: Decodable {
            nonisolated struct Added: Decodable { let id: Int }
            nonisolated struct C: Decodable { let AddedQueueItems: [Added]? }
            let MediaContainer: C
        }
        guard let id = try decodeRepairingUTF8(Response.self, from: data).MediaContainer.AddedQueueItems?.first?.id else {
            throw PlexAPIError.parsingError
        }
        return id
    }

    nonisolated static func parseLiveItemIDs(_ data: Data, ratingKey: String) throws -> [Int] {
        nonisolated struct Response: Decodable {
            nonisolated struct Item: Decodable { let id: Int; let key: String?; let status: String }
            nonisolated struct C: Decodable { let DownloadQueueItem: [Item]? }
            let MediaContainer: C
        }
        let items = try decodeRepairingUTF8(Response.self, from: data).MediaContainer.DownloadQueueItem ?? []
        return items.filter { $0.key == "/library/metadata/\(ratingKey)" && !["error", "expired"].contains($0.status) }.map(\.id)
    }

    nonisolated static func parseDownloadQueueItem(_ data: Data, itemID: Int) throws -> PlexDownloadQueueItem {
        nonisolated struct Response: Decodable {
            nonisolated struct Decision: Decodable {
                let generalDecisionCode: Int?
                let generalDecisionText: String?
                let transcodeDecisionText: String?
            }
            nonisolated struct Session: Decodable { let progress: Double? }
            nonisolated struct Item: Decodable {
                let id: Int
                let status: String
                let error: String?
                let DecisionResult: Decision?
                let TranscodeSession: Session?
            }
            nonisolated struct C: Decodable { let DownloadQueueItem: [Item]? }
            let MediaContainer: C
        }
        let items = try decodeRepairingUTF8(Response.self, from: data).MediaContainer.DownloadQueueItem ?? []
        guard let item = items.first(where: { $0.id == itemID }) else { throw PlexAPIError.notFound }

        let status = PlexDownloadQueueItem.Status(item.status)
        var errorText: String?
        if status == .error {
            // A failed decision explains itself; otherwise the decision was fine and the job failed.
            let decision = item.DecisionResult
            let decisionOK = decision?.generalDecisionCode.map { (1000..<2000).contains($0) } ?? false
            errorText = decisionOK
                ? item.error
                : decision?.generalDecisionText ?? decision?.transcodeDecisionText ?? item.error
        }
        return PlexDownloadQueueItem(
            id: item.id, status: status, progress: item.TranscodeSession?.progress, errorText: errorText)
    }

    nonisolated static func parseDownloadDecision(_ data: Data) throws -> PlexDownloadDecision {
        nonisolated struct Response: Decodable {
            nonisolated struct Part: Decodable { let size: LenientInt? }
            nonisolated struct Media: Decodable {
                let width, height, bitrate, duration: LenientInt?
                let selected: Bool?
                let Part: [Part]?
            }
            nonisolated struct Meta: Decodable { let Media: [Media]? }
            nonisolated struct C: Decodable { let Metadata: [Meta]? }
            let MediaContainer: C
        }
        let medias = try decodeRepairingUTF8(Response.self, from: data).MediaContainer.Metadata?.first?.Media ?? []
        guard let media = medias.first(where: { $0.selected == true }) ?? medias.first else { throw PlexAPIError.parsingError }

        let bitrate = media.bitrate?.value
        let partSizes = media.Part?.compactMap { $0.size?.value } ?? []
        var size: Int? = partSizes.isEmpty ? nil : partSizes.reduce(0, +)
        if size == nil, let bitrate, let durationMs = media.duration?.value {
            size = bitrate * durationMs / 8
        }
        return PlexDownloadDecision(
            width: media.width?.value, height: media.height?.value, bitrateKbps: bitrate, sizeBytes: size)
    }

    // MARK: - Helpers

    /// PMS sends some ids as strings and some as numbers.
    nonisolated struct LenientInt: Decodable, Sendable {
        let value: Int?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { value = i }
            else if let s = try? c.decode(String.self) { value = Int(s) }
            else if let d = try? c.decode(Double.self) { value = Int(d) }
            else { value = nil }
        }
    }

    /// Identity headers for every download call. Without Platform/Product/Version PMS fails the decision (2004).
    func downloadHeaders(authToken: String) -> [String: String] {
        var headers = plexHeaders(authToken: authToken)
        headers["X-Plex-Version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return headers
    }

    private func downloadRequest(_ url: URL, method: String = "GET", authToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in downloadHeaders(authToken: authToken) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private func downloadAPIRequest(
        _ serverURL: String, _ path: String, method: String = "GET",
        query: [URLQueryItem] = [], authToken: String
    ) -> URLRequest? {
        guard var components = URLComponents(string: serverURL + path) else { return nil }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { return nil }
        var request = downloadRequest(url, method: method, authToken: authToken)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(_ request: URLRequest?) async throws -> Data {
        guard let request, let url = request.url else { throw PlexAPIError.invalidURL }
        return try await requestData(url, method: request.httpMethod ?? "GET", headers: request.allHTTPHeaderFields ?? [:])
    }
}
