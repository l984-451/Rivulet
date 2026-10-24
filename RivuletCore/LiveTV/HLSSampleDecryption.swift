// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HLSSampleDecryption.swift
//  Rivulet
//
//  Segment-head decryption for live scrub previews (LiveHLSScrubThumbnails).
//

import CommonCrypto
import Foundation

/// Decrypts the head of an encrypted HLS segment so a scrub preview can be
/// decoded from it, for every scheme whose key is a plain URL in the playlist:
///
/// - `AES-128`: the whole segment, AES-CBC (`LiveHLSScrubThumbnails`).
/// - `SAMPLE-AES` in MPEG-TS: Apple's H.264 scheme. Each slice NAL unit leaves
///   its first 32 bytes clear, then encrypts one 16-byte block in ten, chained
///   from the key's IV, over the unescaped NAL. The video is pulled out of the
///   transport stream, decrypted and returned as an Annex B H.264 stream.
/// - `SAMPLE-AES` in fMP4 (`cbcs`) and `SAMPLE-AES-CTR` (`cenc`): the init
///   segment's `tenc` and the media segment's `senc` say which bytes of which
///   sample are protected; decryption is in place, so sizes never change.
///
/// Only the bytes that arrived are touched: a sample or NAL cut off by the
/// head's end is left alone, and the preview needs only the first keyframe.
/// FairPlay and other DRM key formats are out of reach by design.
nonisolated enum HLSSampleDecryption {
    // MARK: AES primitives

    static func cbcDecrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else { return nil }
        let length = data.count - data.count % kCCBlockSizeAES128
        guard length > 0 else { return Data() }
        var output = Data(count: length)
        var written = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            input.baseAddress, length, out.baseAddress, length, &written
                        )
                    }
                }
            }
        }
        return status == kCCSuccess ? output.prefix(written) : nil
    }

    /// A chained cipher for one run of a pattern: the chain (CBC) or the
    /// counter (CTR) carries across `update` calls, as the schemes require.
    final class Cipher {
        private var ref: CCCryptorRef?

        init?(mode: CCMode, key: Data, iv: Data) {
            guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else { return nil }
            let status = key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCryptorCreateWithMode(
                        CCOperation(kCCDecrypt), mode, CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                        ivBytes.baseAddress, keyBytes.baseAddress, key.count, nil, 0, 0,
                        CCModeOptions(mode == CCMode(kCCModeCTR) ? kCCModeOptionCTR_BE : 0), &ref
                    )
                }
            }
            guard status == kCCSuccess else { return nil }
        }

        deinit { if let ref { CCCryptorRelease(ref) } }

        /// Decrypts `bytes[range]` in place.
        func update(_ bytes: inout [UInt8], _ range: Range<Int>) {
            guard let ref, !range.isEmpty, range.lowerBound >= 0, range.upperBound <= bytes.count else { return }
            var output = [UInt8](repeating: 0, count: range.count)
            var moved = 0
            let status = bytes.withUnsafeBufferPointer { input in
                CCCryptorUpdate(ref, input.baseAddress! + range.lowerBound, range.count, &output, output.count, &moved)
            }
            guard status == kCCSuccess, moved == range.count else { return }
            bytes.replaceSubrange(range, with: output)
        }
    }

    // MARK: SAMPLE-AES in MPEG-TS (H.264)

    /// The video of a TS head as a decrypted Annex B H.264 stream, or nil when
    /// the stream holds no H.264 video this scheme covers.
    static func decryptTransportStreamH264(_ data: Data, key: Data, iv: Data) -> Data? {
        guard let elementary = videoElementaryStream(Array(data)) else { return nil }
        var output = Data()
        output.reserveCapacity(elementary.count)
        for nal in nalUnits(elementary) {
            output.append(contentsOf: [0, 0, 0, 1])
            let type = nal.first.map { $0 & 0x1F } ?? 0
            if (type == 1 || type == 5) && nal.count > 48 {
                var raw = unescape(nal)
                decryptSampleAESNAL(&raw, key: key, iv: iv)
                output.append(contentsOf: escape(raw))
            } else {
                output.append(contentsOf: nal)
            }
        }
        return output
    }

    /// Apple's pattern: 32 clear bytes, then one encrypted block followed by
    /// up to nine clear ones, repeating; a final block of 16 bytes or fewer
    /// stays clear. The CBC chain runs across the encrypted blocks of a NAL.
    static func decryptSampleAESNAL(_ nal: inout [UInt8], key: Data, iv: Data) {
        guard nal.count > 48, let cipher = Cipher(mode: CCMode(kCCModeCBC), key: key, iv: iv) else { return }
        var offset = 32
        var remaining = nal.count - 32
        while remaining > 0 {
            if remaining > 16 {
                cipher.update(&nal, offset..<(offset + 16))
                offset += 16
                remaining -= 16
            }
            let skip = min(144, remaining)
            offset += skip
            remaining -= skip
        }
    }

    /// The payload of the first H.264 video stream (`0x1B`, or `0xDB` when
    /// SAMPLE-AES protected), reassembled from its PES packets.
    static func videoElementaryStream(_ bytes: [UInt8]) -> [UInt8]? {
        let packet = 188
        guard let start = (0..<min(packet, bytes.count)).first(where: { index in
            stride(from: index, to: min(bytes.count, index + packet * 3), by: packet).allSatisfy { bytes[$0] == 0x47 }
        }) else { return nil }
        var pmtPID: Int?
        var videoPID: Int?
        var stream: [UInt8] = []
        var collecting = false
        var offset = start
        while offset + packet <= bytes.count {
            defer { offset += packet }
            guard bytes[offset] == 0x47 else { continue }
            let unitStart = bytes[offset + 1] & 0x40 != 0
            let pid = Int(bytes[offset + 1] & 0x1F) << 8 | Int(bytes[offset + 2])
            let adaptation = (bytes[offset + 3] >> 4) & 0x3
            var payload = offset + 4
            if adaptation == 2 { continue }
            if adaptation == 3 { payload += 1 + Int(bytes[offset + 4]) }
            guard payload < offset + packet else { continue }
            let body = Array(bytes[payload..<(offset + packet)])
            if pid == 0, unitStart, pmtPID == nil {
                pmtPID = programMapPID(fromPAT: body)
            } else if pid == pmtPID, unitStart, videoPID == nil {
                videoPID = h264PID(fromPMT: body)
            } else if pid == videoPID {
                if unitStart {
                    guard body.count > 9, body[0] == 0, body[1] == 0, body[2] == 1 else { collecting = false; continue }
                    let headerLength = 9 + Int(body[8])
                    guard headerLength <= body.count else { collecting = false; continue }
                    stream.append(contentsOf: body[headerLength...])
                    collecting = true
                } else if collecting {
                    stream.append(contentsOf: body)
                }
            }
        }
        return videoPID == nil || stream.isEmpty ? nil : stream
    }

    private static func programMapPID(fromPAT body: [UInt8]) -> Int? {
        let pointer = Int(body.first ?? 0)
        let table = 1 + pointer
        guard body.count > table + 12 else { return nil }
        let sectionLength = Int(body[table + 1] & 0x0F) << 8 | Int(body[table + 2])
        var entry = table + 8
        let end = min(body.count, table + 3 + sectionLength - 4)
        while entry + 4 <= end {
            let program = Int(body[entry]) << 8 | Int(body[entry + 1])
            let pid = Int(body[entry + 2] & 0x1F) << 8 | Int(body[entry + 3])
            if program != 0 { return pid }
            entry += 4
        }
        return nil
    }

    private static func h264PID(fromPMT body: [UInt8]) -> Int? {
        let pointer = Int(body.first ?? 0)
        let table = 1 + pointer
        guard body.count > table + 12 else { return nil }
        let sectionLength = Int(body[table + 1] & 0x0F) << 8 | Int(body[table + 2])
        let programInfoLength = Int(body[table + 10] & 0x0F) << 8 | Int(body[table + 11])
        var entry = table + 12 + programInfoLength
        let end = min(body.count, table + 3 + sectionLength - 4)
        while entry + 5 <= end {
            let type = body[entry]
            let pid = Int(body[entry + 1] & 0x1F) << 8 | Int(body[entry + 2])
            let infoLength = Int(body[entry + 3] & 0x0F) << 8 | Int(body[entry + 4])
            if type == 0x1B || type == 0xDB { return pid }
            entry += 5 + infoLength
        }
        return nil
    }

    /// NAL units of an Annex B stream, without their start codes.
    static func nalUnits(_ stream: [UInt8]) -> [[UInt8]] {
        var starts: [(code: Int, body: Int)] = []
        var index = 0
        while index + 2 < stream.count {
            if stream[index] == 0, stream[index + 1] == 0, stream[index + 2] == 1 {
                let code = index > 0 && stream[index - 1] == 0 ? index - 1 : index
                starts.append((code, index + 3))
                index += 3
            } else {
                index += 1
            }
        }
        return starts.enumerated().compactMap { offset, start in
            let end = offset + 1 < starts.count ? starts[offset + 1].code : stream.count
            return start.body < end ? Array(stream[start.body..<end]) : nil
        }
    }

    /// Removes emulation-prevention bytes (`00 00 03` → `00 00`).
    static func unescape(_ nal: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(nal.count)
        var zeros = 0
        for byte in nal {
            if zeros >= 2, byte == 3 {
                zeros = 0
                continue
            }
            output.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return output
    }

    /// Re-inserts emulation prevention so the stream parses again.
    static func escape(_ nal: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(nal.count + nal.count / 64)
        var zeros = 0
        for byte in nal {
            if zeros >= 2, byte <= 3 {
                output.append(3)
                zeros = 0
            }
            output.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return output
    }

    // MARK: Completeness

    /// Whether a segment head holds its whole first video frame: in TS, the
    /// next video PES has begun; in fMP4, the first sample ends inside the head.
    /// A cut keyframe still decodes, as a picture that goes green where the
    /// bytes ran out, so this, not a decode failure, decides to read more.
    /// Unparseable input answers true, leaving the decode to judge.
    static func leadingFrameIsComplete(_ data: Data, fragmented: Bool) -> Bool {
        let bytes = Array(data)
        return fragmented ? fragmentedLeadingSampleIsComplete(bytes) : transportLeadingFrameIsComplete(bytes)
    }

    private static func transportLeadingFrameIsComplete(_ bytes: [UInt8]) -> Bool {
        let packet = 188
        guard let start = (0..<min(packet, bytes.count)).first(where: { bytes[$0] == 0x47 }) else { return true }
        var pmtPID: Int?
        var videoPID: Int?
        var starts = 0
        var offset = start
        while offset + packet <= bytes.count {
            defer { offset += packet }
            guard bytes[offset] == 0x47 else { continue }
            let unitStart = bytes[offset + 1] & 0x40 != 0
            let pid = Int(bytes[offset + 1] & 0x1F) << 8 | Int(bytes[offset + 2])
            let adaptation = (bytes[offset + 3] >> 4) & 0x3
            var payload = offset + 4
            if adaptation == 2 { continue }
            if adaptation == 3 { payload += 1 + Int(bytes[offset + 4]) }
            guard payload < offset + packet else { continue }
            let body = Array(bytes[payload..<(offset + packet)])
            if pid == 0, unitStart, pmtPID == nil {
                pmtPID = programMapPID(fromPAT: body)
            } else if pid == pmtPID, unitStart, videoPID == nil {
                videoPID = videoPIDFromPMT(body)
            } else if pid == videoPID, unitStart {
                starts += 1
                if starts >= 2 { return true }
            }
        }
        return videoPID == nil
    }

    private static func fragmentedLeadingSampleIsComplete(_ bytes: [UInt8]) -> Bool {
        guard let moof = boxes(in: bytes, range: 0..<bytes.count).first(where: { $0.type == "moof" }),
              let traf = child("traf", of: bytes, in: moof.payload),
              let tfhd = child("tfhd", of: bytes, in: traf),
              let trun = child("trun", of: bytes, in: traf),
              let first = trackRunSampleSizes(bytes, tfhd: tfhd, trun: trun).first
        else { return true }
        return moof.start + (trackRunDataOffset(bytes, trun: trun) ?? 0) + first <= bytes.count
    }

    /// Any video stream: H.264 (incl. SAMPLE-AES 0xDB), HEVC, MPEG-2.
    private static func videoPIDFromPMT(_ body: [UInt8]) -> Int? {
        let pointer = Int(body.first ?? 0)
        let table = 1 + pointer
        guard body.count > table + 12 else { return nil }
        let sectionLength = Int(body[table + 1] & 0x0F) << 8 | Int(body[table + 2])
        let programInfoLength = Int(body[table + 10] & 0x0F) << 8 | Int(body[table + 11])
        var entry = table + 12 + programInfoLength
        let end = min(body.count, table + 3 + sectionLength - 4)
        while entry + 5 <= end {
            let type = body[entry]
            let pid = Int(body[entry + 1] & 0x1F) << 8 | Int(body[entry + 2])
            let infoLength = Int(body[entry + 3] & 0x0F) << 8 | Int(body[entry + 4])
            if [0x1B, 0xDB, 0x24, 0x02].contains(type) { return pid }
            entry += 5 + infoLength
        }
        return nil
    }

    // MARK: Common encryption in fMP4 (cbcs / cenc)

    struct TrackEncryption: Equatable {
        enum Scheme: String { case cbcs, cenc }
        let scheme: Scheme
        let trackID: UInt32
        let cryptBlocks: Int
        let skipBlocks: Int
        let perSampleIVSize: Int
        let constantIV: Data?
    }

    /// The video track's encryption, from an init segment's `encv` entry.
    static func videoTrackEncryption(initSegment: Data) -> TrackEncryption? {
        let bytes = Array(initSegment)
        for trak in descendants(of: bytes, in: 0..<bytes.count, path: ["moov", "trak"]) {
            guard let tkhd = child("tkhd", of: bytes, in: trak),
                  let encv = descendants(of: bytes, in: trak, path: ["mdia", "minf", "stbl", "stsd"]).first.flatMap({
                      sampleEntry("encv", of: bytes, stsd: $0)
                  }),
                  encv.count >= 78, !tkhd.isEmpty,
                  let sinf = child("sinf", of: bytes, in: (encv.lowerBound + 78)..<encv.upperBound),
                  let schm = child("schm", of: bytes, in: sinf),
                  let tenc = descendants(of: bytes, in: sinf, path: ["schi", "tenc"]).first
            else { continue }
            let version = bytes[tkhd.lowerBound]
            let idOffset = tkhd.lowerBound + 4 + (version == 1 ? 16 : 8)
            guard idOffset + 4 <= tkhd.upperBound, schm.lowerBound + 8 <= schm.upperBound,
                  let scheme = TrackEncryption.Scheme(rawValue: String(bytes: bytes[(schm.lowerBound + 4)..<(schm.lowerBound + 8)], encoding: .ascii) ?? "")
            else { continue }
            let t = tenc.lowerBound
            guard t + 24 <= tenc.upperBound else { continue }
            let tencVersion = bytes[t]
            let pattern = tencVersion == 0 ? 0 : bytes[t + 5]
            let ivSize = Int(bytes[t + 7])
            guard [0, 8, 16].contains(ivSize) else { continue }
            var constantIV: Data?
            if bytes[t + 6] == 1, ivSize == 0, t + 25 <= tenc.upperBound {
                let size = Int(bytes[t + 24])
                if t + 25 + size <= tenc.upperBound { constantIV = Data(bytes[(t + 25)..<(t + 25 + size)]) }
            }
            return TrackEncryption(
                scheme: scheme, trackID: be32(bytes, idOffset),
                cryptBlocks: Int(pattern >> 4), skipBlocks: Int(pattern & 0x0F),
                perSampleIVSize: ivSize, constantIV: constantIV
            )
        }
        return nil
    }

    /// Decrypts, in place, every sample of the video track that lies wholly
    /// inside `segment` (a media segment's head). Encryption info comes from
    /// `senc`, or from the auxiliary data `saiz`/`saio` point at; the IV from
    /// the sample, the track's constant IV, or the playlist's EXT-X-KEY.
    static func decryptFragmentedMP4(
        _ segment: Data, track: TrackEncryption, key: Data, playlistIV: Data? = nil
    ) -> Data {
        var bytes = Array(segment)
        for moof in boxes(in: bytes, range: 0..<bytes.count) where moof.type == "moof" {
            for traf in boxes(in: bytes, range: moof.payload) where traf.type == "traf" {
                guard let tfhd = child("tfhd", of: bytes, in: traf.payload),
                      tfhd.count >= 8,
                      be32(bytes, tfhd.lowerBound + 4) == track.trackID,
                      let trun = child("trun", of: bytes, in: traf.payload)
                else { continue }
                let info: [(iv: Data?, subsamples: [(clear: Int, protected: Int)])]
                if let senc = child("senc", of: bytes, in: traf.payload) {
                    info = sampleEncryption(bytes, senc: senc, ivSize: track.perSampleIVSize)
                } else if let auxiliary = auxiliaryEncryption(bytes, traf: traf.payload, moofStart: moof.start,
                                                               ivSize: track.perSampleIVSize) {
                    info = auxiliary
                } else {
                    continue
                }
                let sizes = trackRunSampleSizes(bytes, tfhd: tfhd, trun: trun)
                let tfhdFlags = be32(bytes, tfhd.lowerBound) & 0xFFFFFF
                let base: Int
                if tfhdFlags & 0x01 != 0 {
                    guard tfhd.count >= 16, let offset = Int(exactly: be64(bytes, tfhd.lowerBound + 8)) else { continue }
                    base = offset
                } else {
                    base = moof.start
                }
                let (start, overflow) = base.addingReportingOverflow(trackRunDataOffset(bytes, trun: trun) ?? 0)
                guard !overflow, start >= 0, start <= bytes.count else { continue }
                var sampleStart = start
                for (index, size) in sizes.enumerated() {
                    guard size > 0, size <= bytes.count - sampleStart else { break }
                    let sampleEnd = sampleStart + size
                    if index < info.count {
                        let iv = info[index].iv ?? track.constantIV ?? playlistIV
                        decryptSample(&bytes, sampleStart..<sampleEnd, subsamples: info[index].subsamples,
                                      track: track, key: key, iv: iv)
                    }
                    sampleStart = sampleEnd
                }
            }
        }
        return Data(bytes)
    }

    /// Sample encryption info stored as auxiliary data: `saiz` gives each
    /// entry's size, `saio` where the run of entries starts (from the moof).
    static func auxiliaryEncryption(
        _ bytes: [UInt8], traf: Range<Int>, moofStart: Int, ivSize: Int
    ) -> [(iv: Data?, subsamples: [(clear: Int, protected: Int)])]? {
        guard [0, 8, 16].contains(ivSize),
              let saiz = child("saiz", of: bytes, in: traf), saiz.count >= 9,
              let saio = child("saio", of: bytes, in: traf), saio.count >= 8 else { return nil }
        let saizFlags = be32(bytes, saiz.lowerBound) & 0xFFFFFF
        var cursor = saiz.lowerBound + 4 + (saizFlags & 1 != 0 ? 8 : 0)
        guard cursor + 5 <= saiz.upperBound else { return nil }
        let defaultSize = Int(bytes[cursor])
        let count = Int(be32(bytes, cursor + 1))
        guard count <= 4_096, defaultSize == 0 || defaultSize >= ivSize else { return nil }
        cursor += 5
        var sizes: [Int] = []
        for index in 0..<count {
            if defaultSize != 0 {
                sizes.append(defaultSize)
            } else {
                guard cursor + index < saiz.upperBound, Int(bytes[cursor + index]) >= ivSize else { return nil }
                sizes.append(Int(bytes[cursor + index]))
            }
        }
        let saioVersion = bytes[saio.lowerBound]
        let saioFlags = be32(bytes, saio.lowerBound) & 0xFFFFFF
        let entryStart = saio.lowerBound + 4 + (saioFlags & 1 != 0 ? 8 : 0) + 4
        guard entryStart + (saioVersion == 1 ? 8 : 4) <= saio.upperBound else { return nil }
        guard let offset = saioVersion == 1 ? Int(exactly: be64(bytes, entryStart)) : Int(be32(bytes, entryStart)),
              moofStart >= 0, moofStart <= bytes.count, offset <= bytes.count - moofStart else { return nil }
        var position = moofStart + offset
        var result: [(iv: Data?, subsamples: [(clear: Int, protected: Int)])] = []
        for size in sizes {
            guard size <= bytes.count - position else { break }
            var entry = position
            var iv: Data?
            if ivSize > 0 {
                iv = Data(bytes[entry..<(entry + ivSize)])
                entry += ivSize
            }
            var subsamples: [(clear: Int, protected: Int)] = []
            if size > ivSize, entry + 2 <= position + size {
                let entries = Int(bytes[entry]) << 8 | Int(bytes[entry + 1])
                entry += 2
                for _ in 0..<entries where entry + 6 <= position + size {
                    subsamples.append((Int(bytes[entry]) << 8 | Int(bytes[entry + 1]), Int(be32(bytes, entry + 2))))
                    entry += 6
                }
            }
            result.append((iv, subsamples))
            position += size
        }
        return result
    }

    static func decryptSample(
        _ bytes: inout [UInt8], _ sample: Range<Int>, subsamples: [(clear: Int, protected: Int)],
        track: TrackEncryption, key: Data, iv: Data?
    ) {
        guard sample.lowerBound >= 0, sample.upperBound <= bytes.count, var iv else { return }
        if iv.count == 8 { iv.append(Data(count: 8)) }
        guard iv.count == 16 else { return }
        let ranges: [Range<Int>]
        if subsamples.isEmpty {
            ranges = [sample]
        } else {
            var cursor = sample.lowerBound
            var protectedRanges: [Range<Int>] = []
            for entry in subsamples {
                guard entry.clear >= 0, entry.protected >= 0,
                      entry.clear <= sample.upperBound - cursor else { return }
                let start = cursor + entry.clear
                guard entry.protected <= sample.upperBound - start else { return }
                let end = start + entry.protected
                cursor = end
                if start < end { protectedRanges.append(start..<end) }
            }
            ranges = protectedRanges
        }
        switch track.scheme {
        case .cenc:
            // One counter runs through all of a sample's protected bytes.
            guard let cipher = Cipher(mode: CCMode(kCCModeCTR), key: key, iv: iv) else { return }
            for range in ranges { cipher.update(&bytes, range) }
        case .cbcs:
            // The constant IV restarts every subsample; within one, the chain
            // runs across the encrypted blocks of the crypt:skip pattern.
            for range in ranges {
                guard let cipher = Cipher(mode: CCMode(kCCModeCBC), key: key, iv: iv) else { return }
                let crypt = track.cryptBlocks == 0 && track.skipBlocks == 0 ? Int.max / 32 : track.cryptBlocks
                var offset = range.lowerBound
                while offset + 16 <= range.upperBound {
                    let encrypted = min(crypt * 16, (range.upperBound - offset) / 16 * 16)
                    cipher.update(&bytes, offset..<(offset + encrypted))
                    offset += encrypted + track.skipBlocks * 16
                }
            }
        }
    }

    // MARK: MP4 boxes

    struct Box { let type: String; let start: Int; let payload: Range<Int> }

    static func boxes(in bytes: [UInt8], range: Range<Int>) -> [Box] {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else { return [] }
        var result: [Box] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            var size = Int(be32(bytes, offset))
            var header = 8
            if size == 1 {
                guard range.upperBound - offset >= 16,
                      let extended = Int(exactly: be64(bytes, offset + 8)) else { break }
                size = extended
                header = 16
            } else if size == 0 {
                size = range.upperBound - offset
            }
            guard size >= header else { break }
            let type = String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? ""
            let available = range.upperBound - offset
            guard size <= available || type == "mdat" else { break }
            let end = offset + min(size, available)
            result.append(Box(type: type, start: offset, payload: (offset + header)..<end))
            guard size <= available else { break }
            offset += size
        }
        return result
    }

    static func child(_ type: String, of bytes: [UInt8], in range: Range<Int>) -> Range<Int>? {
        boxes(in: bytes, range: range).first { $0.type == type }?.payload
    }

    static func descendants(of bytes: [UInt8], in range: Range<Int>, path: [String]) -> [Range<Int>] {
        guard let first = path.first else { return [range] }
        return boxes(in: bytes, range: range).filter { $0.type == first }.flatMap {
            descendants(of: bytes, in: $0.payload, path: Array(path.dropFirst()))
        }
    }

    /// A sample entry of `type` inside `stsd` (full box + entry count first).
    static func sampleEntry(_ type: String, of bytes: [UInt8], stsd: Range<Int>) -> Range<Int>? {
        guard stsd.lowerBound + 8 <= stsd.upperBound else { return nil }
        return boxes(in: bytes, range: (stsd.lowerBound + 8)..<stsd.upperBound).first { $0.type == type }?.payload
    }

    static func trackRunSampleSizes(_ bytes: [UInt8], tfhd: Range<Int>, trun: Range<Int>) -> [Int] {
        guard tfhd.count >= 8, trun.count >= 8 else { return [] }
        let tfhdFlags = be32(bytes, tfhd.lowerBound) & 0xFFFFFF
        var cursor = tfhd.lowerBound + 8
        if tfhdFlags & 0x01 != 0 { cursor += 8 }
        if tfhdFlags & 0x02 != 0 { cursor += 4 }
        if tfhdFlags & 0x08 != 0 { cursor += 4 }
        let defaultSize = tfhdFlags & 0x10 != 0 && cursor + 4 <= tfhd.upperBound ? Int(be32(bytes, cursor)) : 0
        let flags = be32(bytes, trun.lowerBound) & 0xFFFFFF
        let count = Int(be32(bytes, trun.lowerBound + 4))
        guard count <= 4_096 else { return [] }
        var offset = trun.lowerBound + 8
        if flags & 0x01 != 0 { offset += 4 }
        if flags & 0x04 != 0 { offset += 4 }
        let stride = [0x100, 0x200, 0x400, 0x800].filter { flags & UInt32($0) != 0 }.count * 4
        guard offset <= trun.upperBound, stride == 0 || count <= (trun.upperBound - offset) / stride else { return [] }
        var sizes: [Int] = []
        for _ in 0..<count {
            if flags & 0x100 != 0 { offset += 4 }
            var size = defaultSize
            if flags & 0x200 != 0 {
                guard offset + 4 <= trun.upperBound else { break }
                size = Int(be32(bytes, offset))
                offset += 4
            }
            if flags & 0x400 != 0 { offset += 4 }
            if flags & 0x800 != 0 { offset += 4 }
            sizes.append(size)
        }
        return sizes
    }

    static func trackRunDataOffset(_ bytes: [UInt8], trun: Range<Int>) -> Int? {
        let flags = be32(bytes, trun.lowerBound) & 0xFFFFFF
        guard flags & 0x01 != 0, trun.lowerBound + 12 <= trun.upperBound else { return nil }
        return Int(Int32(bitPattern: be32(bytes, trun.lowerBound + 8)))
    }

    static func sampleEncryption(
        _ bytes: [UInt8], senc: Range<Int>, ivSize: Int
    ) -> [(iv: Data?, subsamples: [(clear: Int, protected: Int)])] {
        guard senc.lowerBound >= 0, senc.upperBound <= bytes.count, senc.count >= 8,
              [0, 8, 16].contains(ivSize) else { return [] }
        let flags = be32(bytes, senc.lowerBound) & 0xFFFFFF
        let count = Int(be32(bytes, senc.lowerBound + 4))
        guard count <= 4_096, flags & 1 == 0 else { return [] }
        var offset = senc.lowerBound + 8
        var result: [(iv: Data?, subsamples: [(clear: Int, protected: Int)])] = []
        for _ in 0..<count {
            var iv: Data?
            if ivSize > 0 {
                guard offset + ivSize <= senc.upperBound else { break }
                iv = Data(bytes[offset..<(offset + ivSize)])
                offset += ivSize
            }
            var subsamples: [(clear: Int, protected: Int)] = []
            if flags & 0x02 != 0 {
                guard offset + 2 <= senc.upperBound else { break }
                let entries = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                offset += 2
                guard entries <= (senc.upperBound - offset) / 6 else { return [] }
                for _ in 0..<entries {
                    guard offset + 6 <= senc.upperBound else { break }
                    subsamples.append((Int(bytes[offset]) << 8 | Int(bytes[offset + 1]), Int(be32(bytes, offset + 2))))
                    offset += 6
                }
            }
            result.append((iv, subsamples))
        }
        return result
    }

    static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, bytes.count >= 4, offset <= bytes.count - 4 else { return 0 }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    static func be64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        guard offset >= 0, bytes.count >= 8, offset <= bytes.count - 8 else { return 0 }
        return UInt64(be32(bytes, offset)) << 32 | UInt64(be32(bytes, offset + 4))
    }
}
