# XCloud Pro

An iPad-first SwiftUI launcher for Xbox Cloud Gaming.

## Features
- Opens Xbox Cloud Gaming in a native WKWebView container.
- Enables inline media playback.
- Shows connected Bluetooth controller names using Apple's GameController framework.
- Includes a GitHub Actions workflow to build an unsigned iOS IPA on a hosted macOS runner.

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
- Better xCloud is a separate browser userscript and is not injected into this WKWebView build.
- The workflow creates an unsigned IPA. TrollStore installation compatibility must be tested on the target device; it is not represented as tested.

## Target
iPadOS 16 or later. Intended test device: iPad (9th generation), iPadOS 18.1.
