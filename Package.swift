// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MunkiStudio",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "MunkiStudio", targets: ["App"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "PredicateBridge",
            publicHeadersPath: "include"
        ),
        .target(
            name: "Core",
            dependencies: ["PredicateBridge"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .target(
            name: "Infra",
            dependencies: ["Core", "Yams"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .executableTarget(
            name: "App",
            dependencies: ["Core", "Infra", "Yams"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
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
