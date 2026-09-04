# flutter_bench_contract

A performance contract for Flutter widget solutions that render on top of or
next to an application — tooltips, tours, popovers, toasts, overlays,
autocomplete layers, anything scroll-linked.

It makes "our widget code is fast" a repeatable, **gated** claim. You get:

- **Scenario tests that assert the action really happened** — content shown,
  content following a scrolled target, nothing leaking after `hide()`. There
  is nothing to win by doing nothing.
- **A one-sided golden gate** — CI fails only on regressions; improvements
  always pass. Goldens are recorded once per reference hardware.
- **One reproducible number per metric** — samples are emitted on a
  machine-readable envelope, median-reduced, and the number you publish is
  the number the gate checked.

You write one small **driver** (build a neutral scene with your own widgets,
map `show/update/hide` onto your controller). The package owns the rest:
scenario procedures, measurement, goldens, the gate, and the published
metrics card and README table.

## Scenarios

Scenarios are interaction patterns common to any overlay solution — not a
widget class. Each is optional: your manifest declares the ones that apply,
but the metric definition is identical for everyone who declares it.

| Id | What it measures | Primary metric | The scenario asserts |
|---|---|---|---|
| `idle_zero` (S1) | Idle tax of having the solution in the tree | tree-element diff vs the base scene | the diff itself |
| `idle_resources` (S1r) | Declared classes (`idleClasses:`) return to baseline after warm-up + `hide()` | per-class instance count (VM service) | == baseline |
| `show_latency` (S2) | Cold `show()` → first stable, visible content | wall ms, median of 3 runs | content found |
| `update_latency` (S3) | Content switch on a visible overlay | wall ms, median of 3 transitions | new content visible, old gone |
| `scroll_coupled` (S4) | Content anchored to element B rides it under scroll | Δcard == ΔB ± 1 px (two-sided) | scroll really passed |
| `active_heap` (S5) | Retained heap idle → shown | bytes (VM service) | content shown |
| `hide_retention` (S6) | Heap drift per show/hide cycle, tree back to idle, scene interactive | bytes / tree diff / tap | equality + tap on A lands |
| `size` (S7) | The solution's cost in the bundle | native analyze-size + web bundle delta | host builds, no device |

Frames are collected as diagnostics, not gate metrics — the primary prices
are wall-latency and heap. A scenario a solution cannot implement (e.g. no
scroll anchor) reports `unsupported`, visible in reports and tables, never
deleted.

## Quick start

```bash
flutter pub add --dev flutter_bench_contract
dart run flutter_bench_contract:contract init          # scaffold manifest + scenario bridges + driver skeleton
dart run flutter_bench_contract:contract run           # host sanity run, no device
dart run flutter_bench_contract:contract run \
    --device emulator-5554 --mode record --ref android # device run, record goldens
```

The scenario bodies live **once** in the package (`lib/scenarios.dart`), so
consumers cannot edit them — a scenario change is a package version bump.
`init` copies only ~8-line *bridges* into `bench/contract/`, each wiring your
driver into its own `flutter test` process (fresh app/heap per scenario).
`contract verify` checks those generated files are in sync with the
package's template version.

### The driver — the only code you write

`init` scaffolds `bench/drivers/<library>_driver.dart` (a skeleton when
missing); you implement it (condensed):

```dart
class MyDriver implements LibraryDriver {
  @override
  String get name => 'my_package';

  /// The neutral contract scene (AppBar + element A + 12 rows with element
  /// B + scroll margin) with YOUR solution's widgets wired in — the rows
  /// your solution anchors get wrapped, nothing shown (idle).
  @override
  Widget buildScene({required bool withLibrary, required SceneSpec spec}) =>
      buildContractScene(
        spec,
        withLibrary: withLibrary,
        wrapRow: (index, row) => withLibrary && index == kSceneBRow
            ? MyTarget(id: sceneRowKey(index), child: row)
            : row,
      );

  /// The scenario verbs, mapped onto your controller.
  @override
  Future<void> show(int state) async { /* mount content card state */ }
  @override
  Future<void> update(int state) async { /* switch content in place */ }
  @override
  Future<void> hide() async { /* unmount */ }

  /// "My work on the current step is finished" — NOT an action. The
  /// scenario owns pumping: it pumps a frame and polls this until the
  /// timeout. If you pumped yourself, you would control S2/S3's timing.
  @override
  bool isStable() => /* state reached + no frame scheduled */;

  /// The visible ContractCard(state) — scenarios assert presence, absence
  /// and geometry through this finder.
  @override
  Finder currentContent(int state) =>
      find.byKey(Key(contractCardKey(state)), skipOffstage: false);

  /// Whether content follows element B under scroll (S4). Solutions without
  /// an anchor return false → the scenario reports `unsupported`.
  @override
  bool get scrollCoupled => true;
}
```

Scene keys and geometry are the package's constants, so your content is
findable without any solution-specific test code. The manifest
(`bench_contract.yaml`) is generated with sensible defaults — you edit only
your parts:

```yaml
library: my_package
driver: bench/drivers/my_driver.dart
driverClass: MyDriver
scenarios: [idle_zero, idle_resources, show_latency, update_latency,
            scroll_coupled, active_heap, hide_retention, size]
idleClasses: [MyController, MyRegistry]   # S1r per-class counting
```

### CI gate

```yaml
- uses: actions/checkout@v4
- name: Performance contract (check)
  run: dart run flutter_bench_contract:contract run --mode check --ref android
```

## CLI

`dart run flutter_bench_contract:contract <command>`

| Command | What it does |
|---|---|
| `init` | Scaffold `bench_contract.yaml` + the `bench/contract/` scenario bridges + a driver skeleton when missing. `--force` regenerates (and re-syncs the manifest's `template:` key). |
| `run` | Run the manifest's scenarios and check/record goldens. S1–S6 run as `flutter test` (host) or `flutter drive --no-dds --profile` (`--device`); the S7 size legs are host release builds (`size:` section) — pick them with `--legs native\|web\|both`. Options: `--mode check\|record`, `--ref`, `--slack`, `--scenarios`, `--library`. |
| `card` | Render the metrics-card PNG from the recorded goldens (manifest `card:`). |
| `readme` | Render the README section (manifest `readme:`) between its `<!-- bench:start/end -->` markers. |
| `verify` | Manifest/template/driver consistency. |

Exit codes: `0` ok, `1` regressions or failed build, `2` usage/config error.

## Beyond the basics

**Custom scenarios.** The contract metrics are fixed, but you can add your
own: declare `customScenarios:` and write the test yourself. The machinery —
run, goldens, gate — stays the package's, under the id `custom.<name>` with
its own golden ref, excluded from comparisons and public tables.

```yaml
customScenarios:
  startup_to_show:
    target: bench/startup_to_show_test.dart
    ref: android-custom
    runs: 1
```

**Head-to-head.** One manifest can run several solutions side by side: list
them under `libraries:` (a driver per solution), and `contract run` executes
the *same* scenario bodies against each with per-solution golden refs.
The published table gets a column per solution.

## First guarantor: hintful

[hintful](https://pub.dev/packages/hintful) — the tour/tooltip package this
contract was extracted from — is its first real consumer and the living
reference implementation: a full manifest (S1–S7 + S1r + a custom scenario),
a ~110-line driver, device goldens for three solutions (`android`,
`android-scv`, `android-tcm`) run head-to-head, and published results — the
metrics card PNG and the Performance table in hintful's README, both
rendered by `contract card`/`contract readme` from the same goldens the CI
gate checks. Its `bench-core` workflow is the CI shape to copy.

## Methodology and anti-tuning

- **Scenario definitions are frozen before goldens are recorded.** Changing
  one is a PR to this package with a checked reason: which number changed
  and why this is a scenario defect (the scene does not scroll, the action
  does not happen), not a tuning.
- **The protocol is one for everyone**: profile build, warm-ups, run
  counts, medians, slack, timeouts. A consumer cannot pass protocol values
  in the manifest — it picks scenarios but never redefines a metric.
- **Goldens are recorded once per reference hardware**; `check` is
  one-sided (regression only). Correctness asserts (S1, S4, S6) are
  two-sided and cannot be disabled.
- **`unsupported` is never hidden** — a scenario a solution cannot
  implement stays visible in reports and tables.

## Library layout

| File | What it provides |
|---|---|
| `lib/collectors.dart` | Frame-timing windows (`FrameWindow`, `collectFrames`) and VM-service heap probes. |
| `lib/report.dart` | The `HINTFUL_BENCH_JSON:` envelope, the median reducer, run-report reading. Pure Dart. |
| `lib/goldens.dart` | The `benchmarks.json` golden store: `record`, one-sided `check`, `load`. Pure Dart. |
| `lib/scene.dart` | The neutral scene (`buildContractScene`, `SceneSpec`) and its key/geometry constants. |
| `lib/card.dart` | The `ContractCard` content both scenarios and drivers mount by key. |
| `lib/driver.dart` | The `LibraryDriver` contract a consumer implements. |
| `lib/scenarios.dart` | The S1–S7 (+S1r) smart bodies, parameterized by driver — run by the generated bridges, versioned with the package. |
| `lib/manifest.dart` | The `bench_contract.yaml` model: scenarios, `idleClasses:`, `libraries:`, `customScenarios:`, `size:`/`card:`/`readme:`. |
| `lib/size.dart` | S7 size-build machinery (analyze-size, web bundle diff). |
| `lib/defs.dart` | Canonical display metadata (label/unit) and value formatters. Pure Dart. |
| `lib/metrics_card.dart` | The `MetricsCard` widget rendered by `contract card`. |
| `lib/readme.dart` | The README-section renderer. Pure Dart. |
| `bin/contract.dart` | The CLI. |

`report.dart`, `goldens.dart`, `defs.dart`, `readme.dart` and `manifest.dart`
are pure Dart — safe to import from plain `dart run` tools. `collectors.dart`
needs the Flutter engine; `driver.dart`, `scenarios.dart`, `scene.dart` and
`card.dart` run under `flutter_test`, which the package depends on
(precedent: golden_toolkit) so the scenario bodies can live in `lib/` and be
published once instead of copied per consumer.

## Development

```bash
flutter pub get
flutter analyze
flutter test   # device-free self-tests of the package
```

`example/` is a minimal consumer to copy; `test/` covers the store format,
median reduction, manifest validation, README/card rendering and scene
hooks. The full contract run needs an Android emulator (profile build) — see
hintful's `bench-core` workflow for the CI shape.