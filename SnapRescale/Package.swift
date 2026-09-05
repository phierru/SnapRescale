// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SnapRescale",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../RescaleKit"),
    ],
    targets: [
        .executableTarget(
            name: "SnapRescale",
            dependencies: [.product(name: "RescaleKit", package: "RescaleKit")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
