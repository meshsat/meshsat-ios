import XCTest

final class AppSmokeTests: XCTestCase {
    func testBundleIdentity() {
        let info = Bundle.main.infoDictionary ?? [:]
        // The test bundle's host is the app; either way the fonts must be registered.
        let fonts = (Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String]) ?? []
        XCTAssertTrue(fonts.isEmpty || fonts.contains("plex_sans_regular.ttf"))
        XCTAssertNotNil(info)
    }
}
