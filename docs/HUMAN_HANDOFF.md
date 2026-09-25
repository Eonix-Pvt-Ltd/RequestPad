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

_Further items (App Store Connect products, sandbox purchase test, TestFlight, submission) are added in Phases 5–10._
