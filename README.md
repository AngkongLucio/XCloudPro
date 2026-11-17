# XCloudPro

XCloudPro is being rebuilt as a standalone iPad-first Xbox cloud streaming client with an original Xbox-console-inspired SwiftUI interface.

## Product direction
- Original Xbox-console dashboard: dark graphite UI, restrained Xbox green, featured hero, game-library rails, controller-friendly navigation.
- Native SwiftUI app shell and settings.
- Native gameplay renderer and streaming transport; no Xbox gameplay webpage in WKWebView.
- XStreaming is a technical reference only. Do not copy its UI or branding.
- No Better xCloud userscript, userscript manager, or injected page scripts in the target architecture.

## Current migration status
Implemented in this branch:
- Replaced the old browser-launch dashboard with an original Xbox-inspired native SwiftUI dashboard.
- Added Home, My games, Discover, and Settings navigation.
- Added persisted local preferences for haptics and network-stat visibility.
- Kept Bluetooth controller detection through Apple's GameController framework.
- Added a typed native streaming-client contract and explicit connection states.
- Added native PKCE, P-256 proof-signing, and Keychain token-storage primitives.
- Added an Xbox Cloud-only session REST client for provisioning, MSAL-token handoff, configuration, keepalive, and stop.
- Added a native WebRTC receive-only peer transport with SDP/ICE signaling and a SwiftUI video surface.
- Added a stream coordinator and Xbox-style native player quick menu; live auth/catalog wiring and controller input mapping are still pending.

Not yet implemented or verified:
- Microsoft/Xbox authentication and token lifecycle.
- Xbox cloud catalog and entitlement APIs.
- End-to-end authentication/token exchange and catalog integration.
- Live Microsoft authentication/catalog integration, validated WebRTC video/audio on an Xbox Cloud session, and controller input mapping.
- Functional stream quality controls backed by negotiated session capabilities.
- Successful device build, installation, and gameplay test on iPad 9th generation.

The dashboard intentionally reports that streaming is not connected. The cloud session service, authentication primitives, WebRTC transport, coordinator, and player surface are not yet wired to a completed Microsoft sign-in/catalog flow and have not been tested against a live Xbox account. They do not constitute a verified working stream. The app does not simulate a working stream or display fake game catalog entries.

## Architecture rules
- Separate Xbox Cloud Gaming from Xbox console Remote Play; do not claim one protocol supports the other.
- Use supported Microsoft sign-in flows; never collect or store raw Microsoft passwords.
- Keep credentials and tokens out of source control and app logs.
- Expose resolution, frame-rate, codec, and bitrate controls only when the negotiated stream and target device support them.
- Keep main stable; develop on native-xstreaming-migration.

## Build
The repository uses XcodeGen and a macOS GitHub Actions runner to create an unsigned IPA. A successful workflow build and physical iPad test are required before calling an IPA installable or functional.

Target test device: iPad (9th generation), iPadOS 18.1.
