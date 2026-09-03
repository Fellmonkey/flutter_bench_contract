// Public barrel of the performance contract package.
//
// Phase-1 layout (extraction from hintful's benchmark suite):
//   collectors.dart — frame-timing windows + VM-service heap probes
//   report.dart     — HINTFUL_BENCH_JSON envelope (emit/parse/median)
//   goldens.dart    — benchmarks.json store (record/check/read goldens)
library;

export 'card.dart';
export 'collectors.dart';
export 'goldens.dart';
export 'manifest.dart';
export 'report.dart';
export 'scene.dart';
