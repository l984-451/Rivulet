import XCTest
import UIKit
@testable import Rivulet

@MainActor
final class SiloRequestsTests: XCTestCase {
    private func makeService(_ server: SiloAuthTestServer, owner: @escaping @Sendable () async -> Bool = { true }) -> SiloRequests {
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid")!, profileID: "profile-a", transport: server.transport)
        let provider = SiloProvider(serverID: "server-a", displayName: "Synthetic", profileID: "profile-a", client: client)
        return SiloRequests(provider: provider, ownerIsCurrent: owner)
    }

    func testUnavailableCapabilityStopsSearchBeforeItLeavesClient() async throws {
        let server = SiloAuthTestServer()
        await server.respond("GET", "/api/v2/requests/status", [.init(body: #"{"requests_enabled":true,"state":"available","allowed":false}"#)])
        let service = makeService(server)
        do { _ = try await service.search("Synthetic Movie") ; XCTFail("Search should be gated") }
        catch SiloRequestsError.unavailable { }
        let calls = await server.requests()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.url?.path, "/api/v2/requests/status")
    }

    func testStaleAuthorityDiscardsStatus() async throws {
        let server = SiloAuthTestServer()
        let service = makeService(server, owner: { false })
        do { _ = try await service.status(); XCTFail("Stale owner should fail") }
        catch SiloRequestsError.staleAuthority { }
        let calls = await server.requests()
        XCTAssertTrue(calls.isEmpty)
    }

    func testCancelEligibilityRespectsSubmissionBoundary() throws {
        func record(_ status: String, _ outcome: String, targets: String) throws -> SiloRequestRecord {
            let json = """
            {"id":"synthetic-1","media_type":"movie","tmdb_id":123,"title":"Synthetic Movie",\
            "status":"\(status)","outcome":"\(outcome)","created_at":"2026-01-01T00:00:00Z",\
            "updated_at":"2026-01-01T00:00:00Z","targets":\(targets)}
            """
            return try SiloJSON.decoder().decode(SiloRequestRecord.self, from: Data(json.utf8))
        }
        XCTAssertTrue(try record("pending", "active", targets: "[]").canCancel)
        XCTAssertTrue(try record("approved", "active", targets: "[]").canCancel)
        XCTAssertFalse(try record("approved", "active", targets: #"[{"status":"queued"}]"#).canCancel)
        XCTAssertFalse(try record("queued", "active", targets: "[]").canCancel)
        XCTAssertFalse(try record("completed", "active", targets: "[]").canCancel)
        XCTAssertFalse(try record("pending", "cancelled", targets: "[]").canCancel)
        XCTAssertFalse(try record("approved", "active", targets: "null").canCancel)
    }

    func testFollowRequiresExplicitViewerPermissionState() throws {
        func state(_ following: String, viewer: String) throws -> SiloRequestState {
            let json = """
            {"requestable":false,"request_id":"synthetic-1","following":\(following),"requested_by_viewer":\(viewer)}
            """
            return try SiloJSON.decoder().decode(SiloRequestState.self, from: Data(json.utf8))
        }
        XCTAssertTrue(try state("false", viewer: "false").canFollow)
        XCTAssertTrue(try state("true", viewer: "false").canUnfollow)
        XCTAssertFalse(try state("null", viewer: "false").canFollow)
        XCTAssertFalse(try state("false", viewer: "true").canFollow)
        XCTAssertFalse(try state("true", viewer: "true").canUnfollow)
    }

    func testCancelRefusesSubmittedRequestBeforeMutation() async throws {
        let server = SiloAuthTestServer()
        await server.respond("GET", "/api/v2/requests/status", [.init(body: #"{"requests_enabled":true,"state":"available","allowed":true}"#)])
        let json = #"{"id":"synthetic-1","media_type":"movie","tmdb_id":123,"title":"Synthetic Movie","status":"approved","outcome":"active","targets":[{"status":"queued"}],"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}"#
        let record = try SiloJSON.decoder().decode(SiloRequestRecord.self, from: Data(json.utf8))
        do { _ = try await makeService(server).cancel(record); XCTFail("Submitted request should be refused") }
        catch SiloRequestsError.notPermitted { }
        let calls = await server.requests()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.httpMethod, "GET")
    }

    func testNativeCreateFollowUnfollowAndCancelUseExplicitMutations() async throws {
        let server = SiloAuthTestServer()
        await server.respond("GET", "/api/v2/requests/status", [.init(body: """
        {"requests_enabled":true,"state":"available","allowed":true,"follow_supported":true}
        """)])
        let recordJSON = """
        {"id":"synthetic-1","media_type":"movie","tmdb_id":123,"title":"Synthetic Movie",
         "status":"pending","outcome":"active","targets":[],
         "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}
        """
        let resultJSON = """
        {"media_type":"movie","tmdb_id":123,"title":"Synthetic Movie","availability":"missing",
         "request":{"requestable":true,"request_id":"synthetic-1","following":false,"requested_by_viewer":false}}
        """
        let result = try SiloJSON.decoder().decode(SiloRequestSearchResult.self, from: Data(resultJSON.utf8))
        await server.respond("POST", "/api/v2/requests", [.init(body: recordJSON)])
        await server.respond("PUT", "/api/v2/requests/follows/movie/123", [.init(body: """
        {"requestable":false,"request_id":"synthetic-1","following":true,"requested_by_viewer":false}
        """)])
        await server.respond("DELETE", "/api/v2/requests/follows/movie/123", [.init(status: 204, body: "")])
        await server.respond("POST", "/api/v2/requests/synthetic-1/cancel", [.init(body: recordJSON)])
        let service = makeService(server)
        let created = try await service.create(result)
        let followed = try await service.follow(result)
        let followedResult = SiloRequestSearchResult(mediaType: result.mediaType, tmdbId: result.tmdbId,
            title: result.title, year: result.year, overview: result.overview, posterPath: result.posterPath,
            availability: result.availability, request: followed)
        try await service.unfollow(followedResult)
        _ = try await service.cancel(created)
        let mutations = await server.requests().filter { $0.httpMethod != "GET" }
        XCTAssertEqual(mutations.map(\.httpMethod), ["POST", "PUT", "DELETE", "POST"])
        XCTAssertEqual(mutations.map { $0.url!.path }, [
            "/api/v2/requests", "/api/v2/requests/follows/movie/123",
            "/api/v2/requests/follows/movie/123", "/api/v2/requests/synthetic-1/cancel"
        ])
    }

    func testUncertainCreateIsNeverReplayed() async throws {
        let server = SiloAuthTestServer()
        await server.respond("GET", "/api/v2/requests/status", [.init(body: """
        {"requests_enabled":true,"state":"available","allowed":true}
        """)])
        await server.respond("POST", "/api/v2/requests", [.init(error: .networkConnectionLost)])
        let result = try SiloJSON.decoder().decode(SiloRequestSearchResult.self, from: Data("""
        {"media_type":"movie","tmdb_id":123,"title":"Synthetic Movie","availability":"missing",
         "request":{"requestable":true}}
        """.utf8))
        do { _ = try await makeService(server).create(result); XCTFail("A lost reply is uncertain") }
        catch SiloRequestsError.uncertainMutation { }
        let calls = await server.requests()
        XCTAssertEqual(calls.filter { $0.httpMethod == "POST" }.count, 1)
    }
}

/// Real-controller regressions for pagination, profile authority and uncertain
/// mutations. Saved accounts are untouched; transport replies are synthetic.
@MainActor
final class SiloRequestsViewControllerTests: XCTestCase {
    private var authorityCurrent = true
    private let available = """
    {"requests_enabled":true,"state":"available","allowed":true,"follow_supported":true}
    """

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func control<T: UIView>(_ type: T.Type, _ identifier: String,
                                    in controller: UIViewController) throws -> T {
        try XCTUnwrap(descendants(controller.view).compactMap { $0 as? T }
            .first { $0.accessibilityIdentifier == identifier })
    }

    private func waitForUI(_ condition: () -> Bool, file: StaticString = #filePath,
                           line: UInt = #line) async {
        for _ in 0..<250 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Expected Requests UI state did not arrive", file: file, line: line)
    }

    private func makeSurface(_ server: SiloAuthTestServer,
                             context: SiloRequestsViewController.Context = .list) throws
        -> (controller: SiloRequestsViewController, window: UIWindow, previous: UIWindow?) {
        authorityCurrent = true
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid")!,
                                profileID: "profile-a", transport: server.transport)
        let provider = SiloProvider(serverID: "server-a", displayName: "Synthetic",
                                    profileID: "profile-a", client: client)
        let controller = SiloRequestsViewController(provider: provider, context: context,
                                                    ownerIsCurrent: { self.authorityCurrent })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return (controller, window, previous)
    }


    private func record(_ id: Int, title: String, status: String, outcome: String = "active",
                        targets: String = "[]", lastError: String = "null") -> String {
        """
        {"id":"synthetic-\(id)","media_type":"movie","tmdb_id":\(id),"title":"\(title)","year":2026,
         "status":"\(status)","outcome":"\(outcome)","targets":\(targets),"last_error":\(lastError),
         "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}
        """
    }

    func testListPaginationConsumesTheServerCursorWithoutMutations() async throws {
        let server = SiloAuthTestServer()
        await server.respond("GET", "/api/v2/requests/status", [.init(body: available)])
        let pending = record(1, title: "A Synthetic Movie With a Deliberately Long Title for Living Room Reading",
                             status: "pending")
        let downloading = record(2, title: "Synthetic Download", status: "downloading",
                                 targets: #"[{"status":"downloading"}]"#)
        let completed = record(3, title: "Synthetic Completed", status: "completed")
        let failed = record(4, title: "Synthetic Failed", status: "failed", outcome: "failed",
                            lastError: #""The provider could not complete this request.""#)
        let cancelled = record(5, title: "Synthetic Cancelled", status: "pending", outcome: "cancelled")
        let declined = record(6, title: "Synthetic Declined", status: "pending", outcome: "declined")
        await server.respond("GET", "/api/v2/requests/mine", [
            .init(body: """
            {"items":[\(pending),\(downloading),\(completed)],"page":{"has_more":true,"next_cursor":"fixture-next"}}
            """),
            .init(body: """
            {"items":[\(failed),\(cancelled),\(declined)],"page":{"has_more":false}}
            """)
        ])
        let surface = try makeSurface(server)
        defer {
            surface.controller.invalidateAuthority()
            surface.window.isHidden = true
            surface.previous?.makeKeyAndVisible()
        }
        let table = try control(UITableView.self, "silo.requests.list", in: surface.controller)
        await waitForUI { table.numberOfRows(inSection: 0) == 6 }
        let calls = await server.requests()
        let listReads = calls.filter { $0.url?.path == "/api/v2/requests/mine" }
        XCTAssertEqual(listReads.count, 2)
        let cursor = URLComponents(url: try XCTUnwrap(listReads.last?.url),
                                   resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value
        XCTAssertEqual(cursor, "fixture-next")
        XCTAssertTrue(calls.allSatisfy { $0.httpMethod == "GET" })
    }

    func testSearchPaginationRetryRetainsResultsAndTheSubmittedQuery() async throws {
        let server = SiloAuthTestServer()
        await server.respond("GET", "/api/v2/requests/status", [.init(body: available)])
        let missing = """
        {"media_type":"movie","tmdb_id":1,"title":"Synthetic Missing Movie","year":2026,
         "poster_path":"/synthetic.jpg","availability":"missing","request":{"requestable":true}}
        """
        let requested = """
        {"media_type":"series","tmdb_id":2,"title":"Synthetic Requested Series","availability":"missing",
         "request":{"requestable":false,"request_id":"request-2","status":"queued","following":false,"requested_by_viewer":false}}
        """
        let followed = """
        {"media_type":"movie","tmdb_id":3,"title":"Synthetic Followed Movie","availability":"missing",
         "request":{"requestable":false,"request_id":"request-3","status":"pending","following":true,"requested_by_viewer":false}}
        """
        let unknown = """
        {"media_type":"movie","tmdb_id":4,"title":"Synthetic Unknown Availability","availability":"unknown",
         "request":{"requestable":true,"reason":"Silo has not confirmed availability."}}
        """
        let inLibrary = """
        {"media_type":"movie","tmdb_id":5,"title":"Synthetic Library Movie","availability":"available",
         "request":{"requestable":false}}
        """
        await server.respond("GET", "/api/v2/requests/search", [
            .init(body: """
            {"page":1,"total_pages":2,"total_results":5,"results":[\(missing),\(requested),\(followed),\(unknown)]}
            """),
            .init(error: .networkConnectionLost),
            .init(body: """
            {"page":2,"total_pages":2,"total_results":5,"results":[\(missing),\(inLibrary)]}
            """)
        ])
        let surface = try makeSurface(server, context: .search("Synthetic"))
        defer {
            surface.controller.invalidateAuthority()
            surface.window.isHidden = true
            surface.previous?.makeKeyAndVisible()
        }
        let table = try control(UITableView.self, "silo.requests.list", in: surface.controller)
        let retry = try control(FocusableActionButton.self, "silo.requests.retry", in: surface.controller)
        await waitForUI { !retry.isHidden && table.numberOfRows(inSection: 0) == 4 }
        XCTAssertEqual(table.numberOfRows(inSection: 0), 4)
        XCTAssertFalse(retry.isHidden)
        let search = try control(UISearchBar.self, "silo.requests.search", in: surface.controller)
        search.text = "Unsubmitted different title"
        retry.onPrimaryAction?()
        await waitForUI { table.numberOfRows(inSection: 0) == 5 }
        XCTAssertTrue(retry.isHidden)
        let calls = await server.requests()
        let searchReads = calls.filter { $0.url?.path == "/api/v2/requests/search" }
        let pages = searchReads.map {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
        }
        XCTAssertEqual(pages, ["1", "2", "2"])
        let queries = searchReads.map {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        }
        XCTAssertEqual(queries, ["Synthetic", "Synthetic", "Synthetic"])
        XCTAssertTrue(calls.allSatisfy { $0.httpMethod == "GET" }, "Artwork must not trigger fabricated network lookups")
    }

    func testUncertainMutationWaitsForActionDismissalAndDoesNotReplay() async throws {
        let server = SiloAuthTestServer()
        await server.respond("GET", "/api/v2/requests/status", [.init(body: available)])
        let resultJSON = """
        {"media_type":"movie","tmdb_id":1,"title":"Synthetic Movie","availability":"missing",
         "request":{"requestable":true}}
        """
        let result = try SiloJSON.decoder().decode(SiloRequestSearchResult.self, from: Data(resultJSON.utf8))
        let page = """
        {"page":1,"total_pages":1,"total_results":1,"results":[\(resultJSON)]}
        """
        let reconciliation = SiloAuthRequestGate()
        await server.respond("GET", "/api/v2/requests/search", [
            .init(body: page), .init(body: page, gate: reconciliation)
        ])
        await server.respond("POST", "/api/v2/requests", [.init(error: .networkConnectionLost)])
        let surface = try makeSurface(server, context: .search("Synthetic"))
        defer {
            Task { await reconciliation.release() }
            surface.controller.invalidateAuthority()
            surface.window.isHidden = true
            surface.previous?.makeKeyAndVisible()
        }
        let table = try control(UITableView.self, "silo.requests.list", in: surface.controller)
        await waitForUI { table.numberOfRows(inSection: 0) == 1 }
        surface.controller.tableView(table, didSelectRowAt: IndexPath(row: 0, section: 0))
        let actionMenu = try XCTUnwrap(surface.controller.presentedViewController as? UIAlertController)
        await waitForUI { actionMenu.viewIfLoaded?.window != nil && !actionMenu.isBeingPresented }
        surface.controller.mutate { service in _ = try await service.create(result) }
        actionMenu.dismiss(animated: true)
        // A second action during the same mutation must not reach the service.
        surface.controller.mutate { service in _ = try await service.create(result) }
        await fulfillment(of: [reconciliation.entered], timeout: 5)
        await reconciliation.release()
        await waitForUI {
            guard let alert = surface.controller.presentedViewController as? UIAlertController else { return false }
            return alert !== actionMenu && alert.viewIfLoaded?.window != nil && !alert.isBeingPresented
        }
        let calls = await server.requests()
        XCTAssertEqual(calls.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertEqual(calls.filter { $0.url?.path == "/api/v2/requests/search" }.count, 2,
                       "An uncertain mutation must reconcile through a new read, not replay the change")
    }

    func testPermissionAndProfileChangesFenceControlsAndReadOnlyRetry() async throws {
        let server = SiloAuthTestServer()
        let gate = SiloAuthRequestGate()
        await server.respond("GET", "/api/v2/requests/status", [
            .init(body: #"{"requests_enabled":true,"state":"available","allowed":false}"#, gate: gate),
            .init(error: .notConnectedToInternet),
            .init(body: available)
        ])
        await server.respond("GET", "/api/v2/requests/mine", [.init(body: #"{"items":[]}"#)])
        let surface = try makeSurface(server)
        defer {
            Task { await gate.release() }
            surface.controller.invalidateAuthority()
            surface.window.isHidden = true
            surface.previous?.makeKeyAndVisible()
        }
        let search = try control(UISearchBar.self, "silo.requests.search", in: surface.controller)
        let refresh = try control(FocusableActionButton.self, "silo.requests.refresh", in: surface.controller)
        let retry = try control(FocusableActionButton.self, "silo.requests.retry", in: surface.controller)
        await fulfillment(of: [gate.entered], timeout: 5)
        await gate.release()
        await waitForUI { !search.isUserInteractionEnabled }
        XCTAssertFalse(search.isUserInteractionEnabled)
        let deniedCalls = await server.requests()
        XCTAssertTrue(deniedCalls.allSatisfy { $0.url?.path == "/api/v2/requests/status" })
        refresh.onPrimaryAction?()
        await waitForUI { !retry.isHidden }
        retry.onPrimaryAction?()
        await waitForUI { search.isUserInteractionEnabled && retry.isHidden }
        XCTAssertTrue(search.isUserInteractionEnabled)
        XCTAssertTrue(retry.isHidden)
        authorityCurrent = false
        surface.controller.refresh()
        await waitForUI { refresh.isHidden && !search.isUserInteractionEnabled }
        XCTAssertTrue(refresh.isHidden)
        XCTAssertFalse(search.isUserInteractionEnabled)
    }
}
