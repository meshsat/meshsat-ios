import MeshSatUI
import XCTest

final class RouteTests: XCTestCase {
    func testRouteStringsRoundTrip() {
        let routes: [Route] = [
            .home, .messages, .map, .people, .setup, .chat(peer: "!8b04a69e"), .chat(peer: "+31 6 12345678"),
            .setupSection(.node), .setupSection(.integrations), .setupAdvanced, .passes, .radioConfig, .rules,
            .interfaces, .deliveries, .topology, .geofence, .audit, .credentials, .decrypt, .about, .sos,
        ]
        for r in routes {
            XCTAssertEqual(Route(string: r.string), r, r.string)
        }
        XCTAssertEqual(Route.setupSection(.node).string, "setup/node")
        XCTAssertEqual(Route.radioConfig.string, "radio-config")
        XCTAssertNil(Route(string: "setup/nope"))
    }

    func testTabOfRoute() {
        XCTAssertEqual(Route.passes.tab, .home)
        XCTAssertEqual(Route.chat(peer: "x").tab, .messages)
        XCTAssertEqual(Route.topology.tab, .people)
        XCTAssertEqual(Route.about.tab, .setup)
        XCTAssertEqual(Route.map.tab, .map)
    }

    func testSubScreenTitlesMatchAndroid() {
        XCTAssertEqual(Route.setupSection(.integrations).subScreenTitle, "Ham radio, TAK and Reticulum")
        XCTAssertEqual(Route.interfaces.subScreenTitle, "Links")
        XCTAssertEqual(Route.deliveries.subScreenTitle, "Message queue")
        XCTAssertEqual(Route.decrypt.subScreenTitle, "Encrypt or decrypt text")
        XCTAssertNil(Route.chat(peer: "x").subScreenTitle)
    }

    @MainActor
    func testRouterKeepsOneStackPerTab() {
        let router = Router()
        router.navigate(.passes)
        XCTAssertEqual(router.selectedTab, .home)
        XCTAssertEqual(router.path, [.passes])
        router.navigate(.setupSection(.hub))
        XCTAssertEqual(router.selectedTab, .setup)
        XCTAssertEqual(router.paths[.home], [.passes])
        router.back()
        XCTAssertEqual(router.path, [])
        router.openFromNotification("credentials")
        XCTAssertEqual(router.path, [], "only sos, messages and home are accepted from a notification")
        router.openFromNotification("sos")
        XCTAssertEqual(router.top, .sos)
    }
}
