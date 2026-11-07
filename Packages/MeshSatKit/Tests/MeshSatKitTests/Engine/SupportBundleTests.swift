// Mirrors support/SupportBundleTest.kt (MESHSAT-1806, iOS MESHSAT-1810): the debug.zip of Setup >
// Help > Support and what it blanks. The zip is read back with a small reader here and, where the
// tool exists, checked with `unzip -t`.
import Foundation
import XCTest

@testable import MeshSatEngine

final class SupportBundleTests: XCTestCase {
    private func r(_ s: String) -> String { SupportRedactor.redact(s) }

    func testPhoneNumbersAreBlankedTimestampsAreNot() {
        XCTAssertEqual(r("SMS to +31612345678 queued"), "SMS to [phone] queued")
        XCTAssertEqual(r("from +31 6 12345678"), "from [phone]")
        XCTAssertEqual(r("call 0612345678 now"), "call [phone] now")
        // Unix seconds, milliseconds and a log time stay as they are.
        XCTAssertEqual(r("at 1762440000 and 1762440000123"), "at 1762440000 and 1762440000123")
        XCTAssertEqual(r("2026-11-06 15:40:12.345 notice MeshSat: ok"), "2026-11-06 15:40:12.345 notice MeshSat: ok")
        // A signal reading with a sign is no phone number.
        XCTAssertEqual(r("rssi +5 dBm"), "rssi +5 dBm")
    }

    func testImeisEmailsAndKeysAreBlanked() {
        XCTAssertEqual(r("imei 300258060512710 momsn 241"), "imei [imei] momsn 241")
        XCTAssertEqual(r("mail someone.else@example.org failed"), "mail [email] failed")
        XCTAssertEqual(r("password=hunter2 user=kit"), "password=[removed] user=kit")
        XCTAssertEqual(r(#"{"token": "abc.def"}"#), #"{"token": "[removed]"}"#)
        XCTAssertEqual(r("Authorization: Bearer eyJhbGciOi.x-y_z"), "Authorization: Bearer [removed]")
        let pem = "cert -----BEGIN PRIVATE KEY-----\nMIIBVQIBADAN\nBgkqhkiG9w0=\n-----END PRIVATE KEY----- done"
        XCTAssertEqual(r(pem), "cert [key removed] done")
    }

    func testMacAddressesKeepOnlyTheirLastByte() {
        XCTAssertEqual(r("node 48:CA:43:57:07:4D bonded"), "node XX:XX:XX:XX:XX:4D bonded")
        // A node id and a destination hash are not addresses.
        XCTAssertEqual(r("!8b04a69e d180c2083c4b9fecd0ff19812cb9b074"), "!8b04a69e d180c2083c4b9fecd0ff19812cb9b074")
    }

    func testTheZipHoldsEveryPartRedacted() throws {
        let parts = [
            SupportBundle.Part(name: "README.txt", text: "hello\n"),
            SupportBundle.Part(name: "logcat.txt", text: "SMS to +31612345678\n"),
        ]
        let bytes = SupportBundle.bytes(parts, nowMs: 1_762_440_000_000, zone: TimeZone(identifier: "UTC")!)
        let seen = try Self.readStoredZip(bytes)
        XCTAssertEqual(seen.map(\.name), ["README.txt", "logcat.txt"])
        XCTAssertEqual(seen[1].text, "SMS to [phone]\n")
        try Self.unzipTest(bytes)
    }

    func testARunawayPartKeepsItsNewestEnd() throws {
        let big = String(repeating: "a", count: SupportBundle.maxPartChars) + "LAST"
        let bytes = SupportBundle.bytes([SupportBundle.Part(name: "logcat.txt", text: big)], nowMs: 0)
        let text = try XCTUnwrap(Self.readStoredZip(bytes).first).text
        XCTAssertTrue(text.hasPrefix("[the first 4 characters were cut]"))
        XCTAssertTrue(text.hasSuffix("LAST"))
    }

    func testTheFileNameCarriesTheTimeAndTheMailBodyTheVersion() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(SupportBundle.fileName(nowMs: 1_793_976_000_000, zone: utc), "meshsat-debug-20261106-144000.zip")
        let about = SupportBundle.About(version: "0.3.0", build: "26", edition: "App Store edition", ios: "26.1", device: "iPhone17,3")
        let body = SupportBundle.mailBody("  It stopped.  ", about: about, attached: true)
        let expected =
            "It stopped.\n\n--\nMeshSat iOS 0.3.0 (26), App Store edition\niOS 26.1, iPhone17,3\n"
            + "A debug.zip with the app's logs is attached.\n"
        XCTAssertEqual(body, expected)
        XCTAssertFalse(SupportBundle.mailBody("x", about: about, attached: false).contains("debug.zip"))
        XCTAssertEqual(SupportBundle.subject(.problem, version: "0.3.0"), "MeshSat iOS 0.3.0: a problem")
    }

    func testAMailtoLinkEncodesSpacesAsPercent20AndKeepsNewLines() {
        XCTAssertEqual(
            SupportBundle.mailtoUri(
                address: "support@meshsat.net", subject: "MeshSat iOS 0.3.0: a problem", body: "It stopped.\n--\na&b=c"),
            "mailto:support@meshsat.net?subject=MeshSat%20iOS%200.3.0%3A%20a%20problem&body=It%20stopped.%0A--%0Aa%26b%3Dc")
    }

    func testCrc32IsTheZipOne() {
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum([]), 0)
    }

    // MARK: Reading the zip back

    private struct Entry {
        let name: String
        let text: String
    }

    /// Walks the local headers of a stored-only zip and checks each CRC.
    private static func readStoredZip(_ b: [UInt8]) throws -> [Entry] {
        func u16(_ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 }
        func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
        var out: [Entry] = []
        var at = 0
        while at + 30 <= b.count, u32(at) == 0x0403_4B50 {
            XCTAssertEqual(u16(at + 8), 0, "stored")
            let crc = u32(at + 14)
            let size = Int(u32(at + 18))
            let nameLen = u16(at + 26)
            let extra = u16(at + 28)
            let name = String(decoding: b[(at + 30)..<(at + 30 + nameLen)], as: UTF8.self)
            let dataAt = at + 30 + nameLen + extra
            let data = Array(b[dataAt..<(dataAt + size)])
            XCTAssertEqual(CRC32.checksum(data), crc, name)
            out.append(Entry(name: name, text: String(decoding: data, as: UTF8.self)))
            at = dataAt + size
        }
        XCTAssertFalse(out.isEmpty)
        return out
    }

    /// `unzip -t` on the bytes, when the tool is on this machine.
    private static func unzipTest(_ bytes: [UInt8]) throws {
        #if os(Linux) || os(macOS)
        let tool = ["/usr/bin/unzip", "/bin/unzip"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let tool else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("support-\(UUID().uuidString).zip")
        try Data(bytes).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["-tq", file.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "unzip -t")
        #endif
    }
}
