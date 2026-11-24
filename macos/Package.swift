// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repoRoot = packageDir.deletingLastPathComponent()
let profileDir = ProcessInfo.processInfo.environment["SPRITZ_RUST_PROFILE"] == "release"
    ? "release"
    : "debug"
let rustLibDir = ProcessInfo.processInfo.environment["SPRITZ_RUST_LIB_DIR"]
    ?? repoRoot.appendingPathComponent("target/\(profileDir)").path

let package = Package(
    name: "SpritzApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Spritz", targets: ["SpritzApp"]),
    ],
    targets: [
        .target(
            name: "CSpritzFFI",
            path: "Sources/CSpritzFFI",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "SpritzApp",
            dependencies: ["CSpritzFFI"],
            path: "Sources/SpritzApp",
            linkerSettings: [
                .unsafeFlags(["-L\(rustLibDir)", "-lspritz_macos"]),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
