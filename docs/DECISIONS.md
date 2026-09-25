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
`Intents/`, `Resources/`, `Config/`) are created as groups inside the existing `RequestPad/` app folder;
`UITests/` = existing `RequestPadUITests/`. Approved by the human.
Consequences: paths in scripts/CI reference `RequestPad.xcodeproj` at the root.

### ADR-0002 — Identifiers
Decision (approved by the human): bundle ID `lk.eonix.RequestPad` (case preserved — bundle IDs are case-sensitive and
this one may already be registered). Lowercase prefix for everything else: IAP product IDs
`lk.eonix.requestpad.pro.monthly|yearly|lifetime`, subscription group "Pro", Keychain service = bundle ID,
logging subsystem = bundle ID, OAuth redirect `requestpad://oauth/callback`.
Consequences: the B4 table's `com.YOURTEAM.requestpad.*` maps to `lk.eonix.requestpad.*`.

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
Consequences: known product limitation, stated in metadata FAQ. Exact CIDR key syntax: **Unverified: NSExceptionDomains
CIDR entries** — verify with a live request test in Phase 3.

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
