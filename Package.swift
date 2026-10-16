// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Relaybar",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "RelaybarCore"),
        .executableTarget(
            name: "Relaybar",
            dependencies: ["RelaybarCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "RelaybarCoreTests", dependencies: ["RelaybarCore"]),
    ],
    swiftLanguageModes: [.v5]
)
