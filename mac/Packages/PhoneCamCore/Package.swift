// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PhoneCamCore",
    platforms: [.macOS(.v14)],
    products: [
        // Constants + frame drawing shared by the app and the camera extension (no networking).
        .library(name: "PhoneCamShared", targets: ["PhoneCamShared"]),
        // Pairing, signaling, compositing and the CMIO sink client used by the menu bar app.
        .library(name: "PhoneCamCore", targets: ["PhoneCamCore"]),
    ],
    targets: [
        .target(name: "PhoneCamShared"),
        .target(name: "PhoneCamCore", dependencies: ["PhoneCamShared"]),
        .testTarget(name: "PhoneCamCoreTests", dependencies: ["PhoneCamCore", "PhoneCamShared"]),
    ]
)
