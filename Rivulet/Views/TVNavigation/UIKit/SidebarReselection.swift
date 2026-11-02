// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit

@MainActor
protocol SidebarTabReselecting: AnyObject {
    func reselectSidebarTab()
}

@MainActor
enum SidebarReselection {
    /// Follow mounted views so cached, hidden pages cannot consume the request.
    /// A handler can be a controller or a hosted UIKit view, such as the guide.
    static func target(in view: UIView) -> (any SidebarTabReselecting)? {
        guard !view.isHidden else { return nil }
        if let target = view as? any SidebarTabReselecting { return target }
        if let target = view.next as? any SidebarTabReselecting { return target }
        for child in view.subviews {
            if let target = target(in: child) { return target }
        }
        return nil
    }

    static func returnToTop(in collectionView: UICollectionView, focusing indexPath: IndexPath?) {
        ScrollToTopTransition.perform(in: collectionView) {
            collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
            collectionView.layoutIfNeeded()
            guard let indexPath, let cell = collectionView.cellForItem(at: indexPath),
                  let system = UIFocusSystem.focusSystem(for: collectionView) else { return }
            system.requestFocusUpdate(to: cell)
            system.updateFocusIfNeeded()
        }
    }
}
