# XCloudPro Architecture Migration

## Goal

Port the useful application architecture patterns from PeaSyo v1.8.2 into a native iOS/iPadOS Xbox Cloud Gaming client. This is an architectural port, not a port of PlayStation Remote Play. XCloudPro remains Xbox Cloud-only and uses Microsoft's Xbox Cloud session and WebRTC signaling APIs.

## Platform mapping

| PeaSyo area | iOS-native XCloudPro destination | Porting rule |
| --- | --- | --- |
| `src/auth` | `Sources/XboxAuthenticationService.swift`, `Sources/AuthenticationPrimitives.swift` | Keep Microsoft OAuth, Xbox device proof, Sisu, XSTS and cloud-token exchange. Never import PSN auth. |
| `src/utils/http.ts` | `Sources/Core/Networking/XboxHTTPClient.swift` | Shared URLSession transport; endpoint-specific status handling and retry policy stay in each service. |
| `src/store` | Keychain token store, ObservableObject services, UserDefaults preferences | Secrets in Keychain; non-secret preferences only in UserDefaults. |
| `src/pages` | SwiftUI app screens | Preserve the existing XCloudPro UI until core workflows are verified. |
| `src/components` | SwiftUI components and native player views | Rebuild platform-native controls; do not embed Android or React Native UI. |
| `src/pages/Stream.tsx`, stream components | `XboxCloudSessionService`, `NativeStreamCoordinator`, `NativeWebRTCTransport`, `NativePlayerView` | Use Xbox Cloud session lifecycle and WebRTC, never Chiaki/PS Remote Play. |
| Gamepad store/components | `ControllerManager.swift` and WebRTC input channel | Use Apple's GameController framework and Xbox Cloud input packets. |
| Android JNI/C++ audio/video | WebRTC iOS framework, AVFoundation/AVAudioSession where required | Reimplement against iOS APIs; Android JNI, Oboe and Chiaki native code are not portable. |
| Logs/performance panel | Redacted diagnostics and stream telemetry | Never record passwords, OAuth codes, proof keys, cookies, or bearer tokens. |

## Runtime layers

1. **App composition** — SwiftUI entry point and dependency ownership.
2. **State and persistence** — account/session state, Keychain credentials, local preferences.
3. **Xbox domain services** — Microsoft/Xbox authentication, catalog, region and cloud session.
4. **Networking** — one injectable URLSession transport with no generic retries.
5. **Streaming runtime** — cloud provisioning, SDP/ICE signaling, WebRTC media and lifecycle.
6. **Input runtime** — controller discovery, state normalization and Xbox data-channel packets.
7. **Presentation** — existing dashboard and native player; UI redesign is explicitly deferred.

## Validation gates

- Authentication: verify device-auth, Microsoft redirect/PKCE, Sisu, XSTS and cloud token against a real Xbox account.
- Catalog: verify only entitled cloud-play titles are displayed.
- Session: verify provisioning, connect token, configuration, keepalive and teardown.
- Media: verify remote audio/video, ICE completion and recovery on the target iPad.
- Input: verify controller button/axis mapping and disconnect/reconnect.
- Device: build and install on iPad 9th generation / iPadOS 18.1.

A successful CI build proves compilation only. It does not prove Xbox service acceptance, account entitlement, live WebRTC media, controller behavior, or target-device performance.
