# XCloud Pro

An iPad-first SwiftUI launcher for Xbox Cloud Gaming with an experimental bundled Better xCloud integration.

## Features
- Opens Xbox Cloud Gaming in a native WKWebView container.
- Bundles the official Better xCloud userscript and injects it at document start.
- Bundles the supplied play.xbox.com opt-out redirect helper.
- Shows connected Bluetooth controller names using Apple's GameController framework.
- GitHub Actions workflow builds an unsigned iOS IPA on a hosted macOS runner.

## Better xCloud settings
Open the player using **PLAY NOW** and wait for Xbox Cloud Gaming to load. If the userscript initializes successfully, its own Better xCloud button/settings entry should appear in the Xbox page UI near the profile/server controls. These are the upstream Better xCloud settings, not a separate native XCloud Pro settings screen.

The bundled userscript is sourced from the official redphx/better-xcloud repository (MIT license). Its integration into this app's WKWebView is experimental and has not yet been tested on a physical iPad. Upstream documents iOS/iPadOS support through Safari + the Userscripts extension; a custom WKWebView is a different environment and may behave differently.

## Build with GitHub Actions
1. Open the Actions tab in this repository.
2. Select Build iOS IPA.
3. Choose Run workflow.
4. Wait for the workflow to finish.
5. Download the XCloudPro-unsigned-IPA artifact from the successful run.

## Local build
Requires macOS, Xcode, Homebrew, and XcodeGen.

    brew install xcodegen
    xcodegen generate
    xcodebuild -project XCloudPro.xcodeproj -scheme XCloudPro -sdk iphoneos -configuration Release CODE_SIGNING_ALLOWED=NO build

## Important limitations
- This is a launcher/browser wrapper. Xbox account authentication, subscriptions, game availability, stream resolution, bitrate, frame rate, and network latency are controlled by Xbox and the network.
- It does not force 2K/4K, unlock FPS, or guarantee zero input delay.
- Detecting a controller in the app does not guarantee every controller will be accepted by the Xbox web player.
- Better xCloud settings only appear if the upstream script initializes successfully on the Xbox website. Some Safari-specific or extension-dependent behavior may not work in WKWebView.
- The opt-out helper only redirects the legacy play.xbox.com host to www.xbox.com/play; it is not the Better xCloud settings interface.
- The workflow creates an unsigned IPA. TrollStore installation compatibility must be tested on the target device; it is not represented as tested.

## Target
iPadOS 16 or later. Intended test device: iPad (9th generation), iPadOS 18.1.
