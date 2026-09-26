# App Store metadata — RequestPad 1.0.0

Paste each field into App Store Connect as written. `scripts/check-metadata.py` (part of `scripts/lint.sh`) checks
the limits, forbidden terms and URLs; the claims table at the end maps every description statement to evidence in
this build. The same metadata applies to the iOS/iPadOS and macOS versions (Universal Purchase).

## Name

```text
RequestPad: API Client
```

## Subtitle

```text
HTTP & GraphQL, git-friendly
```

> The PRD subtitle "HTTP & GraphQL, Bruno-compatible" is 32 characters (App Store Connect allows 30) and names
> another app (Guideline 2.3.7). Pending the owner's confirmation (Phase 8 gate).

## Promotional Text

```text
Send HTTP and GraphQL requests on iPhone, iPad and Mac. Keep collections as plain .bru files in a folder you own. No account, no cloud, no tracking.
```

## Description

```text
RequestPad is a native API client for iPhone, iPad and Mac. Build HTTP and GraphQL requests, switch environments and read responses — with no account and no cloud.

SEND REQUESTS
• Every HTTP method, including custom ones, with query and path parameters and headers
• JSON, text, XML, form and multipart bodies, including files
• Bearer, Basic and API key authorization, plus OAuth 2.0 client credentials and authorization code with PKCE (Pro)
• Per-request timeouts and redirects, and clear messages when a request fails

READ RESPONSES
• Status, time with a DNS, connect, TLS and waiting breakdown, size and headers
• JSON as a collapsible tree with a JSONPath filter, raw text with charset detection, and image previews
• Large responses go straight to disk, and any response can be saved to a file

ORGANIZE
• Collections with folders, and default headers and authorization that requests inherit
• Environments and global variables with {{name}} placeholders; secret values stay in the Keychain
• History of your recent requests
• Import cURL commands and copy any request as cURL, with secrets masked

GIT-FRIENDLY COLLECTIONS (PRO)
• Keep collections as plain-text .bru files in any folder you choose — iCloud Drive, another Files location or a git repository
• Changes made on disk are picked up automatically, and your edits never silently overwrite them
• Import OpenAPI 3 documents (JSON or YAML) and Postman v2.1 collections

MORE PRO TOOLS
• GraphQL with schema introspection and autocomplete
• Extraction rules that save values from a response into variables for the next request
• Assertions and a collection runner, with results you can export as JSON
• A persistent cookie jar
• A "Send Request" action for Shortcuts
• On Mac, Quick Send from the menu bar

MADE FOR EACH DEVICE
• iPad: request and response side by side, with keyboard shortcuts
• Mac: full menus, a "Send URL with RequestPad" service and optional Open at Login

TRY IT WITHOUT A SERVER
Local Echo is a small test server that runs inside the app. Load the sample requests to explore every feature offline.

PRIVATE BY DESIGN
No account, no sign-in, no analytics and no tracking. Requests go only to the servers you enter, and your data stays on your devices or in folders you choose.

REQUESTPAD PRO
The free version includes one collection with up to 30 requests, environments, secret variables, a history of your last 100 requests, and cURL import and export. RequestPad Pro unlocks unlimited collections and everything marked Pro above, as a monthly or yearly subscription — with a 7-day free trial for eligible customers — or a one-time lifetime purchase. Payment is charged to your Apple Account. Subscriptions renew automatically unless cancelled at least 24 hours before the end of the current period; manage them in your App Store account settings.

Terms of Use: https://requestpad.eonix.lk/terms
Privacy Policy: https://requestpad.eonix.lk/privacy
```

## Keywords

```text
http,rest,graphql,request,openapi,json,curl,oauth,developer,bru,environment,endpoint,webhook,token
```

> Part A lists "postman" and "bruno"; they are other apps' names, which Guideline 2.3.7 and B10.2 forbid in
> keywords. Pending the owner's confirmation (Phase 8 gate).

## What's New in This Version

```text
The first release of RequestPad.
```

## URLs

| Field | Value |
|---|---|
| Support URL | https://requestpad.eonix.lk/support |
| Marketing URL | https://requestpad.eonix.lk |
| Privacy Policy URL | https://requestpad.eonix.lk/privacy |
| License Agreement | Apple's Standard EULA (leave the default; `TERMS.md` adopts it) |

## Other fields

| Field | Value |
|---|---|
| Primary category | Developer Tools |
| Secondary category | none |
| Copyright | © 2026 Eonix (Pvt) Ltd |
| Age rating | 4+ — every content question "None"/"No"; "Unrestricted Web Access": No (no browser or web view; responses are shown as text, JSON and images the user requested) |
| Price | Free, with in-app purchases (`lk.eonix.requestpad.pro.monthly`, `.yearly`, `.lifetime` — see HUMAN_HANDOFF H8) |
| Content rights | Contains no third-party content |
| App Review: sign-in required | No (there is no account) |
| App Review contact | support@eonix.lk (add a name and phone number in App Store Connect) |
| Export compliance | Uses encryption: exempt (standard HTTPS through the OS and hashing only; `ITSAppUsesNonExemptEncryption = NO`, ADR-0018) |

## In-app purchase display names and descriptions

| Product | Display name | Description |
|---|---|---|
| `lk.eonix.requestpad.pro.yearly` | RequestPad Pro Yearly | All Pro features, billed yearly. |
| `lk.eonix.requestpad.pro.monthly` | RequestPad Pro Monthly | All Pro features, billed monthly. |
| `lk.eonix.requestpad.pro.lifetime` | RequestPad Pro Lifetime | Unlock every Pro feature forever. |

## Screenshots

Generated from this build by `scripts/screenshots.sh` into `docs/AppStore/screenshots/` — five per device, no prices:
response, extraction rules, GraphQL autocomplete, collection runner, environments.

| Display | Folder | Size |
|---|---|---|
| iPhone 6.9" | `iphone-6.9/` | 1320 × 2868 |
| iPad 13" | `ipad-13/` | 2064 × 2752 |
| Mac | `mac/` | 2880 × 1800 |

## Claims table (second pass: every statement is true in this build)

| Description statement | Evidence |
|---|---|
| Native client for iPhone, iPad and Mac; no account | Universal app target; no sign-in anywhere (B13); `testOnboardingCanBeSkipped` |
| Every HTTP method incl. custom; query/path params; headers | F01.1–F01.3 — `customMethodAndOnlyEnabledQueryRowsAreSent`, `duplicateHeadersAreSeparateAndDisabledOnesAreDropped` |
| JSON, text, XML, form, multipart bodies incl. files | F01.4 — `jsonFormAndMultipartBodiesArriveIntact` |
| Bearer, Basic, API key; OAuth 2.0 client credentials and PKCE (Pro) | F05.1–F05.4 — `bearerBasicAndAPIKeyAuth`, `oauthClientCredentialsFetchesAndSendsAToken`, `OAuth2Service` PKCE tests |
| Per-request timeouts and redirects; clear failure messages | F01.6–F01.7 — `sendRecordsHistoryAndAppliesTheDefaultTimeout`, `connectionFailureHasASpecificMessageAndLoopbackHTTPWorks` |
| Status, timing breakdown, size, headers | F02.1–F02.3 — `statusTimingsHeadersAndJSONTree` |
| JSON tree with JSONPath filter, raw text with charset detection, image previews | F02.4–F02.6 — `statusTimingsHeadersAndJSONTree`, `rawTextUsesTheDeclaredCharsetAndMarksInvalidBytes`, `imagesPreview` |
| Large responses to disk; save any response | F02.7–F02.8 — `largeBodiesAreSpooledShownInPartAndSavedWhole` |
| Collections, folders, inherited headers and auth | F03.1, F03.3, F05.2 — `collectionAndFolderDefaultsAreInherited` |
| Environments, globals, {{name}}; secrets in Keychain | F04.1–F04.4 — `variablePrecedenceAndUnresolvedWarnings`, `secretVariablesLiveInTheSecretStoreAndCanBeRevealed`, `KeychainStore` tests |
| History of recent requests | F06 — `testHistoryListsSentRequests` |
| cURL import; copy as cURL with secrets masked | F07 — `pastingCurlReplacesTheRequestButKeepsItsName`, `curlExportResolvesVariablesAndMasksSecrets` |
| .bru files in any folder incl. iCloud Drive / git | P01.1–P01.6 — `newFolderCollectionIsBrunoAndEditsAreWrittenBack`; Files/iCloud picker manual (H3) |
| Disk changes picked up; edits never silently overwrite | P01.4 — `externalChangesReloadAndConflictWithUnsavedEdits`, `FolderWatcher` tests |
| OpenAPI 3 (JSON/YAML) and Postman v2.1 import | P02, P03 — `openAPIImportsIntoFoldersPerTagAndFailsWholly`, `postmanImportKeepsFoldersAndRequests` |
| GraphQL introspection and autocomplete | P04 — `graphQLSendsJSONPostAndFetchesACachedSchema` |
| Extraction rules into variables | P05 — `extractedValuesFeedTheNextRequestAndPersist` |
| Assertions and runner with JSON export | P06 — `runResultsExportAsJSON`, `runnerRunsItemsInOrder` |
| Persistent cookie jar | P07 — `cookiesPersistOnlyWithPro` |
| Shortcuts "Send Request" | P08 — `SendRequestIntentTests`; Shortcuts app run manual (H9) |
| Mac menu bar Quick Send | P09 — `MacIntegrationTests` Quick Send tests; manual (H9) |
| iPad side by side with keyboard shortcuts | X01.1 — iPad UI tests (balanced split); `RequestCommands` |
| Mac menus, Services, Open at Login | X01.3 — `servicesOpenTheSelectedURLAsANewRequest`, `loginItemFollowsTheSystemStatus` |
| Local Echo and sample requests, offline | F08 — `testSampleRequestSendsToLocalEcho`, `sampleDataDoesNotCountTowardsTheLimit` |
| No analytics/tracking; requests only to entered servers | B13; `PrivacyInfo.xcprivacy` (no tracking, no collected data); no third-party SDKs (Package.swift has no dependencies) |
| Free: 1 collection × 30 requests, environments, secrets, history 100, cURL | PRD §4; `FeatureGate` tests; `freeTierAllowsOneCollectionAndAsksForPro` |
| Pro: monthly/yearly with 7-day trial for eligible customers, or lifetime | X03 — `StoreKitTests.productsMatchTheConfiguration` (App Store Connect products must match, H8) |
| Terms and Privacy URLs | `AppConstants` (tested in `AppConstantsTests`); pages published by the owner (H1) |
