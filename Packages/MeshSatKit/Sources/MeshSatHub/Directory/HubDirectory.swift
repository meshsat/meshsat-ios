// Mirrors hub/directory/DirectoryEnvelope.kt and HubDirectory.kt: the Hub's signed tenant
// directory on the phone (HeMB-NG C9.5, MESHSAT-1643). The envelope is contract C7.2 (the Hub's
// internal/directory/envelope.go, the Bridge's internal/hubreporter/direnvelope.go, fixture
// docs/fixtures/v1/directory_v2.json); the apply rules are the Bridge's
// internal/directory/hubapply.go for a phone, which holds only what the Hub sent.
import Crypto
import Foundation

public enum DirectoryEnvelope {
    public static let version = 2
    public static let alg = "ES256"

    public static let format = "format"
    public static let unknownKey = "unknown_key"
    public static let badSignature = "bad_signature"

    /// An envelope or a key this phone does not take, and why (`reason` is one of the constants).
    public struct Refused: Error, Equatable, Sendable, CustomStringConvertible {
        public let reason: String
        public let message: String
        public init(_ reason: String, _ message: String) {
            self.reason = reason
            self.message = message
        }
        public var description: String { "\(reason): \(message)" }
    }

    /// A directory key's id: SHA-256 of its PKIX DER, hex.
    public static func keyId(_ pkix: [UInt8]) -> String {
        SHA256.hash(data: pkix).map { String(format: "%02x", $0) }.joined()
    }

    /// The ECDSA P-256 key in `pkix`; any other key or curve is refused.
    public static func p256(_ pkix: [UInt8]) throws -> P256.Signing.PublicKey {
        do {
            return try P256.Signing.PublicKey(derRepresentation: pkix)
        } catch {
            throw Refused(unknownKey, "not an ECDSA P-256 PKIX key")
        }
    }

    /// Verify `env` under `trusted` (PKIX DER) and return its payload bytes. Nothing of the
    /// payload is read before the signature verifies.
    public static func open(_ env: [String: Any], trusted: [UInt8]) throws -> [UInt8] {
        let keyId = env["key_id"] as? String ?? ""
        guard (env["v"] as? Int) == version, (env["alg"] as? String) == alg, let payload = bytes(env, "payload"),
            let sig = bytes(env, "sig"), !sig.isEmpty
        else { throw Refused(format, "not a v2 ES256 envelope") }
        guard keyId == Self.keyId(trusted) else { throw Refused(unknownKey, "signed by key \(keyId), not the key this phone trusts") }
        let key = try p256(trusted)
        guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: sig),
            key.isValidSignature(signature, for: payload)
        else { throw Refused(badSignature, "signature does not verify") }
        return payload
    }

    /// A Go []byte field: standard base64. Nil when it is missing or not base64.
    static func bytes(_ o: [String: Any], _ name: String) -> [UInt8]? {
        guard let s = o[name] as? String else { return nil }
        if s.isEmpty { return [] }
        return Data(base64Encoded: s).map { Array($0) }
    }

    static func object(_ bytes: [UInt8]) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any]
    }
}

/// One address of a directory contact.
public struct DirAddress: Codable, Equatable, Sendable {
    public var kind: String
    public var value: String
    public var label = ""
    public var primaryRank = 0
    enum CodingKeys: String, CodingKey {
        case kind, value, label
        case primaryRank = "primary_rank"
    }
}

/// One contact of the tenant's directory, as the Hub signed it.
public struct DirContact: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var org = ""
    public var role = ""
    public var team = ""
    public var addresses: [DirAddress] = []
    enum CodingKeys: String, CodingKey {
        case id, org, role, team, addresses
        case displayName = "display_name"
    }
}

/// One group of the tenant's directory; `memberIds` are contacts of the same snapshot.
public struct DirGroup: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
    public var memberIds: [String] = []
    enum CodingKeys: String, CodingKey {
        case id, name, kind
        case memberIds = "member_ids"
    }
}

/// A row of a snapshot that was not taken, and why (the Bridge's HubSkip).
public struct DirSkip: Codable, Equatable, Sendable {
    public var kind: String
    public var id: String
    public var reason: String
    public var detail = ""
}

/// What the phone holds of the Hub's directory: the key it trusts, the snapshot it applied last
/// and the version of the last rotation it followed. A snapshot and a rotation share the
/// tenant's version sequence but are counted apart (contract C7.6). The JSON names are the
/// Android file's.
public struct DirectoryState: Codable, Equatable, Sendable {
    /// The trusted key, PKIX DER in base64; empty while none is pinned.
    public var pinnedKey = ""
    /// Where the key came from: "bundle", "https" or "rotation".
    public var pinSource = ""
    public var tenantId = ""
    public var version: Int64 = 0
    public var keyVersion: Int64 = 0
    public var contacts: [DirContact] = []
    public var groups: [DirGroup] = []
    public var skipped: [DirSkip] = []
    public var appliedAt: Int64 = 0
    public var checkedAt: Int64 = 0
    public var refusedReason = ""
    public var refusedDetail = ""
    public var refusedAt: Int64 = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case version, contacts, groups, skipped
        case pinnedKey = "pinned_key"
        case pinSource = "pin_source"
        case tenantId = "tenant_id"
        case keyVersion = "key_version"
        case appliedAt = "applied_at"
        case checkedAt = "checked_at"
        case refusedReason = "refused_reason"
        case refusedDetail = "refused_detail"
        case refusedAt = "refused_at"
    }

    public var pinnedPkix: [UInt8]? { pinnedKey.isEmpty ? nil : Data(base64Encoded: pinnedKey).map { Array($0) } }
    public var keyId: String { pinnedPkix.map { DirectoryEnvelope.keyId($0) } ?? "" }
}

/// The Bridge's apply rules for a phone: a snapshot replaces the whole set. Pure, so the rules
/// have tests.
public enum DirectoryApply {
    public static let otherTenant = "other_tenant"
    public static let notNewer = "not_newer"
    public static let notARotation = "not_a_rotation"
    public static let notASnapshot = "not_a_snapshot"
    public static let skipUnknownKind = "unknown_kind"
    public static let skipAddressTaken = "address_taken"
    public static let skipNoName = "no_display_name"
    public static let skipUnknownMember = "unknown_member"

    /// The Bridge's address kinds (internal/directory/store.go AllKinds).
    public static let addressKinds: Set<String> = [
        "SMS", "MESHTASTIC", "APRS", "IRIDIUM_SBD", "IRIDIUM_IMT", "CELLULAR", "TAK", "RETICULUM",
        "ZIGBEE", "BLE", "WEBHOOK", "EMAIL", "MQTT", "TETRA", "CELL",
    ]
    public static let groupKinds: Set<String> = ["TEAM", "ROLE", "LIST", "MLS_GROUP"]

    /// The state after one record, snapshot or answer; `applied` false carries the refusal.
    public struct Result: Equatable, Sendable {
        public var state: DirectoryState
        public var applied: Bool
        public var reason = ""
        public var detail = ""
    }

    static func refuse(_ s: DirectoryState, _ now: Int64, _ reason: String, _ detail: String) -> Result {
        var next = s
        next.refusedReason = reason
        next.refusedDetail = detail
        next.refusedAt = now
        return Result(state: next, applied: false, reason: reason, detail: detail)
    }

    // checkHubVersion: the tenant must be named and the one this phone follows, the version above held.
    static func check(_ s: DirectoryState, _ what: String, _ tenant: String, _ version: Int64, _ held: Int64) -> (String, String)? {
        if tenant.isEmpty { return (otherTenant, "the \(what) names no tenant") }
        if !s.tenantId.isEmpty && s.tenantId != tenant {
            return (otherTenant, "this phone follows tenant \"\(s.tenantId)\", the \(what) is \"\(tenant)\"")
        }
        if version <= held { return (notNewer, "\(what) version \(version), this phone holds \(held)") }
        return nil
    }

    static func openPayload(_ s: DirectoryState, _ env: [String: Any], _ what: String) throws -> [String: Any] {
        guard let pinned = s.pinnedPkix else { throw DirectoryEnvelope.Refused(DirectoryEnvelope.unknownKey, "no directory key pinned") }
        guard let p = DirectoryEnvelope.object(try DirectoryEnvelope.open(env, trusted: pinned)) else {
            throw DirectoryEnvelope.Refused(DirectoryEnvelope.format, "the \(what) is not JSON")
        }
        return p
    }

    static func int64(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? 0 }

    /// A rotation record: signed by the key this phone trusts, naming a P-256 key that hashes to
    /// its id, for this phone's tenant, above the last rotation followed. The new key is pinned.
    public static func rotation(_ s: DirectoryState, _ env: [String: Any], now: Int64) -> Result {
        let rec: [String: Any]
        do {
            rec = try openPayload(s, env, "record")
        } catch let e as DirectoryEnvelope.Refused {
            return refuse(s, now, e.reason, e.message)
        } catch {
            return refuse(s, now, DirectoryEnvelope.format, "\(error)")
        }
        let type = rec["type"] as? String ?? ""
        guard type == "rotation" else { return refuse(s, now, notARotation, "the payload is a \"\(type)\", not a rotation") }
        guard let newKey = DirectoryEnvelope.bytes(rec, "new_key_pkix"), !newKey.isEmpty,
            DirectoryEnvelope.keyId(newKey) == rec["new_key_id"] as? String ?? ""
        else { return refuse(s, now, DirectoryEnvelope.unknownKey, "the new key does not hash to its id") }
        do {
            _ = try DirectoryEnvelope.p256(newKey)
        } catch let e as DirectoryEnvelope.Refused {
            return refuse(s, now, e.reason, "new key: \(e.message)")
        } catch {
            return refuse(s, now, DirectoryEnvelope.unknownKey, "new key: \(error)")
        }
        let tenant = rec["tenant_id"] as? String ?? ""
        let version = int64(rec["version"])
        if let (r, d) = check(s, "rotation", tenant, version, s.keyVersion) { return refuse(s, now, r, d) }
        var next = s
        next.pinnedKey = Data(newKey).base64EncodedString()
        next.pinSource = "rotation"
        next.tenantId = tenant
        next.keyVersion = version
        next.refusedReason = ""
        next.refusedDetail = ""
        next.refusedAt = 0
        return Result(state: next, applied: true)
    }

    /// A full snapshot, verified under the pinned key, replaces what the phone holds.
    public static func snapshot(_ s: DirectoryState, _ env: [String: Any], now: Int64) -> Result {
        let p: [String: Any]
        do {
            p = try openPayload(s, env, "snapshot")
        } catch let e as DirectoryEnvelope.Refused {
            return refuse(s, now, e.reason, e.message)
        } catch {
            return refuse(s, now, DirectoryEnvelope.format, "\(error)")
        }
        let type = p["type"] as? String ?? ""
        guard type.isEmpty || type == "snapshot" else { return refuse(s, now, notASnapshot, "the payload is a \"\(type)\"") }
        let tenant = p["tenant_id"] as? String ?? ""
        let version = int64(p["version"])
        if let (r, d) = check(s, "snapshot", tenant, version, s.version) { return refuse(s, now, r, d) }

        var skipped: [DirSkip] = []
        let (contacts, ids) = readContacts(p["contacts"] as? [[String: Any]] ?? [], &skipped)
        let groups = readGroups(p["groups"] as? [[String: Any]] ?? [], ids, &skipped)
        var next = s
        next.tenantId = tenant
        next.version = version
        next.contacts = contacts.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
        next.groups = groups.sorted { $0.name.lowercased() < $1.name.lowercased() }
        next.skipped = skipped
        next.appliedAt = now
        next.refusedReason = ""
        next.refusedDetail = ""
        next.refusedAt = 0
        return Result(state: next, applied: true)
    }

    static func readContacts(_ rows: [[String: Any]], _ skipped: inout [DirSkip]) -> ([DirContact], Set<String>) {
        var contacts: [DirContact] = []
        var ids = Set<String>()
        var taken = Set<String>()
        for c in rows {
            let id = c["id"] as? String ?? ""
            if id.isEmpty || ids.contains(id) { continue }
            let name = c["display_name"] as? String ?? ""
            if name.isEmpty {
                skipped.append(DirSkip(kind: "contact", id: id, reason: skipNoName))
                continue
            }
            ids.insert(id)
            var addresses: [DirAddress] = []
            for a in c["addresses"] as? [[String: Any]] ?? [] {
                let kind = a["kind"] as? String ?? ""
                let value = a["value"] as? String ?? ""
                let aid = a["id"] as? String ?? ""
                if !addressKinds.contains(kind) {
                    skipped.append(DirSkip(kind: "address", id: aid, reason: skipUnknownKind, detail: kind))
                } else if value.isEmpty {
                    skipped.append(DirSkip(kind: "address", id: aid, reason: skipUnknownKind, detail: "no value"))
                } else if !taken.insert(kind + "\u{0}" + value).inserted {
                    skipped.append(DirSkip(kind: "address", id: aid, reason: skipAddressTaken, detail: "\(kind) \(value)"))
                } else {
                    addresses.append(
                        DirAddress(kind: kind, value: value, label: a["label"] as? String ?? "", primaryRank: Int(int64(a["primary_rank"])))
                    )
                }
            }
            contacts.append(
                DirContact(
                    id: id, displayName: name, org: c["org"] as? String ?? "", role: c["role"] as? String ?? "",
                    team: c["team"] as? String ?? "",
                    addresses: addresses.enumerated().sorted {
                        ($0.element.primaryRank, $0.offset) < ($1.element.primaryRank, $1.offset)
                    }.map(\.element)))
        }
        return (contacts, ids)
    }

    static func readGroups(_ rows: [[String: Any]], _ ids: Set<String>, _ skipped: inout [DirSkip]) -> [DirGroup] {
        var groups: [DirGroup] = []
        for g in rows {
            let id = g["id"] as? String ?? ""
            if id.isEmpty || groups.contains(where: { $0.id == id }) { continue }
            var kind = (g["kind"] as? String ?? "").uppercased()
            if kind.isEmpty { kind = "LIST" }
            guard groupKinds.contains(kind) else {
                skipped.append(DirSkip(kind: "group", id: id, reason: skipUnknownKind, detail: g["kind"] as? String ?? ""))
                continue
            }
            var members: [String] = []
            for m in g["member_ids"] as? [String] ?? [] {
                if ids.contains(m) {
                    if !members.contains(m) { members.append(m) }
                } else {
                    skipped.append(
                        DirSkip(kind: "member", id: "\(id)/\(m)", reason: skipUnknownMember, detail: "not a contact of this snapshot"))
                }
            }
            let name = g["name"] as? String ?? ""
            groups.append(DirGroup(id: id, name: name.isEmpty ? id : name, kind: kind, memberIds: members))
        }
        return groups
    }

    /// The answer of GET /api/relay/directory: the rotation records in order, each moving the
    /// pin, then the snapshot under the key they lead to. The first refusal stops it; what was
    /// applied before it stays.
    public static func answer(_ s: DirectoryState, _ answer: [String: Any], now: Int64) -> Result {
        var state = s
        var applied = false
        for env in answer["rotations"] as? [[String: Any]] ?? [] {
            var r = rotation(state, env, now: now)
            if !r.applied {
                r.applied = applied
                return r
            }
            state = r.state
            applied = true
        }
        guard let snap = answer["snapshot"] as? [String: Any] else { return Result(state: state, applied: applied) }
        var r = snapshot(state, snap, now: now)
        if !r.applied { r.applied = applied }
        return r
    }
}
