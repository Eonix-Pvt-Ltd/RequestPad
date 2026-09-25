# SDLC Log

## Environment (recorded 2026-09-25)

```
$ xcode-select -p
/Applications/Xcode.app/Contents/Developer
$ xcodebuild -version
Xcode 27.0
Build version 27A266a
$ xcrun simctl list runtimes
iOS 27.0 (27.0 - 24A434) - com.apple.CoreSimulator.SimRuntime.iOS-27-0
```

## Phase 0 — Product definition (2026-09-25)

Deliverables:
- `docs/PRD.md` — identity, personas, free/Pro matrix, out-of-scope, 21 features (F01–F08, P01–P09, X01–X04) with
  acceptance criteria.
- `docs/ARCHITECTURE.md` — modules, Mermaid data-flow and send-sequence diagrams, persistence split, SwiftData schema
  with natural keys, concurrency model, networking rules, threat model (STRIDE-lite), error handling, observability,
  phase plan.
- `docs/DECISIONS.md` — human inputs + ADR-0001…0018.

Research performed:
- Bruno `.bru` grammar read from `usebruno/bruno` `packages/bruno-lang/v2/src/{bruToJson,envToJson,jsonToBru}.js`
  (main branch, 2026-09-25) — informs RPCore codec in Phase 2.
- Bruno variable precedence (docs.usebruno.com/variables/overview) — ADR-0013.
- Apple `NSAllowsLocalNetworking` documentation — ADR-0010.

Exit check — every V1 feature maps to ≥ 1 acceptance criterion:
```
$ for f in $(grep -oE '^### (F|P|X)[0-9]{2}' docs/PRD.md | awk '{print $2}'); do printf "%s=%s " $f $(grep -cE "^- \*\*$f\.[0-9]+" docs/PRD.md); done
F01=10 F02=8 F03=4 F04=6 F05=5 F06=2 F07=2 F08=4 P01=7 P02=3 P03=1 P04=3 P05=2 P06=3 P07=2 P08=2 P09=2 X01=4 X02=3 X03=3 X04=3
```
21 features, 79 acceptance criteria, 0 features without criteria. **Phase 0 exit criteria met.**

## Phase 1 — Scaffold & CI (2026-09-25)

Deliverables:
- Swift package `RequestPadKit` (`Package.swift`, tools 6.2, Swift 6 mode, warnings as errors, iOS 17 / macOS 14)
  with modules RPCore, RPData, RPServices, RPStore, RPUI and five Swift Testing suites; added to the supplied project
  as a local package (ADR-0003). Each module has real, tested foundation code (identifiers/URLs, HTTP method tokens,
  status classes, request limits, storage locations, log redaction, product IDs and free limits, status badge style,
  spacing scale, empty-state view).
- Supplied project extended in place: `Config/{Base,Debug,Release,RequestPad-App}.xcconfig` as base configurations;
  platforms iOS/iPadOS + macOS (visionOS removed); deployment 17.0 / 14.0; Swift 6, strict concurrency complete,
  warnings as errors; macOS universal binary; macOS entitlements file (sandbox, network client/server,
  user-selected read-write, app-scope bookmarks); template code, CloudKit/push entitlements and the
  `remote-notification` background mode removed (ADR-0015); shared `RequestPad` scheme with StoreKit configuration.
- `Info.plist`: ATS local-network exceptions (ADR-0010), `NSLocalNetworkUsageDescription`,
  `ITSAppUsesNonExemptEncryption = NO` (ADR-0018); category Developer Tools; version 1.0.0 (1).
- Resources: `PrivacyInfo.xcprivacy`, `Products.storekit` (excluded from the app bundle), `Localizable.xcstrings`.
- App shell: `LaunchModel` (prepares storage, recoverable failure with retry) and `RootView` (split view with real
  empty states).
- Scripts: `bootstrap.sh`, `lint.sh`, `test.sh` (coverage gate, sanitizers, analyze), `archive.sh`,
  `exportOptions-appstore.plist`. CI: `.github/workflows/ci.yml` (gitleaks job + macOS build/test job).
- Docs: README, LICENSE, CHANGELOG, PRIVACY, TERMS, SUPPORT, SECURITY, RUNBOOK, `.env.example`,
  `docs/TEST_PLAN.md` (79/79 ACs tracked), `docs/HUMAN_HANDOFF.md` (H1–H4), ADR-0019…0023 + 3 "Unverified" entries.

Issues found and fixed during the phase:
- Test used `URL.path()` (percent-encoded) → false failure on "Application Support"; switched to
  `path(percentEncoded: false)`.
- Accessibility audit (macOS): real contrast problem in the empty-state title/icon and an over-narrow sidebar →
  fixed with `RPUI.EmptyStateView` and a 220–260 pt sidebar. Framework-owned elements exempted narrowly (ADR-0019).
- Accessibility audit (iOS): "text may be clipped" on the sidebar row. Manually verified false positive: at
  `accessibility-extra-extra-extra-large` the row wraps to two lines with no clipping (simulator screenshot,
  iPhone 18 Pro, iOS 27.0). Recorded as a per-element `VerifiedExemption`.
- `Products.storekit` was being copied into the app bundle → membership exception added; verified absent from the
  macOS and iOS Release bundles.

Verification (local, Xcode 27.0 / 27A266a, macOS 27.0, simulators iPhone 18 Pro and iPad Pro 11-inch (M5), iOS 27.0):
```
$ scripts/test.sh --sanitizers --analyze
▸ swift-format / setup placeholders / unfinished-work markers   → Lint passed.
▸ Coverage gate (RPCore RPStore ≥ 80%) from package-macos.xcresult
  RPCore: 96.59% (85/88) ok
  RPStore: 100.00% (11/11) ok
▸ Result summary
  app-ipad.xcresult: Passed — passed 6, failed 0, skipped 0
  app-iphone.xcresult: Passed — passed 6, failed 0, skipped 0
  app-macos.xcresult: Passed — passed 6, failed 0, skipped 0
  package-address-sanitizer.xcresult: Passed — passed 34, failed 0, skipped 0
  package-iphone.xcresult: Passed — passed 34, failed 0, skipped 0
  package-macos.xcresult: Passed — passed 34, failed 0, skipped 0
  package-thread-sanitizer.xcresult: Passed — passed 34, failed 0, skipped 0
  (static analysis macOS + iOS: succeeded)
All tests passed.

$ xcodebuild build -configuration Release -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO  → Build Succeeded, 0 warnings
$ xcodebuild build -configuration Release -destination 'generic/platform=iOS'   CODE_SIGNING_ALLOWED=NO  → Build Succeeded, 0 warnings
$ lipo -archs RequestPad.app/Contents/MacOS/RequestPad   → x86_64 arm64
$ PlistBuddy: LSMinimumSystemVersion 14.0, ITSAppUsesNonExemptEncryption false, CFBundleShortVersionString 1.0.0
```

Not exercised in Phase 1 (by design): `scripts/archive.sh` (needs an Apple Distribution certificate — Phase 9),
iOS 17 / macOS 14 runtime testing (HUMAN_HANDOFF H2).
