// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MeetingAssistant",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MeetingAssistant", targets: ["MeetingAssistant"]),
        .library(name: "MeetingAssistantCore", targets: ["MeetingAssistantCore"]),
        .executable(name: "MeetingAssistantChecks", targets: ["MeetingAssistantChecks"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            exact: "1.1.0"
        ),
    ],
    targets: [
        .target(name: "MeetingAssistantCore"),
        .executableTarget(
            name: "MeetingAssistant",
            dependencies: [
                "MeetingAssistantCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
        .executableTarget(
            name: "MeetingAssistantChecks",
            dependencies: ["MeetingAssistantCore"]
        ),
    ]
)
