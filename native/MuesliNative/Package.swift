// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MuesliNative",
    platforms: [
        .macOS("14.2"),
    ],
    products: [
        .executable(name: "MuesliNativeApp", targets: ["MuesliNativeApp"]),
    ],
    targets: [
        .executableTarget(
            name: "MuesliNativeApp",
            path: "Sources/MuesliNativeApp",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "MuesliTests",
            dependencies: ["MuesliNativeApp"],
            path: "Tests/MuesliTests",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
