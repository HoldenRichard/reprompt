// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Reprompt",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RepromptCore", targets: ["RepromptCore"]),
        .executable(name: "reprompt-harness", targets: ["RepromptHarness"]),
        .executable(name: "Reprompt", targets: ["Reprompt"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "RepromptCore",
            resources: [
                .embedInCode("Resources/optimizer_system.md"),
                .embedInCode("Resources/clarify_questions_system.md"),
                .embedInCode("Resources/clarify_final_system.md"),
                .embedInCode("Resources/judge_system.md"),
            ]
        ),
        .executableTarget(
            name: "RepromptHarness",
            dependencies: [
                "RepromptCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "Reprompt",
            dependencies: ["RepromptCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "RepromptCoreTests", dependencies: ["RepromptCore"]),
        .testTarget(
            name: "HarnessTests",
            dependencies: ["RepromptHarness"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
