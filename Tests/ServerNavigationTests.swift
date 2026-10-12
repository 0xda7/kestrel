import Foundation
@testable import KestrelCore

final class ServerNavigationTests: CheckCase {
    @MainActor func testSelectedInstanceIsTheOnlyVisibleServer() {
        let navigation = ControlPanelState()
        let primary = ServerController()
        let secondary = ServerController()
        let servers = [primary, secondary]
        XCTAssertEqual(navigation.visibleServers(from: servers).map(\.id), servers.map(\.id))
        navigation.focusServer(secondary.id)
        XCTAssertEqual(navigation.visibleServers(from: servers).map(\.id), [secondary.id])
        navigation.focusServer(primary.id)
        XCTAssertEqual(navigation.visibleServers(from: servers).map(\.id), [primary.id])
        navigation.serverAnchor = nil
        XCTAssertEqual(navigation.visibleServers(from: servers).count, 2)
    }

    @MainActor func testServerLogBufferKeepsLatestOutputWhileCoalescingUIRefreshes() {
        let buffer = ServerLogBuffer()
        buffer.set("start\n")
        buffer.append("one\n")
        buffer.append("two\n", limit: 12, retained: 8)
        XCTAssertEqual(buffer.text, String("start\none\ntwo\n".suffix(8)))
    }
}

// MARK: - Generated registration (port from XCTest)
extension ServerNavigationTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "ServerNavigationTests",
        instance: { ServerNavigationTests() },
        checks: [
            .init(name: "testSelectedInstanceIsTheOnlyVisibleServer") { $0.testSelectedInstanceIsTheOnlyVisibleServer() },
            .init(name: "testServerLogBufferKeepsLatestOutputWhileCoalescingUIRefreshes") { $0.testServerLogBufferKeepsLatestOutputWhileCoalescingUIRefreshes() },
        ])
}
