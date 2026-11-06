// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  FakeEmbyServer.swift
//  RivuletTests
//
//  In-memory transport for EmbyClient. Routes match a method and the exact
//  request path (so a stray or missing "/emby" is a miss); anything unrouted
//  fails like an unreachable host. A route with several responses serves them
//  in order and repeats the last. Every request is recorded and its
//  Authorization header checked against the one form Emby is sent.
//

import Foundation
@testable import Rivulet

nonisolated final class FakeEmbyServer: @unchecked Sendable {
    struct Reply {
        var status = 200
        var body = ""
        var contentType = "application/json"
    }

    private struct Route {
        let method: String
        let path: String
        let query: [String: String]
        var replies: [Reply]
    }

    private let lock = NSLock()
    private var routes: [Route] = []
    private var recorded: [URLRequest] = []
    private var problems: [String] = []

    /// `path` is the full request path, e.g. "/System/Info/Public". `query` narrows a route
    /// to requests carrying every listed parameter.
    func respond(_ path: String, method: String = "GET", query: [String: String] = [:],
                 status: Int = 200, body: String = "", contentType: String = "application/json") {
        respond(path, method: method, query: query, replies: [Reply(status: status, body: body, contentType: contentType)])
    }

    func respond(_ path: String, method: String = "GET", query: [String: String] = [:], replies: [Reply]) {
        lock.withLock { routes.append(Route(method: method, path: path, query: query, replies: replies)) }
    }

    func reset() {
        lock.withLock { routes = []; recorded = []; problems = [] }
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    /// Requests whose Authorization header was not the MediaBrowser form, or that carried a
    /// legacy token header. Empty when every request was well formed.
    var headerProblems: [String] { lock.withLock { problems } }

    func requests(_ method: String, _ path: String) -> [URLRequest] {
        requests.filter { $0.httpMethod == method && $0.url?.path == path }
    }

    /// The JSON body of the `index`th request, as a dictionary.
    func jsonBody(_ index: Int) -> [String: Any] {
        let data = requests[index].httpBody ?? Data()
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    var transport: EmbyClient.Transport {
        { [self] request in
            let sent = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let reply = lock.withLock { () -> Reply? in
                recorded.append(request)
                problems += Self.authorizationProblems(request)
                guard let index = routes.firstIndex(where: { route in
                    route.method == (request.httpMethod ?? "GET") && route.path == request.url!.path
                        && route.query.allSatisfy { key, value in sent.contains { $0.name == key && $0.value == value } }
                }) else { return nil }
                let replies = routes[index].replies
                if replies.count > 1 { routes[index].replies.removeFirst() }
                return replies[0]
            }
            guard let reply else { throw URLError(.cannotConnectToHost) }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                           headerFields: ["Content-Type": reply.contentType])!
            return (Data(reply.body.utf8), response)
        }
    }

    private static func authorizationProblems(_ request: URLRequest) -> [String] {
        let label = "\(request.httpMethod ?? "GET") \(request.url!.path)"
        var found: [String] = []
        let header = request.value(forHTTPHeaderField: "Authorization") ?? ""
        for part in [#"MediaBrowser Client="Rivulet", Device=""#, #"", DeviceId=""#, #"", Version=""#] where !header.contains(part) {
            found.append("\(label): Authorization lacks \(part)")
        }
        for legacy in ["X-Emby-Token", "X-Emby-Authorization", "X-MediaBrowser-Token"]
        where request.value(forHTTPHeaderField: legacy) != nil {
            found.append("\(label): sent \(legacy)")
        }
        return found
    }
}
