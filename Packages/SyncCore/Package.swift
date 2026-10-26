// swift-tools-version: 6.2
import PackageDescription

// Module names are deliberately product-neutral so the app can be renamed
// without touching the engine.
let package = Package(
    name: "SyncCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SyncModel", targets: ["SyncModel"]),
        .library(name: "RsyncCore", targets: ["RsyncCore"]),
        .library(name: "SyncStore", targets: ["SyncStore"]),
        .library(name: "SyncScheduler", targets: ["SyncScheduler"]),
        .library(name: "SSHKit", targets: ["SSHKit"]),
        .library(name: "SyncEngine", targets: ["SyncEngine"]),
    ],
    targets: [
        .target(name: "SyncModel"),
        .target(name: "ProcessSupport"),
        .target(name: "RsyncCore", dependencies: ["SyncModel", "ProcessSupport"]),
        .target(name: "SyncStore", dependencies: ["SyncModel"]),
        .target(name: "SyncScheduler", dependencies: ["SyncModel"]),
        .target(name: "SSHKit", dependencies: ["SyncModel", "ProcessSupport"]),
        .target(
            name: "SyncEngine",
            dependencies: ["SyncModel", "ProcessSupport", "RsyncCore", "SyncStore", "SyncScheduler", "SSHKit"]
        ),

        .testTarget(name: "SyncModelTests", dependencies: ["SyncModel"]),
        .testTarget(name: "RsyncCoreTests", dependencies: ["RsyncCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "SyncStoreTests", dependencies: ["SyncStore"]),
        .testTarget(name: "SyncSchedulerTests", dependencies: ["SyncScheduler"]),
        .testTarget(name: "SSHKitTests", dependencies: ["SSHKit"]),
        .testTarget(name: "SyncEngineTests", dependencies: ["SyncEngine"]),
    ],
    swiftLanguageModes: [.v6]
)
