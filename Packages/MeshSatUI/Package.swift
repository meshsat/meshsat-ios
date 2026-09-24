// swift-tools-version: 6.0
// MeshSatUI: the SwiftUI layer, one Swift file per Kotlin file of MeshSat Android's ui/
// (Theme/, Chrome/, Material/, Components/, Screens/, Charts/, Words/). Apple platforms only.
import PackageDescription

let package = Package(
    name: "MeshSatUI",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MeshSatUI", targets: ["MeshSatUI"])
    ],
    dependencies: [
        .package(path: "../MeshSatKit"),
        .package(path: "../MeshSatApple"),
    ],
    targets: [
        .target(
            name: "MeshSatUI",
            dependencies: [
                .product(name: "MeshSatEngine", package: "MeshSatKit"),
                .product(name: "MeshSatSatellite", package: "MeshSatKit"),
                .product(name: "MeshSatMeshtastic", package: "MeshSatKit"),
                .product(name: "MeshSatNet", package: "MeshSatKit"),
                .product(name: "MeshSatHub", package: "MeshSatKit"),
                .product(name: "MeshSatPlatform", package: "MeshSatApple"),
                .product(name: "MeshSatBLE", package: "MeshSatApple"),
                .product(name: "MeshSatStore", package: "MeshSatApple"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "MeshSatUITests", dependencies: ["MeshSatUI"]),
    ],
    swiftLanguageModes: [.v6]
)
