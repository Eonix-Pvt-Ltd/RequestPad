// swift-tools-version: 6.2
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error)
]

let package = Package(
    name: "RequestPadKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "RPCore", targets: ["RPCore"]),
        .library(name: "RPData", targets: ["RPData"]),
        .library(name: "RPServices", targets: ["RPServices"]),
        .library(name: "RPUI", targets: ["RPUI"]),
    ],
    targets: [
        .target(name: "RPCore", resources: [.process("Resources")], swiftSettings: strictSettings),
        .target(
            name: "RPData", dependencies: ["RPCore"], resources: [.process("Resources")], swiftSettings: strictSettings),
        .target(
            name: "RPServices", dependencies: ["RPCore", "RPData"], resources: [.process("Resources")],
            swiftSettings: strictSettings),
        .target(
            name: "RPUI", dependencies: ["RPCore"], resources: [.process("Resources")], swiftSettings: strictSettings),
        .testTarget(
            name: "RPCoreTests", dependencies: ["RPCore"], resources: [.copy("Fixtures")], swiftSettings: strictSettings
        ),
        .testTarget(name: "RPDataTests", dependencies: ["RPData"], swiftSettings: strictSettings),
        .testTarget(name: "RPServicesTests", dependencies: ["RPServices"], swiftSettings: strictSettings),
        .testTarget(name: "RPUITests", dependencies: ["RPUI"], swiftSettings: strictSettings),
    ],
    swiftLanguageModes: [.v6]
)
