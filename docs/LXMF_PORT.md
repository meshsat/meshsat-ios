# LXMF on MeshSat iOS: the port and its tranches

MeshSat iOS speaks the same upstream-compatible Reticulum and LXMF as the Bridge (Go,
`meshsat/internal/reticulum`, `msgpack`, `rns`, `lxmf`) and MeshSat Android (Kotlin, `rns/`, `lxmf/`,
ported from the Bridge on 13 Oct 2026). Android is the reference for the shape; the Bridge is the
reference for the bytes. The contract between the three and the Hub is the Reticulum/LXMF note of
13 Oct 2026 in the project's design records (MESHSAT-1548, 1553, 1555) and, for the Hub's side,
`meshsat-hub/docs/reticulum-lxmf.md`; this port is the iOS half of MESHSAT-1735.

Everything here lives in `Packages/MeshSatKit`, builds and tests on Linux, and has no Apple dependency.
The older `MeshSatReticulum` module is NOT this format (its packet omits the context byte unless the
context flag is set, its announce reads a 10-byte ratchet id, it has its own link handshake); it stays
for the MeshSat-private traffic (`meshsat.node`, HeMB, time sync, the Hub relay), exactly as Android keeps
`reticulum/` beside `rns/`.

## Tranche 1 (this one): the wire, pure Swift, no transport, no UI

Two targets. `MeshSatRns` holds the Reticulum primitives LXMF stands on, so the node that follows never
has to import LXMF; `MeshSatLXMF` holds the message.

| Swift file (`Sources/`) | Mirrors (Android) | Mirrors (Bridge, Go) | What |
|---|---|---|---|
| `MeshSatRns/Rns.swift` | `rns/Wire.kt` (`object Rns`) | `internal/reticulum/constants.go`, `identity.go` hashes | MTU 500, MDU 464, ENCRYPTED_MDU 383, link MDU 431, flag and context bytes, name/identity/destination/plain hashes, the path request destination |
| `MeshSatRns/Header.swift` | `rns/Wire.kt` (`class Header`) | `internal/reticulum/packet.go` | HEADER_1/HEADER_2 pack and unpack (always a context byte; hops >= 128 and empty data refused), the hashable part, packet hash, the transport rewrite and its reverse |
| `MeshSatRns/Msgpack.swift` | `rns/Msgpack.kt` | `internal/msgpack/msgpack.go` | A codec byte-identical to `RNS.vendor.umsgpack` for the shapes LXMF uses (minimal ints, float64 only, str/bin, insertion-ordered maps, ext kept raw) |
| `MeshSatRns/RnsIdentity.swift` | `rns/RnsIdentity.kt` | `internal/reticulum/identity.go`, `encrypt.go` | X25519 + Ed25519 identity: private bytes in `Identity.from_bytes` order, the 64-byte public key, identity hash, `destHash(name)`, sign/verify, single-packet encrypt/decrypt with ratchets, `fromRouting` (the app's routing identity, same keys, same hashes) |
| `MeshSatRns/Token.swift` | `rns/Wire.kt` (`class Token`) | `internal/reticulum/token.go` | `RNS.Cryptography.Token`: iv, AES-CBC, HMAC-SHA256; 64-byte (AES-256) and 32-byte (AES-128) keys |
| `MeshSatRns/Announce.swift` | `rns/Announce.kt` | `internal/reticulum/announce.go` | The announce payload with the optional 32-byte ratchet, the signed body, verify, create, the originator's and a transport's packet, the emission time in the random hash |
| `MeshSatLXMF/LxMessage.swift` | `lxmf/LxMessage.kt` | `internal/lxmf/message.go` | `pack` (hash, stamp, sign, packed form), `unpack` (re-hash of the re-encoding, signature when the source is known, stamp kept), `contentSize`, the limits 287 / 319 / 112, the field numbers, the packet-or-resource decision |
| `MeshSatLXMF/LxMid.swift` | `lxmf/LxMid.kt` | `internal/lxmf/mid.go` | The HeMB-NG mid in FIELD_CUSTOM_TYPE 0xFB / FIELD_CUSTOM_DATA 0xFC: `fields`, `withMid` (never over another custom type), `midOf`, UUID text both ways, a new UUIDv7 |
| `MeshSatLXMF/LxFields.swift` | (none yet on Android) | `internal/lxmf/fields.go` | FIELD_IMAGE 0x06 `["webp", bytes]` and FIELD_AUDIO 0x07 `[mode, bytes]`: `attachmentsOf`, `withAttachments`, `withoutAttachments`, the audio mode names, content types, the 64 KB cap |
| `MeshSatLXMF/LxmfAppData.swift` | `lxmf/LxmfAppData.kt` | `internal/lxmf/appdata.go` | The `lxmf.delivery` announce app data `[name, stamp cost, [SF]]`, both ways, and the pre-0.5.0 raw name |
| `MeshSatLXMF/LxStamper.swift` | `lxmf/LxStamper.kt` | `internal/lxmf/stamper.go` | The workblock (3000 HKDF rounds; 1000 for a propagation node), stamp value and validity, a cancellable multi-core search |

Two lines changed outside the new targets: `MeshSatReticulum/AesCbc.swift` also takes a 16-byte key (the
Token's AES-128 mode) and `MeshSatCrypto/Identity.swift` exposes its raw private seeds for `fromRouting`.

### Vectors and proof

`Tests/MeshSatKitTests/Fixtures/lxmf/` (its README names the sources):

- `golden.properties`, a verbatim copy of Android's, written by Python RNS 1.5.5 and LXMF 1.2.0 themselves:
  tokens, HKDF, an identity and its packets, packet hashes in both header forms, three announces (plain,
  ratcheted, rebroadcast as a path response) and a forged one, a Python-packed message, one with Sideband
  style fields and a stamp at cost 8, announce app data. `RnsGoldenTests`, `MsgpackTests` and
  `LxmfGoldenTests` read them as Android's `GoldenVectorTest` and `LxmfGoldenTest` do.
- `go-vectors.properties`, written by the Bridge's Go packages (`internal/lxmf` at `8c2f6ede`) for the same
  keys with fixed timestamps, and validated by Python LXMF 1.2.1 before being copied here: the Python message
  repacked by Go (byte for byte the Python bytes), a message carrying a mid, a WebP image and a Codec2 note,
  the same with a Go stamp at cost 8, Go's umsgpack golden value, the attachment maps of `fields_test.go`.
  `LxmfGoInteropTests` packs the same inputs in Swift and asserts Go's bytes, hashes, signatures, content
  sizes, workblock digest and stamp value, and unpacks the Go fixtures (signature valid, mid and both
  attachments read, stamp kept). `LxMidTests` reads the HeMB-NG fixture `lxmf_mid_field.json` both ways.

Ed25519 is deterministic, so a Swift pack with Python's keys and timestamp equals Python's and Go's bytes;
the same message packed by the three implementations hashes to one id.

### Facts worth knowing

- LXMF 1.2.x's single-packet content limit is 287 (`ENCRYPTED_PACKET_MDU = RNS.Packet.ENCRYPTED_MDU`);
  1.1.0 allowed 295. The Bridge's `PacketMaxContent` still says 295 while its interop pin moved to 1.2.1
  (MESHSAT-1714); iOS and Android say 287. The wire is the same either way; only the sender's
  opportunistic-or-direct choice differs. The link packet limit is 319 on all three, and above it a direct
  message travels as a resource; a router accepts a resource up to 1000 kB (Android, upstream) or 1 MiB
  (the Bridge).
- Python's `content_size` subtracts a bin16 overhead, so a content under 256 bytes counts one byte less
  than its length; the mid costs 36 bytes of the budget (252 content bytes fill a packet, 283 a link packet).
- The phone announces no `SF_COMPRESSION` (no bzip2 on the phone, as Android); the Bridge announces it.
  A peer's name is stripped of NULs and trimmed, as Android does.
- The app's `lxmf.delivery` address is `RnsIdentity.fromRouting(identity).destHash("lxmf.delivery")`, the
  routing identity's keys in Reticulum order; Android's `d180c2083c4b9fecd0ff19812cb9b074` (msa-flaneur)
  came from the same construction.

## What comes next

1. **Links and resources** (`rns/Link.kt`, `LinkWire.kt`, `Resource.kt`, `Receipts.kt`, `Requests.kt`;
   Go `internal/reticulum/rnslink.go`, `proof.go`, `resource.go`, `internal/rns/link.go`, `resource.go`,
   `receipts.go`): the link request and proof (the golden `link.*`, `linkproof.*`, `proof.*`, `rtt.*`
   vectors are already in `golden.properties`), the link keys, keepalives, proofs, the resource transfer
   LXMF uses above 319 bytes, and IFAC (`ifac.*` vectors) for the Hub's Private networks.
2. **The node** (`rns/Node.kt`, `Transport.kt`, `Paths.kt`, `PathRequests.kt`, `AnnounceHandling.kt`,
   `PaidLinks.kt`; Go `internal/rns/node.go`, `transport.go`, `paths.go`, `pathreq.go`, `announce.go`,
   `paidlinks.go`): the transport node with its path table, announce handling and rebroadcast, path
   requests, the paid-link policy (extra hops 20, the allow-list, one announce per 5 minutes per
   destination) and the leaf mode a kit uses on the Hub's port.
3. **Transport binding**: a TCP interface to `rns.meshsat.net:4242` (and a tenant's Private network with
   its IFAC), the RNSI framing on the Iridium pipe (`rns/ImtFraming.kt` is the same as the existing
   `RnsImtFraming.swift`), and the phones' port 256 framing over Meshtastic (MESHSAT-1721) when the Bridge
   adopts it. The node sees every packet first; what it declines falls through to `MeshSatReticulum`.
4. **The router** (`lxmf/LxmfRouter.kt`; Go `internal/lxmf/router.go`): the delivery destination, inbound
   (signature, stamp enforcement, the mid dedup), outbound (opportunistic below 287 bytes off a paid link,
   direct over a link, resource above 319), receipts and states, the propagation node client
   (`LxmfPropagation.kt`; Go `propagation.go`) for a held message.
5. **Store and screens**: `lxmf_messages` in GRDB, the Reticulum settings (display name, stamp cost, the
   paid-link allow-list of Settings > Reticulum by satellite), a conversation keyed by delivery hash, the
   voice note and photo attachments in chat (recording and encoding are the app's, playback through the
   fields above), and the README's proven table.
