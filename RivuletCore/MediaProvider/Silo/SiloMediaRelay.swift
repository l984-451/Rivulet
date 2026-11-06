// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import Network

/// Refreshable transport for native media, including AVFoundation HLS and
/// independently decoded subtitles (neither reads Aether's live header store).
/// Only registered GET/HEAD resources are exposed on a random loopback mount.
/// Media bodies stream with URLSession backpressure; only bounded playlists
/// are buffered, because their child URIs must remain inside this transport.
nonisolated final class SiloMediaRelay: @unchecked Sendable {
    private nonisolated struct Scope: Sendable {
        let id: UUID
        let originURL: URL
        let headers: [String: String]
        let reportsSessionFaults: Bool
    }
    private nonisolated struct VariableContext: Sendable {
        static let empty = VariableContext(id: nil, values: [:], byteCount: 0)
        let id: UUID?
        let values: [String: String]
        let byteCount: Int
    }
    private nonisolated struct Resource: Sendable {
        let id: UUID
        let url: URL
        let scope: Scope
        let inheritedVariables: VariableContext
    }
    private nonisolated struct Registration: Sendable {
        let path: String
        let resource: Resource
    }
    private nonisolated final class RegistrationBatch {
        let allocation: SiloMediaAllocationBudget.Lease
        var registrations: [String: Registration] = [:]
        var contexts: [UUID: VariableContext] = [:]
        init(budget: SiloMediaAllocationBudget) { allocation = budget.lease() }
    }
    private nonisolated final class Transfer: @unchecked Sendable {
        let id: UUID
        let connection: NWConnection
        let resource: Resource
        let method: String
        let requestHeaders: [String: String]
        var currentURL: URL
        var task: URLSessionDataTask?
        var response: HTTPURLResponse?
        var playlist = false
        var playlistBody = Data()
        var problemBody = Data()
        var captureProblem = false
        var receivedBodyBytes = false
        var refreshed = false
        var pendingSends = 0
        var finished = false
        var redirects = 0

        init(id: UUID, connection: NWConnection, resource: Resource, method: String, headers: [String: String]) {
            self.id = id; self.connection = connection; self.resource = resource
            self.method = method; requestHeaders = headers; currentURL = resource.url
        }
    }

    private let client: SiloClient
    private let listener: NWListener
    private let allocationBudget: SiloMediaAllocationBudget
    private let retainedAllocation: SiloMediaAllocationBudget.Lease
    private let queue = DispatchQueue(label: "com.rivulet.silo-media-relay")
    private let lock = NSLock()
    private let mount = UUID().uuidString.lowercased()
    private var resources: [String: Resource] = [:]
    private var resourcePaths: [String: String] = [:]
    private var variableContexts: [UUID: VariableContext] = [:]
    private var stopped = false
    private var port: UInt16?
    // These three are confined to queue (including the URLSession delegate).
    private var connections: [UUID: NWConnection] = [:]
    private var transfers: [UUID: Transfer] = [:]
    private var tasks: [Int: Transfer] = [:]
    private let delegate = SiloMediaRelayDelegate()
    private var session: URLSession!
    var onSessionProblem: (@Sendable (SiloAPIError) -> Void)?

    private static let headerEnd = Data("\r\n\r\n".utf8)
    private static let maximumHeadBytes = 32_768
    private static let maximumProblemBytes = 8_192
    private static let maximumPlaylistBytes = SiloHLSVariables.maximumPlaylistBytes
    private static let forwardedRequestHeaders: Set<String> = [
        "range", "if-range", "if-none-match", "if-modified-since", "accept", "user-agent"
    ]
    private static let reservedGrantHeaders: Set<String> = [
        "host", "connection", "content-length", "transfer-encoding", "proxy-authorization",
        "proxy-connection", "range", "if-range", "if-none-match", "if-modified-since"
    ]
    private static let forwardedResponseHeaders = [
        "Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "ETag",
        "Last-Modified", "Cache-Control", "Retry-After", "Content-Encoding"
    ]
    private static let uriAttribute = try! NSRegularExpression(pattern: #"(?<=[:,])URI="([^"]*)""#)

    private init(client: SiloClient, configuration: URLSessionConfiguration, retainedByteLimit: Int) throws {
        self.client = client
        let budget = SiloMediaAllocationBudget(limit: retainedByteLimit)
        allocationBudget = budget
        retainedAllocation = budget.lease()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        delegate.owner = self
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
    }

    static func start(client: SiloClient, configuration: URLSessionConfiguration = .ephemeral,
                      retainedByteLimit: Int = SiloMediaAllocationBudget.defaultLimit) async throws -> SiloMediaRelay {
        let relay = try SiloMediaRelay(client: client, configuration: configuration, retainedByteLimit: retainedByteLimit)
        relay.listener.newConnectionHandler = { [weak relay] connection in relay?.accept(connection) }
        let ready = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            relay.listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    relay.lock.withLock { relay.port = relay.listener.port?.rawValue }
                    relay.listener.stateUpdateHandler = nil
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    relay.listener.stateUpdateHandler = nil
                    continuation.resume(returning: false)
                default: break
                }
            }
            relay.listener.start(queue: relay.queue)
        }
        guard ready else {
            relay.stop()
            throw MediaProviderError.backendSpecific(underlying: "Could not start Silo's authenticated media transport.")
        }
        do { try Task.checkCancellation() }
        catch { relay.stop(); throw error }
        return relay
    }

    deinit {
        listener.cancel()
        session.invalidateAndCancel()
    }

    func localURL(for url: URL, headers: [String: String] = [:], reportsSessionFaults: Bool = false) throws -> URL {
        let batch = RegistrationBatch(budget: allocationBudget)
        let result = try register(url, scope: Scope(id: UUID(), originURL: url, headers: headers, reportsSessionFaults: reportsSessionFaults), batch: batch)
        try commit(batch)
        return result
    }

    /// Idempotent. No new registered resource or in-flight response can revive
    /// a relay after its native playback session has been retired.
    func stop() {
        let shouldStop = lock.withLock {
            guard !stopped else { return false }
            stopped = true
            resources.removeAll()
            resourcePaths.removeAll()
            variableContexts.removeAll()
            retainedAllocation.reset()
            return true
        }
        guard shouldStop else { return }
        listener.cancel()
        session.invalidateAndCancel()
        queue.async { [self] in
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
            transfers.removeAll()
            tasks.removeAll()
        }
    }

    private func register(_ url: URL, scope: Scope, variables: VariableContext = .empty,
                          batch: RegistrationBatch) throws -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { throw SiloSignInError.invalidResponse }
        return try lock.withLock {
            guard !stopped, let port else { throw CancellationError() }
            let target = url.absoluteString
            let key = scope.id.uuidString + "|" + (variables.id?.uuidString ?? "") + "|" + target
            if let path = resourcePaths[key] ?? batch.registrations[key]?.path {
                guard let local = URL(string: "http://127.0.0.1:\(port)" + path) else { throw SiloSignInError.invalidResponse }
                return local
            }
            let resourceID = UUID()
            let name = SiloClient.pathComponent(url.lastPathComponent.isEmpty ? "media" : url.lastPathComponent)
            let path = "/\(mount)/\(resourceID.uuidString.lowercased())/\(name)"
            guard let local = URL(string: "http://127.0.0.1:\(port)" + path) else { throw SiloSignInError.invalidResponse }
            // Charge both retained URL/key representations and the inherited
            // variable context before a capability can retain any of them.
            try batch.allocation.reserve(target.utf8.count + key.utf8.count + 2 * path.utf8.count + variables.byteCount)
            let resource = Resource(id: resourceID, url: url, scope: scope, inheritedVariables: variables)
            batch.registrations[key] = Registration(path: path, resource: resource)
            return local
        }
    }

    private func commit(_ batch: RegistrationBatch) throws {
        try lock.withLock {
            guard !stopped else { throw CancellationError() }
            for (key, registration) in batch.registrations {
                resourcePaths[key] = registration.path
                resources[registration.path] = registration.resource
            }
            for (parent, context) in batch.contexts { variableContexts[parent] = context }
            batch.allocation.transfer(to: retainedAllocation)
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !lock.withLock({ stopped }) else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: self?.close(id)
            default: break
            }
        }
        connection.start(queue: queue)
        readHead(connection, id: id, buffered: Data())
    }

    private func readHead(_ connection: NWConnection, id: UUID, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, complete, error in
            guard let self, let data, error == nil else { connection.cancel(); return }
            var buffer = buffered
            buffer.append(data)
            guard buffer.count <= Self.maximumHeadBytes else { self.reject(connection, id: id, status: 431); return }
            guard let end = buffer.range(of: Self.headerEnd) else {
                if complete { self.close(id) }
                else { self.readHead(connection, id: id, buffered: buffer) }
                return
            }
            let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let first = lines.first?.split(separator: " ") ?? []
            guard first.count == 3, ["GET", "HEAD"].contains(first[0]),
                  first[1].hasPrefix("/"), let target = URLComponents(string: String(first[1])),
                  target.host == nil, target.scheme == nil, target.query == nil,
                  let resource = self.lock.withLock({ self.resources[target.percentEncodedPath] }),
                  end.upperBound == buffer.endIndex else { self.reject(connection, id: id, status: 400); return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { self.reject(connection, id: id, status: 400); return }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if ["content-length", "transfer-encoding"].contains(name), value != "0" {
                    self.reject(connection, id: id, status: 400); return
                }
                if Self.forwardedRequestHeaders.contains(name) { headers[name] = value }
            }
            let transfer = Transfer(id: id, connection: connection, resource: resource, method: String(first[0]), headers: headers)
            self.transfers[id] = transfer
            self.begin(transfer, forceRefresh: false)
        }
    }

    private func begin(_ transfer: Transfer, forceRefresh: Bool) {
        let url = transfer.currentURL
        let supplied = scopedHeaders(transfer.resource.scope, for: url)
        Task { [weak self, client] in
            do {
                let headers = try await client.mediaHeaders(for: url, supplied: supplied, forceRefresh: forceRefresh)
                self?.queue.async { [weak self] in
                    guard let self, self.transfers[transfer.id] === transfer else { return }
                    var request = URLRequest(url: url)
                    request.httpMethod = transfer.method
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    for (key, value) in transfer.requestHeaders { request.setValue(value, forHTTPHeaderField: key) }
                    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
                    // URLSession decodes content codings, so ask for identity
                    // to preserve byte ranges and the origin's Content-Length.
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    let task = self.session.dataTask(with: request)
                    transfer.task = task
                    self.tasks[task.taskIdentifier] = transfer
                    task.resume()
                }
            } catch {
                self?.queue.async { [weak self] in
                    guard let self, self.transfers[transfer.id] === transfer else { return }
                    self.reject(transfer.connection, id: transfer.id, status: 502)
                }
            }
        }
    }

    private func scopedHeaders(_ scope: Scope, for url: URL) -> [String: String] {
        guard SiloClient.origin(scope.originURL) == SiloClient.origin(url) else { return [:] }
        // A native plan's fixed headers may not escape its configured web root.
        if client.owns(scope.originURL), !client.owns(url) { return [:] }
        return scope.headers.filter { key, _ in
            let name = key.lowercased()
            guard !Self.reservedGrantHeaders.contains(name) else { return false }
            // Authorization in an explicitly registered foreign scope is its
            // own stream grant. Only Silo profile/device credentials are barred.
            return client.owns(url) || !(name == "x-profile-id" || name == "x-profile-token" ||
                                          name.hasPrefix("x-silo-device-"))
        }
    }

    fileprivate func receive(_ task: URLSessionDataTask, response: URLResponse,
                              completion: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let transfer = tasks[task.taskIdentifier], let http = response as? HTTPURLResponse else { completion(.cancel); return }
        if http.statusCode == 401, !transfer.refreshed, client.canRefreshMediaCredentials, client.owns(transfer.currentURL) {
            transfer.refreshed = true
            tasks.removeValue(forKey: task.taskIdentifier)
            completion(.cancel)
            begin(transfer, forceRefresh: true)
            return
        }
        guard !(300...399).contains(http.statusCode) || http.statusCode == 304 else {
            completion(.cancel)
            reject(transfer.connection, id: transfer.id, status: 502)
            return
        }
        transfer.response = http
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let isPlaylist = transfer.currentURL.pathExtension.lowercased() == "m3u8" || contentType.contains("mpegurl")
        let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        guard !(isPlaylist && http.statusCode == 206),
              !(http.statusCode == 206 && encoding != nil && encoding != "identity") else {
            completion(.cancel)
            reject(transfer.connection, id: transfer.id, status: 502)
            return
        }
        transfer.captureProblem = transfer.method != "HEAD" && transfer.resource.scope.reportsSessionFaults
            && client.owns(transfer.currentURL)
            && [404, 409, 410].contains(http.statusCode)
            && (contentType.contains("json") || contentType.contains("problem"))
            && http.expectedContentLength <= Int64(Self.maximumProblemBytes)
        transfer.playlist = transfer.method != "HEAD" && http.statusCode == 200 && isPlaylist
        if transfer.playlist && http.expectedContentLength > Int64(Self.maximumPlaylistBytes) {
            completion(.cancel)
            reject(transfer.connection, id: transfer.id, status: 502)
            return
        }
        if !transfer.playlist { send(Self.responseHead(http), transfer: transfer) }
        completion(.allow)
    }

    fileprivate func receive(_ task: URLSessionDataTask, data: Data) {
        guard let transfer = tasks[task.taskIdentifier] else { return }
        if !data.isEmpty { transfer.receivedBodyBytes = true }
        if transfer.captureProblem {
            if transfer.problemBody.count + data.count <= Self.maximumProblemBytes { transfer.problemBody.append(data) }
            else { transfer.captureProblem = false; transfer.problemBody.removeAll() }
        }
        if transfer.playlist {
            guard transfer.playlistBody.count + data.count <= Self.maximumPlaylistBytes else {
                reject(transfer.connection, id: transfer.id, status: 502); return
            }
            transfer.playlistBody.append(data)
        } else {
            task.suspend()
            send(data, transfer: transfer, resume: task)
        }
    }

    fileprivate func completed(_ task: URLSessionTask, error: Error?) {
        guard let transfer = tasks.removeValue(forKey: task.taskIdentifier) else { return }
        if error == nil, transfer.resource.scope.reportsSessionFaults,
           client.owns(transfer.currentURL), let response = transfer.response,
           response.statusCode == 410, !transfer.receivedBodyBytes {
            // The native stream deny marker is documented to return 410 with
            // no bytes on some routes. Only a plan-owned media scope may use it.
            onSessionProblem?(SiloAPIError(type: "https://siloserver.org/docs/api/v2/problems/playback_session_ended",
                                           title: "Playback session ended", status: 410, detail: "", errors: nil))
        }
        if error == nil, transfer.captureProblem, let response = transfer.response,
           let problem = Self.nativeProblem(from: transfer.problemBody, status: response.statusCode),
           SiloPlaybackSessionFault.classifyMedia(problem) != nil {
            onSessionProblem?(problem)
        }
        if transfer.playlist {
            guard error == nil, let response = transfer.response,
                  let playlist = String(data: transfer.playlistBody, encoding: .utf8), playlist.hasPrefix("#EXTM3U") else {
                reject(transfer.connection, id: transfer.id, status: 502); return
            }
            do {
                let rewritten = try rewrite(playlist, relativeTo: transfer.currentURL, resource: transfer.resource)
                let data = Data(rewritten.utf8)
                send(Self.responseHead(response, rewrittenLength: data.count), transfer: transfer)
                send(data, transfer: transfer)
            } catch { reject(transfer.connection, id: transfer.id, status: 502); return }
        } else if error != nil, transfer.response == nil {
            reject(transfer.connection, id: transfer.id, status: 502); return
        }
        // An upstream failure after bytes started closes this response. The
        // original Content-Length lets the reader detect truncation correctly.
        transfer.finished = true
        if transfer.pendingSends == 0 { close(transfer.id) }
    }

    fileprivate func redirect(_ task: URLSessionTask, to request: URLRequest,
                              completion: @escaping @Sendable (URLRequest?) -> Void) {
        guard let transfer = tasks[task.taskIdentifier], let url = request.url,
              transfer.redirects < 5,
              SiloClient.origin(url) == SiloClient.origin(transfer.resource.url),
              !client.owns(transfer.resource.url) || client.owns(url),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else {
            completion(nil); return
        }
        transfer.redirects += 1
        transfer.currentURL = url
        let supplied = scopedHeaders(transfer.resource.scope, for: url)
        Task { [client] in
            do {
                let headers = try await client.mediaHeaders(for: url, supplied: supplied)
                var redirected = URLRequest(url: url)
                redirected.httpMethod = transfer.method
                for (key, value) in transfer.requestHeaders { redirected.setValue(value, forHTTPHeaderField: key) }
                for (key, value) in headers { redirected.setValue(value, forHTTPHeaderField: key) }
                redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                completion(redirected)
            } catch { completion(nil) }
        }
    }

    private func rewrite(_ playlist: String, relativeTo url: URL, resource: Resource) throws -> String {
        let parser = try SiloHLSVariables(playlist, url: url, inherited: resource.inheritedVariables.values, budget: allocationBudget)
        let batch = RegistrationBatch(budget: allocationBudget)
        let exports = try variableContext(parser.exports, parent: resource.id, batch: batch)
        var variables: [String: String] = [:]
        var output = ""
        var bytes = 0
        var first = true
        for index in parser.lines.indices {
            guard let line = try parser.line(at: index, variables: &variables) else { continue }
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            var result = line
            if !text.isEmpty && !text.hasPrefix("#") {
                result = try rewrittenURL(text, relativeTo: url, scope: resource.scope, variables: exports, batch: batch).absoluteString
            } else {
                for match in Self.uriAttribute.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                    guard let range = Range(match.range(at: 1), in: result) else { throw SiloSignInError.invalidResponse }
                    let replacement = try rewrittenURL(String(result[range]), relativeTo: url,
                                                       scope: resource.scope, variables: exports, batch: batch).absoluteString
                    result.replaceSubrange(range, with: replacement)
                }
            }
            bytes += result.utf8.count + (first ? 0 : 1)
            guard bytes <= Self.maximumPlaylistBytes else { throw SiloSignInError.invalidResponse }
            if !first { output.append("\n") }
            output.append(result)
            first = false
        }
        // No child is published until the entire parse/rewrite and cumulative
        // reservation succeed. A failed batch releases all temporary charges.
        try commit(batch)
        return output
    }

    private func variableContext(_ values: [String: String], parent: UUID, batch: RegistrationBatch) throws -> VariableContext {
        guard !values.isEmpty else { return .empty }
        return try lock.withLock {
            guard !stopped else { throw CancellationError() }
            if let previous = variableContexts[parent], previous.values == values { return previous }
            let bytes = values.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
            try batch.allocation.reserve(bytes)
            let context = VariableContext(id: UUID(), values: values, byteCount: bytes)
            batch.contexts[parent] = context
            return context
        }
    }

    private func rewrittenURL(_ value: String, relativeTo url: URL, scope: Scope,
                              variables: VariableContext, batch: RegistrationBatch) throws -> URL {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SiloSignInError.invalidResponse }
        let target: URL?
        if client.owns(url), value.hasPrefix("/api/v2/") || value.hasPrefix("/api/v3/") {
            target = client.mediaURL(value)
        } else { target = URL(string: value, relativeTo: url)?.absoluteURL }
        guard let target else { throw SiloSignInError.invalidResponse }
        return try register(target, scope: scope, variables: variables, batch: batch)
    }

    private static func nativeProblem(from body: Data, status: Int) -> SiloAPIError? {
        if let problem = try? SiloJSON.decoder().decode(SiloAPIError.self, from: body), problem.status == status {
            return problem
        }
        // The native stream proxy also uses the documented {error,message}
        // envelope. Accept only exact session codes, never the message text.
        struct ProxyProblem: Decodable { let error: String; let message: String }
        guard let proxy = try? JSONDecoder().decode(ProxyProblem.self, from: body),
              (status == 404 && proxy.error == "playback_session_not_found") ||
              (status == 409 && proxy.error == "installation_changed") ||
              (status == 410 && proxy.error == "playback_session_ended") else { return nil }
        return SiloAPIError(type: "https://siloserver.org/docs/api/v2/problems/\(proxy.error)",
                            title: proxy.error, status: status, detail: proxy.message, errors: nil)
    }

    private static func responseHead(_ response: HTTPURLResponse, rewrittenLength: Int? = nil) -> Data {
        var head = "HTTP/1.1 \(response.statusCode) Relayed\r\nConnection: close\r\n"
        let decoded = response.value(forHTTPHeaderField: "Content-Encoding").map { $0.lowercased() != "identity" } ?? false
        for name in forwardedResponseHeaders {
            if rewrittenLength != nil && ["Content-Length", "Content-Encoding", "ETag", "Content-Range"].contains(name) { continue }
            if decoded && ["Content-Length", "Content-Encoding"].contains(name) { continue }
            if let value = response.value(forHTTPHeaderField: name), !value.contains("\r"), !value.contains("\n") {
                head += "\(name): \(value)\r\n"
            }
        }
        if let rewrittenLength { head += "Content-Length: \(rewrittenLength)\r\n" }
        return Data((head + "\r\n").utf8)
    }

    private func send(_ data: Data, transfer: Transfer, resume task: URLSessionDataTask? = nil) {
        transfer.pendingSends += 1
        transfer.connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { self.close(transfer.id); return }
            transfer.pendingSends -= 1
            task?.resume()
            if transfer.finished && transfer.pendingSends == 0 { self.close(transfer.id) }
        })
    }

    private func reject(_ connection: NWConnection, id: UUID, status: Int) {
        if let transfer = transfers.removeValue(forKey: id), let task = transfer.task {
            tasks.removeValue(forKey: task.taskIdentifier)
            task.cancel()
        }
        let head = Data("HTTP/1.1 \(status) Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: head, completion: .contentProcessed { [weak self] _ in self?.close(id) })
    }

    private func close(_ id: UUID) {
        if let transfer = transfers.removeValue(forKey: id), let task = transfer.task {
            tasks.removeValue(forKey: task.taskIdentifier)
            task.cancel()
        }
        connections.removeValue(forKey: id)?.cancel()
    }
}

/// Weak forwarding avoids a URLSession/delegate/relay retain cycle. Only the
/// relay's serial queue handles delegate state; TLS uses system trust unchanged.
private nonisolated final class SiloMediaRelayDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    weak var owner: SiloMediaRelay?

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let owner else { completionHandler(.cancel); return }
        owner.receive(dataTask, response: response, completion: completionHandler)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        owner?.receive(dataTask, data: data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        owner?.completed(task, error: error)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let owner else { completionHandler(nil); return }
        owner.redirect(task, to: request, completion: completionHandler)
    }
}
