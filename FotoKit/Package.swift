// swift-tools-version:6.0
import PackageDescription

// FotoKit: Synology Photos (SYNO.Foto.* / SYNO.FotoTeam.*) models and service,
// built on SynoKit's generic transport. App-specific (only SynologyPhotosManager
// uses it), kept as a package so it's unit-testable headlessly via the
// FotoKitChecks executable — no host app, no XCTest requirement.
let package = Package(
    name: "FotoKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FotoKit", targets: ["FotoKit"]),
    ],
    dependencies: [
        .package(path: "../../SynoKit"),
    ],
    targets: [
        .target(
            name: "FotoKit",
            dependencies: [.product(name: "SynoKit", package: "SynoKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "FotoKitChecks",
            dependencies: ["FotoKit", .product(name: "SynoKit", package: "SynoKit")],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
