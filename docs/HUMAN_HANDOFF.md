# Human Handoff

Steps the agent cannot perform (Apple Developer account actions, physical hardware, hosting, Apple's review). Each
item lists exactly what to do. Items are added as phases complete; nothing here is recorded as done until a human
confirms it.

## Open items

### H1 — Publish legal and support pages (needed before TestFlight external testing)
Publish these files as web pages at exactly these URLs (the app, paywall and App Store metadata link to them):

| Source file | URL |
|---|---|
| `PRIVACY.md` | https://requestpad.eonix.lk/privacy |
| `TERMS.md` | https://requestpad.eonix.lk/terms |
| `SUPPORT.md` | https://requestpad.eonix.lk/support |

Confirm `support@eonix.lk` receives mail. Have the privacy policy and terms reviewed by someone qualified for your
jurisdiction — they are written to match the app's behavior, not reviewed by a lawyer.

**Status 2026-09-27 — published and verified by the agent:**
- `/privacy`, `/terms` and `/support` return 200 over HTTPS, and their text matches `PRIVACY.md`, `TERMS.md` and
  `SUPPORT.md` word for word (including the Phase 11 corrections).
- `http://` redirects to `https://` (308), with HSTS (2 years, includeSubDomains, preload), a strict CSP, nosniff and
  referrer-policy.
- Every link resolves.
- The home and `/pricing` pages match the app: features, free-tier limits, Pro history of 1,000 requests, prices,
  trial and renewal terms.

**Still open:**
- Confirm `support@eonix.lk` receives mail (send yourself a test).
- Legal review of the privacy policy and terms.
- The source files' "_Published at …_" line appears as visible text on the published pages. Harmless; hide it on
  the site if you prefer.
- At release (H13 step 7), replace "Coming soon to the App Store" with the App Store link.

### H2 — Test on minimum OS versions
The build Mac has only the iOS 27 simulator runtime. Install an iOS 17 runtime (Xcode → Settings → Components) or
use a device on iOS/iPadOS 17, and a Mac on macOS 14, then run the app and `scripts/test.sh`. Record results in
`docs/SDLC_LOG.md`.

### H3 — Manual accessibility pass (B8)
VoiceOver full pass plus Accessibility Inspector audit on iPhone, iPad and Mac for every screen, including text
contrast in the macOS translucent sidebar with different windows/wallpapers behind it (automated contrast audit is
exempt there — ADR-0019). Record findings in `docs/SDLC_LOG.md`.

### H4 — Confirm CI runner Xcode
CI selects the newest Xcode on GitHub's `macos-26` image. The project was created with Xcode 27 (project format
objectVersion 110). If CI reports the project cannot be opened, switch `runs-on` to an image that ships Xcode 27.

### H5 — Restore GitHub Actions and confirm CI green (blocks Phase 9)
CI jobs are refused for billing reasons (failed payment / spending limit). Fix under GitHub → Settings → Billing &
plans, then re-run the latest `main` workflow (`gh run rerun <id>` or push). Phase 1's "CI green" exit criterion
remains open until this passes; record the run ID in `docs/SDLC_LOG.md`.

### H6 — Device-only checks for Phase 3 services (after Phase 4 UI exists)
On a physical iPhone or iPad:
1. Send a request to a LAN address (e.g. a dev server at `http://192.168.x.y:port`). Expect RequestPad's explainer
   first, then the system Local Network prompt; after allowing, the request succeeds. After denying, the error reads
   "RequestPad doesn't have permission to reach …" (F01.9, `ServiceError.localNetworkDenied`).
2. Reveal a secret variable: Face ID / Touch ID / passcode prompt appears with the RequestPad usage text (F04.5).
3. OAuth 2.0 authorization code + PKCE against a real provider (e.g. a test tenant): the system sign-in sheet opens,
   the token is stored, and the request is sent with it (F05.4).
Record results in `docs/SDLC_LOG.md`.

### H7 — macOS UI tests and manual macOS UI pass (Phase 4)
On the build Mac, SwiftUI opens no window for `lk.eonix.RequestPad` when the app is launched directly (as XCUITest
does), even for a minimal app with that bundle ID, so the macOS UI tests cannot drive the app there (ADR-0037).
The same flows pass on iPhone and iPad, and macOS is covered by the app-hosted unit tests.
1. Quit RequestPad, delete `~/Library/Containers/lk.eonix.RequestPad/Data/Library/Saved Application State/`
   (Finder → Go to Folder; the shell is blocked from reading it), then run
   `xcodebuild test -project RequestPad.xcodeproj -scheme RequestPad -destination 'platform=macOS' -only-testing:RequestPadUITests`.
   If they still find no window, run them on another Mac or on CI and record the result.
2. Manually on macOS: onboarding → Load Sample Data; open "Echo a GET" and press ⌘↩; ⌘N (New Request), ⌥⌘N (New
   Window), ⌘S, ⌘E (environment picker), ⌘L; Settings (⌘,) → Export/Import/Erase; import a cURL command, an OpenAPI
   file and a Postman export; run a folder (Pro via `-UITestPro` in a Debug build) and export results.
Record results in `docs/SDLC_LOG.md`.

**Phase 8 addition:** after the next restart of this Mac, run
`scripts/test.sh --platform macos --skip-macos-ui --sanitizers --analyze` once and record the result in
`docs/SDLC_LOG.md` — the xcodebuild macOS test runner stopped connecting after an automation-mode timeout on
2026-09-26 (SDLC_LOG Phase 8).

### H8 — App Store Connect in-app purchases (before TestFlight, Phase 9)
1. In App Store Connect → RequestPad → Monetization, create the subscription group **Pro** with
   `lk.eonix.requestpad.pro.yearly` ($19.99/year) and `lk.eonix.requestpad.pro.monthly` ($2.99/month), each with a
   7-day free trial introductory offer, and the non-consumable `lk.eonix.requestpad.pro.lifetime` ($39.99). Match the
   IDs exactly (`ProductID`); prices, periods and the trial should match `RequestPadTests/StoreKit/Products.storekit`.
2. Add display names and descriptions (`docs/AppStore/metadata.md` → "In-app purchase display names") and the
   review screenshot for each product from `docs/AppStore/iap-review/` (`yearly.png`, `monthly.png`,
   `lifetime.png`: the real paywall with that product selected, made by `scripts/screenshots.sh`). If you set
   different prices, change them in `RequestPadTests/StoreKit/Products.storekit` and the fake store
   (`Sources/RPStore/StoreClient.swift`) first, then recapture. Submit the products with the first app version.
3. Accept the Paid Apps agreement and complete tax and banking (purchases do not work in TestFlight otherwise).
4. With a Sandbox Apple Account on a device: buy each product, cancel, restore on a second device (Pro unlocks
   there, X03.3), use Ask to Buy with a family sandbox account, and refund via the Sandbox account settings. Record
   results in `docs/SDLC_LOG.md`.

### H9 — Shortcuts, menu bar, Services and login item (Phase 6, manual)
1. **Shortcuts** (iPhone and Mac, with Pro): in the Shortcuts app add "Send Request", pick a saved request (and
   optionally an environment), run it with RequestPad closed; expect a dialog like "200 OK · 42 ms" and the Response
   properties (Status Code, Body) available to the next action. Without Pro, expect the "part of RequestPad Pro"
   error. Try the App Shortcut phrase "Send a request with RequestPad" with Siri.
2. **Menu bar Quick Send** (Mac, Pro): Settings › Mac › Menu Bar Quick Send; click the paper-plane item. Measure the
   popover opening with Instruments (SwiftUI / Time Profiler) — target < 100 ms (P09.2). Send a saved request with a
   chosen environment and a typed URL; use "Open in RequestPad" with all windows closed.
3. **Services** (Mac): select a URL in TextEdit or Safari → app menu › Services › "Send URL with RequestPad"; a new
   unsaved request opens with that URL. If the item is missing, log out and in (the Services list is cached).
4. **Launch at login** (Mac): turn on Settings › Mac › Open at Login, check System Settings › General › Login Items,
   log out and in; turn it off again.
5. **State restoration** (X01.4): with a request selected, quit and relaunch on each platform; the same request opens.
Record results in `docs/SDLC_LOG.md`.

### H10 — Release checks that need your certificates and devices (Phase 7)
1. **Privacy report:** Xcode → Window → Organizer → Archives → select the archive → Generate Privacy Report. Expect
   UserDefaults (CA92.1) and File Timestamp (C617.1) only, no tracking, no collected data.
2. ~~**Distribution signing**~~ — done by the agent in Phase 9 with cloud-managed signing (ADR-0045).
   `get-task-allow = false` on iOS, and the macOS entitlements are exact (SDLC_LOG Phase 9).
3. **Launch time on devices:** Instruments › App Launch on an iPhone, an iPad and a Mac, cold launch. Budget < 1.0 s
   (TEST_PLAN). The iPhone simulator measured 2.83 s (Release, XCTest launch metric, which includes simulator and
   test overhead) — not representative, so the device number decides.
Record results in `docs/SDLC_LOG.md`.

### H11 — App Store Connect listing (Phase 8 assets; before submission)
1. Subtitle and keywords are decided (ADR-0044). `python3 scripts/check-metadata.py` must pass after any edit.
2. Create the app record (bundle ID `lk.eonix.RequestPad`, SKU of your choice, primary language English (U.S.)) and
   enter every field from `docs/AppStore/metadata.md` for the iOS and macOS versions.
3. Upload the screenshots in `docs/AppStore/screenshots/`: `iphone-6.9/` to iPhone 6.9", `ipad-13/` to iPad 13",
   `mac/` to Mac, in file-name order.
4. App Privacy: answer as in `docs/AppStore/privacy_labels.md`, then publish. Age rating: answer as in
   `metadata.md` → 4+.
5. App Review Information: sign-in not required; paste `docs/AppStore/review_notes.md`; add a contact name and phone.
6. Work through `docs/APP_REVIEW_CHECKLIST.md` and `docs/RELEASE_RUNBOOK.md` sections 5–8.

### H12 — TestFlight beta (Phase 9)
The archives and exports for build 1.0.0 (1) are ready in `build/` (`scripts/archive.sh`, verified in SDLC_LOG
Phase 9). The TestFlight text and plan are in `docs/AppStore/testflight.md`.
1. **Before the first upload:** do H11 step 2 (the app record), and do H8 steps 1–3 (in-app purchases, the Paid Apps
   agreement, tax and banking). Without them, purchases cannot be tested in TestFlight.
2. **Upload.** Create an App Store Connect API key (Users and Access → Integrations, role App Manager) and store the
   `.p8` outside the repo. Then run
   `ASC_KEY_PATH=… ASC_KEY_ID=… ASC_ISSUER_ID=… scripts/upload.sh --platform all` and answer `y`. Transporter or
   Xcode Organizer with `build/ios-export/RequestPad.ipa` and `build/macos-export/RequestPad.pkg` also works.
3. **Wait for processing** (5–30 min). Check the email for ITMS-9xxxx warnings. The export-compliance question is
   already answered by `ITSAppUsesNonExemptEncryption = NO`.
4. **Internal group** "Eonix Internal": add the builds and install via the TestFlight app on an iPhone, an iPad and a
   Mac. Run the "What to Test" steps yourself first, including a purchase and Restore; this also covers H8 step 4 and
   H9.
5. **External group** "Public Beta": fill in the Test Information from `testflight.md`, add the build, and submit it
   for Beta App Review (usually within 24–48 h). Invite 10–50 testers by email or public link.
6. **Feedback:** TestFlight → Feedback and Crashes, plus support@eonix.lk. Send the reports to the agent. It fixes P1
   and P2 issues with tests, bumps the build number and re-archives; you upload each new build with step 2.
7. **Exit (human-verified):**
   - the external build is approved;
   - Xcode Organizer → Crashes shows **0 crashes** for the beta builds after at least a week of testing;
   - there are no open P1 or P2 issues.
   Record this in `docs/SDLC_LOG.md` under "Phase 9 — Beta".

### H13 — App Store submission and release (Phase 10)
**Prerequisite:** H12 is complete — the external TestFlight build is approved, there are 0 crashes in Organizer and
no open P1/P2 issues. Submitting before that is possible but skips the beta's safety net.
1. **Choose the build:** the last TestFlight build (same `CURRENT_PROJECT_VERSION` on iOS and macOS). If code changed
   after it, run `scripts/archive.sh` and `scripts/upload.sh` again with a bumped build number.
2. **Complete the version page** for iOS and for macOS (App Store Connect → the app → 1.0.0):
   - everything from H11 (metadata, screenshots, privacy, age rating, review information with
     `docs/AppStore/review_notes.md`);
   - select the build;
   - attach the three in-app purchases (In-App Purchases and Subscriptions → select all);
   - set pricing: Free, all territories you choose.
3. **Release options:**
   - **iOS:** "Automatically release this version" is off; use **Manually release**, and turn on **Phased Release for
     Automatic Updates**.
   - **macOS:** **Manually release this version**.
   - Releasing both manually lets the Universal Purchase go live on both platforms at once.
4. **Final check:** every row of `docs/APP_REVIEW_CHECKLIST.md` is ✅ or its 👤 step is done, and the legal pages
   are live (H1).
5. **Submit** both versions for review (Add for Review → Submit). Review usually takes 24–48 hours.
6. **During review:** forward any message from App Review to the agent. It drafts a reply from
   `docs/AppStore/rejection_responses.md` within 24 hours and fixes the issue if a fix is needed.
7. **After "Pending Developer Release" on both platforms:**
   - release iOS and macOS the same day;
   - tag the submitted commit: `git tag -a v1.0.0 -m "RequestPad 1.0.0"`, then `git push origin v1.0.0`;
   - set the date on the 1.0.0 entry in `CHANGELOG.md`.
   - on requestpad.eonix.lk, replace "Coming soon to the App Store" with the App Store link or badge.
8. **Exit (human-verified):** "Ready for Sale" on both platforms. Then follow `docs/RELEASE_RUNBOOK.md` §10–14
   (post-launch).

_All handoff items are now listed. Post-launch operations live in `docs/RELEASE_RUNBOOK.md`._
