// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacKopiaKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "BackupDomain", targets: ["BackupDomain"]),
        .library(name: "KopiaCLI", targets: ["KopiaCLI"]),
        .library(name: "KopiaServer", targets: ["KopiaServer"]),
        .library(name: "BackupEngine", targets: ["BackupEngine"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "Secrets", targets: ["Secrets"]),
        .library(name: "SystemIntegration", targets: ["SystemIntegration"]),
        .library(name: "AgentProtocol", targets: ["AgentProtocol"]),
    ],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")],
    targets: [
        .target(name: "BackupDomain", dependencies: []),
        .target(name: "KopiaCLI", dependencies: ["BackupDomain"]),
        .target(name: "KopiaServer", dependencies: ["KopiaCLI"]),
        .target(
            name: "BackupEngine",
            dependencies: ["BackupDomain", "KopiaCLI", "KopiaServer", "Persistence", "Secrets", "SystemIntegration"]),
        .target(
            name: "Persistence", dependencies: ["BackupDomain", .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Resources/GRDB-LICENSE.txt")]),
        .target(name: "Secrets", dependencies: ["BackupDomain"]),
        .target(name: "SystemIntegration", dependencies: ["BackupDomain"]),
        .target(name: "AgentProtocol", dependencies: ["BackupDomain"]),
        .target(name: "TestSupport", dependencies: ["BackupDomain"]),
        .testTarget(
            name: "KopiaContractTests",
            dependencies: ["KopiaServer"],
            path: "Tests",
            exclude: ["FoundationTests"],
            sources: ["KopiaContractTests"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "FoundationTests",
            dependencies: [
                "BackupDomain", "KopiaCLI", "KopiaServer", "BackupEngine", "Persistence", "Secrets",
                "SystemIntegration", "AgentProtocol", "TestSupport",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
