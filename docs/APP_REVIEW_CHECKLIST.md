# App Review compliance checklist — RequestPad 1.0.0 (B10)

Status key: **✅ verified** by the agent in this repository (evidence linked) · **👤 human** needs a device, a
certificate or App Store Connect (listed in `docs/HUMAN_HANDOFF.md`). Update this file before every submission; the
evidence here is what the agent uses to answer a rejection (Phase 10).

| # | Guideline | Status | Evidence |
|---|---|---|---|
| 1 | 2.1 Completeness | ✅ / 👤 | No placeholders: `scripts/lint.sh` placeholder check (ADR-0020). Full suites green (`docs/SDLC_LOG.md`, Phase 8). Demo data without login: onboarding and Settings → Try It Out → Load Sample Data (`testSampleRequestSendsToLocalEcho`). 👤 Physical-device runs on iPhone, iPad and Mac (H2, H6, H10); legal/support links live (H1). |
| 2 | 2.3 Accurate metadata | ✅ | Screenshots produced from this build by `scripts/screenshots.sh` (real UI through `ScreenshotDirector`, no prices). Description claims table in `docs/AppStore/metadata.md`. `scripts/check-metadata.py`: name 22 characters, keywords 98, no other apps' or platforms' names, no prices. Review notes (`docs/AppStore/review_notes.md`) cover every feature, the menu bar, Services, login item and Pro sandbox. Subtitle and keyword deviations from Part A approved by the owner (ADR-0044). |
| 3 | 2.4.5 macOS | ✅ | App Sandbox on (`RequestPad.entitlements`); no helper installers; Open at Login is an off-by-default toggle using `SMAppService` (`loginItemFollowsTheSystemStatus`); no self-update or Sparkle (no package dependencies); one bundle with String Catalogs; built for macOS 14+ (ADR-0004). |
| 4 | 2.5.1 / 2.5.2 | ✅ | Public APIs only (no `dlopen`, private selectors or runtime class lookup — semgrep/grep review, ADR-0043). No downloaded or executed code, no interpreter; Local Echo reflects requests as JSON and evaluates nothing (`Sources/RPServices/Echo`; review notes). Assertions and JSONPath are declarative parsers, not scripts. |
| 5 | 2.5.4 Background | ✅ | No `UIBackgroundModes` in `RequestPad/Info.plist`. Shortcuts action runs only on user invocation; menu bar item only while the app runs (review notes "BACKGROUND"). |
| 6 | 3.1.1 / 3.1.2 IAP | ✅ / 👤 | All unlocks via StoreKit 2 (`EntitlementManager`, ADR-0040); Restore Purchases in the paywall and Settings; paywall shows price, period, trial, Terms and Privacy links (`PaywallView`, `testPaywallPurchaseUnlocksPro`); monthly is the shortest period (≥ 7 days); free tier fully usable (`freeTierAllowsOneCollectionAndAsksForPro`); Universal Purchase (single bundle ID `lk.eonix.RequestPad`). 👤 Products created in App Store Connect and the sandbox purchase test (H8). |
| 7 | 4.0 Design | ✅ | SwiftUI native controls only; no web views anywhere (no `WebKit`, `WKWebView` or `SFSafariViewController` in the source, ADR-0011). OAuth sign-in uses the system `ASWebAuthenticationSession`. |
| 8 | 4.2 Minimum functionality | ✅ | Native, offline tool: HTTP/GraphQL client, streaming large responses to disk, Keychain secrets, `.bru` folder collections with change detection, runner, Shortcuts, menu bar and Services — see PRD "Why this is not a template app" and the claims table. |
| 9 | 4.2.3 Standalone | ✅ | Works with no external service: Local Echo and sample data (review notes). No companion app or server. |
| 10 | 4.8 Login services | ✅ n/a | No accounts or third-party login. OAuth 2.0 is a request-authorization feature against the user's own APIs, not app sign-in. |
| 11 | 5.1.1 Privacy | ✅ / 👤 | Privacy Policy link in metadata, Settings and the paywall (`AppLinks.privacy`). Local Network purpose string in `Info.plist`, preceded by an in-app explanation. Pickers only (security-scoped bookmarks, no broad file access). No login. 👤 Pages published at the URLs (H1). |
| 12 | 5.1.2 Data use and sharing | ✅ | No third-party or AI data sharing; requests go only to the addresses the user enters. No system feature (Face ID, Local Network, Shortcuts) is required to use the app. |
| 13 | Privacy manifest and labels | ✅ / 👤 | `PrivacyInfo.xcprivacy`: no tracking, no collected data, required reasons CA92.1 and C617.1 (DECISIONS "Verified (Phase 7)"). Labels "Data Not Collected" (`docs/AppStore/privacy_labels.md`). 👤 Archive privacy report (H10.1). |
| 14 | Export compliance | ✅ | `ITSAppUsesNonExemptEncryption = NO` in `Info.plist`; ADR-0018 re-checked in Phase 7 (OS TLS and hashing only). |
| 15 | Age rating 4+ | ✅ / 👤 | No objectionable content; no web browser. 👤 Answer the questionnaire as in `metadata.md` "Other fields". |
| 16 | Accessibility | ✅ / 👤 | `performAccessibilityAudit` on every screen in UI tests (`AccessibilityAudit.swift`, ADR-0038); `testLargestDynamicTypeSizes`. 👤 Manual VoiceOver and keyboard pass (H3) and macOS UI pass (H7). |
| 17 | SDK and binary | ✅ | Xcode 27.0 with the OS 27 SDKs, which meets "Xcode 26 or later" (ADR-0016). macOS binary is universal (`lipo -archs` → `x86_64 arm64`, re-checked on the Phase 8 Release build, `docs/SDLC_LOG.md`). |

## Other submission checks

- `LSApplicationCategoryType = public.app-category.developer-tools` in `Info.plist` (required for Mac uploads; added
  in Phase 8), matching the Developer Tools category.
- `NSAllowsArbitraryLoads` is absent; HTTP to local addresses via `NSAllowsLocalNetworking` (ADR-0010).
- The app icon is an Icon Composer `.icon` bundle with Default, Dark, Clear and Tinted renditions (ADR-0044).
- Demo instructions do not depend on the network: every sample request targets `127.0.0.1`.

## Responding to a rejection

1. Find the guideline in the table and quote the evidence (a test name, file or ADR) in the Resolution Center reply.
2. If the reviewer could not find a feature, update `docs/AppStore/review_notes.md` with the exact path and reply
   with it; there is no need to resubmit a binary for a notes-only issue.
3. If a real defect is reported, follow the hotfix path in `docs/RELEASE_RUNBOOK.md`.
