# XCloudPro Native Streaming Migration

Status: native dashboard shell implemented; streaming protocol integration remains in progress.

## Visual direction: Xbox console UI
XCloudPro has its own Xbox-console-inspired SwiftUI design. Do not copy XStreaming's layout, branding, or visual identity. Use XStreaming only as a technical reference.

- Dark graphite background and restrained Xbox-green accents.
- Featured game hero and prominent Play action.
- Horizontal game/library rails as catalog data becomes available.
- Home, My games, Discover, and Settings navigation.
- Native settings and a dedicated full-screen native player.
- Landscape-first responsive layout and controller focus states for iPad 9th generation.

## Implemented in the migration branch
- Native SwiftUI console dashboard replacing the previous browser-launch screen.
- Native Home, My games, Discover, and Settings pages.
- Persisted local haptics and network-stat display preferences.
- Existing Bluetooth controller detection retained.
- Typed XboxCloudStreamingClient interface and connection-state model.
- Secure PKCE/state generation, P-256 proof-key creation, Xbox request-signature generation, and Keychain token storage primitives.
- Native Microsoft/Xbox sign-in flow using ASWebAuthenticationSession, XAL callback handling, PKCE state validation, device-token proof-of-possession, Sisu authorization, XSTS exchange, and Xbox Cloud streaming-token acquisition.
- Microsoft/XAL callback URL scheme registered in the generated iOS app Info.plist.
- Native Account screen wired to sign-in status, gamertag/XUID display, cloud-token status, and sign-out.
- Native Xbox Cloud catalog and recently-played API client, with product-title metadata lookup.
- Native Xbox Cloud session REST lifecycle for the /v5/sessions/cloud path: create session, poll provisioning, perform the ReadyToConnect handoff through a supplied user-token provider, fetch stream configuration, keepalive, and terminate/cleanup.
- Native SDP offer and ICE candidate exchange against the cloud session signaling endpoints.
- Native WebRTC receive-only audio/video peer-connection layer and Metal-backed video surface.
- Native full-screen player shell and stream coordinator with session cleanup and connection-state reporting.
- Cloud-session service keeps Xbox Cloud Gaming separate from console Remote Play; it does not call /sessions/home.
- Play action on the dashboard remains disabled until Microsoft sign-in and session setup are wired.

## Still required
- Implement and validate secure refresh/recovery for Microsoft, Sisu, XSTS, and cloud-stream tokens; verify sign-in against a real Xbox account on the target iPad.
- Wire the catalog client to authenticated account state and populate the dashboard/library UI.
- Xbox Cloud WebRTC controller-input data channel and Xbox input packet mapping.
- Validate native audio routing, remote video, ICE behavior, and stream controls against a live Xbox Cloud session.
- Native video/audio rendering and controller input mapping.
- Capability-backed quality settings and network diagnostics.
- Build and test on the target iPad.

## Architecture rules
- Xbox Cloud Gaming and Xbox console Remote Play are separate paths and must be validated independently.
- No Xbox gameplay website wrapper, Better xCloud userscript, userscript manager, or injected page scripts.
- Never collect raw Microsoft passwords or commit credentials/tokens.
- Do not claim forced 2K/4K, unlocked FPS, or zero latency.
- Only expose stream settings supported by the negotiated session and device.

## Reference and license
The upstream Geocld/XStreaming `ios` branch LICENSE is MIT. Any code reused from that branch must retain the copyright and license notice. Its iOS app is React Native and includes bundled web stream assets; the existing native iOS modules cover platform integration such as XAL signing and gamepad support. XCloudPro is not importing those bundled web gameplay assets because the target is a native SwiftUI player. Use the upstream implementation and protocol docs as a reference, and keep XCloudPro's UI original. The native cloud-session REST layer and WebRTC transport are implemented as separate components, but they have not yet been validated against a live Xbox Cloud account or stream. The stream coordinator is dependency-injected and is not yet connected to a completed Microsoft sign-in/catalog UI.

## Target and delivery
Target: iPad 9th generation (iPad12,1), iPadOS 18.1. GitHub Actions unsigned IPA output is not proof of TrollStore compatibility; physical installation and gameplay tests are required.
