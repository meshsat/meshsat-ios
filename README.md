<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/meshsat/meshsat/main/docs/images/mark-dark.png">
  <img src="https://raw.githubusercontent.com/meshsat/meshsat/main/docs/images/mark-light.png" alt="MeshSat" width="190">
</picture>

### An iPhone as a MeshSat gateway: mesh and satellite in one app.

[![License: GPL v3](https://img.shields.io/badge/license-GPLv3-blue)](LICENSE)
[![Release](https://img.shields.io/github/v/release/meshsat/meshsat-ios?color=F25C05&label=release&include_prereleases)](https://github.com/meshsat/meshsat-ios/releases)
![iOS 17+](https://img.shields.io/badge/iOS-17%2B-000000?logo=apple&logoColor=white)
[![Pipeline](https://gitlab.nuclearlighters.net/products/meshsat/meshsat-ios/badges/main/pipeline.svg)](https://gitlab.nuclearlighters.net/products/meshsat/meshsat-ios/-/pipelines)

[Download](https://github.com/meshsat/meshsat-ios/releases) ·
[Android app](https://github.com/meshsat/meshsat-android) ·
[MeshSat node](https://docs.meshsat.net/node/) ·
[What works](#what-works-and-what-does-not) ·
[meshsat.net](https://meshsat.net)

<sub>Screenshots follow the first build that runs on an iPhone.</sub>

</div>

MeshSat iOS turns an iPhone into a MeshSat gateway. Pair it with a [MeshSat node](https://docs.meshsat.net/node/), a pocket-sized box with a Meshtastic LoRa radio and a RockBLOCK 9603 Iridium modem, and one phone can send and receive over the mesh and by satellite. It reports to the [MeshSat Hub](https://hub.meshsat.net) whenever there is any link to it, and it keeps working when the mobile network and the internet are gone.

It is the iOS counterpart of [MeshSat Android](https://github.com/meshsat/meshsat-android): the same screens, the same wording, the same wire formats, built from the Android app's code. Where iOS does not allow something Android does, this page says so.

> **Status: pre-release.** This is a prototype under active development, not a finished product. It has never been deployed to a real user and has never been used in an actual emergency. See [What works, and what does not](#what-works-and-what-does-not) before you rely on it for anything.

## Install

There is no App Store or TestFlight build yet. Each [release](https://github.com/meshsat/meshsat-ios/releases) carries two files:

- `MeshSat-<version>-unsigned.ipa`, for an iPhone. It is not signed by MeshSat. To run it you sign it yourself with a free Apple ID through [AltStore](https://altstore.io) or [Sideloadly](https://sideloadly.io); a free Apple ID limits you to three sideloaded apps and a certificate that expires every seven days, so the app has to be re-signed weekly.
- `MeshSat-<version>-simulator.zip`, for the iOS Simulator on a Mac. Drag `MeshSat.app` onto a running simulator. The simulator has no Bluetooth, so nothing about the node works there.

Developers build and run on their own phone from Xcode, see [Build from source](#build-from-source).

You need iOS 17 or later.

## Getting started

1. **Pair your node.** In Setup, open **Your MeshSat node**, tap **Scan for Meshtastic devices**, then **Connect** next to your node and enter its Bluetooth PIN. A plain Meshtastic radio pairs the same way.
2. **Satellite.** With **Use the node's modem** on (the default), the app uses the node's RockBLOCK while it is connected. Setup > Satellite shows the modem, with **Poll Signal** and **Check Mailbox**.
3. **Hub (optional).** Setup > Hub > **Scan the Hub's QR code**, with the QR code from the Hub. That sets the Hub address, credentials and client certificate.
4. **Emergency contacts.** In Setup > Safety, add the people an SOS goes to by text, then tap **Test the alarm** to see every route work.
5. **Send something.** In Messages, tap **New message** and pick who it is for: a node, everyone on the mesh, a phone number or the satellite. For a satellite message the compose bar shows the bytes and credits before you send.

## What it does

The list below is what the app is being built to do, following MeshSat Android. Each item is marked in the table under [What works, and what does not](#what-works-and-what-does-not).

- **Mesh.** Meshtastic over Bluetooth LE with the official protobufs: text, positions, telemetry, waypoints, node info, traceroute and more.
- **Satellite.** Iridium SBD through the node's RockBLOCK 9603, up to 340 bytes out and 270 bytes in, with a queue, retries, and sessions only when there is something to send, when the modem rings, or when you check the mailbox. Passes are predicted on the phone from orbit data that ships with the app.
- **Text messages.** The app opens the Messages composer with the text ready, one message per recipient. iOS does not let an app send a text by itself or read incoming texts, so replies arrive in Messages, not in MeshSat.
- **APRS** through a KISS TNC over TCP or directly to APRS-IS, with smart beaconing and acknowledged messages.
- **Hub.** MQTT with a client certificate; the phone shows up in the Hub's fleet like a field kit, reports health and positions, and takes remote commands.
- **TAK.** Positions from the Hub's TAK feed appear on the map. Receive only.
- **Reticulum.** The phone runs as a Reticulum transport node and relays between the mesh, the Iridium modem, MQTT and TCP peers.
- **Safety.** Hold the SOS button for 3 seconds and the SOS goes out on every route the phone has, each retried until it is sent. A check-in timer and zones drawn on the map.
- **Offline map** down to country level, and **night mode**, which turns the whole app red.

Two things Android does that an iPhone cannot: the RockBLOCK 9704 over an HC-05 Bluetooth serial adapter (iOS has no Bluetooth Classic serial for apps), and running as a gateway with the screen off without limits. iOS keeps the app alive for Bluetooth events and, when you allow it, for location updates; the Gateway card in Setup says which mode you are in.

## What works, and what does not

| | State |
|---|---|
| Mesh through a MeshSat node over Bluetooth | **Not built yet** |
| Satellite messages out through the node, landing at the Hub | **Not built yet** |
| A satellite message in, picked up by the app | **Not built yet** |
| Reconnecting to the node and taking its modem back after an app restart | **Not built yet** |
| Pass prediction with no internet | **Not built yet** |
| The phone connected to the Hub as a bridge | Verified 25 September 2026 on an iPhone 11 Pro Max: provisioned by QR code, birth signature verified by the Hub, a ping answered in 0.1 s |
| SOS: hold to send, the text composers, cancel, and the all-clear after it | **Not built yet** |
| SOS by satellite to the Hub | **Not built yet** |
| Contact cards swapped by QR code | **Not built yet** |
| The gateway kept alive in the background | **Not built yet** |
| RockBLOCK 9704 over HC-05 | **Not possible on iOS** |
| Reading incoming text messages | **Not possible on iOS** |
| Deployment to a real end user | **Never** |
| Use in an actual emergency | **Never** |

## Hardware

| Kind | Device | Connection | Status |
|---|---|---|---|
| Phone | iPhone 11 Pro Max, iOS 27 | | Main test phone |
| MeshSat node | v0: XIAO ESP32-S3, Wio-SX1262, RockBLOCK 9603 | Bluetooth LE | Not tested with this app |
| MeshSat node | v1: LILYGO T-Beam Supreme, RockBLOCK 9603 | Bluetooth LE | Not tested with this app |
| Meshtastic radio | any Meshtastic device | Bluetooth LE | Not tested with this app |
| APRS | any KISS TNC reachable over TCP, for example Direwolf | KISS over TCP | Not tested with this app |

## Build from source

You need a Mac with Xcode 26.

```bash
git clone https://github.com/meshsat/meshsat-ios.git
cd meshsat-ios
brew install xcodegen swiftlint
xcodegen generate                 # writes MeshSat.xcodeproj from project.yml
open MeshSat.xcodeproj            # pick the MeshSat scheme and a simulator or your phone
```

Everything that has no Apple dependency lives in `Packages/MeshSatKit` and also builds and tests on Linux:

```bash
scripts/linux-packages.sh          # with a Swift 6.2 toolchain
scripts/linux-packages.sh --docker # with Docker only
```

It is Swift 6 and SwiftUI, with GRDB for storage, swift-protobuf for the Meshtastic protobufs, swift-crypto for Ed25519, X25519 and AES-GCM, mqtt-nio for the Hub, and ONNX Runtime for the compression model. Library versions are in the `Package.swift` files.

## Release signing

Releases are not signed by MeshSat yet. When they are, this section will carry the Team ID and how to check a build. Until then the release files are unsigned, and you sign them yourself as described under [Install](#install).

## Troubleshooting

**The app does not find my node.** Bluetooth must be on, and the node must not be connected to another phone or to a laptop.

**Nothing happens with the app closed.** iOS wakes the app for Bluetooth events from the node. For everything else the gateway needs to be allowed to run in the background, under Setup > Advanced > Diagnostics, which also asks for location access.

**The satellite shows 0 bars.** That is normal between passes and under a limited view of the sky. The app sends anyway and keeps retrying.

**A text I sent shows one tick only.** iOS gives the app no delivery report for texts. One tick means the Messages app has it.

## Related projects

- [MeshSat Android](https://github.com/meshsat/meshsat-android), the reference for this app
- [MeshSat](https://github.com/meshsat/meshsat), the Bridge: the same gateway on a Raspberry Pi
- [MeshSat node](https://github.com/meshsat/meshsat-esp32) and its firmware, [meshsat-firmware](https://github.com/meshsat/meshsat-firmware)
- [MeshSat Hub](https://hub.meshsat.net), fleet management
- [Documentation](https://docs.meshsat.net/)

## Contributing

Issues and pull requests are welcome. Run `scripts/linux-packages.sh` and, on a Mac, `xcodebuild test` before you open a pull request, and open an issue first for anything large. Report security problems privately to security@meshsat.net rather than in a public issue; see [meshsat.net/security](https://meshsat.net/security/).

## License

Copyright 2026 Elli and Kyriakos. [GNU General Public License v3.0](LICENSE).

The app is GPLv3 because it includes the Meshtastic protobuf definitions in `Vendor/protos/meshtastic/`, which are GPL-3.0. Meshtastic publishes its own GPLv3 iOS app on the App Store the same way. Third-party material and its licences are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and [NOTICE](NOTICE).
