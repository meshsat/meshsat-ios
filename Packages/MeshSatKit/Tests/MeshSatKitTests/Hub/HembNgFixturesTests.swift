// The HeMB-NG fixture release the app tests against (contract C12, MESHSAT-1584): the copy is the
// release fixtures.lock names. Mirrors HembNgFixturesTest.kt; iOS sends no SMS, so the SMS vectors
// have no consumer here.
import Crypto
import Foundation
import XCTest

final class HembNgFixturesTests: XCTestCase {
    private func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testTheCopyIsTheLockedRelease() throws {
        let lockURL = try XCTUnwrap(Bundle.module.url(forResource: "fixtures", withExtension: "lock", subdirectory: "Fixtures/hemb-ng"))
        let dir = lockURL.deletingLastPathComponent().appendingPathComponent("v1")
        var lock: [String: String] = [:]
        for line in try String(contentsOf: lockURL, encoding: .utf8).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { lock[String(parts[0])] = String(parts[1]) }
        }
        let sums = try Data(contentsOf: dir.appendingPathComponent("SHA256SUMS"))
        XCTAssertEqual(hex(sums), lock["sha256"], "SHA256SUMS against fixtures.lock")
        var listed: Set<String> = ["SHA256SUMS"]
        for line in String(decoding: sums, as: UTF8.self).split(separator: "\n") {
            let parts = line.components(separatedBy: "  ")
            XCTAssertEqual(parts.count, 2, "bad SHA256SUMS line \(line)")
            guard parts.count == 2, !parts[1].contains("/") else { continue }
            let data = try Data(contentsOf: dir.appendingPathComponent(parts[1]))
            XCTAssertEqual(hex(data), parts[0], "\(parts[1]) differs from the release")
            listed.insert(parts[1])
        }
        let present = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(Set(present).subtracting(listed), [], "not part of the release")
        let release = try String(contentsOf: dir.appendingPathComponent("RELEASE"), encoding: .utf8)
        XCTAssertEqual(release.trimmingCharacters(in: .whitespacesAndNewlines), lock["tag"])
    }
}
