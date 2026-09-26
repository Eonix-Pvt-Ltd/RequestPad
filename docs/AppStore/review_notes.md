# Notes for App Review — RequestPad 1.0.0

Paste the text between the lines into App Store Connect → App Review Information → Notes (same text for iOS and
macOS). Sign-in required: **No**.

---

RequestPad is a native API client (HTTP and GraphQL) for developers. There is no account or login of any kind.

HOW TO TRY EVERYTHING WITHOUT A SERVER
On first launch, the welcome screens end with "Load Sample Data". (Later: Settings → Try It Out → Load Sample Data.) This starts Local Echo — a small HTTP test server that runs inside the app on 127.0.0.1 only — and adds a "Sample" collection whose requests all target it. No internet connection or external service is needed. Local Echo only reflects the requests it receives back as JSON; it evaluates no user-supplied code and downloads nothing.

FEATURES (with the sample data)
1. Send a request: in the sidebar open Sample → Basics → "Echo a GET" and tap Send (⌘↩ on iPad keyboard or Mac). The response shows status, time, size, headers, a JSON tree with a JSONPath filter, raw text, and Timeline. On iPhone, switch between Request and Response with the control under the URL.
2. Bodies and files: "Create JSON" (JSON body with {{variables}}), "Form login" (form body). Multipart files: Body → Multipart Form → Add File.
3. Environments: the environment menu in the toolbar (globe icon with the environment's name) selects the "Local" environment; ⌘E manages environments. Secret variables are stored in the Keychain; revealing one asks for Face ID / Touch ID / passcode.
4. Large and binary responses: "Large body (12 MB)" is streamed to disk and can be saved with the save button; "Image preview" shows an image.
5. History: the History row in the sidebar.
6. Import: sidebar + → Import… → cURL (free), OpenAPI or Postman (Pro).
7. Local network: requests to LAN addresses show an explanation before iOS asks for Local Network permission (NSLocalNetworkUsageDescription). Local Echo itself uses loopback and needs no permission.

PRO FEATURES AND PURCHASES
Pro is sold as auto-renewable subscriptions (monthly, yearly; 7-day free trial for eligible customers) in the "Pro" subscription group, and a lifetime non-consumable. Open the paywall from any Pro feature — e.g. a request's Assert tab → "See RequestPad Pro", "Run Collection…" in a collection's context menu, or Settings → See Pro Features; use the sandbox purchase flow. The paywall shows the price, period, trial terms, Restore Purchases, Terms of Use and Privacy Policy. Settings also has Restore Purchases, Manage Subscription and (iOS) Redeem Offer Code. The free version stays fully usable (one collection with up to 30 requests).
With Pro, try on the sample data:
- GraphQL: "GraphQL query" → Body → Fetch Schema, then type in the query to see completions.
- Extraction and chaining: Chaining → "1. Get a token" (Extract tab), then "2. Use the token".
- Runner: long-press or right-click the Sample collection → Run Collection… → Run; results can be exported as JSON.
- OAuth 2.0: Auth → "OAuth 2.0 client credentials" against Local Echo's token endpoint. The authorization-code flow uses ASWebAuthenticationSession (the system sign-in sheet) with the provider the user configures.
- Git-friendly collections: sidebar + → Open Collection Folder… / New Collection in Folder… stores requests as plain .bru text files in a folder the user picks (security-scoped bookmark; no broad file access).
- Cookie jar: sidebar + → Cookie Jar.

SHORTCUTS (iOS, iPadOS, macOS; Pro)
Shortcuts app → + → search "RequestPad" → "Send Request", choose a saved request. It runs without opening the app and returns the status and body. Without Pro it reports that the action is part of RequestPad Pro.

MAC-ONLY BEHAVIOR
- Menu bar Quick Send (Pro, off by default): Settings (⌘,) → Mac → Menu Bar Quick Send. A paper-plane item appears in the menu bar to send a saved request or a URL.
- Services: select a URL in any app → app menu → Services → "Send URL with RequestPad" opens it as a new request (the Services list may need a log out/in to refresh).
- Open at Login (off by default): Settings → Mac → Open at Login, using SMAppService; nothing launches without the user turning it on.
- The com.apple.security.network.server entitlement is used only by Local Echo, which listens on 127.0.0.1 and is unreachable from other devices. The app is sandboxed and uses user-selected file access and app-scoped bookmarks for collection folders.

BACKGROUND
No background modes are used. Nothing runs when the app is not open, except the Shortcuts action when the user runs it and the optional menu bar item while the app is running.

PRIVACY
No analytics, advertising, tracking or third-party SDKs. Requests go only to addresses the user enters. No web views. Encryption: standard HTTPS through the OS and SHA-256 hashing only (ITSAppUsesNonExemptEncryption = NO).

Contact: support@eonix.lk

---

Checked against the build: every path above exists (sample request names from `SampleData.swift`; Settings
sections "Try It Out" and "Mac"; paywall triggers from `FeatureGate`). Re-check after any UI change.
