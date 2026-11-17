# XCloudPro Native Streaming Migration

Status: architecture and source audit started. This branch preserves the existing main branch while the native client migration is prepared.

## Target

Replace the current SwiftUI + WKWebView Xbox website wrapper and injected userscripts with a standalone Xbox Cloud Gaming client based on the iOS implementation in [Geocld/XStreaming](https://github.com/Geocld/XStreaming/tree/ios).

The intended app must:
- authenticate through Microsoft's supported account sign-in flow;
- obtain Xbox/XCloud tokens and game catalog data through the client API layer;
- establish the cloud streaming session and WebRTC media connection inside the app;
- render the stream in an app-owned player surface;
- expose stream, display, audio, and controller preferences in native app settings;
- keep the Xbox website out of the gameplay path;
- contain no Better xCloud userscript or opt-out redirect userscript.

## Source and license

The selected reference is the upstream `ios` branch of Geocld/XStreaming. That branch's root LICENSE identifies the code as MIT licensed. Any source files reused or adapted must retain the upstream copyright and MIT license notice. Re-check the upstream branch and license before each substantial import.

Reference:
- https://github.com/Geocld/XStreaming/tree/ios
- https://github.com/Geocld/XStreaming/blob/ios/LICENSE
- https://github.com/Geocld/XStreaming/blob/ios/docs/1.Auth.md
- https://github.com/Geocld/XStreaming/blob/ios/docs/2.Web.md
- https://github.com/Geocld/XStreaming/blob/ios/docs/3.Stream.md

## Important implementation notes

- The upstream iOS project is React Native (not a pure SwiftUI app). Its JavaScript/TypeScript is compiled into the application bundle; it is not a browser userscript.
- The upstream login flow uses a WebView for Microsoft's OAuth redirect. This is separate from using the Xbox website as the game-streaming client.
- The streaming flow requires authenticated streaming credentials, a session, SDP/ICE negotiation, and a WebRTC media renderer. Do not replace this with a WKWebView loading `xbox.com/play`.
- The upstream docs describe Xbox home streaming and cloud streaming paths. Validate both paths separately; do not claim xCloud works merely because Xbox console remote play works.
- Do not claim forced 2K/4K, unlocked FPS, or zero latency. Expose only options the target iPad and streaming service actually support.

## iPad target

Primary test device: iPad 9th generation (iPad12,1), iPadOS 18.1.

Build and device testing are required. The existing GitHub Actions unsigned IPA workflow is not proof of a successful build or TrollStore compatibility.

## Migration checklist

- [ ] Import/adapt the upstream iOS client and retain required MIT notices.
- [ ] Rebrand the application as XCloudPro and set version/build metadata.
- [ ] Audit and adapt the native WebRTC renderer for iPadOS 18.1.
- [ ] Validate Microsoft OAuth redirect handling without embedding Xbox gameplay pages.
- [ ] Validate xCloud catalog, entitlement, session, SDP and ICE flow.
- [ ] Validate Bluetooth controller input and audio output.
- [ ] Add XCloudPro-specific native settings and persist supported preferences.
- [ ] Remove the old Better xCloud and redirect userscript resources and injection only after the native streaming path replaces them.
- [ ] Build, inspect logs, install and test on iPad 9th Gen.

