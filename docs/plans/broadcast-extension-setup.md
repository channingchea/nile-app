# iPad Screen Share — Broadcast Extension Setup (one-time, in Xcode)

Everything code-side is done: the extension source lives in
`ios/BroadcastExtension/`, the App Group is in both entitlements files, and
`Runner/Info.plist` carries the `RTCScreenSharingExtension` /
`RTCAppGroupIdentifier` keys. What remains is registering the extension as a
target — Xcode owns that file format, so it's a short manual step:

1. Open `ios/Runner.xcworkspace` in Xcode.
2. File → New → Target… → **Broadcast Upload Extension**.
   - Product Name: `BroadcastExtension` (exactly — the bundle ID must come out
     as `com.nilestreaming.app.BroadcastExtension` to match Info.plist).
   - Language: Swift. Uncheck "Include UI Extension". Team: same as Runner.
   - When Xcode asks to activate the new scheme, choose Cancel.
3. Xcode generates its own `SampleHandler.swift` inside a new group. Delete
   Xcode's generated files, then drag the files from `ios/BroadcastExtension/`
   (all five .swift files) into the extension target's group, ticking the
   BroadcastExtension target membership. Set the target's Info.plist to
   `ios/BroadcastExtension/Info.plist` (Build Settings → `INFOPLIST_FILE`).
4. Extension target → Signing & Capabilities → add **App Groups** →
   `group.com.nilestreaming.app` (Runner already has it via
   `Runner.entitlements`; point the extension's Code Signing Entitlements at
   `ios/BroadcastExtension/BroadcastExtension.entitlements` or let Xcode
   manage it — either way the group must be ticked).
5. Extension target → General → Deployment target: match Runner's iOS minimum.
6. Build & run on a **physical iPad** (extensions don't run in the simulator).

Test: join a stream as a camera on the iPad → tap the screen-share button →
the system broadcast picker appears → select Nile → whole-device capture
publishes as a second tile for viewers. Stopping from the red status-bar pill
also clears the in-app button state (handled via LocalTrackUnpublishedEvent).

Notes:
- The extension has a ~50 MB memory ceiling; the sample uploader stays well
  under it, but avoid adding work inside `processSampleBuffer`.
- Personal (free) dev team: App Groups + broadcast extensions work for
  on-device development; App Store distribution will need the paid team
  (same constraint already noted for Associated Domains).
