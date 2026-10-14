# Changelog

All notable changes to RequestPad are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- RequestPad is now completely free. RequestPad Pro, its subscriptions, lifetime purchase and paywall are removed,
  and every feature is available to everyone: unlimited collections and requests, folder collections, OpenAPI and
  Postman import, GraphQL, OAuth 2.0, extraction rules, assertions and the runner, the cookie jar, Shortcuts, menu
  bar Quick Send and a history of the last 1,000 requests.

### Removed
- The `RPStore` module, StoreKit configuration, paywall, Restore Purchases, Manage Subscription and Redeem Offer
  Code.

### Fixed
- macOS: dragging a row inside an expanded collection in the sidebar could crash the app (App Review, 1.0.0 (3)).
  Collection reordering now ignores out-of-range move indices.

## [1.0.0] — pending submission (the date is set on release)

The first release: everything below ships in 1.0.0. The full feature list with acceptance criteria is in
`docs/PRD.md`.

### Added
- Project foundation: Swift package `RequestPadKit` (RPCore, RPData, RPServices, RPUI), Swift 6 strict
  concurrency, iOS/iPadOS 17 and macOS 14 deployment, App Sandbox, privacy manifest, lint/test/archive scripts and
  CI.
- Request editing and sending on iPhone, iPad and Mac: collections and folders (native and Bruno `.bru` folders),
  environments with Keychain secrets, response viewer (JSON tree with JSONPath filter, raw, image preview, timings,
  save to file), history, cURL/OpenAPI/Postman import, collection runner, cookie jar, Local Echo with sample data,
  onboarding, settings with data export/import/erase and diagnostics, keyboard shortcuts.
- Shortcuts "Send Request" action, macOS menu bar Quick Send, macOS Services "Send URL with
  RequestPad", and Open at Login on macOS.
- Settings: follow redirects by default for new requests; the History limit is shown.
- App icon in Icon Composer format with dark, clear and tinted appearances.
- Settings → Export Diagnostics shares the report as a text file.

### Fixed
- Saving a request that changed on disk since it was opened now reports a conflict instead of overwriting.
- OpenAPI paths with undeclared `{parameters}` import as path parameters.
- Responses show the standard status text ("200 OK" instead of "200 No Error").
- JSON responses open with the top-level members visible.
- Selecting a request inside a collapsed folder expands the folder in the sidebar.
- On Mac, start-up work runs once even when the window and the menu bar item open together.
- The Environments note is no longer cut off on Mac.
