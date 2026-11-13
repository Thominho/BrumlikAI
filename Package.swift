// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BrumlikAI",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .executable(name: "BrumlikAI", targets: ["BrumlikAI"])
    ],
    targets: [
        .executableTarget(
            name: "BrumlikAI",
            path: "Sources/BrumlikAI",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Contacts"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("EventKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .testTarget(
            name: "BrumlikAITests",
            dependencies: ["BrumlikAI"],
            path: "Tests/BrumlikAITests"
        )
    ]
)
