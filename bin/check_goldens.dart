// The golden gate CLI of the performance contract.
//
// Reads machine-readable samples (`HINTFUL_BENCH_JSON:` lines) from a run
// report and either records them into `benchmarks.json` as goldens
// (`--record`) or checks the current run against existing goldens
// (`--check`, the CI default). Goldens are keyed per reference ("android",
// "web",...) so runs on different hardware/setups don't cross-compare.
//
// Duplicate samples (the runners emit several runs of the noisy frame
// metrics) are reduced by the median. Every metric is "lower is better", so
// the check is a one-sided regression gate: worse than the golden by more
// than the slack fails; better always passes.
//
// Usage (cwd: any package that depends on flutter_bench_contract):
//   dart run flutter_bench_contract:check_goldens <report.jsonl> --check --ref android
//   dart run flutter_bench_contract:check_goldens <report.jsonl> --record --ref android
//   [--slack 0.3]  relative tolerance per metric (default 0.3)
//
// Exit codes: 0 ok, 1 regressions found (--check) or no samples, 2 usage.
//
// A sample line looks like: HINTFUL_BENCH_JSON:{"metric":"startup_to_show","value":2}
// Missing goldens (a `--check` run before any `--record`) print a warning and
// do not fail — the first benchmark recording on a reference establishes them.
import 'dart:io';

// Only report.dart + goldens.dart here: this CLI runs under the plain Dart
// VM (`dart run`), which has no dart:ui — collectors.dart must not be
// pulled in (its flutter/scheduler import needs the Flutter engine).
import 'package:flutter_bench_contract/goldens.dart';
import 'package:flutter_bench_contract/report.dart';

void usage() {
  stderr.writeln('''
usage: dart run flutter_bench_contract:check_goldens <report.jsonl> --check|--record \\
            --ref <reference> [--slack 0.3]

  --check   compare samples from the report against goldens; fail on
            regression (missing golden = warning only)
  --record  write the report's samples as goldens for <reference>
  --ref     golden key under which values are stored (e.g. android, web)
  --slack   relative tolerance, 0..1 (default 0.3)''');
}

double slack = 0.3;
bool record = false;
String ref = '';
String? reportPath;

void parseArgs(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--check':
        record = false;
      case '--record':
        record = true;
      case '--ref':
        ref = args[++i];
      case '--slack':
        slack = double.parse(args[++i]);
      default:
        if (args[i].endsWith('.jsonl')) reportPath = args[i];
    }
  }
  if (reportPath == null || ref.isEmpty) {
    usage();
    exit(2);
  }
}

void main(List<String> args) {
  parseArgs(args);

  final samples = ReportFile(reportPath!).samples;
  if (samples.isEmpty) {
    stderr.writeln('No HINTFUL_BENCH_JSON samples found in $reportPath');
    exit(1);
  }
  final measured = samples.keys.toList()..sort();
  stdout.writeln('samples: ${measured.join(', ')} (ref=$ref, '
      '${record ? 'record' : 'check'})');

  final store = GoldenStore();
  if (record) {
    store.record(samples, ref: ref);
    return;
  }
  final failures = store.check(samples, ref: ref, slack: slack);
  if (failures > 0) exit(1);
}
