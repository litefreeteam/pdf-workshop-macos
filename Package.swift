// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PDFWorkshop",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PDFWorkshop", targets: ["PDFWorkshop"]),
        .executable(name: "WorkshopChecks", targets: ["WorkshopChecks"])
    ],
    targets: [
        .target(name: "WorkshopCore"),
        .executableTarget(name: "PDFWorkshop", dependencies: ["WorkshopCore"]),
        .executableTarget(name: "WorkshopChecks", dependencies: ["WorkshopCore"], path: "Tests/WorkshopChecks")
    ]
)
