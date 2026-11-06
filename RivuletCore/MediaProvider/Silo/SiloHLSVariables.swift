// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// HLS variable semantics are resolved before URIs become loopback capabilities.
/// Definitions are local to one response; only a multivariant parent's exports
/// are eligible for an explicit IMPORT in a child media playlist. See HLS 2nd
/// Edition §§4.3, 4.4.2.3, 6.3.1:
/// https://datatracker.ietf.org/doc/html/draft-pantos-hls-rfc8216bis-22
nonisolated struct SiloHLSVariables {
    // Native node playlists can repeat ~1.7 KiB signed queries for every
    // segment of a feature film. Bound playlists, not ordinary media bodies.
    static let maximumPlaylistBytes = 32 * 1_024 * 1_024

    private nonisolated struct Definition {
        let name: String
        let value: String
    }
    private nonisolated struct Attribute {
        let value: String
        let quoted: Bool
    }
    private static let attributes = try! NSRegularExpression(pattern: #"(?:^|,)([A-Z0-9-]+)=("[^"]*"|[^,]*)"#)
    let lines: [Substring]
    let exports: [String: String]
    private let definitions: [Int: Definition]
    private let allocation: SiloMediaAllocationBudget.Lease

    init(_ playlist: String, url: URL, inherited: [String: String], budget: SiloMediaAllocationBudget) throws {
        let allocation = budget.lease()
        // Bound the retained source-span array before split allocates it, too.
        let lineCount = playlist.utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
        try allocation.reserve(lineCount * MemoryLayout<Substring>.stride)
        let lines = playlist.split(separator: "\n", omittingEmptySubsequences: false)
        let multivariant = lines.contains { line in
            ["#EXT-X-STREAM-INF:", "#EXT-X-I-FRAME-STREAM-INF:", "#EXT-X-MEDIA:",
             "#EXT-X-SESSION-DATA:", "#EXT-X-SESSION-KEY:", "#EXT-X-CONTENT-STEERING:"].contains { line.hasPrefix($0) }
        }
        var definitions: [Int: Definition] = [:]
        var variables: [String: String] = [:]
        for (index, line) in lines.enumerated() {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasPrefix("#EXT-X-DEFINE:") else { continue }
            let expanded = try Self.expandAttributes(text, variables: variables)
            let attributes = try Self.definitionAttributes(String(expanded.dropFirst("#EXT-X-DEFINE:".count)))
            let kinds = ["NAME", "IMPORT", "QUERYPARAM"].filter { attributes[$0] != nil }
            guard kinds.count == 1, let kind = kinds.first, let attribute = attributes[kind],
                  attribute.quoted, Self.validName(attribute.value), variables[attribute.value] == nil else {
                throw SiloSignInError.invalidResponse
            }
            let value: String
            switch kind {
            case "NAME":
                guard let literal = attributes["VALUE"], literal.quoted else { throw SiloSignInError.invalidResponse }
                value = literal.value
            case "IMPORT":
                guard !multivariant, let imported = inherited[attribute.value] else { throw SiloSignInError.invalidResponse }
                value = imported
            default:
                guard let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                      let decoded = query.first(where: { $0.name == attribute.value })?.value else {
                    throw SiloSignInError.invalidResponse
                }
                value = decoded
            }
            guard !value.contains("\""), !value.contains("\r"), !value.contains("\n") else {
                throw SiloSignInError.invalidResponse
            }
            // Charge each retained expanded definition, including aliases and
            // IMPORTs, before either lookup table can retain its value.
            try allocation.reserve(attribute.value.utf8.count + value.utf8.count + 128)
            variables[attribute.value] = value
            definitions[index] = Definition(name: attribute.value, value: value)
        }
        self.lines = lines
        self.definitions = definitions
        self.allocation = allocation
        exports = multivariant ? variables : [:]
    }

    /// Single pass, in source order. Substituted values are not recursively
    /// expanded, and variables declared later cannot resolve earlier references.
    /// DEFINE tags themselves are consumed, keeping signed values off the player.
    func line(at index: Int, variables: inout [String: String]) throws -> String? {
        if let definition = definitions[index] {
            variables[definition.name] = definition.value
            return nil
        }
        let text = String(lines[index])
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") {
            return try Self.expandAttributes(text, variables: variables)
        }
        return try Self.expand(text, variables: variables)
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func expand(_ text: String, variables: [String: String]) throws -> String {
        guard text.contains("{$") else { return text }
        var result = ""
        var cursor = text.startIndex
        var bytes = 0
        while let start = text.range(of: "{$", range: cursor..<text.endIndex) {
            guard let end = text[start.upperBound...].firstIndex(of: "}") else { throw SiloSignInError.invalidResponse }
            let name = String(text[start.upperBound..<end])
            guard validName(name), let value = variables[name] else { throw SiloSignInError.invalidResponse }
            let prefix = text[cursor..<start.lowerBound]
            bytes += prefix.utf8.count + value.utf8.count
            guard bytes <= maximumPlaylistBytes else { throw SiloSignInError.invalidResponse }
            result.append(contentsOf: prefix)
            result.append(value)
            cursor = text.index(after: end)
        }
        let suffix = text[cursor...]
        guard bytes + suffix.utf8.count <= maximumPlaylistBytes else { throw SiloSignInError.invalidResponse }
        result.append(contentsOf: suffix)
        return result
    }

    private static func expandAttributes(_ line: String, variables: [String: String]) throws -> String {
        guard line.contains("{$"), let colon = line.firstIndex(of: ":") else { return line }
        let start = line.index(after: colon)
        let body = String(line[start...])
        var result = body
        var bytes = body.utf8.count
        for match in attributes.matches(in: body, range: NSRange(body.startIndex..., in: body)).reversed() {
            guard let range = Range(match.range(at: 2), in: result) else { throw SiloSignInError.invalidResponse }
            let raw = String(result[range])
            let replacement: String
            if raw.hasPrefix("\"") && raw.hasSuffix("\"") {
                replacement = "\"" + (try expand(String(raw.dropFirst().dropLast()), variables: variables)) + "\""
            } else if raw.hasPrefix("0x") || raw.hasPrefix("0X") {
                replacement = try expand(raw, variables: variables)
            } else { continue }
            bytes += replacement.utf8.count - raw.utf8.count
            guard bytes <= maximumPlaylistBytes else { throw SiloSignInError.invalidResponse }
            result.replaceSubrange(range, with: replacement)
        }
        guard result.utf8.count <= maximumPlaylistBytes else { throw SiloSignInError.invalidResponse }
        return String(line[..<start]) + result
    }

    private static func definitionAttributes(_ body: String) throws -> [String: Attribute] {
        var result: [String: Attribute] = [:]
        var end = 0
        for match in attributes.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard match.range.location == end, let nameRange = Range(match.range(at: 1), in: body),
                  let valueRange = Range(match.range(at: 2), in: body) else { throw SiloSignInError.invalidResponse }
            let name = String(body[nameRange])
            guard result[name] == nil else { throw SiloSignInError.invalidResponse }
            let raw = body[valueRange]
            let quoted = raw.hasPrefix("\"") && raw.hasSuffix("\"")
            result[name] = Attribute(value: quoted ? String(raw.dropFirst().dropLast()) : String(raw), quoted: quoted)
            end = NSMaxRange(match.range)
        }
        guard end == body.utf16.count else { throw SiloSignInError.invalidResponse }
        return result
    }
}
