// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  StreamHeaderProbe.swift
//  Rivulet
//
//  A live stream's picture height and audio channels, read from its first
//  bytes without decoding: an MPEG transport stream names its streams in the
//  PMT, and the video's sequence parameters (H.264, HEVC, MPEG-2) and the
//  audio's frame headers (AAC, AC-3, E-AC-3, MPEG audio) carry the rest. An
//  HLS playlist says them in its attributes. Pure, so it is tested on bytes.
//

import Foundation

nonisolated enum StreamHeaderProbe {
    struct Result: Equatable, Sendable {
        var height: Int?
        var audioChannels: Int?
        var isComplete: Bool { height != nil && audioChannels != nil }
    }

    // MARK: - HLS

    /// A master playlist's best variant: its RESOLUTION height and its audio's CHANNELS.
    static func playlist(_ text: String) -> Result {
        var result = Result()
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#EXT-X-STREAM-INF"), let resolution = attribute("RESOLUTION", in: line),
               let height = resolution.split(separator: "x").last.flatMap({ Int($0) }) {
                result.height = max(result.height ?? 0, height)
            }
            if line.hasPrefix("#EXT-X-MEDIA"), line.contains("TYPE=AUDIO"), let channels = attribute("CHANNELS", in: line),
               let count = Int(channels.prefix { $0.isNumber }) {
                result.audioChannels = max(result.audioChannels ?? 0, count)
            }
        }
        return result
    }

    /// The first media URI in a playlist (a variant or a segment), relative to `base`.
    static func firstURI(in text: String, base: URL) -> URL? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
            .flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
    }

    private static func attribute(_ name: String, in line: Substring) -> String? {
        guard let range = line.range(of: "\(name)=") else { return nil }
        var value = line[range.upperBound...]
        if value.first == "\"" {
            value = value.dropFirst()
            return String(value.prefix { $0 != "\"" })
        }
        return String(value.prefix { $0 != "," })
    }

    // MARK: - Transport stream

    private enum Codec { case h264, hevc, mpeg2, aac, ac3, eac3, mpegAudio }

    /// What `bytes` (the start of a transport stream) says. Parts it cannot find stay nil.
    static func transportStream(_ bytes: Data) -> Result {
        let data = [UInt8](bytes)
        guard let start = syncOffset(data) else { return Result() }
        var pmtPIDs = Set<Int>()
        var streams: [Int: Codec] = [:]
        var payloads: [Int: [UInt8]] = [:]
        var offset = start
        while offset + 188 <= data.count {
            defer { offset += 188 }
            guard data[offset] == 0x47 else { continue }
            let pid = Int(data[offset + 1] & 0x1F) << 8 | Int(data[offset + 2])
            let unitStart = data[offset + 1] & 0x40 != 0
            let control = (data[offset + 3] >> 4) & 0x3
            var payload = offset + 4
            if control & 0x2 != 0 { payload += 1 + Int(data[offset + 4]) }
            guard control & 0x1 != 0, payload < offset + 188 else { continue }
            let packet = Array(data[payload..<(offset + 188)])
            if pid == 0, unitStart {
                pmtPIDs.formUnion(programMapPIDs(packet))
            } else if pmtPIDs.contains(pid), unitStart {
                for (esPID, codec) in elementaryStreams(packet) where streams[esPID] == nil { streams[esPID] = codec }
            } else if streams[pid] != nil {
                // PES payloads, header stripped at each unit start; enough for a header or two.
                guard (payloads[pid]?.count ?? 0) < 400_000 else { continue }
                if unitStart, packet.count > 9, packet[0] == 0, packet[1] == 0, packet[2] == 1 {
                    let headerLength = 9 + Int(packet[8])
                    if headerLength < packet.count { payloads[pid, default: []] += packet[headerLength...] }
                } else if payloads[pid] != nil {
                    payloads[pid]! += packet
                }
            }
        }
        var result = Result()
        for (pid, codec) in streams.sorted(by: { $0.key < $1.key }) {
            guard let bytes = payloads[pid] else { continue }
            switch codec {
            case .h264, .hevc, .mpeg2:
                if result.height == nil { result.height = videoHeight(bytes, codec: codec) }
            case .aac, .ac3, .eac3, .mpegAudio:
                if result.audioChannels == nil { result.audioChannels = audioChannels(bytes, codec: codec) }
            }
        }
        return result
    }

    private static func syncOffset(_ data: [UInt8]) -> Int? {
        (0..<min(188, data.count)).first { start in
            stride(from: start, to: min(data.count, start + 188 * 4), by: 188).allSatisfy { data[$0] == 0x47 }
        }
    }

    /// PAT: the PMT PID of each program.
    private static func programMapPIDs(_ packet: [UInt8]) -> [Int] {
        guard let section = section(packet), section.count >= 8 else { return [] }
        let length = (Int(section[1] & 0x0F) << 8 | Int(section[2])) + 3
        var pids: [Int] = []
        var index = 8
        while index + 4 <= min(length - 4, section.count) {
            let program = Int(section[index]) << 8 | Int(section[index + 1])
            if program != 0 { pids.append(Int(section[index + 2] & 0x1F) << 8 | Int(section[index + 3])) }
            index += 4
        }
        return pids
    }

    /// PMT: each elementary stream's PID and codec, private streams by their descriptors.
    private static func elementaryStreams(_ packet: [UInt8]) -> [(Int, Codec)] {
        guard let section = section(packet), section.count >= 12, section[0] == 0x02 else { return [] }
        let length = (Int(section[1] & 0x0F) << 8 | Int(section[2])) + 3
        let infoLength = Int(section[10] & 0x0F) << 8 | Int(section[11])
        var streams: [(Int, Codec)] = []
        var index = 12 + infoLength
        let end = min(length - 4, section.count)
        while index + 5 <= end {
            let type = section[index]
            let pid = Int(section[index + 1] & 0x1F) << 8 | Int(section[index + 2])
            let esInfo = Int(section[index + 3] & 0x0F) << 8 | Int(section[index + 4])
            let descriptors = Array(section[min(index + 5, end)..<min(index + 5 + esInfo, end)])
            let codec: Codec? = switch type {
            case 0x1B: .h264
            case 0x24: .hevc
            case 0x01, 0x02: .mpeg2
            case 0x0F: .aac
            case 0x03, 0x04: .mpegAudio
            case 0x81: .ac3
            case 0x87: .eac3
            case 0x06: privateCodec(descriptors)
            default: nil
            }
            if let codec { streams.append((pid, codec)) }
            index += 5 + esInfo
        }
        return streams
    }

    /// DVB puts AC-3 and E-AC-3 in private streams, named by a descriptor.
    private static func privateCodec(_ descriptors: [UInt8]) -> Codec? {
        var index = 0
        while index + 2 <= descriptors.count {
            switch descriptors[index] {
            case 0x6A: return .ac3
            case 0x7A: return .eac3
            default: index += 2 + Int(descriptors[index + 1])
            }
        }
        return nil
    }

    /// The table section a PSI packet starts, after its pointer field.
    private static func section(_ packet: [UInt8]) -> [UInt8]? {
        guard let pointer = packet.first, 1 + Int(pointer) < packet.count else { return nil }
        return Array(packet[(1 + Int(pointer))...])
    }

    // MARK: - Video

    private static func videoHeight(_ bytes: [UInt8], codec: Codec) -> Int? {
        var index = 0
        while let start = nextStartCode(bytes, from: index) {
            index = start + 3
            guard index < bytes.count else { break }
            switch codec {
            case .h264 where bytes[index] & 0x1F == 7:
                if let height = h264Height(unescape(bytes, from: index + 1)) { return height }
            case .hevc where (bytes[index] >> 1) & 0x3F == 33:
                if let height = hevcHeight(unescape(bytes, from: index + 2)) { return height }
            case .mpeg2 where bytes[index] == 0xB3 && index + 3 < bytes.count:
                let height = (Int(bytes[index + 2] & 0x0F) << 8) | Int(bytes[index + 3])
                if height > 0 { return height }
            default:
                break
            }
        }
        return nil
    }

    private static func nextStartCode(_ bytes: [UInt8], from index: Int) -> Int? {
        var i = index
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 { return i }
            i += 1
        }
        return nil
    }

    /// A NAL unit's payload up to the next start code, emulation prevention bytes removed.
    private static func unescape(_ bytes: [UInt8], from index: Int) -> [UInt8] {
        var out: [UInt8] = []
        var zeros = 0
        var i = index
        while i < bytes.count, out.count < 512 {
            let byte = bytes[i]
            if zeros >= 2, byte == 1 { break }
            if zeros >= 2, byte == 3 { zeros = 0; i += 1; continue }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
            i += 1
        }
        return out
    }

    private struct Bits {
        let bytes: [UInt8]
        var position = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func bit() -> Int? {
            guard position < bytes.count * 8 else { return nil }
            defer { position += 1 }
            return Int(bytes[position / 8] >> (7 - position % 8)) & 1
        }

        mutating func bits(_ count: Int) -> Int? {
            var value = 0
            for _ in 0..<count {
                guard let bit = bit() else { return nil }
                value = value << 1 | bit
            }
            return value
        }

        mutating func skip(_ count: Int) -> Bool { bits(count) != nil || count == 0 }

        /// Exp-Golomb, unsigned.
        mutating func ue() -> Int? {
            var zeros = 0
            while let bit = bit(), bit == 0 {
                zeros += 1
                if zeros > 31 { return nil }
            }
            guard let rest = bits(zeros) else { return nil }
            return (1 << zeros) - 1 + rest
        }

        mutating func se() -> Int? { ue().map { $0 % 2 == 0 ? -($0 / 2) : ($0 + 1) / 2 } }
    }

    private static func h264Height(_ sps: [UInt8]) -> Int? {
        var r = Bits(sps)
        guard let profile = r.bits(8), r.skip(16), r.ue() != nil else { return nil }
        var chroma = 1
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            guard let format = r.ue() else { return nil }
            chroma = format
            if format == 3, r.bit() == nil { return nil }
            guard r.ue() != nil, r.ue() != nil, r.skip(1), let scaling = r.bit() else { return nil }
            if scaling == 1 {
                for list in 0..<(format == 3 ? 12 : 8) {
                    guard let present = r.bit() else { return nil }
                    guard present == 1 else { continue }
                    var last = 8, next = 8
                    for _ in 0..<(list < 6 ? 16 : 64) where next != 0 {
                        guard let delta = r.se() else { return nil }
                        next = (last + delta + 256) % 256
                        last = next == 0 ? last : next
                    }
                }
            }
        }
        guard r.ue() != nil, let pocType = r.ue() else { return nil }
        if pocType == 0 {
            guard r.ue() != nil else { return nil }
        } else if pocType == 1 {
            guard r.skip(1), r.se() != nil, r.se() != nil, let cycle = r.ue() else { return nil }
            for _ in 0..<min(cycle, 255) { guard r.se() != nil else { return nil } }
        }
        guard r.ue() != nil, r.skip(1), r.ue() != nil, let heightUnits = r.ue(), let frameOnly = r.bit() else { return nil }
        if frameOnly == 0, r.bit() == nil { return nil }
        guard r.skip(1), let cropping = r.bit() else { return nil }
        var height = (2 - frameOnly) * (heightUnits + 1) * 16
        if cropping == 1 {
            guard r.ue() != nil, r.ue() != nil, let top = r.ue(), let bottom = r.ue() else { return nil }
            let unit = (chroma == 1 ? 2 : 1) * (2 - frameOnly)
            height -= (top + bottom) * unit
        }
        return height > 0 ? height : nil
    }

    private static func hevcHeight(_ sps: [UInt8]) -> Int? {
        var r = Bits(sps)
        guard r.skip(4), let maxSubLayers = r.bits(3), r.skip(1) else { return nil }
        // profile_tier_level: the general profile (88 bits) and level (8), then the sub-layers.
        guard r.skip(96) else { return nil }
        var profilePresent: [Int] = [], levelPresent: [Int] = []
        for _ in 0..<maxSubLayers {
            guard let profile = r.bit(), let level = r.bit() else { return nil }
            profilePresent.append(profile)
            levelPresent.append(level)
        }
        if maxSubLayers > 0 { guard r.skip(2 * (8 - maxSubLayers)) else { return nil } }
        for layer in 0..<maxSubLayers {
            if profilePresent[layer] == 1 { guard r.skip(88) else { return nil } }
            if levelPresent[layer] == 1 { guard r.skip(8) else { return nil } }
        }
        guard r.ue() != nil, let chroma = r.ue() else { return nil }
        if chroma == 3, r.bit() == nil { return nil }
        guard r.ue() != nil, var height = r.ue(), let window = r.bit() else { return nil }
        if window == 1 {
            guard r.ue() != nil, r.ue() != nil, let top = r.ue(), let bottom = r.ue() else { return nil }
            height -= (top + bottom) * (chroma == 1 ? 2 : 1)
        }
        return height > 0 ? height : nil
    }

    // MARK: - Audio

    private static func audioChannels(_ bytes: [UInt8], codec: Codec) -> Int? {
        var i = 0
        while i + 8 < bytes.count {
            switch codec {
            case .aac where bytes[i] == 0xFF && bytes[i + 1] & 0xF6 == 0xF0:
                let config = Int(bytes[i + 2] & 0x01) << 2 | Int(bytes[i + 3] >> 6)
                if config > 0 { return config == 7 ? 8 : config }
            case .mpegAudio where bytes[i] == 0xFF && bytes[i + 1] & 0xE0 == 0xE0 && bytes[i + 1] & 0x06 != 0:
                return bytes[i + 3] >> 6 == 3 ? 1 : 2
            case .ac3, .eac3:
                if bytes[i] == 0x0B, bytes[i + 1] == 0x77, let channels = dolbyChannels(Array(bytes[(i + 2)...].prefix(8))) {
                    return channels
                }
            default:
                break
            }
            i += 1
        }
        return nil
    }

    /// AC-3 or E-AC-3 from the bytes after the sync word, told apart by the bsid.
    private static func dolbyChannels(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 6 else { return nil }
        let bsid = Int(bytes[3] >> 3)
        let acmodChannels = [2, 1, 2, 3, 3, 4, 4, 5]
        var r = Bits(bytes)
        if bsid <= 10 {
            // AC-3: crc (16), fscod/frmsizecod (8), bsid (5), bsmod (3), then acmod.
            guard r.skip(32), let acmod = r.bits(3) else { return nil }
            if acmod & 1 != 0, acmod != 1 { guard r.skip(2) else { return nil } }
            if acmod & 4 != 0 { guard r.skip(2) else { return nil } }
            if acmod == 2 { guard r.skip(2) else { return nil } }
            guard let lfe = r.bit() else { return nil }
            return acmodChannels[acmod] + lfe
        } else if bsid == 16 {
            // E-AC-3: strmtyp (2), substreamid (3), frmsiz (11), fscod (2), fscod2 or numblkscod (2), acmod, lfeon.
            guard r.skip(20), let acmod = r.bits(3), let lfe = r.bit() else { return nil }
            return acmodChannels[acmod] + lfe
        }
        return nil
    }
}
