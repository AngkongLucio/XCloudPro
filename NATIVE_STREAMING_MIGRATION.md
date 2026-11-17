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
- Play action clearly reports that native streaming is not connected yet.

## Still required
- Microsoft OAuth sign-in and secure token lifecycle.
- Xbox Cloud Gaming catalog and entitlement integration.
- Verified xCloud session negotiation and WebRTC media transport.
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
Use Geocld/XStreaming iOS branch as a technical reference only. Review its current source and license before adapting code. Preserve required upstream copyright/license notices for any reused implementation.

## Target and delivery
Target: iPad 9th generation (iPad12,1), iPadOS 18.1. GitHub Actions unsigned IPA output is not proof of TrollStore compatibility; physical installation and gameplay tests are required.
