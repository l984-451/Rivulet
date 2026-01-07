//
//  XMLTVParser.swift
//  Rivulet
//
//  Parses XMLTV format EPG (Electronic Program Guide) data
//

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
        let (data, _) = try await fetchWithHTTPSUpgrade(url: url)
        return try parse(data: data)
    }

    // MARK: - Private Networking

    /// Fetch data from URL, attempting HTTPS upgrade for HTTP URLs
    private func fetchWithHTTPSUpgrade(url: URL) async throws -> (Data, URLResponse) {
        // If already HTTPS or not HTTP, use as-is
        guard url.scheme == "http",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return try await fetchData(from: url)
        }

        // Try HTTPS first with a short timeout
        components.scheme = "https"
        if let httpsURL = components.url {
            do {
                return try await fetchData(from: httpsURL, timeout: 3.0)
            } catch {
                // HTTPS failed, fall back to HTTP
                print("📺 XMLTVParser: HTTPS failed for \(httpsURL.host ?? "unknown"), falling back to HTTP")
            }
        }

        // Fall back to original HTTP URL
        return try await fetchData(from: url)
    }

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
        return try parser.parse(data: data)
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

private class XMLTVInternalParser: NSObject, XMLParserDelegate {
    private var channels: [String: XMLTVParser.ParsedXMLTVChannel] = [:]
    private var programs: [String: [XMLTVParser.ParsedProgram]] = [:]

    // Current parsing state
    private var currentElement: String = ""
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
    private var currentEpisodeNum: String = ""
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
        currentElement = elementName

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
            currentEpisodeNum = ""
            currentIsNew = false

        case "icon":
            let src = attributeDict["src"]
            if currentChannelId != nil {
                currentIconURL = src
            } else if currentProgramChannelId != nil {
                currentProgramIcon = src
            }

        case "new":
            currentIsNew = true

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch currentElement {
        case "display-name":
            currentDisplayName += trimmed
        case "title":
            currentTitle += trimmed
        case "sub-title":
            currentSubtitle += trimmed
        case "desc":
            currentDescription += trimmed
        case "category":
            if !currentCategory.isEmpty {
                currentCategory += ", "
            }
            currentCategory += trimmed
        case "episode-num":
            currentEpisodeNum += trimmed
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
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

        currentElement = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
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

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = TimeZone(identifier: "UTC")

        return Calendar(identifier: .gregorian).date(from: components)
    }
}

// MARK: - Errors

enum XMLTVParseError: LocalizedError {
    case httpError(Int)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .httpError(let code):
            return "HTTP error \(code)"
        case .parseFailed:
            return "Failed to parse XMLTV data"
        }
    }
}

// MARK: - Convenience Extensions

extension XMLTVParser.ParsedProgram {
    /// Convert to UnifiedProgram
    func toUnifiedProgram(unifiedChannelId: String) -> UnifiedProgram {
        // Create unique ID from channel and start time
        let id = "\(unifiedChannelId):\(Int(start.timeIntervalSince1970))"

        return UnifiedProgram(
            id: id,
            channelId: unifiedChannelId,
            title: title,
            subtitle: subtitle,
            description: description,
            startTime: start,
            endTime: stop,
            category: category,
            iconURL: icon.flatMap { URL(string: $0) },
            episodeNumber: episodeNum,
            isNew: isNew
        )
    }
}
