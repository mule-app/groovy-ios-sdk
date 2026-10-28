# Groovy SDK for iOS

Groovy's offer widget for iOS apps: a view that shows Groovy's offers on your screens and sizes
itself to them. iOS 15 and later, Swift 5.9 and later.

## Install

Swift Package Manager: in Xcode, File > Add Package Dependencies, and enter
`https://github.com/mule-app/groovy-ios-sdk`. Or in `Package.swift`:

```swift
.package(url: "https://github.com/mule-app/groovy-ios-sdk", from: "1.0.1")
```

## Use

```swift
import GroovySDK

// UIKit
let widget = GroovyWidgetView(publisherId: "<your publisher ID>", accountId: "<your account ID>",
                              placement: "tracking.top", initialHeight: 0,
                              context: GroovyContext(retailer: "…", parcelStatus: "…"))

// SwiftUI
GroovyWidget(publisherId: "<your publisher ID>", accountId: "<your account ID>",
             placement: "tracking.top", context: GroovyContext(retailer: "…", parcelStatus: "…"))
```

An offer opens only after a tap inside the widget, the SDK sends no user identifier, and the
widget's storage is its own, gone when the app's process ends (1.0.1).

Your publisher ID, account ID and the reserved height for your design come with your onboarding,
together with Groovy's integration guide: the guide covers the context fields, the listener
events, privacy answers for the App Store, and testing before release.

This repository is published from Groovy's source at each release; please send questions and
issues to your Groovy contact.
