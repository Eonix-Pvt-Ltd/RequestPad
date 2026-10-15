# TestFlight — RequestPad 1.0.0 beta

Paste the fields below into App Store Connect → TestFlight. The same text applies to the iOS and macOS builds.
The process (groups, Beta App Review, feedback loop, exit criteria) is in `docs/HUMAN_HANDOFF.md` H12.

## Test Information

### Beta App Description

```text
RequestPad is a native API client for iPhone, iPad and Mac: build HTTP and GraphQL requests, switch environments and read responses, with no account and no cloud. Load the sample data to try everything offline against Local Echo, a test server inside the app.
```

### Feedback Email

```text
support@eonix.lk
```

### Marketing URL / Privacy Policy URL

`https://requestpad.eonix.lk` / `https://requestpad.eonix.lk/privacy`

### Beta App Review Information

- Sign-in required: **No**.
- Contact: the owner's name and phone number, with support@eonix.lk.
- Review notes: paste `docs/AppStore/review_notes.md`. It is the same text the App Store review uses.

## What to Test (build 1)

```text
Thank you for testing RequestPad!

1. Start: finish the welcome screens with "Load Sample Data" (or Settings → Try It Out → Load Sample Data).
2. Send: open Sample → Basics → "Echo a GET" and tap Send. Check the status, timing, headers and JSON tree. Try the other Basics requests: the 12 MB body, image preview, redirects, 404.
3. Your own API: create a collection and a request against a server you use. Try environments ({{name}} variables, a secret value), cURL import (sidebar + → Import…) and Copy as cURL.
4. More features: try GraphQL (Fetch Schema), extraction rules (Chaining folder), Run Collection…, OAuth 2.0 and a folder collection (sidebar + → Open Collection Folder…). Everything is free; there is nothing to buy.
5. iPhone and iPad: rotation, Split View, a hardware keyboard (⌘↩ sends), Dynamic Type, VoiceOver, dark mode.
6. Mac: menus and shortcuts, Settings → Mac (Menu Bar Quick Send, Open at Login), Services → "Send URL with RequestPad".
7. Shortcuts: add the "Send Request" action and run it with the app closed.

Report problems with a screenshot (TestFlight → Send Beta Feedback) or email support@eonix.lk. For crashes, iOS asks to share the report; please accept.
```

## Tester groups

| Group | Type | Who | Builds |
|---|---|---|---|
| Eonix Internal | Internal (no review) | Team members with App Store Connect access, up to 100 | Every processed build, automatically |
| Public Beta | External (Beta App Review) | 10–50 invited developers: iPhone, iPad and Mac users; include one on iOS 17 or macOS 14 | Builds that pass internal smoke tests |

## Feedback triage

| Severity | Examples | Response |
|---|---|---|
| P1 | Crash, data loss, a secret shown or written in plain text | Fix before the next build; new build within 2 days |
| P2 | Wrong result, broken flow with a workaround, accessibility blocker | Fix in the next build |
| P3 | Cosmetic, wording, a feature request | Log for 1.x (`docs/RELEASE_RUNBOOK.md` roadmap) |

For each fix: write a failing test first, fix, bump `CURRENT_PROJECT_VERSION`, then run `scripts/archive.sh` and
`scripts/upload.sh`. Add a "What to Test" note listing the fixes. Record the results in `docs/SDLC_LOG.md` under
"Phase 9 — Beta".
