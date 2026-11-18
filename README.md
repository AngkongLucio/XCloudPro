# XCloudPro

XCloudPro is an iPad-first native Xbox Cloud Gaming client for iOS/iPadOS.

## Product direction
- Native SwiftUI application shell and dashboard.
- Native WebRTC gameplay transport; no Xbox gameplay webpage in WKWebView.
- Xbox Cloud Gaming only. Xbox console Remote Play and PlayStation Remote Play are separate protocols and are not included.
- Preserve the existing dashboard while core authentication, catalog, session, media and controller workflows are completed.
- XStreaming and PeaSyo are technical architecture references only; do not copy their UI or branding.
- No Better xCloud userscript, userscript manager, or injected page scripts in the target architecture.

## Native architecture

The codebase is organized around native iOS feature modules:

- `Sources/Core/Models` — shared streaming models and client contracts.
- `Sources/Core/Networking` — injectable shared URLSession transport.
- `Sources/Core/Security` — PKCE, P-256 proof signatures and Keychain storage.
- `Sources/Features/Authentication` — Microsoft/Xbox XAL sign-in and callback views.
- `Sources/Features/Catalog` — Xbox Cloud catalog and entitlement filtering.
- `Sources/Features/Controller` — GameController discovery and input normalization.
- `Sources/Features/Dashboard` — existing SwiftUI dashboard.
- `Sources/Features/Streaming` — native WebRTC transport, player and stream coordinator.
- `Sources/Features/Streaming/Services` — Xbox Cloud session provisioning and signaling REST API.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the PeaSyo-to-XCloudPro platform mapping and validation gates.

## Current migration status

Implemented in source and compiling in CI:
- Native Microsoft/Xbox XAL authentication flow, PKCE, P-256 proof signing and Keychain token persistence.
- Xbox Cloud token exchange and region selection.
- Entitled Xbox Cloud catalog retrieval and product metadata mapping.
- Xbox Cloud session start, provisioning, connect-token handoff, configuration, keepalive and stop.
- Native WebRTC offer/answer and ICE signaling, video rendering surface, and Xbox input data-channel implementation.
- GameController discovery and normalized gamepad state.
- Shared HTTP transport used by authentication, catalog and cloud-session services.
- Feature-based source organization; the current dashboard UI has not been redesigned.

Not yet verified end-to-end:
- Successful Microsoft/Xbox sign-in against a live account. The last user-tested build (Build #146) returned HTTP 500 at Xbox device authentication. The architecture/network refactor in Build #154 does not by itself claim to fix that server rejection.
- Live catalog results for an entitled account.
- Complete cloud-game provisioning and WebRTC audio/video playback on a real Xbox Cloud session.
- Controller input correctness, disconnect/reconnect recovery and sustained gameplay on the target iPad.
- Negotiated stream-quality capability handling and actual performance measurements.

A successful GitHub Actions build proves compilation and IPA packaging only. It does not prove Microsoft service acceptance, account entitlement, live WebRTC media, controller behavior, or target-device performance. Do not treat the app as fully working until those validation gates pass.

## Security and protocol rules
- Use Microsoft sign-in; never collect or store raw Microsoft passwords.
- Keep OAuth codes, refresh/access tokens, proof keys, cookies and bearer tokens out of logs and source control.
- Keep endpoint-specific retry policies; do not blindly retry all Xbox authentication failures.
- Expose resolution, frame-rate, codec and bitrate controls only when the negotiated stream and target device support them.
- Do not represent an Xbox Cloud session as Xbox console Remote Play.
- Keep `main` stable; develop on `native-xstreaming-migration`.

## Build

The repository uses XcodeGen and a macOS GitHub Actions runner to create an unsigned iOS IPA. A successful workflow build and physical iPad test are required before calling a build functional.

Target test device: iPad (9th generation, Wi-Fi), iPadOS 18.1.
