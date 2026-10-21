// Mirrors engine/TransformSpec.kt and engine/TransformPipeline.kt (a port of the Bridge's
// internal/engine/transform.go): ordered transforms on a payload, base64 for text-only
// channels, AES-256-GCM with a "key" or a "key_ref" resolved through `keyResolver`, MSVQ-SC
// with an encoder for sending and the codebook for receiving, and SMAZ2 with the "dict"
// param's table, byte for byte as the Bridge ("smaz2", and "smaz2g" with its mode byte,
// HeMB-NG S3-1). An encrypt or decrypt that fails is a TransformError, never a guess.
// [MESHSAT-1624]
import Foundation
import MeshSatMsvqsc
import MeshSatWire

public struct TransformSpec: Sendable, Equatable {
    public var type: String
    public var params: [String: String]
    public init(type: String, params: [String: String] = [:]) {
        self.type = type
        self.params = params
    }

    public enum ParseError: Error, Equatable { case notAList, badItem(Int) }

    /// A JSON array of {"type": ..., "params": {...}}; empty for nil, blank or "[]".
    public static func parseList(_ json: String?) throws -> [TransformSpec] {
        guard let json, !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, json != "[]" else { return [] }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)), let items = parsed as? [Any] else {
            throw ParseError.notAList
        }
        return try items.enumerated().map { i, item in
            guard let obj = item as? [String: Any], let type = obj["type"] as? String else { throw ParseError.badItem(i) }
            var params: [String: String] = [:]
            if let p = obj["params"] as? [String: Any] {
                for (key, value) in p { params[key] = value as? String ?? "\(value)" }
            }
            return TransformSpec(type: type, params: params)
        }
    }
}

public struct TransformError: Error, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public final class TransformPipeline: @unchecked Sendable {
    /// 12-byte nonce and 16-byte tag.
    public static let aesGcmOverhead = 28
    private let lock = NSLock()
    private var encoderValue: (any MsvqscEncoding)?
    private var codebookValue: MsvqscCodebook?
    private var keyResolverValue: (@Sendable (String) -> String?)?
    private var fixedNonceValue: [UInt8]?

    public init() {}

    /// Resolves an encrypt step's "key_ref" ("channel:address", e.g. "iridium:shared") to its
    /// 64-hex AES key, nil when there is none: the step then fails, it never runs without a key.
    public var keyResolver: (@Sendable (String) -> String?)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return keyResolverValue
        }
        set {
            lock.lock()
            keyResolverValue = newValue
            lock.unlock()
        }
    }

    /// A fixed nonce for the encrypt step, set only by the shared test vectors.
    package var fixedNonce: [UInt8]? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return fixedNonceValue
        }
        set {
            lock.lock()
            fixedNonceValue = newValue
            lock.unlock()
        }
    }

    public var msvqscEncoder: (any MsvqscEncoding)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return encoderValue
        }
        set {
            lock.lock()
            encoderValue = newValue
            lock.unlock()
        }
    }

    public var msvqscCodebook: MsvqscCodebook? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return codebookValue
        }
        set {
            lock.lock()
            codebookValue = newValue
            lock.unlock()
        }
    }

    /// Sending: the transforms in order (compress, encrypt, base64).
    public func applyEgress(_ data: [UInt8], transformsJson: String?) throws -> [UInt8] {
        try applyEgress(data, try TransformSpec.parseList(transformsJson))
    }

    /// `applyEgress` on a parsed chain.
    public func applyEgress(_ data: [UInt8], _ transforms: [TransformSpec]) throws -> [UInt8] {
        var result = data
        for t in transforms { result = try apply(t, result) }
        return result
    }

    /// Receiving: the transforms in reverse (decode, decrypt, decompress).
    public func applyIngress(_ data: [UInt8], transformsJson: String?) throws -> [UInt8] {
        try applyIngress(data, try TransformSpec.parseList(transformsJson))
    }

    /// `applyIngress` on a parsed chain.
    public func applyIngress(_ data: [UInt8], _ transforms: [TransformSpec]) throws -> [UInt8] {
        var result = data
        for t in transforms.reversed() { result = try reverse(t, result) }
        return result
    }

    private static func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func encryptKey(_ t: TransformSpec) throws -> String {
        if let key = t.params["key"], !Self.isBlank(key) { return key }
        guard let ref = t.params["key_ref"] else { throw TransformError("encrypt transform requires a 'key' or 'key_ref' param") }
        guard let key = keyResolver?(ref), !Self.isBlank(key) else { throw TransformError("encrypt transform: no key for '\(ref)'") }
        return key
    }

    private func apply(_ t: TransformSpec, _ data: [UInt8]) throws -> [UInt8] {
        switch t.type {
        case "base64": return Array(Base64Std.encode(data).utf8)
        case "encrypt":
            let key = try encryptKey(t)
            do {
                return try AesGcmCrypto.encrypt(data, hexKey: key, fixedNonce: fixedNonce)
            } catch {
                throw TransformError("encrypt: \(type(of: error))")
            }
        case "smaz2": return Smaz2Bytes.compress(data, dict: Smaz2Dict.of(t.params["dict"]))
        case "smaz2g": return Smaz2g.encode(data, dict: Smaz2Dict.of(t.params["dict"]))
        case "msvqsc":
            guard let encoder = msvqscEncoder else { return data }  // no encoder: passed through, as Android
            guard let wire = encoder.encode(String(decoding: data, as: UTF8.self), maxStages: Self.maxStages(t.params)) else {
                throw TransformError("msvqsc encode failed")
            }
            return wire
        default: return data
        }
    }

    private func reverse(_ t: TransformSpec, _ data: [UInt8]) throws -> [UInt8] {
        switch t.type {
        case "base64":
            guard let decoded = Base64Std.decode(String(decoding: data, as: UTF8.self)) else {
                throw TransformError("base64 decode failed")
            }
            return decoded
        case "encrypt":
            let key = try encryptKey(t)
            do {
                return try AesGcmCrypto.decrypt(data, hexKey: key)
            } catch {
                // A wrong key, a changed tag or ciphertext, a cut message: never a guess.
                throw TransformError("decrypt: \(type(of: error))")
            }
        case "smaz2", "smaz2g":
            let dict = Smaz2Dict.of(t.params["dict"])
            do {
                if t.type == "smaz2" { return try Smaz2Bytes.decompress(data, dict: dict) }
                return try Smaz2g.decode(data, dict: dict)
            } catch let e as Smaz2Error {
                throw TransformError(e.description)
            }
        case "msvqsc":
            guard let codebook = msvqscCodebook else { throw TransformError("msvqsc: codebook not available for decode") }
            return Array(try codebook.decode(data).utf8)
        default: return data
        }
    }

    static func maxStages(_ params: [String: String]) -> Int {
        guard let s = params["stages"]?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s != "auto" else { return 3 }
        return Int(s) ?? 3
    }

    /// A chain against a channel: warnings and errors (errors mean an invalid chain).
    public static func validate(transformsJson: String?, binaryCapable: Bool, maxPayload: Int) -> (warnings: [String], errors: [String]) {
        let transforms: [TransformSpec]
        do {
            transforms = try TransformSpec.parseList(transformsJson)
        } catch {
            return ([], ["Invalid transforms JSON: \(error)"])
        }
        if transforms.isEmpty { return ([], []) }
        var warnings: [String] = []
        var errors: [String] = []
        var hasBinaryOutput = false
        var endsWithBase64 = false
        var hasBase64 = false
        for t in transforms {
            switch t.type {
            case "encrypt":
                hasBinaryOutput = true
                endsWithBase64 = false
                if isBlank(t.params["key"] ?? ""), isBlank(t.params["key_ref"] ?? "") {
                    errors.append("encrypt transform requires a 'key' or 'key_ref' param")
                }
            case "msvqsc", "smaz2", "smaz2g":
                hasBinaryOutput = true
                endsWithBase64 = false
            case "base64":
                hasBinaryOutput = false
                endsWithBase64 = true
                hasBase64 = true
            default: break
            }
        }
        if !binaryCapable, hasBinaryOutput, !endsWithBase64 {
            errors.append("Text-only transport (SMS) requires base64 as the final transform after encrypt/compress")
        }
        if maxPayload > 0 {
            var usable = maxPayload
            for t in transforms.reversed() {
                switch t.type {
                case "base64": usable = usable * 3 / 4
                case "encrypt": usable -= aesGcmOverhead
                default: break
                }
            }
            if usable < 20 {
                warnings.append("Transforms leave very little usable payload (~\(usable) bytes of \(maxPayload))")
            } else if hasBase64, Double(usable) / Double(maxPayload) < 0.6 {
                warnings.append("Transforms reduce usable capacity to ~\(usable) bytes (of \(maxPayload) max)")
            }
        }
        return (warnings, errors)
    }
}
