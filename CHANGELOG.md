## 0.4.0

- **Charts + PR gate (big):** `contract run` → `build/benchmark-data.json`
  (`charts.dart`, `customSmallerIsBetter`) + `build/check-report.json`
  (`goldens.dart:MetricCheck`); `action.yml` `charts:` → gh-pages dashboard
  (auto-push, `chartsUrl` → `readme.dart: Trend history`) + `comment:` → PR
  regression table.
- **S5/S6:** unphysical heap drift (`< −1 MiB`) after retries → `n/a`
  (`status: unphysical`) not `FAIL`; `lib/scenarios.dart` docs trimmed.
- **CI + cache:** `.github/workflows/ci.yml` + action cache Gradle/pub/NDK.

## 0.3.4

- **pub.dev score fixes.** Description trimmed to 125 chars; `example/README.md` added

## 0.3.3

- **S5 protocol defect fix (mirrors S6).** `active_heap` re-samples the
  idle floor before each of 3 measured shows (mean of per-cycle deltas); a
  delta below the −1 MiB unphysical floor fails instead of recording — one
  rival ref had recorded −10 MB from the shared-floor artifact. Re-record
  all refs.

## 0.3.2

- **S1r published metric.** Declared `idleClasses:` → max per-class delta
  (0 = no leak) recorded; otherwise n/a. Counter counts implementers too
  (abstract classes would otherwise measure a trivial 0).
- **Card.** Footer note/legend derived from the manifest (no hardcoded
  rivals); redesigned tiles; 2400×1080 → 1600×900 + larger type (README
  caps at ~800px); decorative per-tile progress bars removed.
- `contract card` resolves the consumer's own refs only (a rival metric
  can no longer render as the consumer's own).

## 0.3.1

**S6 protocol defect fix: per-cycle heap baseline + unphysical-drift guard.**
On the runner image the first record run wrote `hide_retention` as
−10.2 MB — an artifact: the shared post-warm-up baseline was inflated by
~10 MB of still-settling heap garbage that later GCs reclaimed, and the
one-sided gate (drift ≤ golden + slack) silently accepts any negative
value, so the broken number became a golden and reached the published
card.

- `hide_retention` now re-samples its idle floor (`base_i`, median of 3
  GC reads) **before each measured show**, so the drift is per-cycle
  (`h_i − base_i`) and a settling floor cancels instead of biasing one
  shared baseline negative.
- New two-sided defect guard: a per-cycle drift below −1 MiB (unphysical
  for a show/hide cycle whose active cost measures in KB) FAILS the
  scenario with the top retained classes in the failure reason — a broken
  sample can no longer be recorded as a golden.
- Scenario bodies live in the package, so consumers need no regeneration:
  `^0.3.0` resolves pick up 0.3.1 automatically.

## 0.3.0

**One command runs the whole contract.** S7 `size` stopped being a second
CLI verb — it was already a scenario in the registry, the manifest
(`scenarios: [..., size]`) and the store, but `contract run` dead-ended on
it ("run `contract size` instead"). Now `contract run` executes the size
legs itself, once per manifest, when `size` is selected:

- `contract size` removed; `run` gained `--legs native|web|both` (default
  `both`) so the device-free web leg still runs in plain CI without the
  emulator job.
- Size metrics keep their OWN golden refs inside `run`: `bundle_delta` is
  SDK-pinned under `any`; `native_size` follows the invocation ref (the
  docker dispatch records it under `android`).
- The runner-image entrypoint collapsed to one `contract run` invocation
  (device scenarios + native size leg); card/readme renders unchanged.

## 0.2.0

**Smart bench, dumb bridge.** The S1–S7 scenario bodies now live ONCE in
`lib/scenarios.dart` instead of being copied into every consumer: the
package depends on `flutter_test` (precedent: golden_toolkit) so the bodies
can be published as code, not templates. `contract init` copies only ~8-line
per-scenario **bridges** that wire the consumer's driver into its own test
process. Consumers physically cannot edit the bodies anymore — a scenario
change is a package version bump, which makes the anti-tuning property
stronger. `LibraryDriver` moved into `lib/driver.dart` (public API); the
consumer's driver stays consumer-side because it imports the solution under
test.

- `lib/scenarios.dart` — `runContractScenario(id, driver:, idleClasses:)`
  registers the S1–S7 (+S1r) bodies as tests; protocol constants stay the
  package's methodology.
- `templates/` removed; generated files are now the dumb bridges plus the
  flutter-drive test driver (`test_driver/integration_test.dart`, also
  generated now).
- `contract init` re-syncs the manifest's `template:` key (previously it
  was only a header comment, so `contract verify` could not detect stale
  generated files); template version bumped to 2.
- Dead `bin/check_goldens.dart` CLI removed (duplicated `contract run`'s
  gate); internal extraction-history comments purged from all shipped
  files.

## 0.1.0

First release: the generic core of the bench contract, extracted from the
hintful benchmark suite and generalized.

**Measurement & gate core**

- `collectors.dart` — `FrameWindow`/`collectFrames` (frame timings) and
  VM-service heap probes (used-bytes medians after GC, top retained classes).
- `report.dart` — the `HINTFUL_BENCH_JSON:` envelope (`reportMetric`,
  `parseSample`), the median reducer, and run-report reading.
- `goldens.dart` — the `benchmarks.json` golden store: `record`, one-sided
  `check` (lower-is-better, per-ref), `load` with ref preference.

**Contract machinery**

- `LibraryDriver` API + the neutral scene (`buildContractScene`, `SceneSpec`)
  — the only consumer-written code: scene building with the solution's own
  widgets and the scenario verbs `show/update/hide`, `isStable()`,
  `currentContent()`, `scrollCoupled`.
- Scenario templates S1–S7 (idle tree diff, idle resources with per-class
  VM-service counting, show/update latency, scroll coupling, active heap,
  hide retention, size) with in-scenario asserts — copied into the consumer
  by `contract init`, never edited by hand (template versioned in the
  manifest, `contract verify` checks it).
- `contract` CLI: `init`, `run` (host `flutter test` or device
  `flutter drive --no-dds --profile`), `size`, `card`, `readme`, `verify`.
- Custom scenarios: `customScenarios:` in the manifest — consumer-owned
  metrics under `custom.*` ids with their own golden refs, excluded from
  rival comparisons and public tables.
- Multi-library manifests (`libraries:`): one scenario list, one driver per
  solution, per-solution golden refs — the head-to-head shape used by
  hintful's `benchmark/compare`.

**Published results**

- `defs.dart` — canonical display metadata (label/unit) and value formatters
  shared by the card and the README table.
- `metrics_card.dart` — the `MetricsCard` widget (title, tiles, note, legend)
  rendered by `contract card` into a golden-checked PNG.
- `readme.dart` — generic `renderReadmeSection` for the root-README
  "Performance" table between `<!-- bench:start/end -->` markers.
- Manifest `card:`/`readme:` sections — the consumer writes only the copy;
  layout, formatting, fonts and rendering belong to the package.