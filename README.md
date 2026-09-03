# flutter_bench_contract

A performance contract for Flutter widget solutions that live on top of or
next to an application — tooltips and tours, popovers, toasts, overlays,
autocomplete layers, scroll-linked content.

It turns “our widget code is fast” into a repeatable, gated claim:

- **Canonical scenarios with assertions** — a scenario asserts that the
  action really happened (content shown, content following a scrolled
  target, nothing leaking after hide), so there is nothing to win by doing
  nothing.
- **One-sided golden gate** — CI fails only on regressions; honest
  improvements always pass. Goldens are recorded once per reference
  hardware/setup.
- **Reproducible numbers** — every sample is emitted on a machine-readable
  envelope (`HINTFUL_BENCH_JSON:` lines), duplicates are reduced by the
  median, and the published number is the same number the gate checked.

This repository is the generic core of that contract: measurement
collectors, the report envelope, and the golden store with its gate CLI. It
is device-scenario agnostic — solution-specific drivers and scene templates
plug into it.

## Library layout

| File | What it provides |
|---|---|
| `lib/collectors.dart` | Frame-timing windows (`FrameWindow`, `collectFrames`) and VM-service heap probes (`VmServiceHeap`: used-bytes medians after GC, top retained classes). Timings in microseconds; free of `flutter_test`. |
| `lib/report.dart` | The `HINTFUL_BENCH_JSON:` envelope (`reportMetric`, `parseSample`), the median reducer (`medianOf`), and run-report reading (`ReportFile` → per-metric medians). |
| `lib/goldens.dart` | The `benchmarks.json` golden store (`GoldenStore`): `record`, one-sided `check`, and `load` for lookups with ref preference. |
| `bin/check_goldens.dart` | The golden gate CLI (see below). |

Pure-Dart layers only: `report.dart` and `goldens.dart` are safe to import
from plain `dart run` tools; `collectors.dart` needs the Flutter engine.

## Using the golden gate

From any package that depends on `flutter_bench_contract`:

```bash
dart run flutter_bench_contract:check_goldens build/bench_report.jsonl --check  --ref android
dart run flutter_bench_contract:check_goldens build/bench_report.jsonl --record --ref android
```

Every benchmark emits one machine-readable line per sample:

```
HINTFUL_BENCH_JSON:{"metric":"startup_to_show","value":3}
```

The CLI reads all samples of a metric from the report and reduces them to
the median, then either:

- `--record` writes them as goldens for the reference (`benchmarks.json`,
  keyed per reference setup — different hardware doesn’t cross-compare), or
- `--check` compares against the recorded goldens: every metric is
  *lower-is-better*, so only values worse than the golden by more than the
  slack fail (a missing golden warns instead of failing — run `--record`
  once per reference to establish it).

Exit codes: `0` ok, `1` regressions found (or no samples in the report),
`2` usage error. `--slack` sets the relative tolerance per metric
(default `0.3`).

## Quick API tour

```dart
// Inside a benchmark test (device/profile runs):
final window = await collectFrames(() async { /* the action being measured */ });
reportMetric('frame_step_change', window.avgBuildUs.round()); // FrameWindow

final heap = await VmServiceHeap.connect(); // needs a VM-service run (--no-dds)
final bytes = await heap?.usedBytesMedian(); // used heap after forced GC

// Reading a run report (anywhere):
final samples = ReportFile('build/bench_report.jsonl').samples; // per-metric medians

// The golden store (cwd: the package owning benchmarks.json):
final store = GoldenStore();
store.record(samples, ref: 'android');           // write goldens
final regressions = store.check(samples, ref: 'android', slack: 0.3);
final golden = store.load('startup_to_show');    // prefers 'android', then 'any'
```

## Development

```bash
flutter pub get
flutter analyze
flutter test   # device-free self-tests of the report and golden layers
```
