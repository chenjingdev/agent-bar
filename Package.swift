// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "agent-bar",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "agent-bar", targets: ["agent_bar"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "swift-6.2.4-RELEASE"
        ),
    ],
    targets: [
        .executableTarget(
            name: "agent_bar",
            path: "Sources/agent-bar"
        ),
        .testTarget(
            name: "agent_barTests",
            dependencies: [
                "agent_bar",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/agent-barTests"
        ),
    ]
)
