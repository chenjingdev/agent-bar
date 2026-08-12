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
            revision: "5ee435b15ad40ec1f644b5eb9d247f263ccd2170"
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
