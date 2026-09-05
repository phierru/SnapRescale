// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RescaleKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RescaleKit", targets: ["RescaleKit"]),
        .executable(name: "rescale", targets: ["rescale"]),
    ],
    targets: [
        .target(
            name: "RescaleKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "rescale",
            dependencies: ["RescaleKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RescaleKitTests",
            dependencies: ["RescaleKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
