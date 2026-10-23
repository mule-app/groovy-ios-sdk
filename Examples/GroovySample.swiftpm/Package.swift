// swift-tools-version: 5.9
// The Groovy SDK sample app: UIKit and SwiftUI screens, two widgets on one screen, a label right
// below each widget, and controls for the context, placement, design, test labels, initial height
// and log level (specs/222-mobile-sdk/quickstart.md). Open in Xcode, or build with
// `xcodebuild -scheme GroovySample` from this directory.
import AppleProductTypes
import PackageDescription

let package = Package(
    name: "GroovySample",
    platforms: [.iOS("15.0")],
    products: [
        .iOSApplication(
            name: "GroovySample",
            targets: ["GroovySample"],
            bundleIdentifier: "com.joingroovy.sample",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .box),
            accentColor: .presetColor(.teal),
            supportedDeviceFamilies: [.phone, .pad],
            supportedInterfaceOrientations: [.portrait, .landscapeRight, .landscapeLeft]
        ),
    ],
    dependencies: [
        .package(name: "GroovySDK", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "GroovySample",
            dependencies: [.product(name: "GroovySDK", package: "GroovySDK")],
            path: "Sources"
        ),
    ]
)
