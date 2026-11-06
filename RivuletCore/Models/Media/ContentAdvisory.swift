// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ContentAdvisory.swift
//  Rivulet
//
//  Provider-agnostic content-advisory model (Common Sense Media on Plex, but the
//  shape is backend-neutral). Lives above the provider seam like MediaItem /
//  MediaPerson; each MediaProvider maps its own source into this, and the detail
//  UI renders from it without knowing the backend. Carried on MediaItemDetail.
//

import Foundation

struct ContentAdvisory: Sendable, Hashable {
    /// Age recommendation, display-ready (e.g. "13+").
    var ageRating: String?
    /// Overall quality/age star rating, 0–5.
    var starRating: Double?
    /// One-line summary ("A great show for…").
    var oneLiner: String?
    /// The "what parents need to know" paragraph.
    var parentsNeedToKnow: String?
    /// Per-category breakdown (Violence & Scariness, Language, Sex…).
    var topics: [Topic] = []

    struct Topic: Sendable, Hashable, Identifiable {
        let id: String          // label, stable within an item
        let label: String       // "Violence & Scariness"
        let rating: Int?        // 0–5 intensity, if provided
        let isPositive: Bool    // CSM positive category (messages/role models) vs a concern
        let systemImage: String // SF Symbol for the category

        init(label: String, rating: Int?, isPositive: Bool) {
            self.id = label
            self.label = label
            self.rating = rating
            self.isPositive = isPositive
            self.systemImage = ContentAdvisory.symbol(for: label)
        }
    }

    /// True when there's more than just an age rating — i.e. the rich Discover
    /// data arrived (paragraph and/or topic breakdown).
    var hasRichDetail: Bool {
        (parentsNeedToKnow?.isEmpty == false) || !topics.isEmpty
    }

    /// Any advisory content at all (age rating counts).
    var hasAny: Bool {
        ageRating?.isEmpty == false || starRating != nil || hasRichDetail
    }

    /// Map a Common Sense category label to an SF Symbol (substring match — the
    /// labels vary slightly across titles/versions).
    static func symbol(for label: String) -> String {
        let l = label.lowercased()
        switch true {
        case l.contains("violen"), l.contains("scary"), l.contains("scarines"), l.contains("fright"):
            return "exclamationmark.triangle.fill"
        case l.contains("sex"), l.contains("romance"), l.contains("nudity"):
            return "heart.fill"
        case l.contains("language"), l.contains("profan"):
            return "text.bubble.fill"
        case l.contains("drink"), l.contains("drug"), l.contains("smok"):
            return "pills.fill"
        case l.contains("consum"), l.contains("product"), l.contains("purchas"):
            return "cart.fill"
        case l.contains("role model"):
            return "person.fill.checkmark"
        case l.contains("positive"), l.contains("message"):
            return "checkmark.bubble.fill"
        case l.contains("divers"), l.contains("represent"):
            return "person.3.fill"
        case l.contains("educat"):
            return "graduationcap.fill"
        default:
            return "info.circle.fill"
        }
    }
}
