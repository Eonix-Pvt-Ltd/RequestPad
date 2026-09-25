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

_Further items (App Store Connect products, sandbox purchase test, TestFlight, submission) are added in Phases 5–10._
