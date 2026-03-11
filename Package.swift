// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenRecorder",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "ScreenRecorder", targets: ["ScreenRecorderApp"]),
        .executable(name: "TestRecorderApp", targets: ["TestRecorderApp"]),
        .executable(name: "TestUIApp", targets: ["TestUIApp"]),
    ],
    targets: [
        .executableTarget(
            name: "ScreenRecorderApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia")
            ]
        ),
        .executableTarget(
            name: "TestRecorderApp",
            path: "Sources/TestRecorderApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
            ]
        ),
        .executableTarget(
            name: "TestUIApp",
            path: "Sources/TestUIApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
