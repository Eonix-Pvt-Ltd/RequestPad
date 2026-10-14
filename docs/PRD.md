# RequestPad — Product Requirements (V1.0.0)

Source: the RequestPad brief, Part A (restated here with decisions). Where a decision was made to fill a gap, the
ADR number in `docs/DECISIONS.md` is referenced.

## 1. Identity

| | |
|---|---|
| App name | RequestPad: API Client |
| Subtitle | HTTP & GraphQL, Bruno-compatible |
| Tagline | An unbloated API client. Git-friendly collections. Works on iPad. |
| Category | Developer Tools |
| Platforms | iPhone, iPad (iOS/iPadOS 17.0+), Mac (macOS 14.0+) — Universal Purchase |
| Bundle ID | `lk.eonix.RequestPad` (all platforms) — ADR-0002 |
| Account | None. No sign-in, no cloud, no telemetry. |

## 2. Problem and persona

**Primary persona — "Dana, backend/mobile developer".** Uses Postman or Bruno on a laptop, dislikes Postman's
account requirement and bloat, keeps API definitions in git, and wants to hit an endpoint from an iPad or iPhone when
away from the desk.

**Secondary persona — "Sam, iOS developer"** testing their own staging/LAN servers from the device they are building
for.

**Job to be done:** "Hit my APIs quickly with saved environments, keep collections in git, and test from anywhere."

**One core action that must be flawless:** compose a request → Send → read the response.

## 3. Success metrics (from A15)

Measured only through App Store Connect's opt-in App Analytics (no in-app telemetry — B1):
- First request sent ≥ 85 % of installs (proxy: retention day-1 + review sentiment; no in-app measurement exists).
- Collection saved ≥ 50 %.
- ~~Pro conversion ≥ 5 %~~ — removed (ADR-0046: no purchases).

## 4. Pricing

RequestPad is free. Every feature is included for everyone: no in-app purchases, no subscriptions, no ads, no
usage limits (ADR-0046). The former Free / Pro split (ADR-0009, ADR-0012) no longer applies.

| Capability | Included |
|---|---|
| Compose & send HTTP requests (all methods, params, headers, body kinds) | ✅ |
| Response viewer (status, timing, size, headers, JSON tree + filter, raw, image preview, save to file) | ✅ |
| JSON body editor with validation; form-urlencoded; multipart with file picker | ✅ |
| Collections stored in-app (native) | ✅ Unlimited collections and requests |
| Collections stored as `.bru` files in a user-selected folder (git-friendly) | ✅ |
| Environments & `{{variables}}`, secret variables in Keychain | ✅ |
| Auth: None / Inherit / Bearer / Basic / API key | ✅ |
| Auth: OAuth 2.0 client credentials, authorization code + PKCE | ✅ |
| History | ✅ Last 1,000 (ADR-0008) |
| cURL import / export | ✅ |
| OpenAPI 3.x import (JSON & YAML), Postman v2.1 collection import | ✅ |
| GraphQL body with schema introspection & autocomplete | ✅ |
| Response extraction rules → variables | ✅ |
| Collection runner (run a folder sequentially with assertions) | ✅ |
| Persistent cookie jar (per-collection toggle) | ✅ |
| Shortcuts action "Send Request" (returns body) | ✅ |
| macOS menu bar Quick Send | ✅ |
| macOS Services "Send URL with RequestPad" | ✅ |
| Local Echo server + sample collection | ✅ |
| Export / import app data (JSON), Erase all data, Export diagnostics | ✅ |

The bundled **Sample collection** (loaded via Settings → Developer → Load Sample Data) lets App Review and new users
evaluate every feature without external services.

## 5. Out of scope (V1 — do not start)

JavaScript pre/post-request scripts and tests, mock servers, team/cloud sync, WebSocket, gRPC, proxies/traffic
capture, iCloud sync of app data (iCloud Drive folders work through Files only), widgets, push notifications, HTML
rendering of response bodies (no web views — ADR-0011), plain-HTTP to public internet hosts (ATS — ADR-0010), visionOS.

## 6. User stories and acceptance criteria

IDs are stable and referenced by tests (`// AC: F01.2`) and by `docs/TEST_PLAN.md`.

### F01 — Compose and send an HTTP request
*As a developer, I want to compose a request with method, URL, query params, headers and body and send it, so that I
can see how my API responds.*
- **F01.1** Methods GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS are selectable; a custom method token (RFC 9110
  `token` chars) can be entered.
- **F01.2** Query params edited in the table and in the URL stay in sync both ways; disabled rows are not sent.
- **F01.3** Headers table supports enable/disable per row; duplicate header names are sent as separate fields.
- **F01.4** Body kinds: none, JSON, text, XML, form-urlencoded, multipart (text fields + files via file picker),
  GraphQL. The correct `Content-Type` is added unless the user set one explicitly.
- **F01.5** ⌘↩ sends on iPad (hardware keyboard) and Mac; a Send button is always visible; while in flight it becomes
  Cancel and cancellation stops the transfer within 1 s.
- **F01.6** Request timeout defaults to 30 s and is configurable per request (1–600 s); follow-redirects toggle
  (default on, max 10 hops).
- **F01.7** Network failures (offline, DNS, TLS, timeout, ATS block, local-network permission denied) show a specific,
  human-readable error with a recovery suggestion; nothing crashes.
- **F01.8** Plain `http://` to loopback, `.local`, unqualified hosts and RFC 1918 / link-local addresses works; plain
  `http://` to a public host shows the ATS explanation and suggests `https://` (ADR-0010).
- **F01.9** On iOS/iPadOS the first request to a LAN address shows the pre-permission explainer before the system
  Local Network prompt; the explainer is never shown for public hosts.
- **F01.10** Unsaved edits to any request persist as a draft and survive app relaunch.

### F02 — Response viewer
*As a developer, I want to inspect status, timing, size, headers and body, so that I can debug my API.*
- **F02.1** Shows status code + reason phrase, color **and** text/icon status class (never color alone).
- **F02.2** Shows total time and a timing breakdown (DNS, connect, TLS, request, waiting/TTFB, download) from
  `URLSessionTaskMetrics`, response size (headers + body bytes), protocol (HTTP/1.1, h2, h3), remote address, and TLS
  version/cipher suite when available.
- **F02.3** Headers tab lists all response headers; values are copyable.
- **F02.4** Body "Pretty" view: JSON rendered as a collapsible tree; a filter field accepts a JSON path
  (`$.data.items[0].id`, `$..name`, `[*]`) and shows matching nodes; invalid path shows an inline error.
- **F02.5** Body "Raw" view shows text with detected encoding (charset header → UTF-8 → Latin-1 fallback); invalid
  UTF-8 never crashes.
- **F02.6** Body "Preview" renders PNG/JPEG/GIF/HEIC/WebP images; other types show "No preview for <type>".
- **F02.7** Bodies > 10 MB are not rendered: the viewer shows size + "Save to File…" and the body is streamed to a
  temporary file, never held whole in memory. Bodies ≤ 10 MB render without blocking the main thread.
- **F02.8** "Save Response…" writes the body to a user-chosen location on every platform.

### F03 — Collections
*As a developer, I want to save requests into collections with folders, so that I can reuse them.*
- **F03.1** Create, rename, delete (with confirmation) collections, folders and requests; duplicate a request;
  reorder by drag & drop and by "Move Up/Down" commands (keyboard/VoiceOver accessible).
- **F03.2** Removed (ADR-0046). Was: free-tier limit of 1 collection × 30 requests and read-only data after a
  subscription lapsed (ADR-0012). Collections and requests are now unlimited.
- **F03.3** A collection can define default headers and default auth that requests inherit.
- **F03.4** Search filters requests by name, method and URL across the sidebar.

### F04 — Environments and variables
*As a developer, I want environments with variables and secrets, so that I can switch between dev/staging/prod
without editing requests.*
- **F04.1** Create/rename/duplicate/delete environments per collection plus one set of global variables.
- **F04.2** `{{name}}` interpolation in URL, params, headers, body, auth fields. Precedence (highest first):
  runtime (extracted) vars → request vars → folder vars → active environment → collection vars → globals
  (matches Bruno's documented precedence; ADR-0013).
- **F04.3** Unresolved variables are highlighted in the editor and listed in a pre-send warning; sending is still
  allowed (the literal `{{name}}` is sent).
- **F04.4** A variable can be marked secret: its value is stored only in the Keychain, masked (••••) in all UI, never
  written to `.bru` files, exports, history, cURL export (unless the user explicitly chooses "Include secret values"),
  or diagnostics.
- **F04.5** Revealing a secret requires Face ID / Touch ID / device passcode when the device supports it.
- **F04.6** The environment switcher is reachable from the request toolbar on every platform and via ⌘E.

### F05 — Auth helpers
*As a developer, I want auth helpers, so that I don't hand-craft auth headers.*
- **F05.1** Bearer adds `Authorization: Bearer <token>`; Basic adds RFC 7617 Base64 `user:pass`; API key adds a
  named header or query parameter.
- **F05.2** "Inherit" resolves auth from folder → collection.
- **F05.3** OAuth 2.0 client credentials: token endpoint, client ID, client secret (secret var), scope;
  credentials sent via Basic header or body (selectable); token cached in Keychain until `expires_in`; "Get new token"
  and "Clear token" actions.
- **F05.4** OAuth 2.0 authorization code + PKCE (S256): authorize & token endpoints, client ID, optional secret,
  scope, redirect URI `requestpad://oauth/callback` (shown with a Copy button); login runs only in
  `ASWebAuthenticationSession`; `state` is verified; refresh tokens used automatically when present.
- **F05.5** Auth errors (invalid_client, invalid_grant, user cancelled, state mismatch, network) show specific messages.

### F06 — History (1,000 entries)
*As a developer, I want a history of sent requests, so that I can re-run or save them.*
- **F06.1** Every sent request records a snapshot of the **unresolved** request (so secrets are not stored) and a
  response summary (status, time, size, content type, date). Bodies are not stored.
- **F06.2** History is capped (oldest pruned); can be searched, re-opened into a new tab, saved to a collection, and
  cleared.

### F07 — cURL import/export
- **F07.1** Paste a cURL command (from Chrome/Firefox/Safari "Copy as cURL", Postman, Bruno) → new request with
  method, URL, headers, body (`-d/--data*/--data-raw/--data-binary/--data-urlencode/-F/--form`), `-u`, `-X`, `-H`,
  `-G`, `-L`, `-k` (ignored with a notice — no custom trust, B1), `--compressed`; shell quoting (`'`, `"`, `$'…'`,
  backslash-newline) handled; unsupported flags listed in a notice.
- **F07.2** Export a request as a single-line and a multi-line cURL command, variables resolved and secrets masked by
  default; round-trip import(export(r)) == r for all supported fields (property-tested).

### F08 — Local Echo & sample data (App Review path)
*As an App Reviewer or new user, I want a local server that echoes requests, so that I can try every feature
without external services.*
- **F08.1** Settings → Developer → Local Echo toggle starts an in-process HTTP/1.1 server bound to 127.0.0.1 on a
  free port; the port is shown and exported as the global variable `echoBaseURL`.
- **F08.2** Echo returns JSON describing the received method, path, query, headers, body (UTF-8 or Base64), and
  supports `/status/{code}`, `/delay/{ms ≤ 10000}`, `/bytes/{n ≤ 20 MB}`, `/image.png`, `/cookies/set?k=v`,
  `/oauth/token` (client-credentials test grant) and `/graphql` (static introspection result + echo). It evaluates no
  user code and downloads nothing.
- **F08.3** Settings → Developer → Load Sample Data creates the Sample collection (targets `{{echoBaseURL}}`), a
  "Local" environment, and starts Local Echo.
- **F08.4** Echo caps request size at 20 MB, 16 concurrent connections, 30 s idle timeout; stops when toggled off and
  when the app terminates.

### P01 — Folder-backed `.bru` collections
*As a developer, I want my collections stored as Bruno `.bru` files in a folder I own, so that I can commit them to
git and share with Bruno users.*
- **P01.1** "Open Collection Folder…" picks a folder (Files on iOS — including iCloud Drive and other providers;
  `NSOpenPanel` on macOS); access persists across launches via a security-scoped bookmark; stale/denied bookmarks show
  a "Grant access again" state.
- **P01.2** Reads Bruno collection layout: `bruno.json`, `collection.bru`, `folder.bru`, `*.bru` requests,
  `environments/*.bru`; `.gitignore`, `.env` and other non-`.bru` files are left untouched.
- **P01.3** Every edit is written back to the corresponding `.bru` file atomically; unknown blocks and unknown keys are
  preserved byte-for-byte; round-trip of every fixture (parse → serialize) is lossless.
- **P01.4** External changes (git pull, Bruno desktop edits) are detected and reloaded; a conflict with unsaved local
  edits prompts Keep Mine / Use File.
- **P01.5** Secret environment variables follow Bruno's `vars:secret [ … ]` convention: names in the file, values only
  in the Keychain.
- **P01.6** "New Collection in Folder…" creates a valid Bruno collection (`bruno.json` + `collection.bru`).
- **P01.7** "Convert to Folder Collection…" exports a native collection into a folder as `.bru` files.

### P02 — OpenAPI 3.x import
- **P02.1** Imports OpenAPI 3.0.x and 3.1.x in JSON or YAML (≤ 10 MB) → a collection with a folder per tag,
  one request per operation, path params as Bruno path parameters (`/pets/:petId` + a path-params row; ADR-0024),
  query/header params, and example request bodies (from
  `example`, `examples`, or synthesized from schema, depth-limited to 8); `servers[0].url` becomes the `baseUrl`
  variable; security schemes map to Bearer/Basic/API key/OAuth2 auth.
- **P02.2** Local `$ref`s (`#/components/...`) resolve; external refs and cycles are reported, not followed.
- **P02.3** Malformed input shows the line/column (YAML) or key path of the failure; nothing partial is saved.

### P03 — Postman v2.1 import
- **P03.1** Imports Postman Collection v2.1 JSON: folders, requests, headers, query, body modes (raw, urlencoded,
  formdata, graphql), auth (bearer, basic, apikey, oauth2 client credentials), collection variables. Scripts are
  dropped with a notice listing affected requests.

### P04 — GraphQL
- **P04.1** GraphQL body kind with query editor and variables (JSON) editor; sent as `application/json` POST.
- **P04.2** "Fetch Schema" runs the standard introspection query; the schema is cached per endpoint URL.
- **P04.3** Editor offers completion for fields, arguments and types at the cursor based on the cached schema, and
  shows syntax errors inline.

### P05 — Response extraction rules → variables
- **P05.1** Per request, define rules `variable ← source` where source is status, a header name, or a JSON path in the
  body; after each successful response the variables are set in the runtime scope (and optionally persisted to the
  active environment).
- **P05.2** Rules round-trip to `.bru` as `vars:post-response` using Bruno's `res.body.path` / `res.headers.name` /
  `res.status` expressions; expressions outside that subset are preserved but shown as "unsupported (requires
  scripting)".

### P06 — Collection runner with assertions
- **P06.1** Per request assertions: status equals; JSON path equals / not equals / contains / exists; header equals.
  Stored as Bruno `assert` blocks (`res.status: eq 200`, `res.body.id: isDefined`).
- **P06.2** "Run Folder" (or collection) sends requests sequentially in sort order, applying extraction rules so later
  requests use earlier variables; shows per-request pass/fail, time, and a summary; can be cancelled; stop-on-failure
  option.
- **P06.3** Run results can be exported as JSON.

### P07 — Cookie jar
- **P07.1** Cookies from `Set-Cookie` are stored per domain (RFC 6265 domain/path/secure/expiry rules) and sent on
  matching requests; the jar can be viewed, edited, and cleared per domain; toggle per collection.
- **P07.2** With the jar turned off for a collection, cookies are not persisted between requests (ephemeral).

### P08 — Shortcuts "Send Request"
- **P08.1** App Intent "Send Request" with parameters Request (entity query over saved requests) and optional
  Environment; returns the response body as text plus status code; runs without opening the app.
- **P08.2** Removed (ADR-0046). Was: without Pro the intent returned a "Pro required" error.

### P09 — macOS menu bar Quick Send
- **P09.1** Optional `MenuBarExtra` (Settings toggle, default off) with a popover: pick a saved request or type a URL,
  choose environment, Send, see status/time and first 64 KB of the body; "Open in RequestPad" button.
- **P09.2** Popover opens in < 100 ms.

### X01 — Platform UX
- **X01.1 iPad:** three-column `NavigationSplitView` (collections / request / response), Split View & Stage Manager,
  keyboard shortcuts (⌘↩ send, ⌘N new request, ⌘S save, ⌘E environment, ⌘L focus URL, ⌘. cancel), pointer support.
- **X01.2 iPhone:** stacked navigation; request and response as segmented tabs; all controls reachable one-handed.
- **X01.3 macOS:** sidebar + request tabs (window tabs), full menu bar (File/Edit/View/Request/Window/Help), Settings
  scene, Services "Send URL with RequestPad" opens a new request with the selected URL, launch at login opt-in.
- **X01.4** Window/tab/last-selection state restores on relaunch.

### X02 — Onboarding, settings, legal, support
- **X02.1** First launch shows ≤ 3 skippable onboarding screens; no permission prompts during onboarding.
- **X02.2** Settings: appearance, default timeout, follow redirects, history size, Local Echo, Load Sample Data,
  Privacy Policy, Terms of Use, Support, Rate RequestPad, Export Diagnostics, Export/Import App Data, Erase All Data,
  launch at login (macOS), menu bar Quick Send (macOS).
- **X02.3** "Rate RequestPad" review prompt only after the 5th successful request and never more than the system
  allows; never on launch.

### X03 — Monetization — removed (ADR-0046)
The app has no in-app purchases, paywall or entitlements. IDs kept for traceability only.
- **X03.1** Removed (ADR-0046). Was: paywall content (products, price, trial terms, links).
- **X03.2** Removed (ADR-0046). Was: purchase / restore / refund-revocation flows.
- **X03.3** Removed (ADR-0046). Was: unlock on all the user's devices after purchase.

### X04 — Data control & diagnostics (B5/B1)
- **X04.1** Export App Data writes a versioned JSON of native collections, environments (secret values excluded),
  globals and settings; Import validates schema version and size (≤ 50 MB) and merges by natural key.
- **X04.2** Erase All Data removes SwiftData store, Keychain items, bookmarks, cookie jar, caches, MetricKit payloads
  and preferences, then returns to onboarding. Folder collections' files on disk are **not** deleted (they are the
  user's files) — stated in the confirmation dialog.
- **X04.3** Export Diagnostics produces a redacted text file (app/OS version, device class, settings, recent
  `os.Logger` entries from this process with URLs reduced to scheme+host, MetricKit summaries); no secrets, bodies,
  headers values or file contents.

## 7. Traceability

Every feature above (F01–F08, P01–P09, X01, X02, X04) has ≥ 1 acceptance criterion; X03 and the ACs marked
"Removed (ADR-0046)" are kept as IDs only. `docs/TEST_PLAN.md` (Phase 1+) maps each AC ID to the test(s) that verify
it; an AC without a test fails the Phase 7 exit criteria.
