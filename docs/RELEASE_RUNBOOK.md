# Release runbook — RequestPad (B11, Phase 11)

Every command below was run on the development Mac (Xcode 27.0, macOS 27) unless marked **👤 human**: those need the
Apple Distribution certificate, App Store Connect access or a device. Scripts start with `set -euo pipefail`, so a
failing `xcodebuild` fails the script.

## 1. Environment

```bash
xcode-select -p && xcodebuild -version
```
```bash
scripts/bootstrap.sh
```
```bash
xcrun simctl list devices available
```
`bootstrap.sh` fails unless Xcode 26 or later is active and `swift-format` is available, then resolves packages.
Command-line builds use the private DerivedData folder `build/DerivedData` (ADR-0036), so they never disturb other
Xcode work on the machine.

## 2. Checks and tests

```bash
scripts/lint.sh
```
```bash
scripts/test.sh --platform ios
```
```bash
scripts/test.sh --platform macos --sanitizers --analyze
```
- `lint.sh`: swift-format, setup placeholders, unfinished-work markers, forbidden APIs (web views, dynamic
  loading, arbitrary loads) and `check-metadata.py`.
- `test.sh` runs the package suites, app unit tests and UI tests with coverage (result bundles in `build/`) and enforces
  the coverage gate.
- On a Mac where XCUITest cannot get an app window, add `--skip-macos-ui` and do the macOS UI pass by hand (H7).

## 3. Store assets (when the UI changed)

```bash
scripts/screenshots.sh --platform all
```
```bash
python3 scripts/check-metadata.py
```
- Screenshots use dedicated simulators, so the owner's simulators are never touched. On the Mac, leave the display
  unlocked and don't move windows during the run (about 2 minutes).
- Then update `docs/AppStore/metadata.md` and re-check the claims table and `docs/AppStore/review_notes.md` against
  the build.

## 4. Version and build number

- `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` are set in `Config/Base.xcconfig`; one value covers every
  platform (Universal Purchase).
- Increment `CURRENT_PROJECT_VERSION` before **every** upload; App Store Connect rejects a reused build number.
- Change `MARKETING_VERSION` for each release: 1.0.1 for fixes, 1.1.0 for features.
- Commit the bump as `chore(release): 1.0.0 (build N)`.

## 5. Archive and export (👤 human: needs the Apple Distribution certificate)

```bash
scripts/archive.sh --platform all
```
This runs `lint.sh`, then for iOS and macOS:
- `xcodebuild archive … -configuration Release -archivePath build/<platform>.xcarchive`;
- `xcodebuild -exportArchive` with `scripts/exportOptions-appstore.plist` (method `app-store-connect`, destination
  `export`, automatic signing, team 835LNLUPAJ, symbols uploaded), producing `build/ios-export/` and
  `build/macos-export/`.

Before uploading, check:
- no `get-task-allow` in the signed entitlements (H10.2);
- the archive privacy report lists only UserDefaults (CA92.1) and File Timestamp (C617.1) (H10.1);
- `lipo -archs` on the macOS executable prints `x86_64 arm64`.

## 6. Upload (👤 human)

Use Xcode Organizer (Distribute App → App Store Connect → Upload) or Transporter with the exported `.ipa` and `.pkg`.
Alternatively, use an authenticated export with an App Store Connect API key kept **outside the repository**:
```bash
xcodebuild -exportArchive -archivePath build/ios.xcarchive -exportOptionsPlist scripts/exportOptions-upload.plist -exportPath build/ios-upload -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"
```
- `exportOptions-upload.plist` is the App Store plist with `destination` set to `upload`; create it only on the
  release machine.
- Never commit the `.p8` key.
- Never use `altool`.

## 7. Verify before submitting (👤 human)

1. App Store Connect → the build is processed, with no ITMS-91xxx (privacy manifest) warnings in the email.
2. TestFlight internal smoke test on an iPhone, an iPad and a Mac:
   - Load Sample Data, then send a request;
   - buy Pro in the sandbox, then Restore;
   - run a Shortcut;
   - use the menu bar item.
3. `docs/APP_REVIEW_CHECKLIST.md`: every row is ✅ or has its 👤 step done.
4. Paste the metadata from `docs/AppStore/metadata.md` and the notes from `docs/AppStore/review_notes.md`, and upload
   the screenshots from `docs/AppStore/screenshots/`.
5. Answer App Privacy as in `docs/AppStore/privacy_labels.md` and the age rating as in `metadata.md`.

## 8. Submit (👤 human)

- **iOS/iPadOS:** submit with **Phased Release for Automatic Updates** (7 days). Pause the rollout if the crash rate
  rises.
- **macOS:** submit with **Manually release this version**. Release it after the iOS version is approved, so the
  Universal Purchase launches together.
- Attach the in-app purchases to the first submission (App Store Connect requires this for new IAPs).
- After approval: tag the submitted commit, then push the tag.
  ```bash
  git tag -a v1.0.0 -m "RequestPad 1.0.0"
  ```
  ```bash
  git push origin v1.0.0
  ```

## 9. Rollback

A shipped binary cannot be pulled back to an earlier build. The options are:
- **Pause** the phased release (iOS) to stop automatic updates.
- **Remove from sale** (App Store Connect → Pricing and Availability) in a severe case; people who already have the
  app keep it.
- **Ship a hotfix** (section 11).
- If a failure is caused by server-side App Store data (products, prices), fix it in App Store Connect; no binary is
  needed.

---

## Post-launch operations (Phase 11)

### 10. Weekly review (every Monday)

- **Xcode Organizer → Crashes and Hangs** (both platforms, the last 7 days):
  - triage every new signature;
  - anything affecting more than 0.1% of sessions, or any crash at launch, is P1 and gets the hotfix path.
  - Record the result in `docs/SDLC_LOG.md` under "Operations".
- **MetricKit:**
  - Organizer → Energy, Launch Time, Memory, Disk Writes: compare against the budgets in `docs/TEST_PLAN.md` (cold
    launch < 1.0 s).
  - Users' own diagnostic payloads arrive only when they send Settings → Export Diagnostics with a support email.
- **App Store Connect → Ratings and Reviews:** reply to 1–2★ reviews that describe a bug, pointing to the fix or to
  support.
- **Subscriptions:** App Store Connect → Sales and Trends / Subscriptions (trial conversion, churn). No analytics are
  added to the app.

### 11. Hotfix path (1.0.1 in under 48 hours)

1. Reproduce the problem. Write a failing test first (unit, end-to-end or UI).
2. Branch: `git switch -c hotfix-1.0.1 v1.0.0`. Fix the issue with the smallest change, then run section 2.
3. Bump the version: `MARKETING_VERSION = 1.0.1`, `CURRENT_PROJECT_VERSION` + 1. Write "What's New" as one specific
   line ("Fixes a crash when …").
4. Run sections 5–7, then submit. Ask for **expedited review** (App Store Connect → Contact Us → Request Expedited
   Review) for crashes or data loss.
5. Merge `hotfix-1.0.1` into `main` and tag `v1.0.1`.
   - Target: fix merged within 24 h; submission within 48 h of the report.

### 12. Support

- **Inbox:** support@eonix.lk. **SLA:** first reply within **2 business days**; P1 reports (crash, data loss, a
  purchase not unlocking) the same business day.
- Ask for the app version, device and OS, and optionally an exported diagnostics file. Never ask for secrets or
  request contents.
- **Purchase problems:**
  - first, Settings → Restore Purchases;
  - refunds go through Apple (reportaproblem.apple.com); the developer cannot issue them.
- Keep a list of recurring questions to feed `SUPPORT.md` and the 1.x roadmap.

### 13. Pricing

- Change prices and run experiments **only in App Store Connect**: price schedules, introductory and promotional
  offers, offer codes, and product page optimization.
- The app reads everything from StoreKit and never hard-codes prices, so no build is needed.
- Never add external purchase links or non-IAP unlocks (B13).

### 14. 90-day roadmap (V1.x; from PRD §5 "Out of scope" — not built in V1)

Ranked by user value against review and security risk. Each item needs its own discovery, threat model and ADR
before work starts.

| Window | Candidate | Notes |
|---|---|---|
| Days 1–30 | Stability: fixes from Organizer and support; 1.0.x | Takes priority over everything below |
| Days 1–30 | Widgets (recent request status, one-tap send via App Intents) | Reuses the Shortcuts intent; no background refresh needed |
| Days 30–60 | WebSocket requests | `URLSessionWebSocketTask`; new `.bru` type; UI for message streams |
| Days 30–60 | Local mock responses (per-request stub served by Local Echo, loopback only) | Must stay declarative — no scripting (Guideline 2.5.2) |
| Days 60–90 | iCloud sync of app data (CloudKit, private database) | Needs privacy-label review; secrets stay device-only |
| Days 60–90 | Proxy settings per environment | System proxy is already honored by URLSession |
| Not planned | JavaScript scripts, traffic capture, team/cloud accounts, HTML rendering, visionOS | Review (2.5.2, 4.2), sign-in (B13) or web-view (ADR-0011) conflicts |
