// swift-tools-version: 6.0
// MeshSatUI: the SwiftUI layer, one Swift file per Kotlin file of MeshSat Android's ui/
// (Theme/, Chrome/, Material/, Components/, Screens/, Charts/, Words/). Apple platforms only.
import PackageDescription

let package = Package(
    name: "MeshSatUI",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MeshSatUI", targets: ["MeshSatUI"]),
    ],
    dependencies: [
        .package(path: "../MeshSatKit"),
    ],
    targets: [
        .target(
            name: "MeshSatUI",
            dependencies: [
                .product(name: "MeshSatEngine", package: "MeshSatKit"),
                .product(name: "MeshSatSatellite", package: "MeshSatKit"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "MeshSatUITests", dependencies: ["MeshSatUI"]),
    ],
    swiftLanguageModes: [.v6]
)
