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

CI status: run 36098984682 on `phase-1-scaffold` — **not executed**. Both jobs were refused by GitHub before start:
"The job was not started because recent account payments have failed or your spending limit needs to be
increased." Phase 1 exit criterion "CI green" is therefore **not met**. Human decision (2026-09-25): merge to `main`
on local evidence; billing to be fixed later (HUMAN_HANDOFF H5). CI must be re-run and green before Phase 9.

## Phase 2 — Core domain (2026-09-25)

Deliverables (RPCore, no UI):
- Models: requests, bodies (JSON/text/XML/form/multipart/GraphQL), auth (bearer/basic/API key/OAuth 2.0), variables
  with Keychain secret references, environments, extractors, assertions, folders, collections, history.
- JSON: order- and literal-preserving value type, strict parser with line/column errors and limits, serializer,
  JSONPath (RFC 9535 subset), semantic equality — all iterative (ADR-0030).
- Variables: `{{var}}` interpolation with Bruno precedence, nesting/cycle/size limits, masking, dynamic values;
  request resolution (header layering, auth inheritance, path params, bodies, default Content-Type, default scheme),
  query-string ↔ table sync, local-address classification matching the ATS exceptions.
- Bruno `.bru`: block-level lossless document model; request, folder/collection and environment codecs with
  minimal-diff writing; `bruno.json`. All 16 request fixtures (Bruno's own + RequestPad's, incl. CRLF) re-encode
  byte-for-byte when unchanged.
- cURL: shell lexer, parser (browser/Postman/docs styles, notices), exporter (empty-header `;` syntax).
- YAML subset parser; OpenAPI 3.0/3.1 (JSON/YAML) and Postman v2.0/2.1 importers.
- Response evaluation (extractors, assertions), RFC 6265 cookie jar, response body decoding/classification.
- GraphQL lexer, syntax validator, introspection schema, completion engine. OAuth 2.0/PKCE helpers (RFC 7636 vector).

Defects found by the Phase 2 tests and fixed:
- cURL export dropped empty-valued headers (`-H 'X: '` removes a header in curl) — property test, fixed with `X;`.
- YAML "billion laughs" stayed under the alias cap but expanded to ~43 M nodes — expanded-node limit (ADR-0027).
- Stack overflow on deeply nested JSON/YAML under ASan and on small stacks — iterative parsers + large-stack YAML
  (ADR-0030); an interim iterative version was 20× slower (buffer copies) and was fixed before merge.
- `.bru` re-encoding added `seq: 1` and normalized unknown enum spellings — minimal-diff writing (ADR-0026).
- OpenAPI self-referencing schemas nested one level too deep; server `Optional<RequestAuth>.none` ambiguity.

Verification (local; Xcode 27.0, macOS 27.0, iPhone 18 Pro / iPad Pro 11-inch (M5) simulators, iOS 27.0):
```
scripts/lint.sh                                             → Lint passed.
Package suite (xcodebuild, RequestPadKit-Package)           → macOS: passed 221, failed 0 · iOS sim: passed 221, failed 0
  (214 Swift Testing tests in 35 suites + 7 XCTest performance tests)
swift test --sanitize=address                               → 214 passed, 0 failed, no sanitizer reports (perf tests skipped)
swift test --sanitize=thread                                → 214 passed, 0 failed, no sanitizer reports (perf tests skipped)
xcodebuild … -enableAddressSanitizer YES / -enableThreadSanitizer YES (macOS) → exit 0 / exit 0
App tests: iPhone passed 6/0 · iPad passed 6/0 · macOS app unit tests (RequestPadTests) exit 0
Coverage (xccov, package-macos): RPCore 95.82% (6287/6561) · RPStore 100% (11/11)
xcodebuild analyze (macOS, iOS)                             → ANALYZE SUCCEEDED ×2
Release builds (macOS, iOS, CODE_SIGNING_ALLOWED=NO)        → Build Succeeded ×2, 0 warnings
Performance (Debug): 10 MB JSON 0.77 s · 2,000-path YAML 0.22 s · OpenAPI import 0.26 s · 1,000 .bru round trips 0.34 s
```

Not run in this phase, with reason:
- macOS **UI** tests (`RequestPadUITests` on macOS): a RequestPad instance launched from the user's Xcode session was
  paused in the debugger (pid 33954, parent Xcode pid 9373), so XCUITest could not launch/terminate the app. App
  code is unchanged since Phase 1, where these tests passed. To re-run: stop the debug session in Xcode, then
  `scripts/test.sh --platform macos`.
- CI: still blocked by GitHub billing (HUMAN_HANDOFF H5).

## Phase 3 — Data & services (2026-09-25)

Deliverables:
- RPData: SwiftData `SchemaV1` + migration plan; `LocalStore` (`@ModelActor`) with natural-key upserts for
  collections, folders, requests, environments, history (pruned), cookies, GraphQL schema cache and drafts;
  `KeychainStore` / `InMemorySecretStore` + `SecretSnapshot`; `DeviceOwnerAuthenticator` / `FakeAuthenticator`;
  security-scoped `SecurityScopedBookmarks` / `PathBookmarks` + `ScopedAccess`; typed `Preferences`;
  `FolderCollectionRepository` (Bruno folders: load with limits and ignore rules, minimal-diff saves, conflict
  detection, folders, environments, renames/moves/deletes, no symlink following); `FolderWatcher`;
  `NativeCollectionExporter` (P01.7); `AppDataTransfer` (export/import, X04.1); `DataEraser` (X04.2).
- RPServices: `LocalEchoServer` (Network.framework, 127.0.0.1 only) with `EchoRequestParser` / `EchoRouter`;
  `URLSessionHTTPClient` (metrics, TLS info, redirect policy, credential stripping, disk spooling > 10 MB, multipart
  streaming, cancellation) + `FakeHTTPClient`; `URLSessionTransport` / `FakeTransport`; `RetryPolicy`;
  `OAuth2Service` (client credentials, authorization code + PKCE, refresh, Keychain tokens) with
  `SystemWebAuthenticator` / `FakeWebAuthenticator`; `GraphQLSchemaService`; `RequestExecutor`; `CollectionRunner`;
  `DiagnosticsService`, `MetricsSubscriber`, `AppPolicies`.
- App: macOS `keychain-access-groups` entitlement, `NSFaceIDUsageDescription`; app-hosted `PlatformIntegrationTests`.
- Every service protocol has a live and a fake implementation: `HTTPClient` (URLSessionHTTPClient / FakeHTTPClient),
  `HTTPTransport` (URLSessionTransport / FakeTransport), `SecretStore` (KeychainStore / InMemorySecretStore),
  `UserAuthenticator` (DeviceOwnerAuthenticator / FakeAuthenticator), `WebAuthenticator` (SystemWebAuthenticator /
  FakeWebAuthenticator), `FolderAccess` (SecurityScopedBookmarks / PathBookmarks), `SchemaCache` / `HistoryRecorder` /
  `CookieStore` (LocalStore; in-memory container in tests), `FileReferenceResolver` (PathFileResolver).

Defects found by Phase 3 tests and fixed:
- macOS Keychain `errSecMissingEntitlement` in the signed app — missing `keychain-access-groups` (ADR-0033).
- Local Echo accepted no connections on iOS (`acceptLocalOnly`) and sent bodies with 204/HEAD responses (ADR-0035);
  loopback-only binding now has a LAN-reachability test.
- `xcodebuild` stalls behind the open Xcode's DerivedData lock — private DerivedData in scripts (ADR-0036).
- Typed-throws stored closures unavailable on macOS 14 / iOS 17 runtimes (ADR-0032).

Verification (local; Xcode 27.0, macOS 27.0; iPhone 18 Pro and iPad Pro 11-inch (M5) simulators, iOS 27.0):
```
scripts/test.sh --platform ios                       → Lint passed · package-iphone: passed 296, failed 0, skipped 2*
                                                       · app-iphone: passed 11, failed 0 · app-ipad: passed 11, failed 0
                                                       · RPCore 95.93% · RPStore 100% · All tests passed.
Package suite, macOS (xcodebuild, coverage)          → passed 298, failed 0
App-hosted tests, macOS (RequestPadTests)            → passed 8, failed 0 (ATS, Keychain, bookmarks, Local Echo in sandbox)
swift test --sanitize=address                        → 291 Swift Testing tests passed, no reports (perf tests skipped)
swift test --sanitize=thread                         → 291 Swift Testing tests passed, no reports (perf tests skipped)
Coverage (macOS package): RPCore 95.94% · RPData 93.36% · RPServices 90.74% · RPStore 100%
xcodebuild analyze (macOS, iOS)                      → ANALYZE SUCCEEDED ×2
Release builds (macOS, iOS)                          → Build Succeeded ×2, 0 warnings
```
\* The two live-Keychain package tests are skipped on the iOS simulator by design (unsigned runner has no Keychain
entitlement); the iOS Keychain is verified by the app-hosted test (passed on iPhone and iPad).

Not run in this phase, with reason:
- macOS UI tests: a RequestPad instance launched by the user's Xcode (pid 33954) is still paused in the debugger,
  which blocks XCUITest from launching the app. App UI code is unchanged since Phase 1. Stop the debug session in
  Xcode and run `scripts/test.sh --platform macos`.
- CI: blocked by GitHub billing (HUMAN_HANDOFF H5). Device-only checks listed in HUMAN_HANDOFF H6.

## Phase 4 — UI (2026-09-25)

Built (app target, `RequestPad/Shared/`):
- App layer: `AppEnvironment` (composition root; Debug-only `-UITestMode` in-memory store/secrets and `-UITestPro`),
  `AppModel` (collections, folders, requests, environments + Keychain secrets, sending, history, imports, Local
  Echo, sample data, export/import/erase; runner and cookie jar in `AppModel+Runner`), `WorkspaceModel` +
  `RequestEditorModel` (drafts, query sync, cURL paste, save with conflict handling, send/cancel, Local Network
  explainer, review prompt, GraphQL schema, OAuth tokens), `LaunchModel` with a recoverable failure screen.
- Views: sidebar (collections tree, search, add menu, prompts, deletions, folder picker), request workspace (URL bar,
  method menu, 9 editor tabs incl. body modes, multipart files, GraphQL with completions, auth incl. OAuth 2.0,
  extraction and assertion editors, settings, docs), response (status, timings, body Pretty/Raw/Preview with JSONPath
  filter, save to file, headers, cookies, timeline, tests), history, import (cURL/OpenAPI/Postman with preview and
  notices), environments (secrets with reveal), collection/folder settings, runner (export JSON), cookie jar,
  settings, onboarding (3 pages), Pro sheet (feature list; purchase arrives in Phase 5).
- Commands: ⌘N New Request, ⌥⌘N New Window, ⌘S, ⌘↩, ⌘., ⌘E, ⌘L; macOS Settings scene and Help links.
- RPUI: `KeyValueEditor`, `CodeEditor`, `LargeTextView`, `MethodBadge`, `StatusBadge`, `JSONTreeView`,
  `minimumHitTarget()`, accessible text colors (`TextColors.swift`). RPServices: `BookmarkFileResolver` (ADR-0039).
- String Catalog synced from the compiler (437 keys); `scripts/sync-strings.sh` for command-line builds.

Defects found by Phase 4 tests and fixed:
- Name prompt submitted the value captured when the alert appeared, not the typed name (collections could not be
  created from the prompt).
- Onboarding sheet taller than the default macOS window (buttons outside the window); window default size is now
  1100×720. ⌘N was bound twice (New Window and New Request) — ADR-0037.
- Contrast: system blue/green/orange/red and secondary text are below 4.5:1 in light mode; white on the dark-mode
  accent is 3:1; selected sidebar rows put colored badges on the accent highlight — accessible colors (ADR-0038).
- Large text (AX-XXXL): URL bar squeezed the URL to one letter per line, onboarding buttons pushed off screen or
  overlapping, history metadata and sidebar rows squeezed, response sections truncated, Settings toolbar button
  disappeared into overflow — all adapt now (screenshots reviewed below).
- iPad portrait showed the sidebar as an overlay dimming the editor — balanced split view; choosing a search result
  now hides the keyboard.
- Container accessibility identifiers hid their children's identifiers on macOS.

Verification (local; Xcode 27.0, macOS 27.0; iPhone 18 Pro and iPad Pro 11-inch (M5) simulators, iOS 27.0):
```
scripts/lint.sh                                            → Lint passed (swift-format strict, placeholders, markers)
scripts/test.sh --platform ios                             → package-iphone: passed 307, failed 0, skipped 2*
                                                             · app-iphone: passed 34, failed 0 · app-ipad: passed 34, failed 0
                                                             · RPCore 95.91% · RPStore 100% · All tests passed.
scripts/test.sh --platform macos --skip-macos-ui \
    --sanitizers --analyze                                 → package-macos: passed 309 · app-macos: passed 25 (unit + app-hosted)
                                                             · ASan: passed 302, skipped 7† · TSan: passed 302, skipped 7†
                                                             · Analyze Succeeded ×2 (macOS, iOS) · All tests passed.
Coverage (macOS package): RPCore 95.91% · RPData 93.47% · RPServices 91.81% · RPStore 100% · RPUI 8.9% (views)
Release builds (macOS, iOS)                                → succeeded; 0 compiler warnings (1 App Intents metadata note:
                                                             no AppIntents dependency until Phase 6)
```
\* Live-Keychain package tests skipped on the iOS simulator by design (covered by the app-hosted test).
† Performance tests skip under sanitizers.

UI tests (iPhone and iPad; 8 each incl. accessibility audits on every visited screen): onboarding skip, sample data →
send to Local Echo (status + JSON tree), create collection → edit URL → save, environment switch resolves
variables, history lists sent requests, Pro sheet from a locked feature, erase all data → onboarding, and every main
screen at AX-XXXL. The AX-XXXL screenshots (onboarding, sidebar, editor, response, history, settings) were
reviewed by eye: text wraps without clipping and all controls stay reachable. Audit exemptions and deferred
Dynamic Type findings are listed in ADR-0038.

Not run in this phase, with reason:
- macOS UI tests: on this Mac, SwiftUI opens no window for this bundle ID when XCUITest launches the app directly,
  even for a minimal app (ADR-0037); the app itself works when launched normally. HUMAN_HANDOFF H7 has the steps to
  clear the host state or run them elsewhere, and the manual macOS pass.
- CI (H5), device-only checks (H6), manual VoiceOver pass (H3).

## Phase 5 — StoreKit and paywall (2026-09-25)

Built:
- RPStore: `StoreProduct` / `TransactionSnapshot` / `PurchaseOutcome` / `StoreError` models, `EntitlementResolver`
  (pure), `PaywallCopy` (prices, trial terms, auto-renewal disclosure, status lines), `StoreClient` protocol with
  `FakeStoreClient`, and the `@Observable EntitlementManager` (products, purchase, pending/Ask to Buy, restore,
  transaction updates, refresh). Coverage 99.5%.
- App: `LiveStoreClient` (StoreKit 2; verified transactions only, finished after delivery), `PaywallView` (plans
  first, trial terms, purchase, Restore, Terms/Privacy, close), paywall presentation from the topmost presenter,
  "Welcome to RequestPad Pro" confirmation, entitlement refresh when the app becomes active, Settings: status,
  See Pro Features, Restore Purchases, Manage Subscription, Redeem Offer Code (iOS).
- `Products.storekit` moved to `RequestPadTests/StoreKit/` (test bundle only; scheme updated) — ADR-0041.

Defects found and fixed in this phase:
- Pro prompts inside sheets (Import, Collection/Folder Settings, Settings' "See Pro Features") were never shown on
  iOS: the root view cannot present while a sheet is up (ADR-0040).
- macOS minimum sheet sizes pushed the paywall and other sheets off screen on iPhone (`sheetFrame` is macOS-only now;
  `testImportSheetFitsOnScreen` guards it).
- iPad form sheet hid the plans below the fold — plans and the purchase button now come first.

Verification (local; Xcode 27.0, macOS 27.0; iPhone 18 Pro and iPad Pro 13-inch (M5) simulators, iOS 27.0):
```
scripts/test.sh --platform ios                         → package-iphone: passed 332, skipped 2* · app-iphone: passed 44
                                                         · app-ipad: passed 44 · RPCore 95.93% · RPStore 99.47%
scripts/test.sh --platform macos --skip-macos-ui \
    --sanitizers --analyze                             → package-macos: passed 334 · app-macos: passed 34 · ASan 327
                                                         passed, 7 skipped† · TSan 327 passed, 7 skipped† · Analyze ×2
Coverage (macOS package): RPCore 95.93% · RPData 93.47% · RPServices 91.74% · RPStore 99.47%
Release builds (macOS, iOS)                            → succeeded, 0 compiler warnings; no .storekit in the app bundle
```
StoreKit tests (app-hosted, `SKTestSession`, on macOS, iPhone and iPad): products/prices/7-day trial from the
configuration, subscription and lifetime purchase, Ask to Buy pending → approval, refund revokes Pro, period end
ends Pro (accelerated time), purchase failure, purchase on another device arrives as an update, restore.
UI tests: `testPaywallPurchaseUnlocksPro` (locked feature → paywall with prices, trial, Restore → purchase →
confirmation → feature unlocked), `testImportSheetFitsOnScreen`; audits pass on iPhone and iPad.
\* Live-Keychain package tests skipped on the iOS simulator by design. † Performance tests skip under sanitizers.

Not run in this phase, with reason:
- Real App Store / sandbox purchases need App Store Connect products and agreements (HUMAN_HANDOFF H8).
- macOS UI tests (H7), CI (H5), device checks (H6), manual VoiceOver pass (H3).

## Phase 6 — System integrations (2026-09-26)

Built:
- `AppRuntime` (single app instance for windows, intents, menu bar, Services) and `AppModel.requestedOpen` routing.
- App Intents: `SendRequestIntent` (Pro) with `RequestEntity` / `EnvironmentEntity` queries, `SentResponse`
  (status code, status, duration, body), specific failures, and an App Shortcut.
- macOS: menu bar Quick Send (`MenuBarExtra`, off by default, Pro), Services "Send URL with RequestPad"
  (`NSServices`, `ServicesProvider`, `SharedURL` in RPCore), Open at Login (`SMAppService`) in Settings › Mac.
- Sends can use the active environment, none, or a chosen one (`EnvironmentChoice`); extracted values persist into
  the environment that was used.

Verification (local; Xcode 27.0, macOS 27.0; iPhone 18 Pro and iPad Pro 13-inch (M5) simulators, iOS 27.0):
```
scripts/test.sh --platform ios                         → package-iphone: passed 336, skipped 2* · app-iphone: passed 50
                                                         · app-ipad: passed 50 · RPCore 95.95% · RPStore 99.47%
scripts/test.sh --platform macos --skip-macos-ui \
    --sanitizers --analyze                             → package-macos: passed 338 · app-macos: passed 48 · ASan 331
                                                         passed, 7 skipped† · TSan 331 passed, 7 skipped† · Analyze ×2
Coverage (macOS package): RPCore 95.92% · RPData 93.47% · RPServices 91.81% · RPStore 99.47%
Release builds (macOS, iOS)                            → succeeded, 0 warnings
Built app bundle                                       → Metadata.appintents lists SendRequestIntent, RequestEntity,
                                                         EnvironmentEntity, SentResponse; Info.plist has NSServices
```
New tests: `SendRequestIntentTests` (Pro send with status/body, environment override, free-tier error, deleted
request, foreign environment, entity queries, identifiers), `MacIntegrationTests` (Services handler and
declaration, open routing, login item with a fake service, Quick Send typed URL / 64 KB cap / chosen environment /
open in app, popover renders in < 100 ms with 300 requests), `SharedURLTests` (accepted and rejected selections).
A test-isolation defect was found and fixed: two parallel suites installed apps into the shared runtime.
\* Live-Keychain package tests skipped on the iOS simulator by design. † Performance tests skip under sanitizers.

Not run in this phase, with reason:
- Running the intent from the Shortcuts app and Siri, the menu bar popover timing in Instruments, the Services menu
  and the real login item need a person at the device (HUMAN_HANDOFF H9). macOS UI tests (H7), CI (H5), device
  checks (H6), VoiceOver (H3), App Store Connect products (H8).

## Phase 7 — Hardening (2026-09-26)

Done:
- **Traceability:** every PRD acceptance criterion now has an automated passing test except X01.4 (relaunch
  restoration; recorded manual check H9). 24 end-to-end tests (`EndToEndTests.swift`) drive the app model against the
  real URLSession client and Local Echo. Corrected ~25 TEST_PLAN rows that a Phase 4 bulk edit had mislabelled.
- **Fuzzing:** `FuzzTests` (15 parsers × 2,000 seeded inputs, round-trip invariants, minimum acceptance per target)
  and `EchoParserFuzzTests` (3,000 hostile byte streams in random pieces); deterministic, part of every run incl.
  ASan/TSan. No crashes or hangs found.
- **Privacy:** required-reason APIs scanned and checked against Apple's reference; `3B52.1` removed (unused);
  manifest verified in both archives.
- **Security:** Release archives inspected (macOS entitlements exact, hardened runtime; no StoreKit file; ATS without
  arbitrary loads; export compliance re-checked); gitleaks (history + tree) clean with a two-fixture allowlist;
  semgrep Swift + secrets rules: 0 findings; semgrep job added to CI; two public error logs made private.
- **Profiling:** Release launch on the iPhone 18 Pro simulator, XCTest launch metric: average 2.830 s (RSD 12.7%).
  Simulator numbers include simulator/XCTest overhead; the < 1.0 s budget is checked on devices (H10). Package
  performance budgets pass in every run (`PerformanceTests`). Quick Send renders in < 100 ms (Phase 6).

Defects found and fixed: stale-base save overwrote external `.bru` changes (P01.4); undeclared OpenAPI path
templates were sent literally (P02.1); error descriptions logged as public.

Verification (local; Xcode 27.0, macOS 27.0; iPhone 18 Pro and iPad Pro 13-inch (M5) simulators, iOS 27.0):
```
scripts/test.sh --platform ios                         → package-iphone: passed 339, skipped 2* · app-iphone: passed 74
                                                         · app-ipad: passed 74 · RPCore 96.84% · RPStore 99.47%
scripts/test.sh --platform macos --skip-macos-ui \
    --sanitizers --analyze                             → package-macos: passed 341 · app-macos: passed 72 · ASan 334
                                                         passed, 7 skipped† · TSan 334 passed, 7 skipped† · Analyze ×2
Coverage (macOS package): RPCore 96.84% · RPData 93.47% · RPServices 91.88% · RPStore 99.47%
Release builds (macOS, iOS) and archives               → succeeded, 0 warnings
gitleaks 8.30.1 (git history + working tree)           → no leaks found (with .gitleaks.toml)
semgrep 1.170.0 (p/swift, p/secrets; Sources + RequestPad) → 0 findings, 0 errors
```
\* Live-Keychain package tests skipped on the iOS simulator by design. † Performance tests skip under sanitizers.

Not run in this phase, with reason: Xcode Organizer privacy report, distribution-signed export, device launch
times (H10); macOS UI tests (H7); CI (H5); device checks (H6); VoiceOver (H3); App Store Connect products (H8);
manual system integrations (H9).

## Phase 8 — App Store assets & metadata (2026-09-26)

Done:
- **Icon:** Icon Composer bundle `RequestPad/AppIcon.icon` (braces + paper plane, Liquid Glass); Default, Dark,
  Clear and Tinted renditions rendered with `ictool` and reviewed; Release builds contain `AppIcon.icns` +
  `Assets.car` (macOS) and the iOS icon set.
- **Screenshots:** `scripts/screenshots.sh` → `docs/AppStore/screenshots/` — 5 scenes each (response, extraction
  rules, GraphQL, runner, environments) for iPhone 6.9" 1320×2868, iPad 13" 2064×2752 and Mac 2880×1800; real UI
  staged by the Debug-only `ScreenshotDirector`; dedicated simulators, restored and shut down afterwards; every
  image reviewed (no prices, no placeholder content).
- **Metadata:** `docs/AppStore/metadata.md` (name 22, subtitle 28, promo 148, description 2,939, keywords 98
  characters), claims table (41 cited tests/types verified to exist), `review_notes.md` (every path checked against
  the source), `privacy_labels.md` (Data Not Collected). `scripts/check-metadata.py` and a forbidden-API check
  (web views, dynamic loading, arbitrary loads) now run in `lint.sh`.
- **Docs:** `docs/APP_REVIEW_CHECKLIST.md` (B10 1–17 with evidence), `docs/RELEASE_RUNBOOK.md` (B11 + Phase 11),
  HUMAN_HANDOFF H11, ADR-0044.

Defects found and fixed (ADR-0044): Pro welcome alert at every launch; concurrent `AppModel.load()` on macOS launch;
"200 No Error" status text; JSON tree collapsed at the root; Export Diagnostics produced no file; selection not
revealed in collapsed folders; Environments footer cut off on macOS; missing `LSApplicationCategoryType`.
Regression tests added (TEST_PLAN "Regression tests from Phase 8"); the entitlement test was confirmed to fail on the
old logic.

Verification (local; Xcode 27.0, macOS 27.0; iOS 27.0 simulators):
```
scripts/lint.sh                                      → passed (incl. metadata and forbidden-API checks)
scripts/test.sh --platform ios                       → package-iphone: passed 343, skipped 2* · app-iphone: passed 76
                                                       · app-ipad: passed 76 · RPCore 96.84% · RPStore 99.47%
scripts/test.sh --platform macos --skip-macos-ui \
    --sanitizers --analyze (before the last UI-test   → package-macos: passed 345 · app-macos: passed 74 · ASan 338
    helper and sidebar-identifier changes)              passed, 7 skipped† · TSan 338 passed, 7 skipped† · Analyze ×2
xcodebuild test, app-macos on the final code         → 74 passed (the run's only failure was the UI runner, see below)
swift test (plain, --sanitize=address, =thread)      → all suites passed on the final code
xcodebuild analyze (macOS, iOS) on the final code    → succeeded, 0 warnings
Release builds (macOS, iOS)                          → succeeded, 0 warnings; lipo: x86_64 arm64;
                                                       LSApplicationCategoryType = public.app-category.developer-tools;
                                                       no ScreenshotDirector symbols in Release
scripts/screenshots.sh --platform all                → 15 images, exact sizes
```
\* Live-Keychain tests skipped on the simulator by design. † Performance tests skip under sanitizers.

Test-infrastructure incident: a `test.sh` change briefly passed both a per-class skip and the whole-target skip for
macOS UI tests, which made xcodebuild start the macOS UI runner; it timed out enabling automation mode (the H7 host
limitation). Fixed in `test.sh`. After that timeout, xcodebuild-hosted macOS test runners on this Mac hung before
connecting (also while the owner's other project was testing), so the final `test.sh --platform macos` could not
complete; the system `testmanagerd` was not restarted to avoid disturbing the owner's other work. The final code is
covered by the runs listed above; re-run `scripts/test.sh --platform macos --skip-macos-ui --sanitizers --analyze`
after the next reboot (HUMAN_HANDOFF H7).

Not run in this phase, with reason: macOS UI tests (H7); device checks (H2, H6, H10); App Store Connect entry (H11).

## Phase 9 — Beta: agent deliverables (2026-09-26)

Done:
- **Owner decisions recorded:** the subtitle "HTTP & GraphQL, git-friendly" and the keywords without other apps'
  names (ADR-0044; the metadata notes and the checklist are updated).
- **Archives and exports** for version 1.0.0 (1): `scripts/archive.sh --platform all` → exit 0 (lint passed first).
  Outputs:
  - `build/ios-export/RequestPad.ipa` (9.6 MB)
  - `build/macos-export/RequestPad.pkg` (10.1 MB)
- **Upload prepared:** `scripts/upload.sh`, human-run. A dry run with a dummy key showed "ios: version 1.0.0 (1),
  macos: version 1.0.0 (1)" and cancelled on "n" with nothing sent. The guards reject a missing key and a key inside
  the repository.
- **TestFlight plan:** `docs/AppStore/testflight.md` has the beta description, "What to Test", groups and triage.
  HUMAN_HANDOFF H12 has the steps and exit criteria.

Export inspection:
```
iOS  RequestPad.app   Authority=Apple Distribution: Eonix (Pvt) Ltd (835LNLUPAJ)
                      entitlements: application-identifier, team-identifier, beta-reports-active=true,
                      get-task-allow=false · PrivacyInfo.xcprivacy present · no .storekit file
macOS RequestPad.pkg  signed by 3rd Party Mac Developer Installer: Eonix (Pvt) Ltd (835LNLUPAJ)
      RequestPad.app  Authority=Apple Distribution: Eonix (Pvt) Ltd · hardened runtime · lipo: x86_64 arm64
                      entitlements: app-sandbox, files.bookmarks.app-scope, files.user-selected.read-write,
                      network.client, network.server, keychain-access-groups [835LNLUPAJ.lk.eonix.RequestPad]
                      (matches ADR-0015/0033) · no .storekit file · codesign --verify --deep --strict: ok
```

Human-gated (H12): upload, internal and external TestFlight groups, Beta App Review, and the feedback loop. Exit
criteria: external build approved, 0 crashes in Organizer, no open P1/P2 issues.

## Phase 10 — Submission: agent deliverables (2026-09-26)

Started at the owner's request before the Phase 9 beta (H12) had run. The beta's exit criteria stay a prerequisite
of submission (HUMAN_HANDOFF H13).

Done:
- **In-app purchase review screenshots:** `docs/AppStore/iap-review/{yearly,monthly,lifetime}.png` (1320×2868). They
  show the real paywall with each product selected: price, period, trial terms, Restore Purchases. They are made by
  `ScreenshotTests.testCaptureInAppPurchaseReviewScreenshots` through `scripts/screenshots.sh` (Debug-only
  `paywall` scenario, no Pro).
- **Prepared App Review replies:** `docs/AppStore/rejection_responses.md` covers 2.1 (IAP not found, crash),
  2.5.2/2.5.4 (Local Echo), 2.4.5 (login item, menu bar, Services, entitlements), 3.1.2, 4.2, 5.1.1, and 2.3
  (other apps' names, screenshots). Every factual statement was checked against the source: Local Echo is off by
  default; Face ID uses `deviceOwnerAuthentication` (passcode fallback); the paywall has the 24-hour renewal text;
  the Local Network usage string is quoted verbatim.
- **Submission and release steps:** HUMAN_HANDOFF H13 (manual release on both platforms, phased release on iOS,
  attach the IAPs, tag `v1.0.0` after approval). H8 step 2 points to the IAP screenshots.
- **Docs:** APP_REVIEW_CHECKLIST links the IAP screenshots and the prepared replies; CHANGELOG has the 1.0.0 section
  (pending submission).

Verification:
```
scripts/screenshots.sh --platform ios        → iPhone 5 + 3 IAP review screenshots (1320×2868), iPad 5 (2064×2752)
                                               (first run failed to compile: missing `import RPStore` under
                                               MemberImportVisibility — fixed)
xcodebuild build-for-testing (macOS)         → succeeded (the Mac compiles the Debug-only code and the UI tests)
scripts/lint.sh                              → passed
```
Unchanged since Phase 9: app code outside the Debug-only screenshot scenario, and the uploaded or exported archives
(`build/*-export`, build 1.0.0 (1)).

Human-gated: H12 (beta), then H13 (submit, review, release). Exit (human-verified): "Ready for Sale".

## Phase 11 — Post-launch definition (2026-09-26)

Agent deliverables:
- `docs/RELEASE_RUNBOOK.md` §10–14: weekly review, hotfix path, support SLA, pricing, 90-day roadmap (written in
  Phase 8).
- `docs/SUPPORT_REPLIES.md`: support templates, each checked against the app and `SECURITY.md`.
- `docs/COMPLETION_AUDIT.md`: completion audit and handoff.
- `SUPPORT.md` corrected: "Settings → Developer" and "Settings → About" do not exist. They are now
  "Settings → Try It Out" and "shown at the bottom of Settings". Republish the page (H1).

Ongoing work starts at "Ready for Sale" (HUMAN_HANDOFF H13) and is logged below.

## Operations

One entry per weekly review (`docs/RELEASE_RUNBOOK.md` §10), incident or release. Template:

```
### YYYY-MM-DD — weekly review (version x.y.z)
Crashes/hangs (Organizer, 7 days): iOS n / macOS n — new signatures: … — actions: …
Metrics vs budgets (launch < 1.0 s, memory): …
Support: n conversations (P1 n, P2 n, P3 n) — recurring topics: …
Reviews: average ★ …, replies sent: n
Subscriptions (App Store Connect): trials n, conversions n, churn n
Decisions / follow-ups: …
```

_No entries yet: the app has not been released._

### 2026-09-27 — website published (H1)
The owner published https://requestpad.eonix.lk.
- **Verified:** `/privacy`, `/terms` and `/support` match the repo text word for word. HTTPS-only (308 redirect),
  HSTS preload, strict CSP, nosniff and referrer-policy. All links resolve. The home and `/pricing` claims match the
  app and StoreKit configuration.
- **Open:** a support mailbox test, legal review, and swapping "Coming soon" for the App Store link at release.

### 2026-09-27 — pre-submission check and App Store Connect setup (H8, H11, H13)
The owner chose to submit 1.0.0 without the TestFlight beta (H12 exit criteria remain unmet).
- **Checks (local):** `scripts/lint.sh` passed. `scripts/test.sh --platform all --skip-macos-ui` passed:
  package macOS 345/0 failed, package iPhone 343/0 (2 skipped), app macOS 74/0, app iPhone 76/0, app iPad 76/0;
  coverage gate passed.
- **Fixed:** the App Review notes were 4,685 characters; App Store Connect allows 4,000. Shortened to 3,665 with
  every path kept, and `scripts/check-metadata.py` now fails on notes over the limit.
- **Committed:** Xcode's generated string-catalog comments, the Xcode Cloud workflow manifest and the explicit
  `PRODUCT_NAME = RequestPad` from Xcode Cloud setup.
- **App Store Connect (agent, in the owner's browser):** name, subtitle, category, content rights, age rating 4+,
  privacy policy URL and "Data Not Collected" (published), price Free in 175 territories; subscription group "Pro"
  with yearly $19.99 and monthly $2.99 (each with a 1-week free trial) and lifetime $39.99, each with display name,
  description and review screenshot; iOS and macOS version 1.0.0 with screenshots, text, URLs, copyright, review
  notes, manual release, and Xcode Cloud build 1.0.0 (3). The owner entered the review contact name and phone.
- **Submitted 2026-09-27 01:14–01:16 (owner confirmed):** macOS 1.0.0 (3), then iOS 1.0.0 (3) with 4 in-app purchase
  items. Both are "Waiting for Review", with manual release.
