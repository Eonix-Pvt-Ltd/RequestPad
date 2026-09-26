# Test Plan

Every acceptance criterion in `docs/PRD.md` maps to at least one automated test (or a recorded manual check
where automation is impossible). Status is updated at each phase gate; an AC without a passing test fails the Phase 7
exit criteria. Test code references ACs with `// AC: <id>` comments.

## Suites and commands

| Suite | Framework | Command | Runs on |
|---|---|---|---|
| Package (RPCore, RPData, RPServices, RPStore, RPUI) | Swift Testing | `scripts/test.sh` (scheme `RequestPadKit-Package`) | macOS, iOS simulator |
| App unit tests (`RequestPadTests`) | Swift Testing | `scripts/test.sh` (scheme `RequestPad`) | macOS, iPhone & iPad simulators |
| UI tests (`RequestPadUITests`) incl. accessibility audits | XCTest / XCUITest | `scripts/test.sh` | macOS, iPhone & iPad simulators |
| Sanitizers | ASan, TSan (separate runs) | `scripts/test.sh --sanitizers` | macOS |
| Static analysis | Clang analyzer | `scripts/test.sh --analyze` | macOS, iOS |
| Secret scan | gitleaks 8.30.1 | CI `secret-scan` job | Linux |

Coverage gate: RPCore and RPStore ≥ 80 % line coverage (xccov), enforced by `scripts/test.sh`.

Performance tests skip themselves under ASan/TSan (budgets are enforced in regular runs). `DeepNestingTests` run the
parsers at maximum nesting on a 512 KB-stack thread (ADR-0030).

## Foundation tests (Phase 1)

| Area | Tests | Status |
|---|---|---|
| App identifiers, legal URLs, support mail URL | `RPCoreTests/AppConstantsTests` | ✅ pass |
| HTTP method tokens (F01.1 groundwork) | `RPCoreTests/HTTPMethodTests` | ✅ pass |
| Status classes (F02.1 groundwork) | `RPCoreTests/HTTPStatusClassTests`, `RPUITests/StatusBadgeStyleTests` | ✅ pass |
| Request limits (F01.6, F02.7 groundwork) | `RPCoreTests/RequestDefaultsTests` | ✅ pass |
| Storage locations (X04.2 groundwork) | `RPDataTests/StorageLocationsTests` | ✅ pass |
| Log redaction (X04.3 groundwork) | `RPServicesTests/LogTests` | ✅ pass |
| Product IDs & free limits (X03, F03.2 groundwork) | `RPStoreTests/ProductIDTests` | ✅ pass |
| Launch preparation & recovery | `RequestPadTests/LaunchModelTests` | ✅ pass |
| App launches (smoke), launch accessibility audit, launch performance | `RequestPadUITests` | ✅ pass |

## Performance budgets (Phase 2, Debug build, `RPCoreTests/PerformanceTests`)

| Hot path | Budget | Measured 2026-09-25 (Apple silicon, Xcode 27.0, Debug) |
|---|---|---|
| Parse 10 MB JSON response | < 3 s | 0.77 s (iterative parser, ADR-0030); peak memory ≈ 48 MB (XCTMemoryMetric) |
| JSONPath `$.items[*].meta.note` over 10 MB document | < 2 s | < 0.1 s (10,000-match cap) |
| YAML parse, 2,000-path OpenAPI (~650 KB) | < 2 s | 0.23 s |
| OpenAPI import of the same document | < 3 s | 0.26 s |
| 1,000 `.bru` decode + encode round trips | < 2 s | 0.33 s |

## Acceptance criteria traceability

Status legend: **services ✅** — verified through RPData/RPServices (real loopback traffic, stores, Keychain, app-hosted
platform tests); only the UI path remains. **core ✅** — the pure logic behind the criterion is verified by the named RPCore suites; the criterion
itself is only marked **✅** once the services/UI path is verified end-to-end in its phase.

| AC | Criterion | Planned tests | Phase | Status |
|---|---|---|---|---|
| F01.1 | Methods GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS are selectable; a custom method token (RFC 9110 | Unit (RPCore resolver, RPServices HTTPClient vs Local Echo) + UI | 3–4 | core ✅ `HTTPMethod`; import UI implemented (Import sheet: preview + notices), manual check (H7) |
| F01.2 | Query params edited in the table and in the URL stay in sync both ways; disabled rows are not sent. | Unit (RPCore resolver, RPServices HTTPClient vs Local Echo) + UI | 3–4 | core ✅ `QueryParameters`; import UI implemented (Import sheet: preview + notices), manual check (H7) |
| F01.3 | Headers table supports enable/disable per row; duplicate header names are sent as separate fields. | Unit (RPCore resolver, RPServices HTTPClient vs Local Echo) + UI | 3–4 | core ✅ `RequestResolver`; import UI implemented (Import sheet: preview + notices), manual check (H7) |
| F01.4 | Body kinds: none, JSON, text, XML, form-urlencoded, multipart (text fields + files via file picker), | Unit (RPCore resolver, RPServices HTTPClient vs Local Echo) + UI | 3–4 | core ✅ `RequestResolver`; import UI implemented (Import sheet: preview + notices), manual check (H7) |
| F01.5 | ⌘↩ sends on iPad (hardware keyboard) and Mac; a Send button is always visible; while in flight it becomes | Unit (RPCore resolver, RPServices HTTPClient vs Local Echo) + UI | 3–4 | services ✅ `URLSessionHTTPClient (cancel < 1 s)`; UI ✅ `testSampleRequestSendsToLocalEcho` (iOS) |
| F01.6 | Request timeout defaults to 30 s and is configurable per request (1–600 s); follow-redirects toggle | Unit (RPCore resolver, RPServices HTTPClient vs Local Echo) + UI | 3–4 | services ✅ `URLSessionHTTPClient (timeout, redirects)`; app ✅ `sendRecordsHistoryAndAppliesTheDefaultTimeout` |
| F01.7 | Network failures (offline, DNS, TLS, timeout, ATS block, local-network permission denied) show a specific, | Unit (RPCore resolver, RPServices HTTPClient vs Local Echo) + UI | 3–4 | services ✅ `URLSessionHTTPClient (error mapping)`; UI implemented, manual check (H3/H7) |
| F01.8 | Plain `http://` to loopback, `.local`, unqualified hosts and RFC 1918 / link-local addresses works; plain | Unit (RPCore resolver, RPServices HTTPClient vs Local Echo) + UI | 3–4 | services ✅ `PlatformIntegration (ATS, app-hosted)`; UI implemented, manual check (H3/H7) |
| F01.9 | On iOS/iPadOS the first request to a LAN address shows the pre-permission explainer before the system | Unit (RPCore resolver, RPServices HTTPClient vs Local Echo) + UI | 3–4 | app: explainer alert before first LAN send (`AppPolicies`); device check H6 |
| F01.10 | Unsaved edits to any request persist as a draft and survive app relaunch. | Unit (RPCore resolver, RPServices HTTPClient vs Local Echo) + UI | 3–4 | app ✅ `draftsSurviveReopening` |
| F02.1 | Shows status code + reason phrase, color **and** text/icon status class (never color alone). | Unit (viewer models, JSONPath, streaming) + UI | 2–4 | core ✅ `HTTPStatusClass, StatusBadgeStyle`; import UI implemented (Import sheet: preview + notices), manual check (H7) |
| F02.2 | Shows total time and a timing breakdown (DNS, connect, TLS, request, waiting/TTFB, download) from | Unit (viewer models, JSONPath, streaming) + UI | 2–4 | services ✅ `URLSessionHTTPClient (timings, protocol, address)`; UI implemented, manual check (H3/H7) |
| F02.3 | Headers tab lists all response headers; values are copyable. | Unit (viewer models, JSONPath, streaming) + UI | 2–4 | UI implemented, manual check (H3/H7) |
| F02.4 | Body "Pretty" view: JSON rendered as a collapsible tree; a filter field accepts a JSON path | Unit (viewer models, JSONPath, streaming) + UI | 2–4 | core ✅ `JSONPath`; import UI implemented (Import sheet: preview + notices), manual check (H7) |
| F02.5 | Body "Raw" view shows text with detected encoding (charset header → UTF-8 → Latin-1 fallback); invalid | Unit (viewer models, JSONPath, streaming) + UI | 2–4 | core ✅ `ResponseBody`; import UI implemented (Import sheet: preview + notices), manual check (H7) |
| F02.6 | Body "Preview" renders PNG/JPEG/GIF/HEIC/WebP images; other types show "No preview for <type>". | Unit (viewer models, JSONPath, streaming) + UI | 2–4 | core ✅ `ResponseBody`; import UI implemented (Import sheet: preview + notices), manual check (H7) |
| F02.7 | Bodies > 10 MB are not rendered: the viewer shows size + "Save to File…" and the body is streamed to a | Unit (viewer models, JSONPath, streaming) + UI | 2–4 | services ✅ `URLSessionHTTPClient (disk spooling)`; UI implemented, manual check (H3/H7) |
| F02.8 | "Save Response…" writes the body to a user-chosen location on every platform. | Unit (viewer models, JSONPath, streaming) + UI | 2–4 | UI implemented, manual check (H3/H7) |
| F03.1 | Create, rename, delete (with confirmation) collections, folders and requests; duplicate a request; | Unit (RPData stores, FeatureGate) + UI | 3–5 | services ✅ `LocalStore`; UI ✅ `testCreateCollectionEditAndSaveRequest` (iOS); app ✅ `requestsCanBeCreatedRenamedMovedAndDeleted` |
| F03.2 | Free tier: creating a 2nd non-sample collection or a 31st request in the free collection opens the paywall; | Unit (RPData stores, FeatureGate) + UI | 3–5 | app ✅ `freeTierAllowsOneCollectionAndAsksForPro` |
| F03.3 | A collection can define default headers and default auth that requests inherit. | Unit (RPData stores, FeatureGate) + UI | 3–5 | UI implemented, manual check (H3/H7) |
| F03.4 | Search filters requests by name, method and URL across the sidebar. | Unit (RPData stores, FeatureGate) + UI | 3–5 | services ✅ `LocalStore`; UI implemented, manual check (H3/H7) |
| F04.1 | Create/rename/duplicate/delete environments per collection plus one set of global variables. | Unit (interpolation, Keychain) + UI | 2–4 | services ✅ `LocalStore`; UI ✅ `testEnvironmentSwitchResolvesVariables` (iOS); app ✅ `secretVariablesLive…` |
| F04.2 | `{{name}}` interpolation in URL, params, headers, body, auth fields. Precedence (highest first): | Unit (interpolation, Keychain) + UI | 2–4 | core ✅ `Interpolator`; import UI implemented (Import sheet: preview + notices), manual check (H7) |
| F04.3 | Unresolved variables are highlighted in the editor and listed in a pre-send warning; sending is still | Unit (interpolation, Keychain) + UI | 2–4 | core ✅ `Interpolator, RequestResolver`; import UI implemented (Import sheet: preview + notices), manual check (H7) |
| F04.4 | A variable can be marked secret: its value is stored only in the Keychain, masked (••••) in all UI, never | Unit (interpolation, Keychain) + UI | 2–4 | services ✅ `SecretStore, RequestExecutor (masked display)`; app ✅ `secretVariablesLiveInTheSecretStoreAndCanBeRevealed` |
| F04.5 | Revealing a secret requires Face ID / Touch ID / device passcode when the device supports it. | Unit (interpolation, Keychain) + UI | 2–4 | app ✅ (fake authenticator); device check H6 |
| F04.6 | The environment switcher is reachable from the request toolbar on every platform and via ⌘E. | Unit (interpolation, Keychain) + UI | 2–4 | UI ✅ `testEnvironmentSwitchResolvesVariables` (toolbar); ⌘E menu command manual (H7) |
| F05.1 | Bearer adds `Authorization: Bearer <token>`; Basic adds RFC 7617 Base64 `user:pass`; API key adds a | Unit (auth builders, OAuth state machine w/ fake server) + UI | 2–4 | core ✅ `RequestResolver`; import UI implemented (Import sheet: preview + notices), manual check (H7) |
| F05.2 | "Inherit" resolves auth from folder → collection. | Unit (auth builders, OAuth state machine w/ fake server) + UI | 2–4 | core ✅ `RequestResolver`; import UI implemented (Import sheet: preview + notices), manual check (H7) |
| F05.3 | OAuth 2.0 client credentials: token endpoint, client ID, client secret (secret var), scope; | Unit (auth builders, OAuth state machine w/ fake server) + UI | 2–4 | services ✅ `OAuth2Service`; UI implemented, manual check (H3/H7) |
| F05.4 | OAuth 2.0 authorization code + PKCE (S256): authorize & token endpoints, client ID, optional secret, | Unit (auth builders, OAuth state machine w/ fake server) + UI | 2–4 | services ✅ `OAuth2Service (PKCE state machine, fake auth server)`; UI implemented, manual check (H3/H7) |
| F05.5 | Auth errors (invalid_client, invalid_grant, user cancelled, state mismatch, network) show specific messages. | Unit (auth builders, OAuth state machine w/ fake server) + UI | 2–4 | services ✅ `OAuth2Service, OAuth2`; UI implemented, manual check (H3/H7) |
| F06.1 | Every sent request records a snapshot of the **unresolved** request (so secrets are not stored) and a | Unit (history store/pruning) + UI | 3–4 | services ✅ `LocalStore, RequestExecutor`; UI ✅ `testHistoryListsSentRequests` (iOS) |
| F06.2 | History is capped (oldest pruned); can be searched, re-opened into a new tab, saved to a collection, and | Unit (history store/pruning) + UI | 3–4 | services ✅ `LocalStore`; UI ✅ `testHistoryListsSentRequests` (iOS) |
| F07.1 | Paste a cURL command (from Chrome/Firefox/Safari "Copy as cURL", Postman, Bruno) → new request with | Unit (cURL parser/exporter, property tests) | 2 | core ✅ `ShellWords, CurlParser`; import UI implemented (Import sheet: preview + notices), manual check (H7) |
| F07.2 | Export a request as a single-line and a multi-line cURL command, variables resolved and secrets masked by | Unit (cURL parser/exporter, property tests) | 2 | core ✅ `CurlExporter (property test)`; import UI implemented (Import sheet: preview + notices), manual check (H7) |
| F08.1 | Settings → Developer → Local Echo toggle starts an in-process HTTP/1.1 server bound to 127.0.0.1 on a | Integration (Local Echo) + UI | 3–4 | services ✅ `LocalEchoServer`; UI ✅ sample flows start Local Echo (iOS) |
| F08.2 | Echo returns JSON describing the received method, path, query, headers, body (UTF-8 or Base64), and | Integration (Local Echo) + UI | 3–4 | services ✅ `EchoRouter, LocalEchoServer`; UI implemented, manual check (H3/H7) |
| F08.3 | Settings → Developer → Load Sample Data creates the Sample collection (targets `{{echoBaseURL}}`), a | Integration (Local Echo) + UI | 3–4 | UI ✅ onboarding → Load Sample Data (iOS); app ✅ `sampleDataDoesNotCountTowardsTheLimit` |
| F08.4 | Echo caps request size at 20 MB, 16 concurrent connections, 30 s idle timeout; stops when toggled off and | Integration (Local Echo) + UI | 3–4 | services ✅ `EchoRequestParser, LocalEchoServer`; UI implemented, manual check (H3/H7) |
| P01.1 | "Open Collection Folder…" picks a folder (Files on iOS — including iCloud Drive and other providers; | Unit (.bru codec fixtures, folder repo) + UI | 2–4 | services ✅ `FolderAccess, PlatformIntegration (sandbox bookmarks)`; UI implemented, manual check (H3/H7) |
| P01.2 | Reads Bruno collection layout: `bruno.json`, `collection.bru`, `folder.bru`, `*.bru` requests, | Unit (.bru codec fixtures, folder repo) + UI | 2–4 | services ✅ `FolderCollectionRepository`; UI implemented, manual check (H3/H7) |
| P01.3 | Every edit is written back to the corresponding `.bru` file atomically; unknown blocks and unknown keys are | Unit (.bru codec fixtures, folder repo) + UI | 2–4 | services ✅ `FolderCollectionRepository`; UI implemented, manual check (H3/H7) |
| P01.4 | External changes (git pull, Bruno desktop edits) are detected and reloaded; a conflict with unsaved local | Unit (.bru codec fixtures, folder repo) + UI | 2–4 | services ✅ `FolderCollectionRepository (conflicts), FolderWatcher`; UI implemented, manual check (H3/H7) |
| P01.5 | Secret environment variables follow Bruno's `vars:secret [ … ]` convention: names in the file, values only | Unit (.bru codec fixtures, folder repo) + UI | 2–4 | services ✅ `FolderCollectionRepository`; UI implemented, manual check (H3/H7) |
| P01.6 | "New Collection in Folder…" creates a valid Bruno collection (`bruno.json` + `collection.bru`). | Unit (.bru codec fixtures, folder repo) + UI | 2–4 | services ✅ `FolderCollectionRepository`; UI implemented, manual check (H3/H7) |
| P01.7 | "Convert to Folder Collection…" exports a native collection into a folder as `.bru` files. | Unit (.bru codec fixtures, folder repo) + UI | 2–4 | services ✅ `NativeCollectionExporter`; UI implemented, manual check (H3/H7) |
| P02.1 | Imports OpenAPI 3.0.x and 3.1.x in JSON or YAML (≤ 10 MB) → a collection with a folder per tag, | Unit (OpenAPI/YAML fixtures) | 2 | core ✅ `OpenAPIImporter, YAMLParser`; import UI implemented (Import sheet: preview + notices), manual check (H7) |
| P02.2 | Local `$ref`s (`#/components/...`) resolve; external refs and cycles are reported, not followed. | Unit (OpenAPI/YAML fixtures) | 2 | core ✅ `OpenAPIImporter`; import UI implemented (Import sheet: preview + notices), manual check (H7) |
| P02.3 | Malformed input shows the line/column (YAML) or key path of the failure; nothing partial is saved. | Unit (OpenAPI/YAML fixtures) | 2 | core ✅ `OpenAPIImporter, YAMLParser`; import UI implemented (Import sheet: preview + notices), manual check (H7) |
| P03.1 | Imports Postman Collection v2.1 JSON: folders, requests, headers, query, body modes (raw, urlencoded, | Unit (Postman fixtures) | 2 | core ✅ `PostmanImporter`; import UI implemented (Import sheet: preview + notices), manual check (H7) |
| P04.1 | GraphQL body kind with query editor and variables (JSON) editor; sent as `application/json` POST. | Unit (GraphQL lexer/completion, introspection) + UI | 2–4 | core ✅ `RequestResolver`; import UI implemented (Import sheet: preview + notices), manual check (H7) |
| P04.2 | "Fetch Schema" runs the standard introspection query; the schema is cached per endpoint URL. | Unit (GraphQL lexer/completion, introspection) + UI | 2–4 | services ✅ `GraphQLSchemaService (Local Echo)`; UI implemented, manual check (H3/H7) |
| P04.3 | Editor offers completion for fields, arguments and types at the cursor based on the cached schema, and | Unit (GraphQL lexer/completion, introspection) + UI | 2–4 | core ✅ `GraphQL`; import UI implemented (Import sheet: preview + notices), manual check (H7) |
| P05.1 | Per request, define rules `variable ← source` where source is status, a header name, or a JSON path in the | Unit (extractors, .bru round trip) | 2–3 | services ✅ `RequestExecutor`; UI implemented, manual check (H3/H7) |
| P05.2 | Rules round-trip to `.bru` as `vars:post-response` using Bruno's `res.body.path` / `res.headers.name` / | Unit (extractors, .bru round trip) | 2–3 | core ✅ `BruRequestCodec, BruExpression`; import UI implemented (Import sheet: preview + notices), manual check (H7) |
| P06.1 | Per request assertions: status equals; JSON path equals / not equals / contains / exists; header equals. | Unit (assertions, runner) + UI | 2–4 | core ✅ `ResponseEvaluator, BruRequestCodec`; import UI implemented (Import sheet: preview + notices), manual check (H7) |
| P06.2 | "Run Folder" (or collection) sends requests sequentially in sort order, applying extraction rules so later | Unit (assertions, runner) + UI | 2–4 | services ✅ `CollectionRunner`; app ✅ `runnerRunsItemsInOrder` |
| P06.3 | Run results can be exported as JSON. | Unit (assertions, runner) + UI | 2–4 | services ✅ `CollectionRunner`; UI implemented, manual check (H3/H7) |
| P07.1 | Cookies from `Set-Cookie` are stored per domain (RFC 6265 domain/path/secure/expiry rules) and sent on | Unit (RFC 6265 matching, jar store) + UI | 2–4 | services ✅ `CookieJar, RequestExecutor (Local Echo)`; UI implemented, manual check (H3/H7) |
| P07.2 | Free tier: cookies are not persisted between requests (ephemeral). | Unit (RFC 6265 matching, jar store) + UI | 2–4 | core ✅ `CookieJar`; import UI implemented (Import sheet: preview + notices), manual check (H7) |
| P08.1 | App Intent "Send Request" with parameters Request (entity query over saved requests) and optional | Unit (intent perform) + manual Shortcuts check | 6 | app ✅ `SendRequestIntentTests` (send, environment override, entity queries); manual Shortcuts run H9 |
| P08.2 | Without Pro, the intent returns a clear error telling the user Pro is required. | Unit (intent perform) + manual Shortcuts check | 6 | app ✅ `freeTierGetsAClearProError` |
| P09.1 | Optional `MenuBarExtra` (Settings toggle, default off) with a popover: pick a saved request or type a URL, | UI (macOS) + Instruments measurement | 6 | app ✅ `quickSendSendsATypedURL`, `quickSendCapsTheBodyAt64KB`, `quickSendUsesTheChosenEnvironment`; manual H9 |
| P09.2 | Popover opens in < 100 ms. | UI (macOS) + Instruments measurement | 6 | app ✅ `quickSendRendersQuickly` (render < 100 ms, 300 requests); Instruments check H9 |
| X01.1 | iPad: three-column `NavigationSplitView` (collections / request / response), Split View & Stage Manager, | UI (iPad/iPhone/macOS) + manual | 4, 6 | UI implemented, manual check (H3/H7) |
| X01.2 | iPhone: stacked navigation; request and response as segmented tabs; all controls reachable one-handed. | UI (iPad/iPhone/macOS) + manual | 4, 6 | UI ✅ all iPhone flows; AX-XXXL screenshots reviewed |
| X01.3 | macOS: sidebar + request tabs (window tabs), full menu bar (File/Edit/View/Request/Window/Help), Settings | UI (iPad/iPhone/macOS) + manual | 4, 6 | app ✅ Services (`servicesOpenTheSelectedURLAsANewRequest`, Info.plist), launch at login (`loginItemFollowsTheSystemStatus`); unit ✅ `SharedURL`; menus and windows manual H7/H9 |
| X01.4 | Window/tab/last-selection state restores on relaunch. | UI (iPad/iPhone/macOS) + manual | 4, 6 | UI implemented, manual check (H3/H7) |
| X02.1 | First launch shows ≤ 3 skippable onboarding screens; no permission prompts during onboarding. | UI + unit | 4 | UI ✅ `testOnboardingCanBeSkipped` (iOS) |
| X02.2 | Settings: appearance, default timeout, follow redirects, history size, Local Echo, Load Sample Data, | UI + unit | 4 | UI implemented, manual check (H3/H7) |
| X02.3 | "Rate RequestPad" review prompt only after the 5th successful request and never more than the system | UI + unit | 4 | app: `AppPolicies` unit ✅ (services); prompt wired after successful send |
| X03.1 | Paywall shows the subscription group (monthly, yearly) with price, period, 7-day trial terms and what | Unit (EntitlementCalculator) + UI (StoreKit config) + manual sandbox | 5 | app ✅ `StoreKitTests.productsMatchTheConfiguration`; unit ✅ `PaywallCopy`; UI ✅ `testPaywallPurchaseUnlocksPro` |
| X03.2 | Purchase / cancel / pending (Ask to Buy) / failed / restore / refund-revocation flows each produce the | Unit (EntitlementCalculator) + UI (StoreKit config) + manual sandbox | 5 | app ✅ `StoreKitTests` (purchase, Ask to Buy, refund, expiry, failure, restore); unit ✅ `EntitlementManager`, `EntitlementResolver` |
| X03.3 | Pro features unlock immediately after purchase on all the user's devices (Universal Purchase). | Unit (EntitlementCalculator) + UI (StoreKit config) + manual sandbox | 5 | app ✅ `purchaseMadeElsewhereArrivesAsAnUpdate`; UI ✅ unlock after purchase; device check H8 |
| X04.1 | Export App Data writes a versioned JSON of native collections, environments (secret values excluded), | Unit (export/import/erase) + UI | 3–4 | services ✅ `AppDataTransfer`; app ✅ `exportAndImportRoundTrip` |
| X04.2 | Erase All Data removes SwiftData store, Keychain items, bookmarks, cookie jar, caches, MetricKit payloads | Unit (export/import/erase) + UI | 3–4 | services ✅ `DataEraser`; UI ✅ `testEraseAllDataReturnsToOnboarding` (iOS); app ✅ `eraseAllDataResetsEverything` |
| X04.3 | Export Diagnostics produces a redacted text file (app/OS version, device class, settings, recent | Unit (export/import/erase) + UI | 3–4 | services ✅ `Diagnostics`; UI implemented, manual check (H3/H7) |

## Manual checks (recorded in `docs/HUMAN_HANDOFF.md`)

- VoiceOver full pass and Accessibility Inspector review on iPhone, iPad and Mac (B8); includes macOS sidebar contrast (ADR-0019).
- StoreKit sandbox purchase with a Sandbox Apple Account on a device (B4.10).
- Instruments: cold launch < 1.0 s, menu bar popover < 100 ms, scrolling, memory (B3).
- Testing on iOS 17 / macOS 14 (minimum OS; only iOS 27 runtime installed on the build Mac — ADR-0004).
