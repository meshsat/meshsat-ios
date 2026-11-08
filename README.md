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

MeshSat is [on the App Store](https://apps.apple.com/app/meshsat/id6815748748), free, in every country except mainland China. Apple reviews each version before it gets there, so a [release](https://github.com/meshsat/meshsat-ios/releases) here can be newer. Each release carries two files:

- `MeshSat-<version>-unsigned.ipa`, for an iPhone. It is not signed by MeshSat. To run it you sign it yourself with a free Apple ID through [AltStore](https://altstore.io) or [Sideloadly](https://sideloadly.io); a free Apple ID limits you to three sideloaded apps and a certificate that expires every seven days, so the app has to be re-signed weekly.
- `MeshSat-<version>-simulator.zip`, for the iOS Simulator on a Mac. Drag `MeshSat.app` onto a running simulator. The simulator has no Bluetooth, so nothing about the node works there.

Developers build and run on their own phone from Xcode, see [Build from source](#build-from-source).

You need iOS 17 or later.

## Getting started

1. **Pair your node.** In Setup, open **Your MeshSat node**, tap **Scan for Meshtastic devices**, then **Connect** next to your node and enter its Bluetooth PIN. A plain Meshtastic radio pairs the same way.
2. **Satellite.** With **Use the node's modem** on (the default), the app uses the node's RockBLOCK while it is connected. Setup > Satellite shows the modem, with **Poll Signal** and **Check Mailbox**.
3. **Hub (optional).** Setup > Hub > **Scan the Hub's QR code**, with the QR code from the Hub. That sets the Hub address, credentials and client certificate. The Camera app works too: point it at the same code and open the `meshsat://` link it shows; MeshSat asks you to confirm before it claims the bridge.
4. **Emergency contacts.** In Setup > Safety, add the people an SOS goes to by text, then tap **Test the alarm** to see every route work.
5. **Send something.** In Messages, tap **New message** and pick who it is for: a node, everyone on the mesh, a phone number or the satellite. For a satellite message the compose bar shows the bytes and credits before you send.

## What it does

The list below is what the app is being built to do, following MeshSat Android. Each item is marked in the table under [What works, and what does not](#what-works-and-what-does-not).

- **Mesh.** Meshtastic over Bluetooth LE with the official protobufs: text, positions, telemetry, waypoints, node info, traceroute and more.
- **Satellite.** Iridium SBD through the node's RockBLOCK 9603, up to 340 bytes out and 270 bytes in, with a queue, retries, and sessions only when there is something to send, when the modem rings, or when you check the mailbox. Passes are predicted on the phone from orbit data that ships with the app.
- **Text messages.** The app opens the Messages composer with the text ready, one message per recipient, in the same wire format as MeshSat Android: compressed with smaz2 or MSVQ-SC and encrypted per conversation with AES-256-GCM when you set that up, so a MeshSat kit reads it. iOS does not let an app send a text by itself or read incoming texts, so replies arrive in Messages, not in MeshSat.
- **APRS** through a KISS TNC over TCP or directly to APRS-IS, with smart beaconing and acknowledged messages.
- **Hub.** MQTT with a client certificate; the phone shows up in the Hub's fleet like a field kit, reports health and positions, and takes remote commands: send a message, flush the queue, update config, rotate keys, restart the transports. Where a field kit cannot be reached directly, the app reaches it through a tunnel via the Hub.
- **TAK.** Positions from the Hub's TAK feed appear on the map, and the phone reports its own position, and an SOS, to the Hub as Cursor on Target events. There is no ATAK on iOS, so nothing is handed to another app.
- **Reticulum and LXMF.** The phone is a Reticulum node with an LXMF address, as Sideband and MeshChat speak it. Messages go to an LXMF address directly, opportunistically or through a propagation node, and a Reticulum chat carries voice notes (hold the microphone; the recogniser's text is only offered) and photos. The links: TCP to a Reticulum server, a listener for peers on the same WiFi, the node's RockBLOCK 9704 by satellite, and an RNode LoRa radio over Bluetooth. The phone also relays between the mesh, the Iridium modem, MQTT and TCP peers.
- **Safety.** Hold the SOS button for 3 seconds and the SOS goes out on every route the phone has, each retried until it is sent. A check-in timer that sends SOS when the phone sees no activity for too long, and zones drawn on the map that record when a node enters or leaves an area.
- **Public warnings.** A public warning a MeshSat kit relays over the mesh sounds an alarm, fills the screen while the app is open and stays under Setup > Safety > Warnings until the kit's cancel or a newer one; a test warning says so and uses the normal sound. It is never shown as a chat and never forwarded.
- **The node's satellite beacon.** With a node that has one, an icon left of night mode on Home lights red while the beacon is on, amber while it sends its last message and grey when it is off, and the node's health card says when the next position goes out.
- **Field kits on your network.** A kit on the same WiFi is reached at its address with the API token it may ask for, kept in the Keychain; through the Hub no token is needed.
- **Support.** Setup > Help > Support sends feedback to the MeshSat Support desk through your own mail, with an optional debug.zip of the app's logs in which phone numbers, email addresses, IMEIs and keys are blanked.
- **Offline map** down to country level, and **night mode**, which turns the whole app red.

Nothing goes online before you ask for it: the map loads tiles once you open it, orbit data is downloaded once your node's satellite modem has been seen, and otherwise only what you set up (the Hub, APRS-IS, Reticulum, a field kit) or tap (Update on the passes screen, Check for update) connects.

Two things Android does that an iPhone cannot: the RockBLOCK 9704 over an HC-05 Bluetooth serial adapter (iOS has no Bluetooth Classic serial for apps), and running as a gateway with the screen off without limits. With **Keep the gateway running in the background** on (Setup > Advanced > Diagnostics) and location allowed Always, the app keeps running behind iOS's blue location indicator and keeps reporting its position, as Android's gateway does; without it, iOS keeps the app alive for Bluetooth events from the node and refreshes the position only on significant movement.

## What works, and what does not

| | State |
|---|---|
| Mesh through a MeshSat node over Bluetooth | Verified 25 September 2026 on an iPhone 11 Pro Max with a T-Beam Supreme (v1) node: connected over Bluetooth LE, 2 nodes heard, and a text to everyone on the mesh taken by the node |
| Satellite messages out through the node, landing at the Hub | Verified 25 September 2026 on an iPhone 11 Pro Max with the T-Beam Supreme node under open sky: "25-sep-2026 1806 test from iPhone" went out as MOMSN 248 after two no-service retries and the Hub confirmed it within 4 s |
| A satellite message in, picked up by the app | Verified 25 September 2026: "25-sep-2026 1805 == test from rock7" (35 bytes), queued at Rock7 at 16:05 UTC, came down in the 16:14 session and was stored by the app 3 s later |
| Reconnecting to the node and taking its modem back after an app restart | Verified 25 September 2026: after every restart the app found the node by itself, claimed its Iridium pipe and the RockBLOCK 9603 answered within 30 s |
| Pass prediction with no internet | Verified 25 September 2026 on an iPhone 11 Pro Max with the phone's network at 100 percent packet loss: 232 passes from orbit data cached a day earlier, the pass overhead named |
| The phone connected to the Hub as a bridge | Verified 25 September 2026 on an iPhone 11 Pro Max: provisioned by QR code, birth signature verified by the Hub, a ping answered in 0.1 s |
| SOS: hold to send, the text composers, cancel, and the all-clear after it | The alarm test verified 25 September 2026: sent by the mesh and the Hub, the satellite copy queued while the node held its modem, the running-test banner and card, Stop test. A real SOS, the Messages composers and the all-clear are not exercised yet |
| SOS by satellite to the Hub | **Not built yet** |
| Contact cards swapped by QR code | Shown (My card) and read as pasted text, fingerprint checked and stored, verified 25 September 2026 on an iPhone 11 Pro Max. **Not yet scanned between two phones** |
| Reticulum/LXMF messages with stock Reticulum | Verified 8 November 2026 on an iPhone 11 Pro Max against Python RNS 1.5.5 and LXMF 1.2.0 over TCP on the LAN: Direct both ways with the delivered tick, and Propagated through a Python propagation node, the reply fetched with Sync now |
| Voice notes and photos in a Reticulum chat | Verified 8 November 2026: an Ogg Opus note and a WebP photo from Python LXMF shown, the note played to its end; a note recorded on the iPhone reached Python as a valid 48 kHz Opus file |
| An RNode LoRa radio over Bluetooth | The driver passes Android's tests against a simulated RNode. **Not yet tried with a radio** |
| Reticulum peers on the same WiFi finding the phone by themselves | **Waits for Apple's multicast entitlement**; until then a peer connects to the phone's listener by address |
| The gateway kept alive in the background | Verified 8 November 2026 on an iPhone 11 Pro Max: with the switch on and location allowed Always, the app went to the home screen for 120 s while a simulated route played; it logged continuous location on, and stored 12 positions along the route while it was off screen. Until 0.5.0 the app never noticed going to the background at all, so not even the significant-change updates ran |
| RockBLOCK 9704 over HC-05 | **Not possible on iOS** |
| Reading incoming text messages | **Not possible on iOS** |
| Night mode over every screen | Verified 7 November 2026 on an iPhone 11 Pro Max: Home, Messages, the map and its tiles, People, Setup and a sub-screen all red, colours back when switched off, the setting kept across a restart. Until 0.3.1 every screen went black (MESHSAT-1827) |
| Nothing online before it is asked for | Verified 7 November 2026 on an iPhone 11 Pro Max: in the first 90 s after the app started, its only connections went to the Hub and the Reticulum server set up on the phone; no map tiles, orbit data or firmware check |
| A field kit on the LAN, checked from Setup | Verified 7 November 2026: tesseract at its LAN address answered Reachable, after iOS asked once about the local network |
| Feedback to the Support desk with a debug.zip | The zip verified 7 November 2026: Android's seven files in Android's formats, nothing left to blank; the test phone has no Mail account, so the share sheet offered it. **Not yet sent to the desk from an iPhone** |
| The node's satellite beacon on Home and on the Node health card | Verified 7 November 2026 on an iPhone 11 Pro Max with an MSC-2 node (T-Beam S3, RockBLOCK 9704): the beacon icon beside night mode in grey and "Satellite beacon: Off" with the node's switch off. **The beacon switched on is not yet seen on an iPhone** |
| A RockBLOCK 9704 behind the node | Verified 7 November 2026 with the same node: the phone took its modem through the node's pipe and the 9704 answered (firmware v1.6.0); orbit data was refreshed only once the modem was seen. **No message sent through it from an iPhone yet** |
| Relayed public warnings: the alarm, the full screen, the list | The list verified 7 November 2026; the reading and the state are tested with Android's cases. **Not yet heard from a kit on an iPhone** |
| A warning that sounds through Do Not Disturb | **Not on iOS**: that needs Apple's critical-alert entitlement, which the app does not have |
| Picking the mail app that sends feedback | **Not possible on iOS**: Mail's composer when Mail has an account, the share sheet otherwise |
| Deployment to a real end user | **Never** |
| Use in an actual emergency | **Never** |

## Hardware

| Kind | Device | Connection | Status |
|---|---|---|---|
| Phone | iPhone 11 Pro Max, iOS 27 | | Main test phone |
| MeshSat node | v0: XIAO ESP32-S3, Wio-SX1262, RockBLOCK 9603 | Bluetooth LE | Not tested with this app |
| MeshSat node | v1: LILYGO T-Beam Supreme, RockBLOCK 9603 | Bluetooth LE | Tested 25 September 2026: node link, the modem over the node's pipe, a satellite message out to the Hub (MOMSN 248) |
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

It is Swift 6 and SwiftUI, with GRDB for storage, swift-protobuf for the Meshtastic protobufs, swift-crypto for Ed25519, X25519 and AES-GCM, mqtt-nio for the Hub, ONNX Runtime for the compression model, and libwebp for the photos sent by Reticulum. Library versions are in the `Package.swift` files.

## Release signing

Releases are not signed by MeshSat yet. When they are, this section will carry the Team ID and how to check a build. Until then the release files are unsigned, and you sign them yourself as described under [Install](#install).

## Troubleshooting

**The app does not find my node.** Bluetooth must be on, and the node must not be connected to another phone or to a laptop.

**Nothing happens with the app closed.** Switch on Keep the gateway running in the background under Setup > Advanced > Diagnostics and allow location Always; the switch says so, with a button to iOS Settings, when location is allowed only while the app is open. Without it iOS wakes the app for Bluetooth events from the node and refreshes the position on significant movement.

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

## Mission and use policy

MeshSat does not work with any organisation that develops, produces, integrates or operates weapon systems, and provides nothing for use in one. The licence below is unchanged: the policy covers whom we work with, not what you may do with the code. Read the [MeshSat Mission and Use Policy](https://meshsat.net/policy/).

## License

Copyright 2026 Elli and Kyriakos. [GNU General Public License v3.0](LICENSE).

The app is GPLv3 because it includes the Meshtastic protobuf definitions in `Vendor/protos/meshtastic/`, which are GPL-3.0. Meshtastic publishes its own GPLv3 iOS app on the App Store the same way. Third-party material and its licences are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and [NOTICE](NOTICE).
