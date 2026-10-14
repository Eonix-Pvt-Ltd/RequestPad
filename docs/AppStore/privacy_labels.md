# App Privacy (App Store Connect questionnaire) — RequestPad 1.0.0

## Answer

**Data Not Collected.** In App Store Connect → App Privacy → "Do you or your third-party partners collect data from
this app?" answer **No, we do not collect data from this app**.

## Why this is accurate

Apple defines "collect" as transmitting data off the device in a way that the developer or its partners can access
for longer than needed to service the request in real time. RequestPad transmits nothing to Eonix or any partner:

| Data | What happens | Collected? |
|---|---|---|
| Requests, collections, environments, history, cookies | Stored on the device (SwiftData) or in folders the user picks | No — never leaves the device except to servers the user chooses |
| Secret values and OAuth tokens | Device Keychain, not synchronized (ADR-0031) | No |
| Network requests | Sent directly to the addresses the user enters; Eonix never receives a copy | No |
| Purchases | None: the app is free, with no in-app purchases and no StoreKit code (ADR-0046) | — |
| MetricKit diagnostics | Kept in the app's container; shared only if the user exports diagnostics and sends them | No — user-initiated, optional support request |
| Crash reports | Only Apple's opt-in crash reporting through App Store Connect | No (collected by Apple, not by the app) |
| Analytics, advertising, tracking, third-party SDKs | None exist in the app (`Package.swift` has no dependencies; B13) | — |

## Consistency checks

- `RequestPad/Resources/PrivacyInfo.xcprivacy`: `NSPrivacyTracking = false`, no tracking domains, no collected data
  types; required-reason APIs UserDefaults (CA92.1) and File Timestamp (C617.1) — verified in Phase 7 (DECISIONS).
- `PRIVACY.md` (published at https://requestpad.eonix.lk/privacy) states the same.
- Tracking: **No** (no App Tracking Transparency prompt; nothing to link across apps).
- The archive privacy report in Xcode Organizer should list only the two required-reason API categories above
  (HUMAN_HANDOFF H10).
