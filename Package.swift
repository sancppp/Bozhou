// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Bozhou",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BozhouCore", targets: ["BozhouCore"]),
        .executable(name: "Bozhou", targets: ["Bozhou"]),
        .executable(name: "BozhouAskPass", targets: ["BozhouAskPass"])
    ],
    targets: [
        // Only the macOS library is needed; upstream demo/benchmark dependencies are omitted.
        .target(name: "SwiftTerm", path: ".runtime/SwiftTerm/Sources/SwiftTerm",
                exclude: ["Mac/README.md"], resources: [.process("Apple/Metal/Shaders.metal")]),
        .systemLibrary(name: "CSQLite"),
        .target(name: "BozhouCore", dependencies: ["CSQLite"], resources: [.copy("Resources/bash-preexec.sh")]),
        .executableTarget(name: "Bozhou", dependencies: ["BozhouCore", "SwiftTerm"]),
        .executableTarget(name: "BozhouAskPass", dependencies: ["BozhouCore"]),
        .executableTarget(name: "BozhouCoreTests", dependencies: ["BozhouCore"], path: "Tests/BozhouCoreTests")
    ]
)
