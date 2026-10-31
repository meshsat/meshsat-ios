import MeshSatFec
import XCTest

final class GfFieldTests: XCTestCase {
    func testReedSolomonFieldGeneratorAndInverse() {
        XCTAssertEqual(Array(GaloisField256.exp[0..<9]), [1, 2, 4, 8, 16, 32, 64, 128, 29])
        for a in 1...255 {
            let x = UInt8(a)
            XCTAssertEqual(GaloisField256.mul(x, GaloisField256.inv(x)), 1, "inverse of \(a)")
        }
        XCTAssertEqual(GaloisField256.inv(0), 0)
    }
}
