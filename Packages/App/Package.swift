// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "App",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "MunkiAdmin", targets: ["App"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../Infra"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: ["Core", "Infra"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
    ]
)
