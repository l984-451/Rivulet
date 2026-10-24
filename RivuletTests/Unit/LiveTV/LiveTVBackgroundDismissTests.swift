import XCTest
@testable import Rivulet

@MainActor
final class LiveTVBackgroundDismissTests: XCTestCase {
    func test_enteringBackground_dismissesLivePlayer() {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()

        let channel = UnifiedChannel(id: "test", sourceType: .dispatcharr, sourceId: "d", name: "Test",
                                     streamURL: URL(string: "http://127.0.0.1:1/x.ts"))
        let player = LiveTVAetherPlayerViewController(channel: channel)
        host.present(player, animated: false)
        XCTAssertNotNil(host.presentedViewController, "player was not presented")

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        let done = expectation(description: "dismissed")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertNil(host.presentedViewController, "player still presented, being dismissed: \(player.isBeingDismissed)")
    }
}
