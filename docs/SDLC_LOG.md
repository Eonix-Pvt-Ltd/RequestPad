# SDLC Log

## Environment (recorded 2026-09-25)

```
$ xcode-select -p
/Applications/Xcode.app/Contents/Developer
$ xcodebuild -version
Xcode 27.0
Build version 27A266a
$ xcrun simctl list runtimes
iOS 27.0 (27.0 - 24A434) - com.apple.CoreSimulator.SimRuntime.iOS-27-0
```

## Phase 0 — Product definition (2026-09-25)

Deliverables:
- `docs/PRD.md` — identity, personas, free/Pro matrix, out-of-scope, 21 features (F01–F08, P01–P09, X01–X04) with
  acceptance criteria.
- `docs/ARCHITECTURE.md` — modules, Mermaid data-flow and send-sequence diagrams, persistence split, SwiftData schema
  with natural keys, concurrency model, networking rules, threat model (STRIDE-lite), error handling, observability,
  phase plan.
- `docs/DECISIONS.md` — human inputs + ADR-0001…0018.

Research performed:
- Bruno `.bru` grammar read from `usebruno/bruno` `packages/bruno-lang/v2/src/{bruToJson,envToJson,jsonToBru}.js`
  (main branch, 2026-09-25) — informs RPCore codec in Phase 2.
- Bruno variable precedence (docs.usebruno.com/variables/overview) — ADR-0013.
- Apple `NSAllowsLocalNetworking` documentation — ADR-0010.

Exit check — every V1 feature maps to ≥ 1 acceptance criterion:
```
$ for f in $(grep -oE '^### (F|P|X)[0-9]{2}' docs/PRD.md | awk '{print $2}'); do printf "%s=%s " $f $(grep -cE "^- \*\*$f\.[0-9]+" docs/PRD.md); done
F01=10 F02=8 F03=4 F04=6 F05=5 F06=2 F07=2 F08=4 P01=7 P02=3 P03=1 P04=3 P05=2 P06=3 P07=2 P08=2 P09=2 X01=4 X02=3 X03=3 X04=3
```
21 features, 79 acceptance criteria, 0 features without criteria. **Phase 0 exit criteria met.**
