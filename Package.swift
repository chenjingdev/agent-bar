// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentBar",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "AgentBar", targets: ["AgentBar"]),
    ],
    targets: [
        .executableTarget(
            name: "AgentBar",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
