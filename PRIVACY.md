# RequestPad Privacy Policy

_Effective: on release of RequestPad 1.0. Published at https://requestpad.eonix.lk/privacy._

RequestPad is an HTTP and GraphQL API client made by Eonix (Pvt) Ltd ("we"). This policy explains what happens to
information when you use RequestPad on iPhone, iPad and Mac.

## The short version

- RequestPad has **no account** and **no sign-in**.
- We **do not collect** any data. RequestPad contains no analytics, advertising, tracking or third-party SDKs.
- Everything you create stays **on your device**, or in folders **you** choose (for example iCloud Drive or a git
  repository).
- RequestPad sends network requests **only when you ask it to**, and only to the servers **you** enter.

## Information processed on your device

RequestPad stores the following locally so the app works:

| Data | Where it is stored |
|---|---|
| Requests, collections, folders, environments and variable values you mark as not secret | The app's private storage on your device |
| Collections you save as `.bru` files | The folder you choose (which may be synced by iCloud Drive, another file provider, or git — under that service's own terms) |
| Secret variables, tokens, passwords and API keys | Your device's Keychain, encrypted by the operating system; not synced |
| Request history (the request as written and a response summary: status, time, size, content type) | The app's private storage. Response bodies are not kept in history. |
| Cookies received from servers (Pro cookie jar) | The app's private storage |
| Diagnostic reports from Apple's MetricKit (performance and crash statistics, no personal content) | The app's private storage |

## Network connections

- **Your requests.** When you tap Send, run a collection, fetch a GraphQL schema, or sign in with OAuth 2.0,
  RequestPad connects to the addresses you entered. Those servers receive your request and handle it under their
  own policies. We never receive a copy.
- **OAuth sign-in** uses Apple's secure web authentication sheet; the provider you configured handles your login.
- **Local network.** If you enter a local address, iOS/iPadOS/macOS may ask for permission to access your local
  network. RequestPad uses it only for the requests you send.
- **Local Echo** is a test server that runs inside the app on your device (127.0.0.1) and is never reachable from
  other devices.
- **Purchases** are processed by Apple through the App Store. We do not receive your payment details or Apple
  Account information.

## Diagnostics you choose to share

Settings → Export Diagnostics creates a file on your device containing app/OS version, settings and redacted logs
(addresses reduced to scheme and host; no request bodies, header values, secrets or file contents). The file is
shared only if you send it to us yourself. Crash reports shared through Apple (if you enabled "Share with App
Developers") are provided to us by Apple in anonymized form.

## Retention and deletion

Data remains on your device until you delete it. Settings → Erase All Data removes everything RequestPad stores in
its private storage and Keychain, including history, cookies, secrets, saved folder access and diagnostics.
Collection folders you chose are your files and are not deleted. Deleting the app also removes its private storage.

## Children

RequestPad is a developer tool rated 4+. It does not knowingly collect information from anyone, including children.

## Changes

If this policy changes, the new version will be published at this address with a new effective date.

## Contact

Eonix (Pvt) Ltd — support@eonix.lk
