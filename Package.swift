// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "KikiAnalyticsKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "KikiAnalytics", targets: ["KikiAnalytics"]),
        .library(name: "KikiPostHog", targets: ["KikiPostHog"]),
        .library(name: "KikiAnalyticsTesting", targets: ["KikiAnalyticsTesting"])
    ],
    dependencies: [
        // Released 2026-10-03; newest release at least two weeks old on 2026-10-18.
        .package(url: "https://github.com/PostHog/posthog-ios.git", exact: "3.89.0")
    ],
    targets: [
        .target(name: "KikiAnalytics"),
        .target(name: "KikiPostHog", dependencies: [
            "KikiAnalytics", .product(name: "PostHog", package: "posthog-ios")
        ]),
        .target(name: "KikiAnalyticsTesting", dependencies: ["KikiAnalytics"]),
        .testTarget(name: "KikiAnalyticsTests", dependencies: ["KikiAnalytics", "KikiAnalyticsTesting"]),
        .testTarget(name: "KikiPostHogTests", dependencies: [
            "KikiPostHog", "KikiAnalyticsTesting", .product(name: "PostHog", package: "posthog-ios")
        ]),
        .testTarget(name: "KikiAnalyticsTestingTests", dependencies: ["KikiAnalyticsTesting"])
    ]
)
