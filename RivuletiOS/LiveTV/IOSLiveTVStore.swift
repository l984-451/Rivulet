// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import Foundation

@MainActor
final class IOSLiveTVStore: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var channels: [IOSIPTVChannel] = []
    @Published private(set) var programsByChannel: [String: [IOSEPGProgram]] = [:]
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var matchedChannelCount = 0
    @Published private(set) var lastLoadedAt: Date?

    private(set) var m3uURLString: String
    private(set) var xmltvURLString: String
    private(set) var userAgentString: String
    private(set) var authorizationHeaderString: String
    private(set) var refererString: String
    private var attemptedAutomaticLoad = false

    private let defaults: UserDefaults
    private let m3uKey = "ios.liveTV.m3uURL"
    private let xmltvKey = "ios.liveTV.xmltvURL"
    private let userAgentKey = "ios.liveTV.userAgent"
    private let authorizationHeaderKey = "ios.liveTV.authorizationHeader"
    private let refererKey = "ios.liveTV.referer"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        m3uURLString = defaults.string(forKey: m3uKey) ?? ""
        xmltvURLString = defaults.string(forKey: xmltvKey) ?? ""
        userAgentString = defaults.string(forKey: userAgentKey) ?? ""
        authorizationHeaderString = defaults.string(forKey: authorizationHeaderKey) ?? ""
        refererString = defaults.string(forKey: refererKey) ?? ""
    }

    var hasSavedSource: Bool {
        !m3uURLString.isEmpty && !xmltvURLString.isEmpty
    }

    var groups: [String] {
        Set(channels.compactMap(\.groupTitle)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    var programCount: Int {
        programsByChannel.values.reduce(0) { $0 + $1.count }
    }

    func loadSavedSourceIfNeeded() async {
        guard !attemptedAutomaticLoad else { return }
        attemptedAutomaticLoad = true
        guard hasSavedSource else { return }
        await load()
    }

    func configureAndLoad(
        m3uURL: String,
        xmltvURL: String,
        userAgent: String,
        authorizationHeader: String,
        referer: String
    ) async -> Bool {
        let playlist = m3uURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let guide = xmltvURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUserAgent = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAuthorization = authorizationHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReferer = referer.trimmingCharacters(in: .whitespacesAndNewlines)

        guard Self.validRemoteURL(from: playlist) != nil else {
            state = .failed("Enter a valid HTTP or HTTPS M3U playlist URL.")
            return false
        }
        guard Self.validRemoteURL(from: guide) != nil else {
            state = .failed("Enter a valid HTTP or HTTPS XMLTV guide URL.")
            return false
        }

        m3uURLString = playlist
        xmltvURLString = guide
        userAgentString = trimmedUserAgent
        authorizationHeaderString = trimmedAuthorization
        refererString = trimmedReferer
        defaults.set(playlist, forKey: m3uKey)
        defaults.set(guide, forKey: xmltvKey)
        defaults.set(trimmedUserAgent, forKey: userAgentKey)
        defaults.set(trimmedAuthorization, forKey: authorizationHeaderKey)
        defaults.set(trimmedReferer, forKey: refererKey)
        await load()
        return state == .loaded
    }

    func load() async {
        guard let m3uURL = Self.validRemoteURL(from: m3uURLString),
              let xmltvURL = Self.validRemoteURL(from: xmltvURLString) else {
            state = .failed("Configure both the M3U playlist and XMLTV guide URLs.")
            return
        }

        state = .loading

        do {
            let m3uParser = M3UParser()
            let xmltvParser = XMLTVParser()
            let headers = playbackHeaders.dictionary
            async let playlistData = Self.fetchData(
                from: m3uURL,
                headers: headers,
                sourceName: "M3U playlist"
            )
            async let guideData = Self.fetchData(
                from: xmltvURL,
                headers: headers,
                sourceName: "XMLTV guide"
            )
            let (m3uData, xmltvData) = try await (playlistData, guideData)
            async let parsedPlaylist = m3uParser.parse(data: m3uData)
            async let parsedGuide = xmltvParser.parse(data: xmltvData)
            let (playlist, guide) = try await (parsedPlaylist, parsedGuide)

            guard !playlist.isEmpty else {
                state = .failed("The playlist loaded, but it did not contain any channels.")
                return
            }

            let mappedChannels = Self.makeChannels(
                from: playlist,
                xmltvChannels: guide.channels,
                playbackHeaders: playbackHeaders,
                sourceHost: m3uURL.host
            )
            let match = Self.match(
                channels: mappedChannels,
                parsedChannels: guide.channels,
                parsedPrograms: guide.programs
            )

            channels = mappedChannels
            programsByChannel = match.programs
            matchedChannelCount = match.matchedCount
            lastLoadedAt = Date()
            state = .loaded
        } catch is CancellationError {
            state = channels.isEmpty ? .idle : .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func clearSource() {
        defaults.removeObject(forKey: m3uKey)
        defaults.removeObject(forKey: xmltvKey)
        defaults.removeObject(forKey: userAgentKey)
        defaults.removeObject(forKey: authorizationHeaderKey)
        defaults.removeObject(forKey: refererKey)
        m3uURLString = ""
        xmltvURLString = ""
        userAgentString = ""
        authorizationHeaderString = ""
        refererString = ""
        channels = []
        programsByChannel = [:]
        matchedChannelCount = 0
        lastLoadedAt = nil
        state = .idle
    }

    private static func validRemoteURL(from string: String) -> URL? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    private static func makeChannels(
        from parsed: [M3UParser.ParsedChannel],
        xmltvChannels: [String: XMLTVParser.ParsedXMLTVChannel],
        playbackHeaders: IOSPlaybackHeaders,
        sourceHost: String?
    ) -> [IOSIPTVChannel] {
        var occurrences: [String: Int] = [:]
        let xmlIDsIgnoringCase = Dictionary(
            xmltvChannels.keys.map { ($0.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let xmlIDsByName = Dictionary(
            xmltvChannels.values.map { (normalize($0.displayName), $0.id) },
            uniquingKeysWith: { first, _ in first }
        )

        return parsed.map { channel in
            let baseID = firstNonempty(channel.tvgId, channel.tvgName, channel.name)
            let occurrence = occurrences[baseID, default: 0]
            occurrences[baseID] = occurrence + 1
            let id = occurrence == 0 ? baseID : "\(baseID)#\(occurrence)"

            // Never leak playlist credentials to an unrelated host named by
            // the playlist. Dispatcharr and conventional authenticated IPTV
            // endpoints keep their streams on the same host.
            let sameOrigin = channel.streamURL.host?.caseInsensitiveCompare(sourceHost ?? "")
                == .orderedSame
            let channelHeaders = IOSPlaybackHeaders(
                userAgent: playbackHeaders.userAgent,
                authorization: sameOrigin ? playbackHeaders.authorization : nil,
                referer: playbackHeaders.referer
            )
            let guideCandidates = [channel.tvgId, channel.tvgName, channel.name]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
            let guideID = guideCandidates.first(where: { xmltvChannels[$0] != nil })
                ?? guideCandidates.compactMap { xmlIDsIgnoringCase[$0.lowercased()] }.first
                ?? guideCandidates.compactMap { xmlIDsByName[normalize($0)] }.first
            let logoURL = channel.tvgLogo.flatMap(URL.init(string:))
                ?? guideID.flatMap { xmltvChannels[$0]?.iconURL }.flatMap(URL.init(string:))

            return IOSIPTVChannel(
                id: id,
                name: firstNonempty(channel.tvgName, channel.name),
                channelNumber: channel.channelNumber,
                tvgID: channel.tvgId,
                tvgName: channel.tvgName,
                groupTitle: channel.groupTitle,
                logoURL: logoURL,
                streamURL: channel.streamURL,
                playbackHeaders: channelHeaders
            )
        }
        .sorted { lhs, rhs in
            switch (lhs.channelNumber, rhs.channelNumber) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private static func match(
        channels: [IOSIPTVChannel],
        parsedChannels: [String: XMLTVParser.ParsedXMLTVChannel],
        parsedPrograms: [String: [XMLTVParser.ParsedProgram]]
    ) -> (programs: [String: [IOSEPGProgram]], matchedCount: Int) {
        let idsIgnoringCase = Dictionary(
            parsedChannels.keys.map { ($0.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let idsByName = Dictionary(
            parsedChannels.values.map { (normalize($0.displayName), $0.id) },
            uniquingKeysWith: { first, _ in first }
        )

        var result: [String: [IOSEPGProgram]] = [:]
        var matchedCount = 0

        for channel in channels {
            let candidates = [channel.tvgID, channel.tvgName, channel.name]
                .compactMap { value -> String? in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }

            let matchedID = candidates.first(where: { parsedChannels[$0] != nil })
                ?? candidates.compactMap { idsIgnoringCase[$0.lowercased()] }.first
                ?? candidates.compactMap { idsByName[normalize($0)] }.first

            guard let matchedID else { continue }
            matchedCount += 1

            result[channel.id] = (parsedPrograms[matchedID] ?? [])
                .map { program in
                    IOSEPGProgram(
                        id: "\(channel.id):\(Int(program.start.timeIntervalSince1970))",
                        channelID: channel.id,
                        title: program.title,
                        subtitle: program.subtitle,
                        description: program.description,
                        category: program.category,
                        episodeNumber: program.episodeNum,
                        posterURL: program.posterIcon.flatMap(URL.init(string:)),
                        landscapeURL: program.landscapeIcon.flatMap(URL.init(string:)),
                        start: program.start,
                        end: program.stop,
                        isNew: program.isNew
                    )
                }
                .sorted { $0.start < $1.start }
        }

        return (result, matchedCount)
    }

    private static func normalize(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        .unicodeScalars
        .filter(CharacterSet.alphanumerics.contains)
        .map(String.init)
        .joined()
    }

    private static func firstNonempty(_ values: String?...) -> String {
        values.compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.first ?? UUID().uuidString
    }

    private var playbackHeaders: IOSPlaybackHeaders {
        IOSPlaybackHeaders(
            userAgent: userAgentString.isEmpty
                ? LiveTVClientIdentity.userAgent
                : userAgentString,
            authorization: normalizedAuthorizationHeader,
            referer: refererString.nilIfEmpty
        )
    }

    private var normalizedAuthorizationHeader: String? {
        guard !authorizationHeaderString.isEmpty else { return nil }
        // Match the tvOS Dispatcharr editor: a bare API token uses DRF's
        // `Token` scheme. Advanced users can supply a complete Bearer/Basic/etc.
        // value and it is preserved exactly.
        if authorizationHeaderString.contains(where: { $0.isWhitespace }) {
            return authorizationHeaderString
        }
        return "Token \(authorizationHeaderString)"
    }

    private nonisolated static func fetchData(
        from url: URL,
        headers: [String: String],
        sourceName: String
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let response = response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            throw IOSLiveTVSourceError.httpError(
                source: sourceName,
                statusCode: response.statusCode
            )
        }
        return data
    }
}

private enum IOSLiveTVSourceError: LocalizedError {
    case httpError(source: String, statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .httpError(let source, let statusCode):
            if statusCode == 401 || statusCode == 403 {
                return "\(source) returned HTTP \(statusCode). Check its Authorization header."
            }
            return "\(source) returned HTTP \(statusCode)."
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
