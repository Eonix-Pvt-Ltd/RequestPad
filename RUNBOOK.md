# RequestPad Runbook

RequestPad is a client-only app: there are no servers, databases or on-call rotations. "Operations" means keeping
the build healthy, shipping fixes, and watching crash/performance signals Apple provides. Release steps live in
`docs/RELEASE_RUNBOOK.md` (completed in Phase 10).

## Onboard a new contributor

1. Install Xcode 26+ and (optionally) `brew install xcbeautify`.
2. Clone the repo, run `scripts/bootstrap.sh`, then `scripts/test.sh --platform macos`.
3. Read `docs/ARCHITECTURE.md` and `docs/DECISIONS.md`. Conventional commits; every commit builds and passes tests.
4. Ask a team admin for membership of Apple Developer team `835LNLUPAJ` (needed for device runs and archives).

## Deploy (ship a build)

Covered by `docs/RELEASE_RUNBOOK.md` and `docs/HUMAN_HANDOFF.md`: bump `CURRENT_PROJECT_VERSION` in
`Config/Base.xcconfig`, run `scripts/test.sh --sanitizers --analyze`, `scripts/archive.sh`, upload with Xcode
Organizer or Transporter, TestFlight, then submit.

## Roll back

The App Store has no rollback. To back out a bad release: pause the phased release (iOS) in App Store Connect,
revert the offending commits on `main`, bump the build number, and ship a hotfix (1.0.x) through expedited review
if needed. Data migrations must therefore be backward-compatible for one version (SwiftData `SchemaMigrationPlan`).

## Backups and restore

User data lives on users' devices. Folder collections are the user's files (and usually in git). Users can export
native app data as JSON (Settings → Export App Data) and import it on another device. There is no server-side
backup.

## Rotate secrets

The app ships no secrets. Credentials that exist in the release process:

| Secret | Where | Rotation |
|---|---|---|
| App Store Connect API key (`.p8`) | Outside the repo at `$ASC_KEY_PATH` | App Store Connect → Users and Access → Integrations: revoke and create a new key, update `.env` |
| Apple Distribution certificate | Keychain of the release Mac | Xcode → Settings → Accounts → Manage Certificates; revoke via developer.apple.com if compromised |
| GitHub access | GitHub account settings | Rotate personal tokens; CI uses the default `GITHUB_TOKEN` (read-only) |

If a secret is committed by mistake: revoke it first, then remove it from history, and confirm the gitleaks CI job
is green.

## Investigate common failures

| Symptom | Where to look | Likely cause / fix |
|---|---|---|
| CI "Select newest Xcode" / build fails on the runner | Job log, `xcodebuild -version` | Runner lacks a compatible Xcode; update `runs-on` image |
| Coverage gate fails | `scripts/test.sh` output, `build/test-results/package-macos.xcresult` | New untested code in RPCore — add tests |
| Accessibility audit fails | Test log shows element + issue | Fix the view; exemptions only per ADR-0019 with recorded evidence |
| Crash reports | Xcode → Organizer → Crashes (weekly) | Symbolicated automatically for uploaded builds |
| Hangs / launch regressions | Organizer → Hangs / Launch Time; MetricKit exports from users | Profile with Instruments (Time Profiler) |
| "Can't open collection folder" reports | User diagnostics export | Stale security-scoped bookmark — user re-grants access (built-in flow) |

## Alerts

There is no alerting infrastructure (no backend, no telemetry by design). Signals are reviewed on a schedule:
Organizer crashes/hangs weekly, App Store reviews and support inbox daily (2-business-day SLA), CI failures via
GitHub notifications.

## Incident response

1. **Detect** — crash spike in Organizer, reviews, support mail, or a security report (SECURITY.md).
2. **Mitigate** — pause phased release; for a security issue affecting secrets, publish guidance on the support page.
3. **Communicate** — reply to affected users; update the support page FAQ.
4. **Fix** — hotfix branch from the release tag, tests reproducing the issue, expedited review if user data or
   security is affected.
5. **Postmortem** — add an entry to `docs/DECISIONS.md` with cause, fix, and the test that now prevents recurrence.
