// swift-tools-version: 6.2
import PackageDescription

// RepromptCore and the harness build on macOS, Linux and Windows. The menubar app is
// macOS by nature (Carbon hotkey, Accessibility, NSPasteboard, SwiftUI) and is only
// declared there, so `swift build` on another platform builds what can run there.
var products: [Product] = [
    .library(name: "RepromptCore", targets: ["RepromptCore"]),
    .executable(name: "reprompt-harness", targets: ["RepromptHarness"]),
]

var targets: [Target] = [
    .target(
        name: "RepromptCore",
        dependencies: [
            // CryptoKit is Apple-only; swift-crypto provides the same SHA-256 API elsewhere.
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux, .windows])),
        ],
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
    .testTarget(name: "RepromptCoreTests", dependencies: ["RepromptCore"]),
    .testTarget(
        name: "HarnessTests",
        dependencies: ["RepromptHarness"],
        resources: [.copy("Fixtures")]
    ),
]

#if os(macOS)
products.append(.executable(name: "Reprompt", targets: ["Reprompt"]))
targets += [
    .executableTarget(
        name: "Reprompt",
        dependencies: ["RepromptCore"],
        resources: [
            // Compiled in rather than bundled: a hand-assembled .app has no resource
            // bundle for Bundle.module to find, and a miss there is a crash.
            .embedInCode("Resources/menubar_quick.png"),
            .embedInCode("Resources/menubar_clarify.png"),
        ],
        swiftSettings: [.defaultIsolation(MainActor.self)]
    ),
    // No defaultIsolation here: the URLProtocol test double must stay nonisolated.
    .testTarget(name: "RepromptAppTests", dependencies: ["Reprompt", "RepromptCore"]),
]
#endif

let package = Package(
    name: "Reprompt",
    platforms: [.macOS(.v26)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: targets,
    swiftLanguageModes: [.v6]
)
