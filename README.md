# RequestPad

An unbloated, native API client for iPhone, iPad and Mac. It sends HTTP and GraphQL requests with environments,
variables and auth helpers, and stores collections as git-friendly Bruno `.bru` files in a folder you own. No
account, no cloud, no telemetry.

- Product requirements: [`docs/PRD.md`](docs/PRD.md)
- Architecture and threat model: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- Decisions (ADRs): [`docs/DECISIONS.md`](docs/DECISIONS.md) · Build evidence: [`docs/SDLC_LOG.md`](docs/SDLC_LOG.md)
- Operations: [`RUNBOOK.md`](RUNBOOK.md) · Security: [`SECURITY.md`](SECURITY.md)

## Requirements

- macOS with **Xcode 26 or later** (developed with Xcode 27.0). `scripts/bootstrap.sh` checks this.
- An iOS simulator runtime (the scripts choose the first available iPhone and iPad simulators).
- Optional: [`xcbeautify`](https://github.com/cpisciotta/xcbeautify) for readable build output.
- To archive: membership of Apple Developer team `835LNLUPAJ` with an Apple Distribution certificate.

## Layout

| Path | Contents |
|---|---|
| `RequestPad.xcodeproj` | The Xcode project (single multiplatform app target + unit and UI test targets). Extend it in Xcode; never regenerate it. |
| `RequestPad/` | App target sources (folder-synchronized): `Shared/`, `iOS/`, `macOS/`, `Intents/`, `Resources/`, entitlements, `Info.plist` |
| `Package.swift`, `Sources/`, `Tests/` | Local Swift package `RequestPadKit`: `RPCore`, `RPData`, `RPServices`, `RPUI` and their Swift Testing suites |
| `Config/` | xcconfig files (`Base`, `Debug`, `Release`, `RequestPad-App`) |
| `RequestPadTests/`, `RequestPadUITests/` | App-hosted unit tests and XCUITests (incl. accessibility audits) |
| `scripts/` | `bootstrap.sh`, `lint.sh`, `test.sh`, `sync-strings.sh`, `archive.sh`, `upload.sh`, `screenshots.sh`, `check-metadata.py`, export options |
| `docs/` | PRD, architecture, decisions, SDLC log, test plan, handoff, App Store material, release runbook, support replies, completion audit (`docs/COMPLETION_AUDIT.md`, start here for status) |

## Build and run

```bash
scripts/bootstrap.sh
open RequestPad.xcodeproj
```

Select the **RequestPad** scheme and a destination (My Mac, an iPhone or iPad simulator), then Run. RequestPad is
free, with no in-app purchases, so nothing needs App Store Connect to run locally.

## Test

```bash
scripts/test.sh                            # lint + package tests + app unit/UI tests on macOS, iPhone, iPad + coverage gate
scripts/test.sh --platform macos           # macOS only (fastest)
scripts/test.sh --sanitizers --analyze     # also ASan, TSan and the static analyzer (what CI runs)
scripts/test.sh --platform macos --skip-macos-ui  # when XCUITest gets no app window on a Mac (HUMAN_HANDOFF H7)
scripts/sync-strings.sh                    # after a command-line build: add new UI strings to the String Catalog
```

Package suites run through `.swiftpm/xcode/package.xcworkspace` (scheme `RequestPadKit-Package`); app suites run
through the project's shared `RequestPad` scheme. The coverage gate fails below 80 % line coverage for `RPCore`. Result bundles are written to `build/test-results/`.

`swift build` / `swift test` also work for the package alone on macOS.

## Lint and format

```bash
scripts/lint.sh                                                        # what CI runs
xcrun swift-format format -i -r Sources Tests RequestPad RequestPadTests RequestPadUITests Package.swift
```

`lint.sh` also fails on unreplaced setup placeholders, TODO/FIXME markers in shipped sources, forbidden APIs (web
views, dynamic loading, arbitrary loads) and App Store metadata problems (`scripts/check-metadata.py`).

## Release

```bash
scripts/archive.sh            # archives + exports iOS and macOS builds into build/*-export (no upload)
scripts/upload.sh             # uploads them to App Store Connect after confirmation (needs an API key; human-run)
```

App Store screenshots come from the real app on dedicated simulators and a Mac window (about 5 minutes; keep the
Mac unlocked and don't move windows during the Mac part):

```bash
scripts/screenshots.sh --platform all   # → docs/AppStore/screenshots/{iphone-6.9,ipad-13,mac}
```

Store listing text, review notes and privacy answers live in `docs/AppStore/`; `docs/APP_REVIEW_CHECKLIST.md` holds
the guideline evidence. Uploading, TestFlight and App Review are human-gated; see `docs/HUMAN_HANDOFF.md` and `docs/RELEASE_RUNBOOK.md`.
Bump `CURRENT_PROJECT_VERSION` in `Config/Base.xcconfig` before every upload.

## Troubleshooting

- **"Xcode 26 or later is required"** — `sudo xcode-select -s /Applications/Xcode.app` (or your Xcode path).
- **UI tests fail to start on macOS** — grant Xcode/`xcodebuild` Accessibility and Automation permission when macOS
  prompts (System Settings → Privacy & Security).
- **Signing errors when running on a Mac** — make sure Xcode is signed in to an account on team `835LNLUPAJ`, or
  run tests the way CI does: `CI=true scripts/test.sh --platform macos` (ad hoc signing).
- **Package changes not picked up** — `rm -rf ~/Library/Developer/Xcode/DerivedData/RequestPad-*` and rebuild.
