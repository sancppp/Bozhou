// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Bozhou",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BozhouCore", targets: ["BozhouCore"]),
        .executable(name: "Bozhou", targets: ["Bozhou"]),
        .executable(name: "BozhouAskPass", targets: ["BozhouAskPass"]),
        .executable(name: "BozhouUpdater", targets: ["BozhouUpdater"])
    ],
    targets: [
        // Only the macOS library is needed; upstream demo/benchmark dependencies are omitted.
        .target(name: "SwiftTerm", path: ".runtime/SwiftTerm/Sources/SwiftTerm",
                exclude: ["Mac/README.md"], resources: [.process("Apple/Metal/Shaders.metal")]),
        .systemLibrary(name: "CSQLite"),
        .target(name: "BozhouCore", dependencies: ["CSQLite"], resources: [
            .copy("Resources/bash-preexec.sh"), .process("Resources/Localization")
        ]),
        .target(name: "BozhouExtensions", dependencies: ["BozhouCore"]),
        .target(name: "BozhouNightHawk", dependencies: ["BozhouCore", "BozhouExtensions"]),
        .executableTarget(name: "Bozhou", dependencies: ["BozhouCore", "BozhouExtensions", "BozhouNightHawk", "SwiftTerm"]),
        .executableTarget(name: "BozhouAskPass", dependencies: ["BozhouCore"]),
        .executableTarget(name: "BozhouUpdater", dependencies: ["BozhouCore"]),
        .executableTarget(name: "BozhouCoreTests", dependencies: ["BozhouCore", "BozhouExtensions", "BozhouNightHawk"], path: "Tests/BozhouCoreTests")
    ]
)
