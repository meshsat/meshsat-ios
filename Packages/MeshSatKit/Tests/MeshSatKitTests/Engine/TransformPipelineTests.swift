// TransformPipeline has no Android unit test; these pin the Kotlin behaviour: the spec parser,
// base64 and AES-GCM both ways, MSVQ-SC with an encoder and a codebook, the pass-through
// without an encoder, and validate()'s warnings and errors.
import MeshSatMsvqsc
import MeshSatWire
import XCTest

@testable import MeshSatEngine

final class TransformPipelineTests: XCTestCase {
    private struct FakeEncoder: MsvqscEncoding {
        func encode(_ text: String, maxStages: Int) -> [UInt8]? {
            text.isEmpty ? nil : MsvqscWire.pack(Array(repeating: 7, count: maxStages))
        }
    }

    func testParseList() throws {
        XCTAssertEqual(try TransformSpec.parseList(nil), [])
        XCTAssertEqual(try TransformSpec.parseList(" "), [])
        XCTAssertEqual(try TransformSpec.parseList("[]"), [])
        let specs = try TransformSpec.parseList("[{\"type\":\"encrypt\",\"params\":{\"key\":\"ab\"}},{\"type\":\"base64\"}]")
        XCTAssertEqual(specs, [TransformSpec(type: "encrypt", params: ["key": "ab"]), TransformSpec(type: "base64")])
        XCTAssertThrowsError(try TransformSpec.parseList("{\"type\":\"base64\"}"))
        XCTAssertThrowsError(try TransformSpec.parseList("[{\"params\":{}}]"))
        XCTAssertThrowsError(try TransformSpec.parseList("not json"))
    }

    func testBase64AndEncryptBothWays() throws {
        let key = AesGcmCrypto.generateKey()
        let chain = "[{\"type\":\"encrypt\",\"params\":{\"key\":\"\(key)\"}},{\"type\":\"base64\"}]"
        let p = TransformPipeline()
        let out = try p.applyEgress(Array("hello".utf8), transformsJson: chain)
        XCTAssertNotNil(Base64Std.decode(String(decoding: out, as: UTF8.self)))
        XCTAssertEqual(try p.applyIngress(out, transformsJson: chain), Array("hello".utf8))
        XCTAssertEqual(try p.applyEgress([1, 2], transformsJson: nil), [1, 2])
        XCTAssertThrowsError(try p.applyEgress([1], transformsJson: "[{\"type\":\"encrypt\"}]"))
        XCTAssertThrowsError(try p.applyIngress(Array("!!".utf8), transformsJson: "[{\"type\":\"base64\"}]"))
        XCTAssertEqual(try p.applyEgress([9], transformsJson: "[{\"type\":\"gzip\"}]"), [9])
    }

    func testMsvqscWithAndWithoutEncoder() throws {
        let p = TransformPipeline()
        let chain = "[{\"type\":\"msvqsc\",\"params\":{\"stages\":\"2\"}}]"
        XCTAssertEqual(try p.applyEgress(Array("hi".utf8), transformsJson: chain), Array("hi".utf8), "no encoder: passed through")
        p.msvqscEncoder = FakeEncoder()
        XCTAssertEqual(try p.applyEgress(Array("hi".utf8), transformsJson: chain), MsvqscWire.pack([7, 7]))
        XCTAssertEqual(try p.applyEgress(Array("hi".utf8), transformsJson: "[{\"type\":\"msvqsc\"}]"), MsvqscWire.pack([7, 7, 7]))
        XCTAssertEqual(
            try p.applyEgress(Array("hi".utf8), transformsJson: "[{\"type\":\"msvqsc\",\"params\":{\"stages\":\"auto\"}}]").count, 7)
        XCTAssertThrowsError(try p.applyEgress([], transformsJson: chain))
        XCTAssertThrowsError(try p.applyIngress(MsvqscWire.pack([7, 7]), transformsJson: chain), "no codebook")
        XCTAssertEqual(TransformPipeline.maxStages(["stages": " 5 "]), 5)
        XCTAssertEqual(TransformPipeline.maxStages(["stages": "x"]), 3)
    }

    func testValidate() {
        let ok = TransformPipeline.validate(transformsJson: nil, binaryCapable: false, maxPayload: 160)
        XCTAssertEqual(ok.warnings, [])
        XCTAssertEqual(ok.errors, [])
        let bad = TransformPipeline.validate(transformsJson: "[{\"type\":\"encrypt\"}]", binaryCapable: false, maxPayload: 160)
        XCTAssertEqual(
            bad.errors,
            [
                "encrypt transform requires a 'key' param",
                "Text-only transport (SMS) requires base64 as the final transform after encrypt/compress",
            ])
        let sms = TransformPipeline.validate(
            transformsJson: "[{\"type\":\"encrypt\",\"params\":{\"key\":\"k\"}},{\"type\":\"base64\"}]", binaryCapable: false,
            maxPayload: 160)
        XCTAssertEqual(sms.errors, [])
        XCTAssertEqual(sms.warnings, ["Transforms reduce usable capacity to ~92 bytes (of 160 max)"])
        let tiny = TransformPipeline.validate(
            transformsJson: "[{\"type\":\"encrypt\",\"params\":{\"key\":\"k\"}},{\"type\":\"base64\"}]", binaryCapable: false,
            maxPayload: 40)
        XCTAssertEqual(tiny.warnings, ["Transforms leave very little usable payload (~2 bytes of 40)"])
        let invalid = TransformPipeline.validate(transformsJson: "nope", binaryCapable: true, maxPayload: 0)
        XCTAssertEqual(invalid.errors.count, 1)
        XCTAssertTrue(invalid.errors[0].hasPrefix("Invalid transforms JSON"))
    }
}
