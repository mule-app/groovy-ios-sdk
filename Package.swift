// swift-tools-version:5.9
// Groovy's iOS SDK: a drop-in view that hosts the Groovy widget (spec 222).
// Released by mirroring this directory to the public `mule-app/groovy-ios-sdk` repository
// (mule-app/groovy-app: modules/mobile-sdk/README.md "Releasing").
import PackageDescription

let package = Package(
    name: "GroovySDK",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "GroovySDK", targets: ["GroovySDK"]),
    ],
    targets: [
        .target(
            name: "GroovySDK",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        // Pure logic: URL builder, message parser, state machine, navigation rule, context encoding.
        .testTarget(name: "GroovySDKTests", dependencies: ["GroovySDK"]),
        // The real WKWebView on the simulator: the injected script, frames, offers (plan §12.2).
        .testTarget(name: "GroovySDKWebViewTests", dependencies: ["GroovySDK"]),
    ]
)
