// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Petalwheel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Petalwheel",
            path: "Sources/Petalwheel",
            linkerSettings: [.linkedFramework("Vision"), .linkedFramework("PDFKit"), .linkedFramework("QuickLookThumbnailing")]
        ),
    ]
)
