# Contributing to MeshSat iOS

## Build setup

You need a Mac with Xcode 26 (Swift 6.2) for the app. The pure-Swift packages
also build and test on Linux.

1. Install the tools: `brew install xcodegen swiftlint`
2. Generate the Xcode project (it is not committed): `xcodegen generate`
3. Open `MeshSat.xcodeproj`, pick the `MeshSat` scheme and an iPhone simulator, and run.

The project file is generated from `project.yml`. Edit that file, never the
generated `.xcodeproj`.

On Linux, or in CI without a Mac:

```bash
scripts/linux-packages.sh          # swift build and swift test for Packages/MeshSatKit
```

`Packages/MeshSatKit` holds every module that has no Apple dependency (wire
formats, crypto, HeMB, Reticulum, SGP4, the 9603 driver, the Hub protocol,
APRS, TAK, MSVQ-SC decoding, the engine). `Packages/MeshSatApple` (CoreBluetooth,
GRDB store, background coordination) and `Packages/MeshSatUI` (SwiftUI) build
only on Apple platforms.

## Code style

- Swift 6 language mode with strict concurrency; transports and stateful engine
  components are actors.
- SwiftUI for every screen. The screens mirror MeshSat Android one file per
  Kotlin file, and each Swift file names the Kotlin file it mirrors in its first
  comment. Wording, colours, fonts and layout follow the Android app; a
  behaviour change in one app is a change in both.
- `swiftlint --strict` and `swift format lint --strict` must pass.
- Byte arrays in wire code are `[UInt8]`; `Data` only at Apple API boundaries.

## Testing transports

Each transport needs hardware. The simulator has no Bluetooth.

### Meshtastic BLE
- Requires a physical Meshtastic radio or a MeshSat node.
- Pair in Setup > Your MeshSat node.
- Test: send a message from the app, confirm it appears on the radio, and back.

### Iridium (RockBLOCK 9603 on a MeshSat node)
- Requires a MeshSat node running meshsat-firmware with a RockBLOCK 9603 (see
  github.com/meshsat/meshsat-esp32). The app reaches the modem over the node's
  Bluetooth Iridium service, on the same connection as the mesh.
- Every session that reaches the satellite network uses at least one credit.
  Confirm delivery in the Rock7 portal or on the Hub.

### SMS
iOS lets an app open the system Messages composer, and nothing else. There is
no way to send a text without the user tapping Send, and no way to read an
incoming text. Test the composer flow, then read the reply in Messages.

## Hardware testing guidelines

When reporting a hardware test, include the iPhone model, the iOS version, the
node or radio firmware version, and, for the satellite path, the modem's
firmware and where the message was confirmed.

## Pull request guidelines

- Describe what changed and why.
- A change to a transport is tested on real hardware before it is submitted.
- One feature or fix per pull request.
- `scripts/linux-packages.sh` passes, and `xcodebuild test` passes on a Mac.

## License

By contributing, you agree that your contributions will be licensed under the
GNU General Public License v3.0, the licence in [LICENSE](LICENSE). The app is
GPL-3.0 because it vendors the GPL-3.0 Meshtastic protobuf definitions.
