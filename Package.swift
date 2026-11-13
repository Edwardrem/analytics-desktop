// swift-tools-version:5.10
import PackageDescription

// Power BI Desktop — a native, Apple-silicon business intelligence studio for macOS.
// No third-party dependencies: system frameworks only.
let swift5: [SwiftSetting] = [.unsafeFlags(["-Xfrontend", "-strict-concurrency=minimal"])]

let package = Package(
    name: "MicrosoftPowerBI",
    platforms: [.macOS("15.0")],
    products: [.executable(name: "MicrosoftPowerBI", targets: ["MicrosoftPowerBI"])],
    targets: [
        .target(name: "FacetCore", swiftSettings: swift5),
        .target(name: "FacetDesign", dependencies: ["FacetCore"], swiftSettings: swift5),
        .target(name: "FacetDAX", dependencies: ["FacetCore"], swiftSettings: swift5),
        .target(name: "FacetQuery", dependencies: ["FacetCore"], exclude: ["API.md"],
                swiftSettings: swift5, linkerSettings: [.linkedLibrary("sqlite3"), .linkedLibrary("z")]),
        .target(name: "FacetAnalytics", dependencies: ["FacetCore"], swiftSettings: swift5),
        .target(name: "FacetCloud", dependencies: ["FacetCore"], swiftSettings: swift5),
        .target(name: "FacetInterop", dependencies: ["FacetCore"], swiftSettings: swift5, linkerSettings: [.linkedLibrary("z")]),
        .target(name: "FacetVisuals", dependencies: ["FacetCore", "FacetDesign"], exclude: ["Components/API.md"],
                swiftSettings: swift5),
        .executableTarget(name: "MicrosoftPowerBI",
                          dependencies: ["FacetCore", "FacetDesign", "FacetDAX", "FacetQuery", "FacetAnalytics", "FacetCloud", "FacetInterop", "FacetVisuals"],
                          swiftSettings: swift5),
        .testTarget(name: "FacetCoreTests", dependencies: ["FacetCore"], swiftSettings: swift5),
        .testTarget(name: "FacetCloudTests", dependencies: ["FacetCloud"], swiftSettings: swift5),
        .testTarget(name: "FacetDAXTests", dependencies: ["FacetDAX"], swiftSettings: swift5),
        .testTarget(name: "FacetQueryTests", dependencies: ["FacetQuery"], swiftSettings: swift5),
        .testTarget(name: "FacetInteropTests", dependencies: ["FacetInterop"], swiftSettings: swift5),
        .testTarget(name: "FacetAnalyticsTests", dependencies: ["FacetAnalytics"], swiftSettings: swift5),
        .testTarget(name: "FacetVisualsTests", dependencies: ["FacetVisuals"], swiftSettings: swift5),
    ]
)
