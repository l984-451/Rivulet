// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import CoreGraphics
import Foundation
import SwiftDraw

/// Renders SVG, which ImageIO and UIImage cannot decode.
nonisolated enum SVGRasterizer {
    private static let maxBytes = 4 * 1024 * 1024
    private static let queue = DispatchQueue(label: "rivulet.svg-rasterizer", qos: .userInitiated)

    /// `cgImage` on its own queue, one file at a time. On Swift's thread pool (about 3 threads on
    /// an Apple TV) a screen of detailed logos would hold up every other image and request.
    static func decode(_ data: Data, maxPixelSize: CGFloat) async -> CGImage? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: cgImage(from: data, maxPixelSize: maxPixelSize))
            }
        }
    }

    /// Judged from the bytes, because a logo URL often has no extension and servers mislabel the type.
    static func isSVG(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
        return head.drop { $0.isWhitespace || $0 == "\u{FEFF}" }.hasPrefix("<")
            && head.contains("<svg")
            && !head.contains("<html")
    }

    /// A bitmap whose longest edge is `maxPixelSize`, whatever size the file declares.
    static func cgImage(from data: Data, maxPixelSize: CGFloat) -> CGImage? {
        guard data.count <= maxBytes,
              isSVG(data),
              SVGSafetyCheck.passes(data),
              let svg = SVG(data: data),
              svg.size.width > 0, svg.size.height > 0
        else { return nil }

        let longest = max(svg.size.width, svg.size.height)
        guard longest.isFinite else { return nil }
        let scale = maxPixelSize / longest
        let width = max(1, Int(svg.size.width * scale))
        let height = max(1, Int(svg.size.height * scale))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.draw(svg)
        return context.makeImage()
    }
}

/// SwiftDraw follows `<use>`, `<mask>` and `<pattern>` references with no cycle check or limit.
/// A cycle or deep nesting overflows the stack and a large expansion hangs, and a cached logo
/// would then kill every launch, so server-supplied files are measured before it sees them.
private nonisolated final class SVGSafetyCheck: NSObject, XMLParserDelegate {
    private static let maxDepth = 64
    private static let maxExpandedElements = 20_000

    private struct Scope {
        var elements = 0
        var height = 0
        var edges: [(target: String, depth: Int)] = []
    }

    private var scopes = ["": Scope()]
    private var open: [(scope: String, depth: Int)] = [("", 0)]
    private var depth = 0
    private var patterns: Set<String> = []
    private var styleText = ""
    private var styleDepth = 0

    static func passes(_ data: Data) -> Bool {
        let check = SVGSafetyCheck()
        let parser = XMLParser(data: data)
        parser.delegate = check
        return parser.parse() && check.isBounded
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String]
    ) {
        depth += 1
        guard depth <= Self.maxDepth else { return parser.abortParsing() }
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "svg", !Self.sizeFits(attributes) { return parser.abortParsing() }
        // SwiftDraw never returns from a path with data after a closepath that names no command.
        if attributes["d"]?.contains(/[zZ]\s*[^MmLlHhVvCcSsQqTtAaZz\s]/) == true { return parser.abortParsing() }
        if name == "style" { styleDepth = depth }

        var (scope, scopeDepth) = open[open.count - 1]
        scopes[scope, default: Scope()].elements += 1
        scopes[scope, default: Scope()].height = max(scopes[scope, default: Scope()].height, depth - scopeDepth)
        if let id = attributes["id"] {
            if name == "pattern" { patterns.insert(id) }
            // A repeated id gets its own scope: references resolve to the first, as SwiftDraw's do.
            let unique = scopes[id] == nil ? id : "\(id)\u{0}\(scopes.count)"
            scopes[scope, default: Scope()].edges.append((unique, depth - scopeDepth))
            scopes[unique] = Scope()
            (scope, scopeDepth) = (unique, depth)
        }
        open.append((scope, scopeDepth))

        for (key, value) in attributes {
            var targets = Self.urlReferences(in: value)
            if key == "href" || key.hasSuffix(":href"), value.hasPrefix("#") {
                targets.append(String(value.dropFirst()))
            }
            for target in targets {
                scopes[scope, default: Scope()].edges.append((target, depth - scopeDepth + 1))
            }
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?
    ) {
        if depth == styleDepth { styleDepth = 0 }
        depth -= 1
        open.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if styleDepth > 0 { styleText += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if styleDepth > 0 { styleText += String(decoding: CDATABlock, as: UTF8.self) }
    }

    /// SwiftDraw traps converting a root size that doesn't fit an Int.
    private static func sizeFits(_ attributes: [String: String]) -> Bool {
        ["width", "height", "viewBox"].allSatisfy { key in
            let value = attributes[key]?.lowercased() ?? ""
            return !value.contains("nan") && !value.contains("inf") && !value.contains("0x")
                && value.matches(of: /[0-9.]+(e[-+]?[0-9]+)?/).allSatisfy { abs(Double($0.0) ?? .infinity) < 10_000_000 }
        }
    }

    private static func urlReferences(in value: String) -> [String] {
        guard value.contains("url(") else { return [] }
        return value.matches(of: /url\(\s*['"]?#([^)'"\s]+)/).map { String($0.1) }
    }

    private var isBounded: Bool {
        // A class rule can apply to anything, so a pattern filled from CSS can't be followed
        // here. Embedded fonts would reach SwiftDraw's WOFF parsers, and logos don't need them.
        guard !styleText.contains("@font-face"),
              Self.urlReferences(in: styleText).allSatisfy({ !patterns.contains($0) })
        else { return false }

        var measured: [String: (elements: Int, height: Int)] = [:]
        var visiting: Set<String> = []

        func measure(_ id: String, at depth: Int) -> (elements: Int, height: Int)? {
            if let known = measured[id] {
                return depth + known.height <= Self.maxDepth ? known : nil
            }
            guard depth <= Self.maxDepth, visiting.insert(id).inserted else { return nil }
            defer { visiting.remove(id) }

            let scope = scopes[id] ?? Scope()
            var total = (elements: scope.elements, height: scope.height)
            for edge in scope.edges {
                guard let target = measure(edge.target, at: depth + edge.depth) else { return nil }
                total.elements += target.elements
                total.height = max(total.height, edge.depth + target.height)
            }
            guard total.elements <= Self.maxExpandedElements, depth + total.height <= Self.maxDepth else { return nil }
            measured[id] = total
            return total
        }
        return measure("", at: 0) != nil
    }
}
