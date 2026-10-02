// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  XMLTVParser.swift
//  Rivulet
//
//  Parses XMLTV format EPG (Electronic Program Guide) data
//

import Compression
import Foundation

/// Actor for parsing XMLTV EPG data
actor XMLTVParser {

    // MARK: - Parsed Types

    /// Represents a channel from XMLTV
    struct ParsedXMLTVChannel: Sendable {
        let id: String
        let displayName: String
        let iconURL: String?
    }

    /// Represents a program from XMLTV
    struct ParsedProgram: Sendable {
        let channelId: String
        let start: Date
        let stop: Date
        let title: String
        let subtitle: String?
        let description: String?
        let category: String?
        let icon: String?
        /// Programme icon closest to 2:3 (portrait), for the guide poster.
        let posterIcon: String?
        /// Programme icon closest to 16:9 (landscape), for the guide background.
        let landscapeIcon: String?
        let episodeNum: String?
        let isNew: Bool
    }

    // MARK: - Parse Result

    struct ParseResult: Sendable {
        let channels: [String: ParsedXMLTVChannel]  // id -> channel
        let programs: [String: [ParsedProgram]]      // channelId -> programs
    }

    // MARK: - Public Methods

    /// Parse XMLTV data from a URL
    func parse(from url: URL) async throws -> ParseResult {
        // Fetch the URL exactly as supplied — http stays http (no https rewrite).
        let (data, _) = try await fetchData(from: url)
        return try parse(data: data)
    }

    // MARK: - Private Networking

    /// Fetch data from a URL with optional custom timeout
    private func fetchData(from url: URL, timeout: TimeInterval? = nil) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        if let timeout = timeout {
            request.timeoutInterval = timeout
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw XMLTVParseError.httpError(httpResponse.statusCode)
        }

        return (data, response)
    }

    /// Parse XMLTV data from raw data
    func parse(data: Data) throws -> ParseResult {
        // XMLParser does NOT require main thread - actor isolation handles thread safety
        let parser = XMLTVInternalParser()
        return try parser.parse(data: data.starts(with: [0x1f, 0x8b]) ? Self.gunzip(data) : data)
    }

    /// Largest guide we will inflate. A week of a few hundred channels is tens
    /// of megabytes; the cap stops a gzip bomb (deflate expands ~1000x) from
    /// exhausting Apple TV memory.
    static let maxInflatedBytes = 256 * 1024 * 1024

    /// Inflates a gzip file (RFC 1952). `.xml.gz` guides are usually served as
    /// raw gzip with no `Content-Encoding`, so URLSession passes them through
    /// compressed. Only the first member is read; concatenated members are rare.
    static func gunzip(_ data: Data, limit: Int = maxInflatedBytes) throws -> Data {
        let start = data.startIndex
        let end = data.endIndex - 8  // CRC32 + ISIZE trailer
        guard data.count > 18, data[start + 2] == 8 else { throw XMLTVParseError.parseFailed }  // CM 8 = deflate
        let flags = data[start + 3]
        var index = start + 10
        if flags & 0x04 != 0 {  // FEXTRA: 2-byte little-endian length, then the field
            guard index + 2 <= end else { throw XMLTVParseError.parseFailed }
            index += 2 + (Int(data[index]) | Int(data[index + 1]) << 8)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {  // FNAME, FCOMMENT: zero-terminated
            guard index < end, let nul = data[index..<end].firstIndex(of: 0) else { throw XMLTVParseError.parseFailed }
            index = nul + 1
        }
        if flags & 0x02 != 0 { index += 2 }  // FHCRC
        guard index < end else { throw XMLTVParseError.parseFailed }

        // Apple's `.zlib` is raw deflate, which is exactly a gzip member's body.
        var inflated = Data()
        let filter = try OutputFilter(.decompress, using: .zlib) { chunk in
            guard let chunk else { return }
            guard inflated.count + chunk.count <= limit else { throw XMLTVParseError.tooLarge }
            inflated.append(chunk)
        }
        try filter.write(data[index..<end])
        try filter.finalize()
        return inflated
    }

    /// Get programs for a specific channel within a time range
    func getPrograms(
        from result: ParseResult,
        channelId: String,
        startDate: Date,
        endDate: Date
    ) -> [ParsedProgram] {
        guard let programs = result.programs[channelId] else {
            return []
        }

        return programs.filter { program in
            // Include if program overlaps with the time range
            program.stop > startDate && program.start < endDate
        }
    }
}

// MARK: - XMLTV Internal Parser (XMLParserDelegate)

private nonisolated final class XMLTVInternalParser: NSObject, XMLParserDelegate {
    private var channels: [String: XMLTVParser.ParsedXMLTVChannel] = [:]
    private var programs: [String: [XMLTVParser.ParsedProgram]] = [:]

    // Current parsing state
    /// Raw character data of the element being read. XMLParser delivers text in
    /// pieces split at every entity (`Tom &amp; Jerry` arrives as `Tom `, `&`,
    /// ` Jerry`), so the pieces are joined untouched and cleaned once at the end tag.
    private var text = ""
    private var currentChannelId: String?
    private var currentDisplayName: String = ""
    private var currentIconURL: String?

    // Program parsing state
    private var currentProgramChannelId: String?
    private var currentProgramStart: Date?
    private var currentProgramStop: Date?
    private var currentTitle: String = ""
    private var currentSubtitle: String = ""
    private var currentDescription: String = ""
    private var currentCategory: String = ""
    private var currentProgramIcon: String?
    /// All <icon> elements seen for the current programme, with dimensions when
    /// supplied, so we can pick a 2:3 poster and a 16:9 background.
    private var currentProgramIcons: [(url: String, w: Int?, h: Int?)] = []
    private var currentEpisodeNum: String = ""
    private var currentEpisodeNumIsOnscreen = false
    private var currentIsNew: Bool = false

    private var parseError: Error?

    func parse(data: Data) throws -> XMLTVParser.ParseResult {
        let parser = XMLParser(data: data)
        parser.delegate = self

        if !parser.parse() {
            if let error = parseError {
                throw error
            }
            throw XMLTVParseError.parseFailed
        }

        return XMLTVParser.ParseResult(channels: channels, programs: programs)
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""

        switch elementName {
        case "channel":
            currentChannelId = attributeDict["id"]
            currentDisplayName = ""
            currentIconURL = nil

        case "programme":
            currentProgramChannelId = attributeDict["channel"]
            currentProgramStart = parseDate(attributeDict["start"])
            currentProgramStop = parseDate(attributeDict["stop"])
            currentTitle = ""
            currentSubtitle = ""
            currentDescription = ""
            currentCategory = ""
            currentProgramIcon = nil
            currentProgramIcons = []
            currentEpisodeNum = ""
            currentIsNew = false

        case "icon":
            let src = attributeDict["src"]
            if currentChannelId != nil {
                currentIconURL = src
            } else if currentProgramChannelId != nil, let src {
                if currentProgramIcon == nil { currentProgramIcon = src }
                currentProgramIcons.append((url: src,
                                            w: attributeDict["width"].flatMap { Int($0) },
                                            h: attributeDict["height"].flatMap { Int($0) }))
            }

        case "new":
            currentIsNew = true

        case "episode-num":
            currentEpisodeNumIsOnscreen = attributeDict["system"] == "onscreen"

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        // Collapse whitespace runs (pretty-printing, line breaks) and trim.
        let value = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        text = ""

        // Repeated elements (one per language or numbering system) keep the
        // first value rather than gluing them together.
        switch elementName {
        case "display-name":
            if currentDisplayName.isEmpty { currentDisplayName = value }
        case "title":
            if currentTitle.isEmpty { currentTitle = value }
        case "sub-title":
            if currentSubtitle.isEmpty { currentSubtitle = value }
        case "desc":
            if currentDescription.isEmpty { currentDescription = value }
        case "category":
            // Each element is one category, even when its text holds an entity.
            if !value.isEmpty {
                currentCategory += currentCategory.isEmpty ? value : ", " + value
            }
        case "episode-num":
            // Prefer the human-readable "S01E05" over xmltv_ns / dd_progid codes.
            if !value.isEmpty, currentEpisodeNum.isEmpty || currentEpisodeNumIsOnscreen {
                currentEpisodeNum = value
            }

        case "channel":
            if let id = currentChannelId, !currentDisplayName.isEmpty {
                channels[id] = XMLTVParser.ParsedXMLTVChannel(
                    id: id,
                    displayName: currentDisplayName,
                    iconURL: currentIconURL
                )
            }
            currentChannelId = nil

        case "programme":
            if let channelId = currentProgramChannelId,
               let start = currentProgramStart,
               let stop = currentProgramStop,
               !currentTitle.isEmpty {
                let program = XMLTVParser.ParsedProgram(
                    channelId: channelId,
                    start: start,
                    stop: stop,
                    title: currentTitle,
                    subtitle: currentSubtitle.isEmpty ? nil : currentSubtitle,
                    description: currentDescription.isEmpty ? nil : currentDescription,
                    category: currentCategory.isEmpty ? nil : currentCategory,
                    icon: currentProgramIcon,
                    posterIcon: Self.posterIcon(from: currentProgramIcons),
                    landscapeIcon: Self.landscapeIcon(from: currentProgramIcons),
                    episodeNum: currentEpisodeNum.isEmpty ? nil : currentEpisodeNum,
                    isNew: currentIsNew
                )

                if programs[channelId] == nil {
                    programs[channelId] = []
                }
                programs[channelId]?.append(program)
            }
            currentProgramChannelId = nil

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }

    /// Programme poster: the declared-portrait icon closest to 2:3, else the
    /// first icon with no declared dimensions (the views measure that one
    /// before trusting it). An icon declared landscape is never a poster, so a
    /// feed whose only art is landscape yields nil and the poster slot falls
    /// back to the channel logo.
    ///
    /// Declared dimensions only: parsing must not depend on anything the UI
    /// has measured, or the same feed would parse differently per session.
    static func posterIcon(from icons: [(url: String, w: Int?, h: Int?)]) -> String? {
        let portraits = icons.compactMap { icon -> (url: String, ratio: Double)? in
            guard let ratio = declaredRatio(icon), ratio < EPGImageClassifier.landscapeThreshold else { return nil }
            return (icon.url, ratio)
        }
        if let best = portraits.min(by: { abs($0.ratio - 2.0 / 3.0) < abs($1.ratio - 2.0 / 3.0) }) {
            return best.url
        }
        return icons.first(where: { declaredRatio($0) == nil })?.url
    }

    /// Programme background: ONLY an icon declared landscape. Icons without
    /// dimensions, or square/portrait ones (e.g. a channel logo used as the
    /// programme icon), are never treated as a background here — so the
    /// backdrop stays empty rather than showing a stretched logo.
    static func landscapeIcon(from icons: [(url: String, w: Int?, h: Int?)]) -> String? {
        let landscape = icons.compactMap { icon -> (url: String, ratio: Double)? in
            guard let ratio = declaredRatio(icon), ratio >= EPGImageClassifier.landscapeThreshold else { return nil }
            return (icon.url, ratio)
        }
        return landscape.min(by: { abs($0.ratio - 16.0 / 9.0) < abs($1.ratio - 16.0 / 9.0) })?.url
    }

    private static func declaredRatio(_ icon: (url: String, w: Int?, h: Int?)) -> Double? {
        guard let w = icon.w, let h = icon.h, w > 0, h > 0 else { return nil }
        return Double(w) / Double(h)
    }

    // MARK: - Helpers

    /// Fast manual date parsing for XMLTV format (yyyyMMddHHmmss with optional timezone)
    /// ~10x faster than DateFormatter for high-volume parsing
    private func parseDate(_ string: String?) -> Date? {
        guard let s = string, s.count >= 14 else { return nil }

        var idx = s.startIndex

        guard let year = Int(s[idx..<s.index(idx, offsetBy: 4)]) else { return nil }
        idx = s.index(idx, offsetBy: 4)

        guard let month = Int(s[idx..<s.index(idx, offsetBy: 2)]) else { return nil }
        idx = s.index(idx, offsetBy: 2)

        guard let day = Int(s[idx..<s.index(idx, offsetBy: 2)]) else { return nil }
        idx = s.index(idx, offsetBy: 2)

        guard let hour = Int(s[idx..<s.index(idx, offsetBy: 2)]) else { return nil }
        idx = s.index(idx, offsetBy: 2)

        guard let minute = Int(s[idx..<s.index(idx, offsetBy: 2)]) else { return nil }
        idx = s.index(idx, offsetBy: 2)

        guard let second = Int(s[idx..<s.index(idx, offsetBy: 2)]) else { return nil }

        // XMLTV timestamps commonly end in an explicit numeric offset, for
        // example `20260802193000 +0800`. Treating the wall-clock portion as
        // UTC shifts an Australian guide by an entire evening. Preserve the
        // previous UTC fallback for feeds that omit the optional timezone.
        let suffix = s[s.index(s.startIndex, offsetBy: 14)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var timeZone = TimeZone(secondsFromGMT: 0)
        if suffix.count >= 5 {
            let signCharacter = suffix.first
            let digits = suffix.dropFirst().prefix(4)
            if (signCharacter == "+" || signCharacter == "-"),
               digits.count == 4,
               let hours = Int(digits.prefix(2)),
               let minutes = Int(digits.suffix(2)),
               hours <= 23,
               minutes <= 59 {
                let sign = signCharacter == "-" ? -1 : 1
                timeZone = TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
            }
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = timeZone

        return Calendar(identifier: .gregorian).date(from: components)
    }
}

// MARK: - Errors

enum XMLTVParseError: LocalizedError {
    case httpError(Int)
    case parseFailed
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .httpError(let code):
            return "HTTP error \(code)"
        case .parseFailed:
            return "Failed to parse XMLTV data"
        case .tooLarge:
            return "The guide is too large"
        }
    }
}
