// swift-tools-version: 6.0
// MeshSatKit: every part of MeshSat iOS that has no Apple dependency. It builds
// and tests on Linux (scripts/linux-packages.sh) and on Apple platforms. The
// Apple-only code lives in Packages/MeshSatApple and Packages/MeshSatUI.
//
// Module map (the Android package each one mirrors is in its README.md):
//   MeshSatWire       codec/, dtn/, timesync/, sos/SosMessages, crypto/AesGcmCrypto,
//                     crypto/KeyBundleImporter, crypto/MsvqscWire, pair/ContactQR,
//                     hub/HubProtocol, hub/BirthSigner (canonical JSON), channel/
//   MeshSatCrypto     routing/Identity, reticulum/RnsHkdf, SPKI pinning, PEM parsing
//   MeshSatHemb       hemb/, rlnc/, fec/
//   MeshSatNet        the ByteStream / WebSocketTransport / HttpGetter protocols
//   MeshSatReticulum  reticulum/ and the used parts of routing/
//   MeshSatSatellite  satellite/ (SGP4, TLE, passes, scheduler) + bundled TLEs
//   MeshSatProto      generated Swift for Vendor/protos (Meshtastic, TAK)
//   MeshSatMeshtastic ble/MeshtasticProtocol, GattOpQueue, the Iridium pipe
//                     contract and streams, bt/IridiumSpp as IridiumATDriver
//   MeshSatEngine     engine/, rules/, dedup/, ratelimit/, sos/, config/, data/ records
//   MeshSatHub        hub/HubReporter, crypto/Provision*, hub/relay/
//   MeshSatMQTT       mqtt/ on mqtt-nio
//   MeshSatMsvqsc     crypto/Msvqsc* decoder, tokenizer, quantiser
//   MeshSatAprs       aprs/
//   MeshSatTak        tak/ minus the ATAK intent
import PackageDescription

let package = Package(
    name: "MeshSatKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MeshSatWire", targets: ["MeshSatWire"]),
        .library(name: "MeshSatCrypto", targets: ["MeshSatCrypto"]),
        .library(name: "MeshSatHemb", targets: ["MeshSatHemb"]),
        .library(name: "MeshSatNet", targets: ["MeshSatNet"]),
        .library(name: "MeshSatReticulum", targets: ["MeshSatReticulum"]),
        .library(name: "MeshSatSatellite", targets: ["MeshSatSatellite"]),
        .library(name: "MeshSatProto", targets: ["MeshSatProto"]),
        .library(name: "MeshSatMeshtastic", targets: ["MeshSatMeshtastic"]),
        .library(name: "MeshSatEngine", targets: ["MeshSatEngine"]),
        .library(name: "MeshSatHub", targets: ["MeshSatHub"]),
        .library(name: "MeshSatMQTT", targets: ["MeshSatMQTT"]),
        .library(name: "MeshSatMsvqsc", targets: ["MeshSatMsvqsc"]),
        .library(name: "MeshSatAprs", targets: ["MeshSatAprs"]),
        .library(name: "MeshSatTak", targets: ["MeshSatTak"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/swift-server-community/mqtt-nio.git", from: "2.10.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .target(name: "MeshSatWire"),
        .target(
            name: "MeshSatCrypto",
            dependencies: [
                "MeshSatWire",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
            ]
        ),
        .target(name: "MeshSatHemb"),
        .target(name: "MeshSatNet"),
        .target(
            name: "MeshSatReticulum",
            dependencies: [
                "MeshSatWire", "MeshSatCrypto", "MeshSatNet",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "MeshSatSatellite",
            dependencies: ["MeshSatNet", .product(name: "Logging", package: "swift-log")],
            resources: [.copy("Resources/tle")]
        ),
        .target(
            name: "MeshSatProto",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
            exclude: ["README.md"]
        ),
        .target(
            name: "MeshSatMeshtastic",
            dependencies: [
                "MeshSatProto", "MeshSatWire", "MeshSatNet",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "MeshSatEngine",
            dependencies: [
                "MeshSatWire", "MeshSatCrypto", "MeshSatHemb", "MeshSatSatellite", "MeshSatNet",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .target(
            name: "MeshSatHub",
            dependencies: [
                "MeshSatWire", "MeshSatCrypto", "MeshSatNet", "MeshSatEngine",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "MeshSatMQTT",
            dependencies: [
                "MeshSatNet",
                .product(name: "MQTTNIO", package: "mqtt-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(name: "MeshSatMsvqsc", dependencies: ["MeshSatWire"]),
        .target(name: "MeshSatAprs", dependencies: ["MeshSatNet", "MeshSatWire"]),
        .target(name: "MeshSatTak", dependencies: ["MeshSatProto"]),
        .testTarget(
            name: "MeshSatKitTests",
            dependencies: [
                "MeshSatWire", "MeshSatCrypto", "MeshSatHemb", "MeshSatNet", "MeshSatReticulum",
                "MeshSatSatellite", "MeshSatProto", "MeshSatMeshtastic", "MeshSatEngine",
                "MeshSatHub", "MeshSatMQTT", "MeshSatMsvqsc", "MeshSatAprs", "MeshSatTak",
            ],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
