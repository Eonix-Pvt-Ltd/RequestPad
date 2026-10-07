# App Review — prepared responses

Drafts for the most likely review questions, based on `docs/APP_REVIEW_CHECKLIST.md`.

**Process** (target: a reply within 24 hours of the message):
1. Paste the reviewer's message to the agent. It picks and adapts the matching draft and checks every statement
   against the current build.
2. Reply in App Store Connect → App Review → the submission's messages (Resolution Center). Attach a screenshot or
   screen recording when the reviewer could not find something.
3. When the reviewer is right, fix it with the hotfix path in `docs/RELEASE_RUNBOOK.md` §11 before replying. For a
   metadata or notes-only change, edit it in App Store Connect and reply without a new build.
4. If a reply doesn't resolve it, request a call via the App Review contact form or appeal to the App Review Board.

Keep replies short, specific and polite. Never argue about other apps.

---

## 2.1 — Could not locate the in-app purchases

> Thank you for reviewing RequestPad. The in-app purchases are offered on the RequestPad Pro screen, which you can
> reach in three ways:
> 1. Settings → "See Pro Features" (on Mac: RequestPad → Settings…, ⌘,).
> 2. Any Pro feature, e.g. open Sample → Basics → "Echo a GET", select the Assert tab, then tap "See RequestPad Pro".
> 3. Right-click or long-press the Sample collection → "Run Collection…".
>
> The screen lists RequestPad Pro Yearly and Monthly (auto-renewable, 7-day free trial for eligible customers) and
> Lifetime (non-consumable), with Restore Purchases, Terms of Use and Privacy Policy. All three products are
> attached to this submission. A screen recording is attached.

*Check first:* the products' status is "Waiting for Review" and they are attached to this version (HUMAN_HANDOFF H8,
H13).

## 2.1 — Crash, or the app doesn't work as described

> Thank you for the report. We could not reproduce this on [devices/OS tested]. Could you tell us the device and OS
> version, and the steps taken? A crash log would help if one is available. In the meantime we are checking the
> reported flow on the same configuration.

*Then:* check the crash in Xcode Organizer (the review device's crash appears there). If it reproduces, fix it with
a test, bump the build number and resubmit, replying with what was fixed.

### 2.1(a) — macOS crash after Load Sample Data + sidebar (1.0.0 (3), 2026-10-02)

Cause: the sidebar's collection reorder trusted SwiftUI `onMove` indices, which on macOS can point past the
collection list when a row inside an expanded collection is dragged. Fixed in the next build. Reply when resubmitting:

> Thank you for the crash logs. We symbolicated them and found the cause: on macOS, dragging a row inside an expanded
> collection in the sidebar could pass an out-of-range position to the collection reorder code. The build we have
> attached fixes this; such moves are now ignored safely, and an automated test covers this case. To check it: load
> the sample data (Settings… → Try It Out → Load Sample Data), then click and drag rows in the sidebar.

## 4.3(a) — Spam: "similar binary, metadata, and/or concept" (1.0.0 (6), iOS + macOS, 2026-10-06)

Rejection came with an Extended Review warning. Do not resubmit unchanged. First reply (no new build) asking which
apps were matched. Facts checked 2026-10-07: no Swift source file in RequestPad is identical to any file in DevKit,
QueryPad, Shellbay, JSON Scope, HookCatcher or UptimeScout.

> Hello, and thank you for the review.
>
> We'd like to understand this decision so we can address it properly. Could you tell us which app or apps
> RequestPad was found to be similar to?
>
> RequestPad was written from scratch for this purpose. It is not built from a template or purchased code, and its
> source is not shared with any of our other apps. Each of our apps does a different job: QueryPad is a database
> client, Shellbay is an SSH terminal, JSON Scope opens large JSON files, DevKit is a set of offline converters and
> decoders, and UptimeScout monitors site uptime. None of them lets you write, send and organize your own API
> requests.
>
> RequestPad is a native HTTP and API client for iPhone, iPad and Mac that needs no account and works offline. What
> it offers that other API clients on the App Store don't combine:
> - Collections stored as plain Bruno (.bru) folders, so a team can edit the same files in git, from the iPad as well as
>   the Mac.
> - Local Echo, a built-in loopback test server, so every feature can be tried without any external service.
> - A collection runner with assertions, and response values extracted into variables for request chaining.
> - OpenAPI 3, Postman v2.1 and cURL import; GraphQL; OAuth 2.0; a cookie jar.
> - A Shortcuts "Send Request" action and a macOS menu bar Quick Send.
>
> To see it quickly: Settings → Try It Out → Load Sample Data, then open the Sample collection and run it.
>
> If a specific part of the binary or metadata looks too close to another app, please point us to it and we will
> change it. Thank you for your time.

## 2.5.2 / 2.5.4 — The app runs a server (Local Echo) or might execute code

> RequestPad includes "Local Echo", a small built-in HTTP test server so that every feature can be tried without an
> internet connection or an external service (it is what the sample requests use). It:
> - listens only on 127.0.0.1 (loopback), so no other device can reach it;
> - runs only while the app is open, and only after "Load Sample Data" or the Settings toggle;
> - replies with a JSON description of the request it received (method, path, headers, body) and a few fixed test
>   responses (status codes, delays, an image, a large body);
> - does not download, interpret or execute any code, and there is no scripting in the app (assertions and JSONPath
>   filters are declarative).
>
> On macOS the com.apple.security.network.server entitlement is used only for this loopback listener.

## 2.4.5 — macOS: automated check says network.server has no matching functionality

Received for 1.0.0 (3) on 2026-09-28. The automated scan doesn't see the listener because Local Echo is off at launch.
The entitlement is required: a sandboxed app cannot bind an `NWListener`, even on 127.0.0.1, without it. Reply
(no new build), and keep the entitlement line in the App Review notes.

> Thank you for the review. RequestPad needs com.apple.security.network.server for one feature: Local Echo, a
> built-in HTTP test server that lets users try the app's request features offline without an external service.
> It is implemented with Network.framework's NWListener (Sources/RPServices/Echo/LocalEchoServer.swift) bound
> to 127.0.0.1 only, so no other device can reach it. The App Sandbox blocks binding a listening socket without this
> entitlement, even on loopback.
>
> The listener is off at launch, which is probably why automated analysis didn't detect it. To see it:
> 1. Open RequestPad → Settings… (⌘,) → Try It Out.
> 2. Turn on "Local Echo Server" (or click "Load Sample Data"). The address http://127.0.0.1:<port> appears.
> 3. Open Sample → Basics → "Echo a GET" and send it. The response comes from the local listener.
>
> It serves only fixed test responses and echoes the received request. It downloads and executes no code, and it
> stops when the app quits. This is also described in the App Review Information notes.

## 2.4.5 — macOS: login item, menu bar, Services, entitlements

> - **Open at Login** is off by default. The user turns it on with an explicit toggle in Settings → Mac, and it uses
>   SMAppService.mainApp, so it appears in System Settings → General → Login Items. The app never enables it itself.
> - **Menu bar Quick Send** is also off by default (Settings → Mac) and only exists while the app is running.
> - The **Services** item "Send URL with RequestPad" opens the selected URL as a new, unsaved request. Nothing is
>   sent automatically.
> - The app is sandboxed, has no helper tools or installers, and has no self-update mechanism.
> - Files are accessed only through the open panel (user-selected read-write, with app-scoped bookmarks for
>   collection folders).

## 3.1.2 — Subscription information is missing

> The subscription terms appear on the RequestPad Pro screen before purchase: title, length (1 month or 1 year),
> price per period from the App Store, the 7-day free trial for eligible customers, and a statement that the
> subscription renews automatically unless cancelled at least 24 hours before the end of the period. Links to the
> Terms of Use (https://requestpad.eonix.lk/terms, Apple's Standard EULA) and the Privacy Policy
> (https://requestpad.eonix.lk/privacy) are on the same screen and in Settings. The App Store description includes
> both links.

*Check first:* the Terms and Privacy pages are live (H1), and the EULA field in App Store Connect is the standard
EULA.

## 4.2 — Minimum functionality / "adds value"

> RequestPad is a native developer tool with functionality that goes beyond a website:
> - an HTTP and GraphQL client using the system networking stack, including streaming large responses to disk and
>   timing breakdowns;
> - secrets kept in the device Keychain behind Face ID / Touch ID;
> - collections stored as plain-text files in any folder the user chooses (including git repositories), with
>   external changes detected and conflicts surfaced;
> - an offline test server for trying every feature;
> - a Shortcuts action that sends requests without opening the app;
> - a Mac menu bar Quick Send and a Services integration;
> - full keyboard support on iPad and Mac.
>
> It works entirely offline and requires no account.

## 5.1.1 — Permissions or privacy

> - **Local Network:** RequestPad asks for Local Network access only when the user sends a request to a device on
>   their own network. The app first shows its own explanation, then the system prompt ("RequestPad connects to
>   servers on your local network when you enter a local address."). Requests to the internet and to Local Echo do
>   not need it.
> - **Face ID:** used only to reveal a stored secret value, and it falls back to the device passcode.
> - **Data:** no data is collected and there are no accounts, analytics, tracking or third-party SDKs. There is
>   nothing to delete server-side; Settings → Erase All Data removes everything on the device.

*Check first:* the quoted usage string must still match `NSLocalNetworkUsageDescription` in `RequestPad/Info.plist`.

## 2.3 — Metadata: names of other apps in the description

> The description mentions Postman and Bruno only to state which file formats RequestPad can import or read
> ("Import … Postman v2.1 collections"; ".bru files"). These are factual interoperability statements. Neither name is
> used in the app name, subtitle or keywords. If you prefer, we will reword them to "Postman v2.1 collection
> export" / "Bruno-format (.bru) files" or remove them.

*If asked to remove them:* edit the description in App Store Connect (no build needed), run
`scripts/check-metadata.py` on the updated `metadata.md`, and reply.

## 2.3.3 — Screenshots

> The screenshots are captured from this build by our screenshot script (real UI, sample data sent to the built-in
> test server, no mock-ups). Each device set was captured on that device class: iPhone 6.9", iPad 13" and Mac.

*If a specific screenshot is questioned:* recapture with `scripts/screenshots.sh` after any UI change, and replace
only that set.
