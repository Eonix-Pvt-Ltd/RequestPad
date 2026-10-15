# Decisions (ADR log)

Format: context → decision → consequences. Newest at the bottom. "Unverified: <API>" entries must be re-verified in
Phase 7 before archiving.

## Human-supplied inputs (B0.8) — 2026-09-25

| Input | Value |
|---|---|
| Xcode project | `RequestPad.xcodeproj` at the repository root (supplied, committed) |
| Reverse-DNS prefix | `lk.eonix` |
| Bundle ID | `lk.eonix.RequestPad` (kept exactly as supplied) |
| Apple Team ID | `835LNLUPAJ` |
| Privacy URL | `https://requestpad.eonix.lk/privacy` |
| Terms URL | `https://requestpad.eonix.lk/terms` |
| Support URL | `https://requestpad.eonix.lk/support` |
| Support email | `support@eonix.lk` |

No placeholders are used. The human supplied only the domain `requestpad.eonix.lk`; the `/privacy`, `/terms`,
`/support` paths were chosen by the agent and must be published at exactly those paths (HUMAN_HANDOFF item).

---

### ADR-0001 — Project stays at the repository root
Context: B2 places the project at `App/RequestPad.xcodeproj`; the supplied project is at the root with sources in
`RequestPad/`, `RequestPadTests/`, `RequestPadUITests/`. B1 forbids moving or re-creating it.
Decision: keep the project and its folders where they are. The B2 `App/` subfolders (`Shared/`, `iOS/`, `macOS/`,
`Intents/`, `Resources/`) are created inside the existing folder-synchronized `RequestPad/` app folder;
`UITests/` = existing `RequestPadUITests/`. Approved by the human. Amended in Phase 1: `Config/` lives at the repo
root as a normal (non-synchronized) group, because files inside the synchronized `RequestPad/` folder are
auto-added to the app target and xcconfigs must not be.
Consequences: paths in scripts/CI reference `RequestPad.xcodeproj` at the root.

### ADR-0002 — Identifiers
Decision (approved by the human): bundle ID `lk.eonix.RequestPad` (case preserved — bundle IDs are case-sensitive and
this one may already be registered). Lowercase prefix for everything else: IAP product IDs
`lk.eonix.requestpad.pro.monthly|yearly|lifetime`, subscription group "Pro", Keychain service = bundle ID,
logging subsystem = bundle ID, OAuth redirect `requestpad://oauth/callback`.
Consequences: every product identifier in the brief's B4 table uses the `lk.eonix.requestpad.` prefix.

### ADR-0003 — Package workspace
Decision: a single local Swift package `RequestPadKit` at the repo root (`Package.swift`, `Sources/RP*`, `Tests/RP*Tests`)
with five library products, added to the supplied project as a local package dependency. Zero third-party
dependencies in V1 (YAML subset, JSONPath, GraphQL, `.bru` codecs are hand-written).

### ADR-0004 — Platforms, OS minimums, language mode
Context: the supplied project targets iOS/macOS/visionOS 27.0 with Swift 5. Part A requires iOS 17.0 / macOS 14.0.
Decision (human: "use recommended"): `IPHONEOS_DEPLOYMENT_TARGET = 17.0`, `MACOSX_DEPLOYMENT_TARGET = 14.0`,
visionOS removed from `SUPPORTED_PLATFORMS`, `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`.
Consequences: every API newer than iOS 17 / macOS 14 is `#available`-guarded. Only the iOS 27 simulator runtime is
installed on the build machine; testing on iOS 17 needs an extra runtime or device (HUMAN_HANDOFF item).

### ADR-0005 — One editing model for native and folder collections
Decision: RPCore value types are the single model; SwiftData stores them as versioned JSON blobs in a small set of
records; `.bru` files are read into the same value types.
Consequences: SwiftData schema is small and stable; migrations are rare; queries over nested fields are not needed
(search runs over the in-memory index).

### ADR-0006 — No App Group
Context: B5/B7 require an App Group only for widgets/extensions. Part A lists none (App Intents run in the app target).
Decision: no App Group entitlement in V1. Keychain access group = default app identifier group.

### ADR-0007 — No automatic retry of user requests
Context: B1 asks for exponential backoff with jitter on 429/5xx.
Decision: applies to app-initiated calls only (OAuth token/refresh, GraphQL introspection): 3 attempts, full jitter,
honors `Retry-After`. User-sent requests and runner requests are sent exactly once and the real status is shown.
Rationale: an API client that silently retries hides the behavior being debugged and can duplicate non-idempotent
writes.

### ADR-0008 — Pro history cap
Part A specifies 100 for Free and is silent for Pro. Decision: 1,000 (bounded memory/storage; simplest).

### ADR-0009 — Sample collection is outside the free limit
Decision: the Sample collection (kind `sample`) does not count toward "1 collection". Keeps App Review's path working
regardless of what the reviewer created first. It is subject to the 30-request cap like the free collection.

### ADR-0010 — App Transport Security for an API client
Context (verified 2026-09-25 against developer.apple.com, `NSAllowsLocalNetworking` page): "In iOS 17, iPadOS 17, and
macOS 14, ATS no longer allows connections to IP addresses by default. Add individual IP addresses and CIDR ranges in
the NSExceptionDomains dictionary." B1/B8 forbid `NSAllowsArbitraryLoads`.
Decision: `NSAllowsLocalNetworking = YES` (unqualified hosts incl. `localhost`, `.local`) + `NSExceptionDomains` with
`NSExceptionAllowsInsecureHTTPLoads` for `127.0.0.0/8`, `::1`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`,
`169.254.0.0/16`, `fe80::/10`, `fc00::/7`. Plain HTTP to public hosts is blocked and explained in-app (F01.8).
Consequences: known product limitation, stated in the support FAQ. CIDR key syntax verified 2026-09-25 against the
`NSExceptionDomains` documentation ("In iOS 17, iPadOS 17, and macOS 14, you can use … a classless inter-domain
routing (CIDR) range"). Note from the same page: an IP exception does not apply when a host is reached by a DNS name
that resolves to that IP, so `http://myserver.lan` style names are only allowed when unqualified or `.local`.
Runtime behavior verified in Phase 3 (app-hosted `PlatformIntegrationTests`, macOS): plain HTTP to `127.0.0.1`
and `localhost` succeeds; `http://example.com` fails with `appTransportSecurityRequiresSecureConnection`;
`http://10.255.255.1` is not rejected by ATS (it times out).

### ADR-0011 — No web views; "Preview" = images only
B7/B10.7 disallow web views. HTML responses show in Raw with syntax highlighting; Preview supports images only.

### ADR-0012 — Lapsed Pro
Data created under Pro is never deleted or hidden. Beyond Free limits it becomes read-only (viewable, exportable,
sendable only if within limits), and folder collections stay readable. Rationale: 5.1.1 honesty, no data hostage.

### ADR-0013 — Variable precedence
Verified against docs.usebruno.com/variables/overview (2026-09-25): runtime → request → folder → environment →
collection → global.

### ADR-0014 — YAML subset
Part A refers to a YAML parser "shared design with DevKit"; DevKit is not in this repo. Decision: standalone YAML 1.2
subset parser in RPCore sufficient for OpenAPI documents: block/flow mappings and sequences, plain/single/double-quoted
scalars, literal/folded block scalars, comments, document markers, anchors/aliases with an expansion cap of 100;
tags other than core schema are rejected with a clear error.

### ADR-0015 — Template code and entitlements removed
Context: the supplied project contained Xcode template code (`Item.swift`, template `ContentView` with SwiftData
`Item`, `fatalError` on container failure) and CloudKit + push (`aps-environment`) entitlements with
`UIBackgroundModes = remote-notification`. Part A lists neither iCloud sync nor APNs; B7 forbids unlisted
capabilities; B0.2 forbids placeholder code.
Decision (approved by the human): remove `Item.swift`, replace `ContentView`/`RequestPadApp` with the real app, remove
CloudKit/push entitlements and the background mode (Phase 1).

### ADR-0016 — Toolchain
Installed: Xcode 27.0 (27A266a). B1 requires "Xcode 26 or later"; Xcode 27 satisfies it. CI uses the newest Xcode on
the `macos-26` GitHub runner (or later image) and records the version in the job log.

### ADR-0017 — Pace and git workflow
Human decision: each phase is built on a `phase-N-*` branch, committed, pushed, and merged to `main` at the phase
gate. The agent stops at each gate for approval (user's global CLAUDE.md).

### ADR-0018 — Export compliance (initial determination; re-check in Phase 7)
Cryptography used: OS TLS via URLSession; Keychain; SHA-256 (CryptoKit `SHA256`) for PKCE code challenge only;
`SecRandomCopyBytes` for PKCE verifier/state. No other cryptography, no `swift-crypto`, no encryption of data at rest
by the app. Therefore `ITSAppUsesNonExemptEncryption = NO` (authentication-only use, exempt), matching Part A A12.
Phase 7 re-check: SHA-256 is used in three places, all hashing — the PKCE challenge, OAuth token cache keys, and
content hashes that detect external changes to `.bru` files. No encryption or decryption of data by the app; the
determination (`NO`) is unchanged.

### ADR-0019 — Accessibility audit exemptions (macOS framework elements)
Context: `performAccessibilityAudit()` on macOS 27 reports (a) "Element has no description" for the unlabeled
`Group` SwiftUI creates around each window's content and each `NavigationSplitView` column, and for the system
Touch Bar element; (b) contrast failures inside the translucent sidebar, whose result depends on whatever windows
are behind it (verified from the failure recording: a Finder window showed through the sidebar material).
Decision: `RequestPadUITests/AccessibilityAudit.swift` exempts exactly those framework-owned elements (containers
matched by frame, only for `sufficientElementDescription`) and contrast issues inside the macOS sidebar column
only. Contrast remains fully audited on iOS/iPadOS and in the macOS detail area, and is checked manually on macOS
(HUMAN_HANDOFF H3). Tests may add per-element `VerifiedExemption`s only with evidence recorded in SDLC_LOG.
Real findings fixed in Phase 1 instead of exempted: a dimmed empty-state title/icon combination (replaced by
`RPUI.EmptyStateView`) and an over-narrow sidebar.

### ADR-0020 — Placeholder check does not match `{{`
The brief asks `lint.sh` to fail on any `{{`. RequestPad's variable syntax is `{{name}}`, which appears legitimately
in code, fixtures and docs. `lint.sh` therefore matches only the brief's four named URL/email placeholders, its
team-prefix placeholder and the `.invalid` fallback domain (exact patterns in `scripts/lint.sh`).

### ADR-0021 — How package tests run under xcodebuild
A project cannot list a local package's test targets in its scheme when the package sits at the project root (Xcode
reports "isn't a member of the specified test plan or scheme"), and `xcodebuild` in the root directory picks the
project over `Package.swift`. Decision: commit `.swiftpm/xcode/package.xcworkspace` (a one-file workspace pointing at
the package) and run package suites with `-workspace .swiftpm/xcode/package.xcworkspace -scheme
RequestPadKit-Package`, which yields xccov coverage per module. App suites run via `-project RequestPad.xcodeproj
-scheme RequestPad`.

### ADR-0022 — CI security scanning without third-party dependencies
There are no third-party dependencies, so there is nothing for a dependency scanner to audit; `Package.resolved`
does not exist. If a dependency is added, CI must add `osv-scanner` on `Package.resolved` in the same change.
Secret scanning: gitleaks 8.30.1 binary, SHA-256 verified, full history. SAST: Clang static analyzer
(`xcodebuild analyze`) plus Swift 6 strict concurrency, warnings-as-errors, ASan and TSan runs. Semgrep's Swift
support is limited and adds a third-party tool for little signal; not adopted. GitHub Actions are pinned to commit
SHAs.

### ADR-0023 — Test bundles run with ad hoc signing on CI
CI runners have no signing certificates. `CI=true scripts/test.sh` overrides macOS signing to ad hoc (`-`) for test
runs only; archives always use automatic signing with team `835LNLUPAJ`.

### Verified (Phase 5): StoreKit configuration file format
`RequestPadTests/StoreKit/Products.storekit` (version 4 JSON) loads in `SKTestSession`: `StoreKitTests` read all three
products with their prices, periods and the 7-day free trial, and run purchases, Ask to Buy, refunds, expiry and
failures against it. It moved from `RequestPad/Resources` to the test target in Phase 5 (ADR-0041).

### Verified (Phase 7): required-reason codes in PrivacyInfo.xcprivacy
Checked against Apple's `NSPrivacyAccessedAPITypeReasons` reference (fetched as JSON on 2026-09-26) and a scan of
all first-party code for required-reason APIs (UserDefaults, file timestamps, boot time, disk space, active
keyboards). Used: UserDefaults for the app's own settings → `CA92.1`; file modification dates of the app's own
MetricKit files in its container (Diagnostics) → `C617.1`. `3B52.1` (timestamps of user-granted files) was removed:
the folder repository and watcher read only directory/symlink flags, never timestamps. No boot-time, disk-space or
keyboard APIs are used. The archived apps (macOS and iOS) contain the manifest. Xcode Organizer's privacy report
is a manual step (HUMAN_HANDOFF H10).

### Verified (Phase 3): `com.apple.security.files.bookmarks.app-scope`
Security-scoped bookmark creation, resolution and access work in the sandboxed, signed macOS app
(`PlatformIntegrationTests.securityScopedBookmarksWorkInSandbox`). Re-check the archived entitlements in Phase 7
(`codesign -d --entitlements`).
Phase 7: the Release archive's signed entitlements (macOS) are exactly app-sandbox, bookmarks.app-scope,
user-selected read-write, network client/server and the app's own keychain group, with the hardened runtime; no
debugging entitlement. The iOS archive is development-signed locally (`get-task-allow`); the App Store export
re-signs with the distribution certificate (H10).

### ADR-0024 — OpenAPI path templates become Bruno path parameters
PRD P02.1 originally said `{{param}}`. Bruno represents path parameters as `:param` in the URL plus a
`params:path` block, and RequestPad's resolver substitutes them. Importing `{petId}` as `:petId` keeps imported
collections identical to what Bruno writes, so they round-trip through `.bru` files unchanged. PRD updated.

### ADR-0025 — Lenient HTTP methods from `.bru` files
Bruno accepts methods that are not RFC 9110 tokens (its own fixture uses `CUSTOM@METHOD`). RequestPad opens and
round-trips them (`HTTPMethod(lenientBruValue:)`); `isValidForSending` is false and the services layer refuses to
send such a request with a clear error. User-typed methods remain strictly validated.

### ADR-0026 — Defaults for missing `.bru` keys
A method block without `body:` decodes as body mode `none`; without `auth:` as auth mode `none` (Bruno's grammar
package sets no default; `none` is the conservative choice — nothing is sent that the file doesn't state). Keys
absent in the original file are not added on save while their value is the default (`seq: 1`, `type: http`,
`auth: none`, `body: none`), so unchanged files stay byte-identical.

### ADR-0027 — YAML expansion limit ("billion laughs")
The alias count cap (100) alone does not stop exponential expansion: 63 aliases in nested flow sequences expand to
≈43 million nodes (found by the Phase 2 test suite). The parser also counts nodes with each alias weighted by its
expanded size and rejects documents above 1,000,000 nodes, in ~2 ms for the attack document.

### ADR-0028 — Bruno test fixtures
`Tests/RPCoreTests/Fixtures/bru/bruno/*.bru` are copied from `usebruno/bruno` (`packages/bruno-lang/v2/tests`,
MIT License, notice in `LICENSE-bruno.md` alongside). They are test resources only and are not shipped in the app.

### ADR-0029 — Package String Catalogs
RPCore/RPData user-facing strings use `String(localized:bundle: .module)` with English source text as keys. V1 is
English-only (PRD); keys absent from a package's `Localizable.xcstrings` fall back to the source text. Catalogs are
synced from the compiler-extracted strings in Xcode before any localization is added.

### ADR-0030 — No deep recursion on untrusted input
Found in Phase 2 by running the suite under AddressSanitizer: parsing a 256-level JSON document recursively
overflowed a 512 KB stack (the size of Swift concurrency threads, where the app parses response bodies), and even
in Debug a 128-level document overflowed a 128 KB stack. A hostile server response could have crashed the app.
Decision: the JSON parser, JSON serializer, semantic equality, JSONPath recursive descent and the YAML flow-collection
scanner are iterative (explicit heap stacks, frames mutated in place so appends stay O(1)). YAML block nesting
remains recursive (depth ≤ 64) but `YAMLParser.parse` runs on a dedicated 8 MB-stack thread (`LargeStack`), which is
acceptable because YAML is only parsed for user-initiated imports. `DeepNestingTests` parses, serializes, queries
and compares maximum-depth JSON, YAML and GraphQL documents on a 512 KB-stack thread; the whole suite passes under
ASan and TSan. Cost: 10 MB JSON parse 0.60 s → 0.77 s (Debug), within budget.

### ADR-0031 — No synchronizable Keychain items; no `setSynchronized`
B5 describes toggling iCloud Keychain sync per item. Part A lists no data that syncs, so every item is
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` with `kSecAttrSynchronizable = false`, and no toggle is built
(it would be untested-in-production code). If a future version syncs secrets, add `setSynchronized(_:for:)` as B5
specifies, with its tests.

### ADR-0032 — No typed-throws function values
Storing a closure whose type has typed `throws` needs runtime support that ships in macOS 15 / iOS 18; with
deployment targets macOS 14 / iOS 17 the compiler rejects it. Stored closures use untyped `throws` and convert to
the module's error type at the boundary; non-escaping typed-throws parameters and typed-throws functions are fine.

### ADR-0033 — macOS `keychain-access-groups` entitlement (defect fixed in Phase 3)
The app-hosted test found `errSecMissingEntitlement` (-34018) when the signed macOS app used the data-protection
keychain: `RequestPad-macOS.entitlements` lacked `keychain-access-groups` (listed in B7). Added
`$(AppIdentifierPrefix)lk.eonix.RequestPad` (the app's own group only; no sharing). iOS uses the default
application-identifier group. Package tests on macOS use the legacy keychain because the unsigned test runner
has no entitlements; the app-hosted test covers the production configuration.

### ADR-0034 — Services design choices
- User requests are sent once; `RetryPolicy` applies only to OAuth token and GraphQL introspection calls (ADR-0007).
- `ASWebAuthenticationSession` runs with `prefersEphemeralWebBrowserSession = true` (no shared browser cookies;
  most privacy-preserving). Users sign in on each "Get New Token"; tokens are cached in the Keychain.
- OAuth tokens are keyed by grant, endpoints, client ID and scope (SHA-256 prefix), so collections sharing a
  configuration share a token.
- History stores the unresolved request (templates) and a response summary; failed sends are recorded with a short
  error summary (F06.1).
- An explicit `Cookie` header wins over the cookie jar; `Authorization` and `Cookie` are dropped on cross-origin
  redirects.
- Response bodies over 10 MB spool to `tmp/Responses`; downloads over 2 GB are cancelled.
- Local Echo binds 127.0.0.1 only; `/redirect-to` accepts only loopback targets (no open redirect).

### ADR-0035 — Local Echo on iOS: no `acceptLocalOnly`; bodiless status codes (defects fixed in Phase 3)
Running the services suite on the iOS simulator found that Local Echo accepted no connections on iOS
(`NWParameters.acceptLocalOnly = true` stops the listener from receiving loopback connections there; macOS was
unaffected). The listener is restricted to loopback by `requiredLocalEndpoint = 127.0.0.1` instead, and
`LocalEchoServerTests.isNotReachableThroughNetworkInterfaces` connects through the machine's LAN address and
expects failure. The same investigation found Local Echo sending a body with 204 responses and with HEAD responses
(forbidden by RFC 9110 §6.4.1); both fixed and tested.

### ADR-0036 — Command-line builds use a private DerivedData folder
`xcodebuild` waited for minutes on "Reload Package" while the user's Xcode had the project open (shared DerivedData
build lock). `scripts/test.sh` now passes `-derivedDataPath build/DerivedData`, so scripted runs never contend
with the IDE.

### ADR-0037 — macOS UI tests and the launch window; ⌘N is New Request
On this development Mac, SwiftUI opened no window when the app was launched directly (as XCUITest does) under the
bundle ID `lk.eonix.RequestPad`, even for a minimal `WindowGroup { Text }` app with that bundle ID, while the same
binary launched through LaunchServices showed its window. A minimal app with another bundle ID opened its window,
so this is per-bundle state on the host, not app code (the persisted state is in the sandbox container, which the
shell cannot read). A fresh install, as App Review sees it, is unaffected. UI tests therefore launch with
`-ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO` and, on macOS, open a window with File › New Window
when none appears, as a user would. This also explains the Phase 3 smoke-test failure.
Building the fallback exposed a real conflict: SwiftUI's New Window and our New Request both used ⌘N. The File
menu's new-item group is replaced: ⌘N = New Request (the app's primary "new" action), ⌥⌘N = New Window.
The default window size is 1100×720 so the onboarding sheet (560×520) fits inside it; at the old 900×450 the
sheet's buttons were outside the window and could not be clicked.

### ADR-0038 — Accessibility decisions from the Phase 4 audits
- **Accent color.** The default system blue is 4.0:1 on white. The app accent is #0A63C9 in light mode (5.8:1 on
  white, 5.2:1 on grouped backgrounds, 5.8:1 for white text on it) and #5AA0FA in dark mode (6.3:1 on #1C1C1E,
  5.2:1 on #2C2C2E). No blue can carry white text at 4.5:1 while also reading at 4.5:1 on dark backgrounds, so
  prominent buttons use `prominentButtonStyle()`: white labels in light mode, black in dark mode (7.8:1).
- **Dynamic Type.** On iOS the audit's Dynamic Type and text-clipped findings include system bar buttons and
  wrapping text that it cannot size-test. They are attached to the test results for review, not failed, and
  `testLargestDynamicTypeSizes` captures every main screen at AX-XXXL for visual verification (evidence in
  SDLC_LOG). Real problems found this way are fixed (onboarding content scrolls at large sizes; history URLs are
  not truncated at accessibility sizes).
- **Touch targets.** Icon-only buttons use `minimumHitTarget()` (44×44 pt on iOS). Switches are regular size.
- **Settings on iPhone** is a sidebar row, not a toolbar button: bar items move into an overflow menu at the
  largest text sizes.
- **iOS contrast sampling.** The contrast audit samples pixels. Elements cut off by the screen edge and navigation
  bar buttons (drawn by the system on Liquid Glass over scrolling content) measure the backdrop, so those two cases
  are exempt from the contrast audit on iOS; the accent colors above are what those buttons use.
- **iPad audit sampling.** Findings without an element come from the dimmed content behind a form sheet and from
  rows clipped by the sheet; contrast findings for elements that are not hittable (scrolled out of a sheet's visible
  area) and for the iPad glass sidebar measure the backdrop, as on macOS
  (ADR-0019). These are exempt; the manual pass (HUMAN_HANDOFF H3) covers them. Choosing a search result now hides
  the keyboard on iPad, and destructive buttons use `Color.textRed` (system red is 4.0:1 on white).
- **Text colors.** `Color.textSecondary`, `textGreen`, `textOrange`, `textRed`, `textPurple` and `textBlue` (RPUI)
  replace the system secondary label and system tints for text; each is ≥ 4.5:1 on the light and dark system
  backgrounds. Section headers and footers use them. On a selected list row, badges switch to the row's own
  foreground (`backgroundProminence`).
- **macOS menu buttons.** The "action missing" audit is exempt for `menuButton` elements only: toolbar menus open
  with AXShowMenu (VoiceOver VO-Space), not AXPress.
- **Container identifiers.** An accessibility identifier on a container replaces its children's identifiers on
  macOS unless the container is `.accessibilityElement(children: .contain)`; containers with identified children
  use `.contain`.

### ADR-0039 — Multipart file references
Files picked for multipart fields are stored as a path relative to the collection folder when they are inside a
folder collection (portable in git, as Bruno does), otherwise as `bookmark:<base64>` (a security-scoped bookmark,
so sandboxed access survives relaunch). `BookmarkFileResolver` resolves both; relative paths cannot escape the
collection folder.

### ADR-0040 — StoreKit 2 entitlement design (Phase 5)
- The App Store is the only source of truth: `Transaction.currentEntitlements` is read at launch, whenever the app
  becomes active, after purchases and restores, and on every `Transaction.updates` event (Ask to Buy approvals,
  renewals, refunds, purchases on other devices). No entitlement is cached in UserDefaults (user-editable).
- Only transactions whose JWS verifies are used; unverified ones are logged without identifiers and never grant
  Pro. Transactions are finished after they are delivered.
- `EntitlementResolver` (pure) grants Pro for an unrevoked lifetime purchase or an unrevoked, not upgraded
  subscription whose expiration date is in the future. Expiry sends no update, which is why entitlements are re-read
  when the app becomes active.
- One paywall (`PaywallView`) for every trigger (B4.6), with prices, periods and trial terms from StoreKit, the
  auto-renewal disclosure, Restore Purchases, Terms and Privacy links and a close control. Settings adds Restore,
  Manage Subscription and (iOS) Redeem Offer Code.
- The paywall is presented by the topmost presenter (root view or a registered sheet); on iOS a sheet cannot be
  presented from the root while another sheet is up, which had silently swallowed Pro prompts inside sheets.

### ADR-0041 — StoreKit testing
- `Products.storekit` lives in `RequestPadTests/StoreKit/`, so it ships in the test bundle only (never in the
  app) and the scheme's Run action uses the same single copy.
- The app-hosted test target adds `-Xcc -Wno-deprecated-declarations` (test target only): `StoreKitTest`'s own
  header uses a StoreKit 1 type deprecated in macOS 15, which warnings-as-errors turned into a build error. App
  code and all other targets keep warnings as errors.
- `SKTestSession.expireSubscription` does not shorten the transaction's recorded period, so expiry is tested with
  accelerated time (`oneRenewalEveryTwoSeconds`) and renewal turned off, which exercises the real date-based path.
- UI tests use `FakeStoreClient` (Debug-only `-UITestMode`); `-UITestPro` starts with a lifetime purchase.

### ADR-0042 — System integrations (Phase 6)
- **One app instance.** `AppRuntime` owns the single `LaunchModel`; windows, App Intents (which run without a
  window), the menu bar and Services all use it, so the SwiftData store is never opened twice in a process.
  Outside entry points ask a window to show something through `AppModel.requestedOpen`; the first window takes it,
  and on macOS a window is opened if none is visible.
- **Shortcuts "Send Request" (P08).** `openAppWhenRun = false`; parameters are a saved request (`RequestEntity`,
  id `collectionID|key`) and an optional environment (default: the collection's active one; an environment from
  another collection is an error). The intent re-reads entitlements, returns a `SentResponse` (status code, status,
  duration, body — text up to 1 MB, binary described) and a dialog, and fails with a specific message for free
  users, deleted requests and mismatched environments. Requests sent this way are recorded in History like any send.
- **Menu bar Quick Send (P09).** `MenuBarExtra` (window style), inserted only while enabled in Settings and Pro is
  active; off by default. It reads already-loaded collections, sends through the same path as the app, shows the
  first 64 KB of the body, and "Open in RequestPad" opens the request or the typed URL.
- **Services (X01.3).** `NSServices` "Send URL with RequestPad" (message `sendURL`). The selection is untrusted:
  `SharedURL` accepts only one http(s) URL or a bare host (≤ 8 KB); anything else returns an error to the system.
  The result opens as an unsaved request; nothing is sent automatically.
- **Launch at login.** `SMAppService.mainApp`, off by default; the system status is the source of truth
  (re-read when Settings appears), including "requires approval" with a button to System Settings › Login Items.

### ADR-0043 — Hardening results (Phase 7)
- **End-to-end tests** through the app model against the real URLSession stack and Local Echo cover every PRD
  criterion that previously rested on a manual UI check, except X01.4 (relaunch restoration, manual H9).
- **Fuzzing:** a deterministic, seeded harness mutates valid seeds and random bytes for 15 parsers (2,000 inputs
  each) plus Local Echo's HTTP parser (3,000 byte streams in random TCP-sized pieces). Invariants: JSON, `.bru` and
  shell-word round trips; every target must accept a minimum share of inputs so deep paths are exercised. Runs in
  every test run, including ASan/TSan.
- **Defects found and fixed:** (1) saving an editor whose base version changed on disk silently overwrote the external
  change — now a conflict (P01.4), and editors without local edits follow the new version; (2) OpenAPI paths with
  undeclared `{templates}` were sent literally — now path parameters (P02.1); (3) two log statements marked
  error descriptions public, which can contain file paths with the user name — now private.
- **Secret scanning:** gitleaks over the full history and the working tree; `.gitleaks.toml` allowlists only two
  placeholder tokens in named parser fixtures, per rule. **SAST:** semgrep (Swift + secrets rules) finds nothing; a
  pinned semgrep job was added to CI.
- **Settings (X02.2):** "Follow Redirects for New Requests" default and the tier's history size are shown.

### ADR-0044 — App Store assets and metadata (Phase 8)
- **Icon:** an Icon Composer bundle `RequestPad/AppIcon.icon` (two vector layers: braces and a paper plane on a
  system blue gradient, Liquid Glass on both groups) replaces the asset-catalog icon. actool compiles it for every
  platform (`AppIcon.icns` + `Assets.car` on macOS, the iOS icon set on iOS). Default, Dark, Clear and Tinted
  renditions were rendered with `ictool` and reviewed. The brief's "Mono" is what Icon Composer calls Clear (and the
  system derives Tinted from it); both come from the same layers, so no separate artwork is needed. The layers are
  plain SVG, so the icon is reviewable in git.
- **Screenshots from the real app:** a Debug-only `-ScreenshotScenario <name>` launch argument (with `-UITestMode
  -UITestPro`) makes `ScreenshotDirector` stage a scene through the app's own flows — load sample data, select a
  request, pick a tab, send, open the runner or environments sheet — so every image shows real UI and real Local Echo
  responses (Guideline 2.3). iOS images come from a UI test on dedicated simulators with a fixed status bar; Mac images
  are `screencapture` of a 1440×900-point window (2880×1800 pixels). The code is compiled out of Release.
- **Metadata deviations from Part A (approved by the owner on 2026-09-26):** the subtitle "HTTP & GraphQL, Bruno-compatible"
  is 32 characters (limit 30) and names another app; keywords "postman" and "bruno" name other apps (Guideline 2.3.7,
  B10.2). Replaced by "HTTP & GraphQL, git-friendly" and neutral keywords. The description names Postman and Bruno
  only as file formats the app imports/reads, which is factual.
- **`scripts/check-metadata.py`** in `lint.sh` enforces the length limits and forbidden terms on every run; `lint.sh`
  also rejects web-view, dynamic-loading and arbitrary-loads APIs.
- **Defects found while staging screenshots and fixed:** (1) the "Welcome to RequestPad Pro" alert appeared at every
  launch for existing Pro users — `didUnlockPro` now fires only for a change after the first entitlement read;
  (2) the JSON tree opened fully collapsed at the root — the root's members are now the first level; (3) every
  response read "200 No Error" (Foundation's status description) — now the IANA reason phrase (`HTTPReasonPhrase`),
  and unregistered codes show the status class; (4) PRIVACY.md promised "Export Diagnostics" but Settings only
  showed text — it now shares a `.txt` file; (5) opening a request inside a collapsed folder did not reveal it in the
  sidebar — folders now expand to the selection; (6) `LSApplicationCategoryType` was missing (required for Mac
  uploads) — set to Developer Tools; (7) on macOS the window, menu bar item and runtime loaded the app model
  concurrently at launch (two store starts, two Local Echo starts) — `AppModel.load()` is now single-flight and the
  entitlement first-read check is captured before its await, so overlapping reads are never an "unlock";
  (8) the Environments footer was cut off on macOS (list footers are one line) — shortened.

### ADR-0045 — Distribution signing and upload (Phase 9)
- **Cloud-managed signing:** no Apple Distribution certificate is installed on the build Mac. `archive.sh` exports
  with automatic signing and `-allowProvisioningUpdates`, and Xcode signs with Apple's cloud-managed distribution
  certificates. No private distribution key lives on a laptop, and nothing needs renewing locally. The one
  requirement is an account role that may use cloud-managed certificates (Admin or App Manager with that access).
- **Upload stays human:** `scripts/upload.sh` wraps `xcodebuild -exportArchive` with `destination=upload` and an
  App Store Connect API key (never `altool`). It prints the version and build and asks for confirmation. The agent
  never runs it (B9; uploading is outward-facing). The key must live outside the repository, and the script checks
  this.
- **Build numbers:** one `CURRENT_PROJECT_VERSION` for both platforms (Universal Purchase), bumped before every
  upload, including beta fix builds.

### ADR-0047 — UI test fixes for Xcode 27 / iOS 27 / macOS 27 (2026-10-15)
Numbered after ADR-0046 on the `free-app` branch so both can merge.
- **iPad search keyboard.** On iOS 27, `UIApplication.sendAction(resignFirstResponder)` no longer dismisses the
  sidebar's `.searchable` field, so choosing a search result left the keyboard up (ADR-0038 says it hides). The
  audit then failed on three unlabeled buttons: the empty slots of UIKit's "Typing Predictions" bar
  (`SystemInputAssistantView`). The sidebar now binds the search field's focus with `.searchFocused` on iOS 18+ and
  clears it on selection; the old call stays as the iOS 17 fallback. The keyboard is fixed in the app, not exempted.
- **macOS sheets.** SwiftUI wraps a sheet's content in the same unlabeled hosting `Group` it puts in every window
  (ADR-0019): the tree is `Sheet › Group (sheet frame, no label) › content`. A label or container on the
  onboarding view lands one level below that group, so it cannot be fixed in app code. The ADR-0019 exemption
  (only `sufficientElementDescription`, only an unlabeled group matching the frame exactly) now also covers sheet
  frames.
- **Simulator choice.** `scripts/test.sh` picks simulators from the newest iOS runtime; it used to take the first in
  dictionary order (iOS 18.6), which Xcode 27 refuses to test on.
