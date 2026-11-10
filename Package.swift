// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PasteClone",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PasteCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "PasteApp", dependencies: ["PasteCore"]),
        .testTarget(name: "PasteCoreTests", dependencies: ["PasteCore"]),
    ]
)
