// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import StoreKit

/// One-time tips (consumable in-app purchases). A tip unlocks nothing.
@MainActor
enum TipJar {
    static let productIDs = [
        "com.gstudios.rivulet.tip.small",
        "com.gstudios.rivulet.tip.medium",
        "com.gstudios.rivulet.tip.large",
    ]

    /// The tips, cheapest first; empty when the App Store can't be reached.
    static func products() async -> [Product] {
        let products = (try? await Product.products(for: productIDs)) ?? []
        return products.sorted { $0.price < $1.price }
    }

    /// True once the tip has gone through. Cancelled, pending and failed all return false.
    static func purchase(_ product: Product) async -> Bool {
        guard case .success(let verification) = try? await product.purchase() else { return false }
        await finish(verification)
        return true
    }

    /// Finishes tips that complete outside a purchase call (Ask to Buy, an interrupted
    /// purchase); an unfinished consumable is delivered again on every launch.
    static func start() {
        Task.detached {
            for await update in Transaction.updates { await finish(update) }
        }
    }

    private static func finish(_ result: VerificationResult<Transaction>) async {
        // Nothing to deliver, so an unverified tip is finished too: leaving it would replay it forever.
        switch result {
        case .verified(let transaction), .unverified(let transaction, _):
            await transaction.finish()
        }
    }
}
