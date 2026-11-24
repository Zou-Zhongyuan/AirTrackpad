// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirTrackpad",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AirTrackpadCore",
            targets: ["AirTrackpadCore"]
        ),
        .executable(
            name: "AirTrackpad",
            targets: ["AirTrackpadApp"]
        )
    ],
    targets: [
        .target(
            name: "AirTrackpadCore",
            dependencies: []
        ),
        .executableTarget(
            name: "AirTrackpadApp",
            dependencies: ["AirTrackpadCore"]
        ),
        .testTarget(
            name: "AirTrackpadCoreTests",
            dependencies: ["AirTrackpadCore"]
        )
    ]
)
