import MeshSatHemb
import XCTest

final class GfFieldTests: XCTestCase {
    func testHembFieldGeneratorAndInverse() {
        // 0x03 generates the multiplicative group of GF(256) under 0x11B: the first entries of
        // the exp table are 1, 3, 5, 15, 17, 51, 85, 255 (the classic AES log table).
        XCTAssertEqual(Array(HembGf256.exp[0..<8]), [1, 3, 5, 15, 17, 51, 85, 255])
        for a in 1...255 {
            let x = UInt8(a)
            XCTAssertEqual(HembGf256.mul(x, HembGf256.inv(x)), 1, "inverse of \(a)")
            XCTAssertEqual(HembGf256.div(x, x), 1)
        }
        XCTAssertEqual(HembGf256.mul(0x57, 0x83), 0xC1)  // the FIPS-197 worked example
        XCTAssertEqual(HembGf256.inv(0), 0)
    }

    func testReedSolomonFieldGeneratorAndInverse() {
        XCTAssertEqual(Array(GaloisField256.exp[0..<9]), [1, 2, 4, 8, 16, 32, 64, 128, 29])
        for a in 1...255 {
            let x = UInt8(a)
            XCTAssertEqual(GaloisField256.mul(x, GaloisField256.inv(x)), 1, "inverse of \(a)")
        }
        XCTAssertEqual(GaloisField256.inv(0), 0)
    }

    func testTheTwoFieldsDiffer() {
        // Mixing the tables is the bug the Kotlin comments warn about; keep them distinguishable.
        XCTAssertNotEqual(HembGf256.exp, GaloisField256.exp)
        XCTAssertEqual(MeshSatHemb.frameMagic, Array("HM".utf8))
    }
}
