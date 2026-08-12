// swift-tools-version: 6.2
import PackageDescription
import Foundation

let selectedDeveloperDirectory =
    ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
    ?? (try? FileManager.default.destinationOfSymbolicLink(
        atPath: "/var/db/xcode_select_link"
    ))
let developerLibraries = selectedDeveloperDirectory.map {
    "\($0)/Library/Developer/usr/lib"
}
let testingLinkerSettings: [LinkerSetting]
if let developerLibraries {
    testingLinkerSettings = [
        .unsafeFlags([
            "-L", developerLibraries,
            "-Xlinker", "-rpath",
            "-Xlinker", developerLibraries,
        ]),
    ]
} else {
    testingLinkerSettings = []
}

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
            revision: "48d727cc1cf4eda667c858c501495f1018f69d21"
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
            path: "Tests/agent-barTests",
            linkerSettings: testingLinkerSettings
        ),
    ]
)
