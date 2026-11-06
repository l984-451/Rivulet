import XCTest
import UIKit
@testable import Rivulet

@MainActor
final class SidebarReselectionTests: XCTestCase {
    func test_explicitHomeReselectionReachesPageInsideWrappers() throws {
        let (shell, home, other) = makeShell()
        let sidebar = try XCTUnwrap(shell.children.compactMap { $0 as? ShellSidebarViewController }.first)

        sidebar.onTabSelected?(.home)
        XCTAssertEqual(home.topRequests, 1)
        XCTAssertEqual(other.topRequests, 0)
    }

    func test_closingSidebarAndSwitchingTabsPreservePosition() throws {
        let (shell, home, other) = makeShell()
        let sidebar = try XCTUnwrap(shell.children.compactMap { $0 as? ShellSidebarViewController }.first)

        sidebar.onCollapseRequested?()
        XCTAssertEqual(home.topRequests, 0)
        sidebar.onTabSelected?(.discover)
        XCTAssertEqual(other.topRequests, 0)
        sidebar.onTabSelected?(.home)
        XCTAssertEqual(home.topRequests, 0, "Returning to Home from another tab must preserve its position")

        sidebar.onTabSelected?(.home)
        XCTAssertEqual(home.topRequests, 1)
    }

    func test_everyContentTabHandlesExplicitReselection() throws {
        let tabs: [SidebarTab] = [.home, .search, .discover, .watchlist, .library(key: "movies"),
                                 .providerLibrary(providerID: "jellyfin", libraryID: "shows"),
                                 .playlists(providerID: "plex"), .liveTV(sourceId: nil),
                                 .liveTV(sourceId: "iptv"), .settings]
        for tab in tabs {
            let shell = RootShellViewController()
            let page = Page()
            shell.makeContent = { _ in page }
            shell.applySelection(tab)
            shell.loadViewIfNeeded()
            let sidebar = try XCTUnwrap(shell.children.compactMap { $0 as? ShellSidebarViewController }.first)
            sidebar.setExpanded(true, animated: false)
            page.onReselect = { XCTAssertFalse(sidebar.isExpanded, "Focus must leave the sidebar before returning to top") }

            sidebar.onTabSelected?(tab)
            XCTAssertEqual(page.topRequests, 1, "Reselecting \(tab)")
            shell.applySelection(tab)
            XCTAssertEqual(page.topRequests, 1, "State synchronization must not repeat the action")
            sidebar.onTabSelected?(tab)
            XCTAssertEqual(page.topRequests, 2, "Each explicit selection must request a return to top")
        }
    }

    func test_accountRemainsAnAction() throws {
        let (shell, home, _) = makeShell()
        let sidebar = try XCTUnwrap(shell.children.compactMap { $0 as? ShellSidebarViewController }.first)
        var selected: SidebarTab?
        shell.onTabChange = { selected = $0 }
        sidebar.onTabSelected?(.account)
        XCTAssertEqual(selected, .account)
        XCTAssertEqual(shell.currentTab, .home)
        XCTAssertEqual(home.topRequests, 0)
    }

    func test_hiddenAndUnmountedPagesAreSkipped() {
        let wrapper = UIViewController()
        let hidden = Page(), unmounted = Page(), visible = Page()
        mount(hidden, in: wrapper)
        hidden.view.isHidden = true
        wrapper.addChild(unmounted)
        unmounted.didMove(toParent: wrapper)
        mount(visible, in: wrapper)

        SidebarReselection.target(in: wrapper.view)?.reselectSidebarTab()
        XCTAssertEqual(hidden.topRequests, 0)
        XCTAssertEqual(unmounted.topRequests, 0)
        XCTAssertEqual(visible.topRequests, 1)
    }

    func test_containerOwnsReselectionBeforeItsResults() {
        let container = Page(), results = Page()
        mount(results, in: container)
        SidebarReselection.target(in: container.view)?.reselectSidebarTab()
        XCTAssertEqual(container.topRequests, 1)
        XCTAssertEqual(results.topRequests, 0)
    }

    func test_hostedViewCanHandleReselection() {
        let host = UIViewController()
        let guide = ReselectableView()
        host.view.addSubview(guide)
        SidebarReselection.target(in: host.view)?.reselectSidebarTab()
        XCTAssertEqual(guide.topRequests, 1)
    }

    private func makeShell() -> (RootShellViewController, Page, Page) {
        let shell = RootShellViewController()
        let home = Page(), other = Page()
        let wrapper = UIViewController(), nestedWrapper = UIViewController()
        mount(nestedWrapper, in: wrapper)
        mount(home, in: nestedWrapper)
        shell.makeContent = { $0 == .home ? wrapper : other }
        shell.loadViewIfNeeded()
        return (shell, home, other)
    }

    private func mount(_ child: UIViewController, in parent: UIViewController) {
        parent.addChild(child)
        parent.view.addSubview(child.view)
        child.didMove(toParent: parent)
    }

    private final class Page: UIViewController, SidebarTabReselecting {
        private(set) var topRequests = 0
        var onReselect: (() -> Void)?

        func reselectSidebarTab() {
            topRequests += 1
            onReselect?()
        }
    }

    private final class ReselectableView: UIView, SidebarTabReselecting {
        private(set) var topRequests = 0

        func reselectSidebarTab() {
            topRequests += 1
        }
    }
}
