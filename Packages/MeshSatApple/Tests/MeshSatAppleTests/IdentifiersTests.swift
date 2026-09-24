import MeshSatBLE
import MeshSatPlatform
import MeshSatStore
import XCTest

final class IdentifiersTests: XCTestCase {
    func testIdentifiersAreStable() {
        XCTAssertEqual(MeshSatBLE.centralRestoreIdentifier, "net.meshsat.ios.central")
        XCTAssertEqual(MeshSatBLE.meshtasticService.uuidString.lowercased(), "6ba1b218-15a8-461f-9fa8-5dcae273eafd")
        XCTAssertEqual(MeshSatStore.settingsSuite, "net.meshsat.ios")
        XCTAssertEqual(MeshSatPlatform.hubSyncTaskIdentifier, "net.meshsat.ios.hubsync")
        XCTAssertEqual(MeshSatPlatform.refreshTaskIdentifier, "net.meshsat.ios.refresh")
    }
}
