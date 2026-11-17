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
- Secure PKCE/state generation, ephemeral P-256 proof-key creation, Xbox request-signature generation, and Keychain token storage primitives.
- Native Xbox Cloud session REST lifecycle for the /v5/sessions/cloud path: create session, poll provisioning, perform the ReadyToConnect handoff through a supplied user-token provider, fetch stream configuration, keepalive, and terminate/cleanup.
- Cloud-session service keeps Xbox Cloud Gaming separate from console Remote Play; it does not call /sessions/home.
- Play action clearly reports that native streaming is not connected yet.

## Still required
- Complete Microsoft OAuth/Sisu/XAL token exchange and refresh flow, including wiring the PKCE and proof-key primitives to real requests.
- Xbox Cloud Gaming catalog and entitlement integration.
- Native WebRTC peer connection, SDP/ICE exchange, media rendering, and controller input channel.
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
The upstream Geocld/XStreaming `ios` branch LICENSE is MIT. Any code reused from that branch must retain the copyright and license notice. Its iOS app is React Native and includes bundled web stream assets; the existing native iOS modules cover platform integration such as XAL signing and gamepad support. XCloudPro is not importing those bundled web gameplay assets because the target is a native SwiftUI player. Use the upstream implementation and protocol docs as a reference, and keep XCloudPro's UI original. The current native cloud-session service is an untested implementation of the documented cloud REST lifecycle; it does not establish a media stream on its own.

## Target and delivery
Target: iPad 9th generation (iPad12,1), iPadOS 18.1. GitHub Actions unsigned IPA output is not proof of TrollStore compatibility; physical installation and gameplay tests are required.
