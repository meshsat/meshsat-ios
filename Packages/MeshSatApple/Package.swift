// swift-tools-version: 6.0
// MeshSatApple: the parts of MeshSat iOS that need Apple frameworks and therefore build only on
// Apple platforms. Mirrors, in MeshSat Android:
//   MeshSatBLE       ble/MeshtasticBle, ble/IridiumBlePipe (CoreBluetooth central), and
//                    reticulum/RnsBlePeripheralInterface (CoreBluetooth peripheral)
//   MeshSatStore     data/AppDatabase and the DAOs (GRDB), data/SettingsRepository (UserDefaults),
//                    crypto/SecureKeyStore (Keychain)
//   MeshSatPlatform  service/GatewayService (GatewayController + BackgroundCoordinator), location/,
//                    sms/ (the Messages composer lane), map/ (MBTiles + MKTileOverlay), api/
//                    (diagnostics), the crash capture of TelemetryLogger, notifications
import PackageDescription

let package = Package(
    name: "MeshSatApple",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MeshSatApple", targets: ["MeshSatBLE", "MeshSatStore", "MeshSatPlatform"]),
        .library(name: "MeshSatBLE", targets: ["MeshSatBLE"]),
        .library(name: "MeshSatStore", targets: ["MeshSatStore"]),
        .library(name: "MeshSatPlatform", targets: ["MeshSatPlatform"]),
    ],
    dependencies: [
        .package(path: "../MeshSatKit"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        // The sentence encoder of MSVQ-SC (MESHSAT-1329); a binary xcframework, iOS only.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.19.2"),
    ],
    targets: [
        .target(
            name: "MeshSatBLE",
            dependencies: [
                .product(name: "MeshSatMeshtastic", package: "MeshSatKit"),
                .product(name: "MeshSatReticulum", package: "MeshSatKit"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "MeshSatStore",
            dependencies: [
                .product(name: "MeshSatEngine", package: "MeshSatKit"),
                .product(name: "MeshSatNet", package: "MeshSatKit"),
                .product(name: "MeshSatSatellite", package: "MeshSatKit"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "MeshSatPlatform",
            dependencies: [
                "MeshSatBLE", "MeshSatStore",
                .product(name: "MeshSatAprs", package: "MeshSatKit"),
                .product(name: "MeshSatTak", package: "MeshSatKit"),
                .product(name: "MeshSatMsvqsc", package: "MeshSatKit"),
                .product(name: "MeshSatEngine", package: "MeshSatKit"),
                .product(name: "MeshSatReticulum", package: "MeshSatKit"),
                .product(name: "MeshSatCrypto", package: "MeshSatKit"),
                .product(name: "MeshSatHub", package: "MeshSatKit"),
                .product(name: "MeshSatSatellite", package: "MeshSatKit"),
                .product(name: "MeshSatMeshtastic", package: "MeshSatKit"),
                .product(name: "MeshSatMQTT", package: "MeshSatKit"),
                .product(name: "MeshSatNet", package: "MeshSatKit"),
                .product(name: "MeshSatWire", package: "MeshSatKit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ]
        ),
        .testTarget(name: "MeshSatAppleTests", dependencies: ["MeshSatBLE", "MeshSatStore", "MeshSatPlatform"]),
    ],
    swiftLanguageModes: [.v6]
)
