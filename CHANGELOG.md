# Changelog

All notable changes to RequestPad are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
- macOS: dragging a row inside an expanded collection in the sidebar could crash the app (App Review, 1.0.0 (3)).
  Collection reordering now ignores out-of-range move indices.

## [1.0.0] — pending submission (the date is set on release)

The first release: everything below ships in 1.0.0. The full feature list with acceptance criteria is in
`docs/PRD.md`.

### Added
- Project foundation: Swift package `RequestPadKit` (RPCore, RPData, RPServices, RPStore, RPUI), Swift 6 strict
  concurrency, iOS/iPadOS 17 and macOS 14 deployment, App Sandbox, privacy manifest, StoreKit test configuration,
  lint/test/archive scripts and CI.
- Request editing and sending on iPhone, iPad and Mac: collections and folders (native and Bruno `.bru` folders),
  environments with Keychain secrets, response viewer (JSON tree with JSONPath filter, raw, image preview, timings,
  save to file), history, cURL/OpenAPI/Postman import, collection runner, cookie jar, Local Echo with sample data,
  onboarding, settings with data export/import/erase and diagnostics, keyboard shortcuts.
- RequestPad Pro: yearly and monthly subscriptions with a 7-day free trial and a lifetime purchase (StoreKit 2),
  one paywall for every Pro feature, Restore Purchases, Manage Subscription and Redeem Offer Code, with Pro
  unlocking immediately and following refunds, renewals and purchases on other devices.
- Shortcuts "Send Request" action (Pro), macOS menu bar Quick Send (Pro), macOS Services "Send URL with
  RequestPad", and Open at Login on macOS.
- Settings: follow redirects by default for new requests; the History limit is shown.
- App icon in Icon Composer format with dark, clear and tinted appearances.
- Settings → Export Diagnostics shares the report as a text file.

### Fixed
- Saving a request that changed on disk since it was opened now reports a conflict instead of overwriting.
- OpenAPI paths with undeclared `{parameters}` import as path parameters.
- Existing Pro customers no longer see the "Welcome to RequestPad Pro" message at every launch.
- Responses show the standard status text ("200 OK" instead of "200 No Error").
- JSON responses open with the top-level members visible.
- Selecting a request inside a collapsed folder expands the folder in the sidebar.
- On Mac, start-up work runs once even when the window and the menu bar item open together.
- The Environments note is no longer cut off on Mac.
