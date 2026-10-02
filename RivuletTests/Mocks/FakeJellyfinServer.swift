// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  FakeJellyfinServer.swift
//  RivuletTests
//
//  In-memory transport for JellyfinClient. Routes match on path suffix;
//  anything unrouted fails like an unreachable host. Locked because the
//  client sends from off the main actor.
//

import Foundation
@testable import Rivulet

nonisolated final class FakeJellyfinServer: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [(suffix: String, query: [String: String], status: Int, body: String)] = []
    private var recorded: [URLRequest] = []

    /// `query` narrows a route to requests carrying every listed parameter,
    /// for one path asked several times (once per library, say).
    func respond(_ pathSuffix: String, query: [String: String] = [:], status: Int = 200, body: String = "") {
        lock.withLock { routes.append((pathSuffix, query, status, body)) }
    }

    func reset() {
        lock.withLock { routes = []; recorded = [] }
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    /// The JSON body of the `index`th request, as a dictionary.
    func jsonBody(_ index: Int) -> [String: Any] {
        let data = requests[index].httpBody ?? Data()
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func query(_ index: Int) -> [URLQueryItem] {
        URLComponents(url: requests[index].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    var transport: JellyfinClient.Transport {
        { [self] request in
            let sent = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let match = lock.withLock { () -> (Int, String)? in
                recorded.append(request)
                return routes.first { route in
                    request.url!.path.hasSuffix(route.suffix)
                        && route.query.allSatisfy { key, value in sent.contains { $0.name == key && $0.value == value } }
                }.map { ($0.status, $0.body) }
            }
            guard let (status, body) = match else { throw URLError(.cannotConnectToHost) }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }
}
