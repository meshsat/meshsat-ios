# MeshSatProto

Generated Swift for the vendored protobuf definitions in `Vendor/protos/`:

- `Generated/meshtastic/` from `Vendor/protos/meshtastic/*.proto` (Meshtastic, GPL-3.0). Swift
  types carry the `Meshtastic_` prefix, for example `Meshtastic_MeshPacket`.
- `Generated/takproto/` from `Vendor/protos/takproto/*.proto` (TAK).

Do not edit the generated files. Run `scripts/regen-protos.sh` after changing a `.proto`, with
`protoc-gen-swift` at the same version as the `swift-protobuf` pin in `Package.swift`.

Mirrors MeshSat Android's `app/src/main/proto/` (compiled there by the protobuf Gradle plugin
into `com.geeksville.mesh`).
