// swift-tools-version:6.0
import PackageDescription

// Phase 0 API spike: logs into the real NAS (read-only) and captures actual
// SYNO.Foto.* response schemas as fixtures, to lock them down before FotoAPI is
// built. Not part of the app; run with: swift run FotoSpike
let package = Package(
    name: "FotoSpike",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../SynoKit"),
        .package(path: "../FotoKit"),
    ],
    targets: [
        .executableTarget(
            name: "FotoSpike",
            dependencies: [
                .product(name: "SynoKit", package: "SynoKit"),
                .product(name: "FotoKit", package: "FotoKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Dev-only: copies the NAS connection/password/cert-pin from
        // SynologyMonitor's store into the Photos app's own store so the app can
        // auto-connect for a live smoke test. Not shipped.
        .executableTarget(
            name: "SeedPhotosStore",
            dependencies: [.product(name: "SynoKit", package: "SynoKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Dev-only: careful write/delete spikes that operate ONLY on test
        // artifacts it creates (test album, one synthetic uploaded image) —
        // never on the user's real photos. Verifies album/upload/delete APIs.
        .executableTarget(
            name: "WriteSpike",
            dependencies: [.product(name: "SynoKit", package: "SynoKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Dev-only, READ-ONLY: probes how to collect photo coordinates for the
        // map view (T3) — GPS fill-rate via item paging vs. the geocoding facet
        // as a cheap place index. No writes.
        .executableTarget(
            name: "MapSpike",
            dependencies: [
                .product(name: "SynoKit", package: "SynoKit"),
                .product(name: "FotoKit", package: "FotoKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
