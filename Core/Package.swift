// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LidlessCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LidlessCore", targets: ["LidlessCore"]),
        .executable(name: "lidless-smc", targets: ["lidless-smc"]),
    ],
    targets: [
        .target(name: "CSMC", linkerSettings: [.linkedFramework("IOKit")]),
        .target(
            name: "LidlessCore",
            dependencies: ["CSMC"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(name: "lidless-smc", dependencies: ["LidlessCore"]),
        .testTarget(name: "LidlessCoreTests", dependencies: ["LidlessCore", "CSMC"]),
    ],
    swiftLanguageVersions: [.v5]
)
