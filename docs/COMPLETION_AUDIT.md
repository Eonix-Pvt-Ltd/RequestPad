# Completion audit and handoff — RequestPad 1.0.0

State on 2026-09-26, after Phase 11 (main at the Phase 11 merge). The agent built and verified Phases 0–8. Its
deliverables for Phases 9–11 are complete. What is left needs a person: an Apple account, devices, hosting and App
Review. Every open item is listed with the `docs/HUMAN_HANDOFF.md` entry that closes it.

Legend: ✅ done and verified by the agent · 👤 open, needs a human (handoff item) · ⚠️ known gap, explained.

## 1. Completion audit

### Features (PRD §6 acceptance criteria)
- ✅ Every V1 acceptance criterion has an automated, passing test except X01.4 (relaunch restoration), which is a
  manual check (H9.5). Traceability: `docs/TEST_PLAN.md`.
- ✅ Every description claim is mapped to evidence (`docs/AppStore/metadata.md`, claims table).
- 👤 Manual checks on devices: H2 (minimum OS), H3 (VoiceOver and keyboard), H6 (device-only services), H9
  (Shortcuts, menu bar, Services, login item).

### Files
- ✅ README (build, test, release, screenshots), `.gitignore`, `LICENSE`, `SECURITY.md`, `RUNBOOK.md`,
  `PRIVACY.md`, `TERMS.md`, `SUPPORT.md`, `CHANGELOG.md`.
- ✅ Swift package manifest. There are no third-party dependencies, so no lockfile is needed.
- ✅ SwiftData schema with versioned migrations (ARCHITECTURE).
- ✅ Sample data ("Load Sample Data") exercises every feature offline.
- n/a `.env.example` and Dockerfile: this is a native app with no server and no environment secrets. The App Store
  Connect API key for `upload.sh` stays outside the repository.

### Code quality
- ✅ No TODO/FIXME/placeholder markers (`lint.sh` enforces this).
- ✅ swift-format `--strict` clean; Swift 6 strict concurrency; warnings are errors.
- ✅ Static analysis clean on iOS and macOS.
- ✅ Structured logging through `os.Logger` with private interpolation for user data. MetricKit diagnostics.
- ✅ Loading, empty, error and success states for every screen (Phase 4, ADR-0038).
- ✅ Layout verified on iPhone, iPad and Mac, including the largest accessibility text size (UI tests and 15 store
  screenshots).

### Tests (last results: `docs/SDLC_LOG.md` Phase 8)
- ✅ **iOS:** package 343 passed (2 skipped by design), app on iPhone 76/76, app on iPad 76/76.
- ✅ **macOS:** package 345, app 74. ASan and TSan 338 each (7 skipped by design); fuzzing 15 parsers.
- ✅ **Coverage:** RPCore 96.84%, RPData 93.47%, RPServices 91.88%, RPStore 99.47% (gate 80%).
- ✅ Automated accessibility audits run on every screen (iOS).
- ⚠️ **macOS UI tests** can't drive the app on the build Mac (ADR-0037). They need another Mac or CI (H7).
- 👤 **Full macOS `test.sh` re-run** once after a restart (H7, Phase 8 addition).
- 👤 **CI has never run green:** GitHub Actions is blocked by account billing (H5). The pipeline exists
  (`.github/workflows/ci.yml`: lint, tests, build, gitleaks, semgrep).

### Security (`SECURITY.md`, ADRs 0010, 0031, 0033, 0035, 0043)
- ✅ **Secrets:** Keychain only, never synchronized, never in files, exports, history or logs. Revealing one needs
  Face ID or the passcode.
- ✅ **Network:** ATS stays on. There are no arbitrary loads; plain HTTP is allowed only for loopback and private
  ranges.
- ✅ **No risky code paths:** no web views, dynamic code loading or scripting (`lint.sh` enforces this).
- ✅ **Local Echo** is loopback only, off by default, and fuzzed.
- ✅ **Sandbox and signing:** App Sandbox with minimal entitlements, verified in the distribution-signed exports
  (SDLC_LOG Phase 9). Hardened runtime on macOS; `get-task-allow` is off.
- ✅ **Scans:** gitleaks (history and working tree) and semgrep: 0 findings (Phase 7).
- ✅ **Untrusted input:** every parser is fuzzed, with depth and expansion limits (ADR-0027, ADR-0030).
- 👤 Archive privacy report in Xcode Organizer (H10.1).

### Observability
- ✅ `os.Logger` categories, MetricKit payload collection, and user-initiated redacted diagnostics export.
- ✅ **Post-launch monitoring:** Xcode Organizer for crashes, hangs and metrics, reviewed weekly
  (`docs/RELEASE_RUNBOOK.md` §10).
- n/a No server, so there are no health endpoints, uptime alerts or backups. User data lives on user devices; export
  and import is in Settings.

### Release
- ✅ Release builds with 0 warnings. The macOS binary is universal. Distribution-signed exports for version 1.0.0 (1).
- ✅ **Store material:** icon, 15 screenshots, 3 IAP review screenshots, metadata, review notes, privacy labels,
  review checklist, prepared review replies, TestFlight plan.
- 👤 **Release steps:** upload and beta (H12), store listing (H11), in-app purchases (H8), submit and release
  (H13), legal and support pages live (H1).

## 2. File tree

| Path | Purpose |
|---|---|
| `RequestPad.xcodeproj` | Xcode project: one multiplatform app target plus unit and UI test targets. Extend it in Xcode; never regenerate it. |
| `RequestPad/` (45 files) | App target: `Shared/App` (models, runtime, screenshot director), `Shared/Views` (SwiftUI screens), `Shared/Intents` (Shortcuts), `Shared/Mac` (menu bar, Services, login item), `AppIcon.icon`, `Info.plist`, entitlements, privacy manifest, String Catalog |
| `Sources/RPCore` (45) | Models, parsers (JSON, YAML, `.bru`, cURL, OpenAPI, Postman, GraphQL, JSONPath), variables, assertions, cookies, OAuth |
| `Sources/RPData` (12) | SwiftData store, Keychain secret store, preferences, bookmarks |
| `Sources/RPServices` (18) | HTTP client, folder collections and file watching, Local Echo, sample data, diagnostics, export/import/erase |
| `Sources/RPStore` (7) | StoreKit 2 entitlements, feature gate, paywall copy, product IDs |
| `Sources/RPUI` (8) | Shared SwiftUI components (JSON tree, badges, colours) |
| `Tests/` (65) | Swift Testing suites for the package: unit, fuzzing, performance, fixtures |
| `RequestPadTests/`, `RequestPadUITests/` | App-hosted tests (end-to-end against Local Echo, StoreKit, system integrations) and XCUITests (flows, accessibility audits, store screenshots) |
| `Config/` | xcconfig files: version, build number, deployment targets, warnings as errors |
| `scripts/` | `bootstrap`, `lint`, `test`, `sync-strings`, `archive`, `upload` (human-run), `screenshots`, `check-metadata.py`, export options |
| `.github/workflows/ci.yml` | CI: lint, tests, build, secret scan, SAST |
| `docs/` | PRD, architecture, decisions (ADR-0001–0045), SDLC log, test plan, handoff, review checklist, release runbook, support replies, this audit |
| `docs/AppStore/` | Metadata, review notes, privacy labels, TestFlight plan, prepared review replies, screenshots, IAP review screenshots |
| Root `*.md` | README, `SECURITY.md`, `RUNBOOK.md` (operations and secrets), `PRIVACY.md`, `TERMS.md`, `SUPPORT.md` (the last three are published at requestpad.eonix.lk), `CHANGELOG.md`, `LICENSE` |

## 3. Run locally

```bash
scripts/bootstrap.sh
```
```bash
open RequestPad.xcodeproj
```
Choose the RequestPad scheme and a destination (My Mac, or an iPhone or iPad simulator), then Run. Purchases use the
local StoreKit configuration. Checks:
```bash
scripts/lint.sh
```
```bash
scripts/test.sh --platform ios
```
```bash
scripts/test.sh --platform macos --skip-macos-ui --sanitizers --analyze
```

## 4. Release ("deploy")

Follow `docs/RELEASE_RUNBOOK.md` §4–9 in order:
1. bump the build number;
2. `scripts/archive.sh`;
3. `scripts/upload.sh`;
4. TestFlight;
5. submit with manual release (phased on iOS);
6. tag.

HUMAN_HANDOFF H11–H13 has the App Store Connect steps.

## 5. Operations summary

- **Crashes, hangs, launch time, memory:** Xcode Organizer (both platforms), reviewed weekly. Record each review
  under "Operations" in `docs/SDLC_LOG.md`.
- **Users' diagnostics:** they arrive only by email when a user exports them (Settings → Support → Export
  Diagnostics).
- **Support:** support@eonix.lk, first reply within 2 business days. Templates in `docs/SUPPORT_REPLIES.md`.
- **Reviews, sales, subscriptions:** App Store Connect. Prices and offers are changed there only; no build is
  needed.
- **Incidents:** `RUNBOOK.md` (detect → mitigate → communicate → fix → postmortem) and the hotfix path (runbook §11).

## 6. Known limitations (V1)

- **Plain `http://` to public hosts is blocked** by App Transport Security; so are names like `server.lan` that
  resolve to private IPs. Use `https://`, an IP address or a `.local` name (ADR-0010).
- **HTTPS servers with self-signed or otherwise untrusted certificates fail.** There is no "ignore certificate
  errors" switch, by design. A workaround is to install the certificate as trusted on the device. Candidate for 1.x
  with a per-host, per-certificate trust prompt.
- **No client certificates (mutual TLS).**
- **JavaScript in `.bru` files is kept but never run.** `script:*` and `tests` blocks are preserved as text, so
  scripted Bruno collections behave differently (PRD §5, `SUPPORT.md`).
- **YAML** is a supported subset: block and flow styles, and anchors and aliases with an expansion cap. Tags
  outside the core schema are rejected with a clear error (ADR-0014).
- **Not in V1:** WebSocket, gRPC, mock servers, proxies and capture, iCloud sync of app data, widgets, HTML
  preview, visionOS (PRD §5).
- **Not yet tested:** iOS 17 and macOS 14 on real devices (only the iOS 27 runtime is installed, H2), and device
  launch-time budgets (H10.3).

## 7. Recommended next phase (1.x, ranked by user impact and risk)

1. **Stability from real use:** Organizer crashes and support reports (runbook §10–11). Highest impact, lowest risk.
2. **Trusting a self-signed certificate** per host, with an explicit prompt showing the fingerprint. This is the
   most likely developer complaint. It needs a threat model covering MITM risk and how to revoke trust.
3. **Widgets** reusing the Shortcuts intent (runbook §14).
4. **WebSocket requests.**
5. **Declarative mock responses in Local Echo** (loopback only, no scripting).
6. **iCloud sync of app data** (CloudKit private database; secrets stay on the device). This changes the privacy
   labels, so it needs a new privacy review.

## 8. Open security questions (revisit at the next scale milestone)

- **Diagnostics by email:** exported diagnostics are redacted, but users send them by ordinary email. If support
  volume grows, consider a documented retention and deletion policy for the support inbox. `docs/SUPPORT_REPLIES.md`
  already says to delete emails containing secrets.
- **Folder collections are plain text:** secrets never go into `.bru` files, but request bodies and URLs do. Users
  syncing folders through third-party services should know this. Consider an in-app note when a folder collection
  is created.
- **Trusting a certificate** (next phase, item 2) would be the app's first feature that weakens TLS on purpose. It
  needs its own threat model before any code.
- **CI security scans** (gitleaks, semgrep) have only run locally, because CI is blocked (H5). Confirm they run on
  every push once billing is fixed.
