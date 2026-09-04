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