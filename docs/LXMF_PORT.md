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
for the MeshSat-private traffic (`meshsat.node`, time sync, the Hub relay), exactly as Android keeps
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

## The Opus spike (7 Nov 2026, for the voice notes of tranche 5)

Apple's own Opus encoder does what Android's MediaRecorder does, so the notes need no libopus: on the build Mac
(Xcode 26.4.1), `AVAudioConverter` from 48 kHz mono Float32 PCM to `kAudioFormatOpus` with `mFramesPerPacket = 960`
and `bitRate = 16_000` turned a 2 s tone into 101 packets (24 to 75 bytes, mean 58, 5939 bytes in all), every packet
with TOC byte 0x48 (SILK wideband, one 20 ms frame, mono), `primeInfo.leadingFrames` 312 (the pre-skip Android's
`OpusVoice` defaults to), and the decoder's round trip measured RMS 0.364 against the tone's 0.354. The applicable
bitrates include 6 to 512 kbit/s. What is left for tranche 5 is the Ogg container (`OggOpus.kt` ported) around these
packets and the same check on the phone. Script: the session scratchpad's `opus_spike.swift`; result also on MESHSAT-1735.

## Tranches 2 and 3 (7 Nov 2026): links, resources, IFAC and the node

Both in `Sources/MeshSatRns`, pure Swift, Linux-tested, file for file after Android's `rns/`:

| Swift | Mirrors (Kotlin; Go) | Pinned by |
|---|---|---|
| `LinkWire.swift` | `LinkWire.kt`; `internal/reticulum/rnslink.go` | `link.*`, `linkproof.*`, `rtt.*` (RnsGoldenTests) |
| `Proof.swift` | the `Proof` object of `Wire.kt`; `proof.go` | `proof.*` |
| `Ifac.swift` | the `Ifac` class of `Wire.kt`; `ifac.go` | `ifac.*` (key, wrap and unwrap byte for byte: Ed25519 is deterministic) |
| `Node/Node.swift` | `Node.kt` (Transmitter, NodeConfig, Packet, Destination, KnownIdentity, Stats, Node) | `NodeTests` |
| `Node/Link.swift`, `Resource.swift`, `Requests.swift`, `Receipts.swift` | `Link.kt`, `Resource.kt`, `Requests.kt`, `Receipts.kt` | `NodeTests` |
| `Node/Transport.swift`, `AnnounceHandling.swift`, `PathRequests.swift`, `Paths.swift`, `PaidLinks.swift` | the same names in `rns/` | `NodeTests` |
| `MeshSatNet/Promise.swift` | `java.util.concurrent.CompletableFuture` as the Kotlin code uses it | |

`NodeTests` is Kotlin's `NodeTest` case for case: three nodes in a line with the middle one a transport (announce
learned at two hops, a single packet proved back through the reverse table, a link whose request and proof cross the
transport, link data proved, identify, teardown, a path request answered by a later announce), a 3,000-byte and a
20,000-byte resource over one link, the packet filter, the announce replacement rules, a neighbour heard across a paid
link with extra hops (HEADER_1 stays HEADER_1; a HEADER_2 naming our own destination is taken as local), and a paid
interface that carries only listed destinations with the 5-minute gate.

Shape differences that are deliberate: `Node`, `Link`, `LinkManager` and the resources are `final class ... @unchecked
Sendable` with recursive locks (Kotlin's ReentrantLock); callbacks are `@Sendable` and run outside the locks as in
Kotlin; Kotlin's 250 ms `ScheduledExecutor` is one Task on the injected `DriverClock`, and its one-shot `schedule` is a
due-list the same tick drains (so a test clock never sleeps); a node that is not running runs a scheduled task at once,
as Kotlin's shut-down scheduler does. Kotlin's `IllegalStateException`s are `NodeError`. `requestPathBlocking` is
`requestPathAwait`.

**The TCP listener and the Python harness (tranche 3's second half, 7 Nov 2026).** `MeshSatNet/ByteStream.swift` gained
`ByteStreamListener` and `ByteStreamListenerFactory`; the new target **MeshSatNIO** (`NIOByteStreams.swift`) implements
the dialer and the listener on SwiftNIO's POSIX sockets for Linux and the Mac (the app keeps Network.framework);
`MeshSatReticulum/RnsTcpServerInterface.swift` mirrors `TcpServerInterface.kt` (any number of HDLC peers, a transmit
goes to all, `peerCount`, `listen(port:)`); `MeshSatRns/Node/InterfaceTransmitter.swift` is the Transmitter of
`RnsStack.kt` (one ordered queue per interface, floodable = online and bidirectional and unpaid, 1000 bit/s for
`mesh*`). Tests: `Reticulum/RnsTcpServerInterfaceTests` on real sockets (CI), and under `Tests/Interop/`: `PyEnv.swift`
and `PyPeer.swift` (mirrors of `PyEnv.kt`, `PyPeer.kt`), `Fixtures/interop/rnsnode.py` (the Bridge's script, unchanged)
and `InteropNodeTests` (Kotlin's six: announce both ways, packet and proof both ways, a link each way with identify,
keepalive and close, three-node transport with us in the middle, us behind a stock rnsd). They skip without the venv;
**`scripts/interop-docker.sh`** runs them with `MESHSAT_INTEROP=1` in `scripts/interop/Dockerfile` (swift:6.2-noble
plus python3; the venv and SwiftPM's caches on the host mount `~/.cache/meshsat-interop`). **All six green against Python
RNS 1.5.5 on 7 Nov 2026 20:44 CET**, first run. NIO trap: `ChannelOptions.socketOption(.tcp_nodelay)` is the SOL_SOCKET
level (option 1 there is SO_DEBUG, EACCES in a container); TCP_NODELAY is `ChannelOptions.Types.SocketOption(level: .tcp,
name: .tcp_nodelay)`.

## Tranche 4 (7 Nov 2026): the router, the propagation client and the stack

`MeshSatLXMF/LxmfRouter.swift` and `LxmfRouter+Propagation.swift` mirror `lxmf/LxmfRouter.kt` (LXMF/LXMRouter.py
1.2.0): the lxmf.delivery destination with ratchets and the announce app data, inbound with stamp checks and the dedup,
the outbound queue (opportunistic one-packet, direct over a link reused and identified for the backchannel, a resource
above 319 bytes, upstream's attempt limits and retry waits, direct across a paid link), the propagation client
(`PROPAGATED` through an lxmf.propagation node with the node's stamp, the signalling packet, `sync()` with the two
`/get` rounds and the confirmation). `LxmfPropagation.swift` = `LxmfPropagation.kt` (the node announce, `SyncState`).
`RnsStack.swift` = `RnsStack.kt`: node + router over the app's `RnsInterface`s, ratchets through an `RnsStackStore`
(the Keychain on the phone), the announce loop, the paid policy with our own address, the propagation choice, the
sync loop, `inbound` for the legacy stack's `RnsTransportNode.upstreamInbound` (added). Shape: `LxmfRouter.Outbound`'s
fields sit behind one lock (`read`/`update`); the 1 s tick and every timer read the node's clock; `Promise` replaces
`CompletableFuture`; the class is split in two files for the linter. Tests: `LXMF/LxmfRouterTests` (Kotlin's four, in
memory: opportunistic, direct with link reuse, a resource and the backchannel; stamps at 6; across a paid link with 2 s
each way; an unreachable peer fails after its attempts), `LXMF/RnsStackTests`, and under `Interop/`: `InteropLxmfTests`
(Kotlin's seven: single packet both ways, the HeMB-NG mid field both ways with the 252/253 boundary, direct links both
ways with reuse, stamps at 6, resources both ways, propagated to Python through a node, propagated from Python through
a node) and `LxmfOracleTests` (two). **All fifteen interop cases green against Python RNS 1.5.5 + LXMF 1.2.0 on 7 Nov
2026 21:01 CET**, first run of the router.

## Tranche 5 (7 Nov 2026): the app

The node and the router run inside the gateway (`MeshSatPlatform/GatewayController+Lxmf.swift`, Android's
`GatewayService.initRnsStack` and its neighbours): `RnsStack` over the same `RnsInterface` objects the legacy
`RnsTransportNode` uses, which hands every packet to the node first (`upstreamInbound`) and keeps what the node
declines; ratchets in the Keychain (`KeychainIdentityStore: RnsStackStore`); the display name from
`lxmf_display_name`, else the Hub bridge id; an inbound message is filed once per (sender, mid) through
`lxmf_mids` (GRDB v5, `insertLxmfOnce` in one transaction, 30-day prune; `data/LxmfMidEntity.kt`) under the
sender's delivery hash as the conversation, with a notification; an outbound one is a `message_deliveries` row on
the virtual channel `lxmf_0` whose `forwardedTo` follows the router (`lxmf:queued/sent/delivered/propagated/
failed/unverified`). Two interfaces are new: `RnsIridium9704Interface` (`reticulum/RnsIridium9704Interface.kt`:
the 9704's IMT topic 244 with RNSI framing, an ordered queue of 64 with 5/15/30/60/120 s retries and a 15 min
drop, a paid link by its `iridium` prefix; the MT sink of `GatewayController+Imt` hands framed payloads to it,
`ImtDedup` in `RnsImtFraming.swift`) and `RnsTcpServerInterface` on `NWByteStreamListener` (Network.framework,
plain TCP, foreground only) so a Sideband on the same WiFi connects to the phone. Settings: the thirteen keys
of Android's Reticulum and RNode cards (`Settings.swift`). Screens, each from its Kotlin twin: the Reticulum
tab in Messages, LXMF peers and the 32-hex address field in New message, the Direct / Auto / Opportunistic /
Propagated chips and the delivery marks in the conversation (two teal checks delivered, "At the propagation
node", "Sender not verified yet"), and the Reticulum card in Setup > Ham radio, TAK and Reticulum (address,
name, Announce now, propagation node and Sync now, the satellite allow-list and extra hops, the TCP listener,
the TCP client). Tests: `Reticulum/RnsIridium9704InterfaceTests` (three, on a clock), `AppDatabaseTests` with
the new table; the Apple packages and the simulator app build on the Mac; `ProvingTests.testLxmf`
(`MESHSAT_PROVE=lxmf`) drives the phone against a stock Python node for the proof below. Not in this tranche:
the AutoInterface switch (Apple's multicast entitlement, MESHSAT-1828), the RNode card, voice notes and photos
(tranches 6 to 8, 0.5.0).

## Tranches 6 to 8 (7 Nov 2026 night): voice notes, photos, the RNode, the AutoInterface core

- **Kit, Linux-tested:** `MeshSatLXMF/OggOpus.swift` (`audio/OggOpus.kt`: RFC 3533 pages and CRC, RFC 7845 headers,
  sample counts from the TOC byte, pre-skip, 50 packets a page, vendor "MeshSat"; Android's six tests plus Apple's
  TOC 0x48), `AttachmentPolicy.swift` (`lxmf/AttachmentPolicy.kt`: only Reticulum carries the bytes, the line under the
  message box, 30 s and 64 KiB; Android's four tests), `MeshSatRns/Rnode/Kiss.swift`, `RnodeProtocol.swift`,
  `RnodeDriver.swift` (`rnode/*`: detect, configure, verify, READY flow control, errors and resets; Kotlin's six tests
  against a software RNode, with the driver's waits on the clock), `MeshSatRns/AutoInterfaceCore.swift`
  (`rns/AutoInterface.kt` without sockets: the group address and token against Python RNS 1.5.5's values, the address
  text rules, the peer table with its 22 s timeout and reverse peering, the 750 ms dedup).
- **Apple:** `MeshSatStore/MessageAttachmentStore+GRDB.swift` (GRDB v6 `message_attachments`, Android's table, the
  16 MiB trim that never takes the rows just written), `MeshSatPlatform/Media/VoiceRecorder.swift` (AVAudioEngine ->
  48 kHz mono -> `kAudioFormatOpus` 960-frame packets at 16 kbit/s -> OggOpus, the spike's settings),
  `VoiceNotePlayer.swift` (OggOpus -> AVAudioConverter -> AVAudioPlayerNode, the pre-skip dropped, Sideband's 60 ms
  packets too), `SpeechTranscriber.swift` (Speech, on the phone when it can), `PhotoShrinker.swift` (ImageIO
  thumbnail, then libwebp at 70/50/35/20 and a halving edge from 640 px; libwebp-Xcode 1.6.0, BSD-3-Clause, because
  ImageIO cannot write WebP), `MeshSatBLE/RnodeBleLink.swift` (the Nordic UART on its own CBCentralManager, "ble:<uuid>",
  and the scanner), `MeshSatPlatform/RnsRnodeInterface.swift` + `GatewayController+Rnode.swift` (the supervisor that
  reopens the radio, Apply without a gateway restart); `GatewayController+Lxmf.swift` sends and files FIELD_AUDIO /
  FIELD_IMAGE.
- **UI:** `Components/VoiceNote.swift` (hold to record, VoiceOver's double tap, pending chips with the policy line,
  "Heard: ..." Use as text / Discard, the note and photo cards), the microphone and photo picker on a Reticulum chat,
  `Screens/SettingsRnodeCard.swift` (Bluetooth LE only; CrossTalk's four presets, custom parameters, airtime limits).
  project.yml: `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`.
- **Not yet:** the AutoInterface's sockets and its switch wait for Apple's multicast entitlement (MESHSAT-1828); until
  then the card says so and shows no switch.

## What comes next

1. **Proofs on the phone**: LXMF text Direct and Propagated both ways against the runner's Python peers; a voice note
   and a photo each way (Python decodes FIELD_AUDIO/FIELD_IMAGE; Android 2.26.x and Sideband when at hand); the RNode
   over BLE only with a radio at hand (the software RNode is the proof otherwise, as on Android).
2. **Releases**: 0.4.0 and 0.5.0 as one App Store version if 0.3.1 is still in review when the code is done (the store
   takes one version in review at a time).
3. The phones' port 256 framing over Meshtastic (MESHSAT-1721) when the Bridge adopts it.
