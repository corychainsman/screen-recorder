// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenRecorder",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "ScreenRecorder", targets: ["ScreenRecorderApp"])
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
        )
    ]
)
