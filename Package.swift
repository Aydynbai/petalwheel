// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Kumquat",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Kumquat",
            path: "Sources/Kumquat",
            linkerSettings: [.linkedFramework("Vision"), .linkedFramework("PDFKit"), .linkedFramework("QuickLookThumbnailing")]
        ),
    ]
)
