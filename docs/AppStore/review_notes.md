# Notes for App Review — RequestPad 1.0.0

Paste the text between the lines into App Store Connect → App Review Information → Notes (same text for iOS and
macOS). Sign-in required: **No**.

---

RequestPad is a native API client (HTTP and GraphQL) for developers. It is free, with every feature included: there are no in-app purchases, subscriptions or ads, and no account or login.

TRY EVERYTHING WITHOUT A SERVER
The welcome screens end with "Load Sample Data" (later: Settings → Try It Out → Load Sample Data). This starts Local Echo, a small HTTP test server inside the app on 127.0.0.1 only, and adds a "Sample" collection whose requests target it. No internet or external service is needed. Local Echo only reflects requests back as JSON; it runs no user code and downloads nothing.

FEATURES (sample data)
1. Send: sidebar → Sample → Basics → "Echo a GET" → Send (⌘↩ on iPad keyboard or Mac). The response shows status, time, size, headers, a JSON tree with JSONPath filter, raw text and Timeline. On iPhone, switch Request/Response with the control under the URL.
2. Bodies and files: "Create JSON" ({{variables}}), "Form login". Multipart: Body → Multipart Form → Add File.
3. Environments: the toolbar environment menu (globe icon) selects "Local"; ⌘E manages environments. Secret variables are kept in the Keychain; revealing one asks for Face ID / Touch ID / passcode.
4. Large and binary responses: "Large body (12 MB)" streams to disk and can be saved; "Image preview" shows an image.
5. History: the History row in the sidebar.
6. Import: sidebar + → Import… → cURL, OpenAPI or Postman.
7. Local network: requests to LAN addresses show an explanation before iOS asks for Local Network permission. Local Echo uses loopback and needs no permission.

MORE FEATURES (sample data)
- GraphQL: "GraphQL query" → Body → Fetch Schema, then type to see completions.
- Chaining: Chaining → "1. Get a token" (Extract tab), then "2. Use the token".
- Runner: long-press or right-click Sample → Run Collection… → Run; export results as JSON.
- OAuth 2.0: Auth → "OAuth 2.0 client credentials" against Local Echo. Authorization code uses ASWebAuthenticationSession with the user's provider.
- Folder collections: sidebar + → Open Collection Folder… / New Collection in Folder… stores .bru text files in a user-picked folder (security-scoped bookmark).
- Cookie jar: sidebar + → Cookie Jar.

SHORTCUTS
Shortcuts → + → "RequestPad" → "Send Request", choose a saved request. It runs without opening the app and returns status and body.

MAC ONLY
- Menu bar Quick Send (off by default): Settings (⌘,) → Mac → Menu Bar Quick Send.
- Services: select a URL in any app → app menu → Services → "Send URL with RequestPad".
- Open at Login (off by default): Settings → Mac → Open at Login (SMAppService).
- The network.server entitlement is used only by Local Echo on 127.0.0.1, unreachable from other devices. The app is sandboxed and uses user-selected file access and app-scoped bookmarks.

BACKGROUND AND PRIVACY
No background modes. No analytics, advertising, tracking or third-party SDKs. Requests go only to addresses the user enters. No web views. Encryption: HTTPS through the OS and SHA-256 hashing only (ITSAppUsesNonExemptEncryption = NO).

Contact: support@eonix.lk

---

Checked against the build: every path above exists (sample request names from `SampleData.swift`; Settings
sections "Try It Out" and "Mac"). Re-check after any UI change.
