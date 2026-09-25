# Security Policy

## Reporting a vulnerability

Email **support@eonix.lk** with the subject "Security". Include the RequestPad version, platform, and steps to
reproduce. Please do not open public issues for vulnerabilities. We acknowledge reports within 2 business days and
aim to ship a fix for confirmed high-severity issues within 14 days (hotfix path in `docs/RELEASE_RUNBOOK.md`).

## Security model (summary)

RequestPad has no backend and no accounts. The full threat model is in `docs/ARCHITECTURE.md` §7.

- **Secrets** (secret variables, OAuth tokens, client secrets, credentials) are stored only in the Keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronized). They are never written to `.bru` files,
  exports, history, logs or diagnostics; revealing one in the UI requires device authentication.
- **Transport**: `URLSession` with App Transport Security enabled. No custom certificate trust. Plain HTTP only to
  loopback, `.local`/unqualified hosts and private/link-local address ranges (ADR-0010).
- **OAuth 2.0**: authorization code with PKCE (S256) and `state` verification via `ASWebAuthenticationSession`;
  no embedded web views.
- **Untrusted input** (`.bru`, OpenAPI, Postman, cURL, responses) is parsed by size- and depth-limited parsers that
  are fuzz-tested; large responses stream to disk.
- **Sandbox**: App Sandbox on macOS, user-selected file access through security-scoped bookmarks only. No
  executables are spawned and no code is downloaded or interpreted.
- **Local Echo** binds to 127.0.0.1 only, is off by default and evaluates nothing.
- **Purchases** are granted only from StoreKit-verified transactions.
- **Supply chain**: zero third-party dependencies. CI runs a pinned gitleaks secret scan, the Clang static analyzer,
  Address and Thread Sanitizer runs, and treats compiler warnings as errors.

## Supported versions

Only the latest App Store release receives security fixes.
