// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Infra",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Infra", targets: ["Infra"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "Infra",
            dependencies: [
                "Core",
                "Yams",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "InfraTests",
            dependencies: ["Infra"],
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
