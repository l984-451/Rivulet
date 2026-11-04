// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyTestSupport.swift
//  RivuletTests
//

import Foundation
@testable import Rivulet

enum EmbyTestJSON {
    static func decode<T: Decodable>(_ json: String) throws -> T {
        try EmbyJSON.decoder().decode(T.self, from: Data(json.utf8))
    }

    static func result(_ json: String) throws -> EmbyQueryResult { try decode(json) }

    static func items(_ json: String) throws -> [EmbyItem] { try result(json).items ?? [] }

    /// One element of a fixture's `Items` array, as a single-item response body.
    static func item(_ fixture: String, at index: Int = 0) -> String {
        let object = try? JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any]
        let element = (object?["Items"] as? [[String: Any]])?[index] ?? [:]
        let data = (try? JSONSerialization.data(withJSONObject: element)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The `Items` of several fixtures in one response, in order.
    static func merged(_ fixtures: [String], total: Int? = nil) -> String {
        var all: [[String: Any]] = []
        for fixture in fixtures {
            let object = try? JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any]
            all += (object?["Items"] as? [[String: Any]]) ?? []
        }
        let body: [String: Any] = ["Items": all, "TotalRecordCount": total ?? all.count]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: body)) ?? Data(), as: UTF8.self)
    }
}
