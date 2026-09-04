// The golden store of the performance contract: `benchmarks.json` — the
// file format and gate semantics recorded goldens live in.
//
// Goldens are keyed per reference ("android", "web", ...) so runs on
// different hardware/setups don't cross-compare. The store format:
//
//   {
//     "metrics": {
//       "startup_to_show": {
//         "unit": "startup_to_show",
//         "goldens": { "android": 2, "any": 3 }
//       }
//     }
//   }
//
// Every metric is "lower is better", so the check is a one-sided regression
// gate: worse than the golden by more than the slack fails; better always
// passes. A symmetric envelope would fail honest improvements (and a faster
// CI machine than the recording one) — recorded goldens sit wherever the
// reference hardware was when recorded, so the check must only answer "did
// it get worse?".
import 'dart:convert';
import 'dart:io';

/// Default store file name, in one place.
const String goldensPath = 'benchmarks.json';

/// The `benchmarks.json` store: reads recorded goldens, checks measured
/// samples against them (regression gate) and records new ones.
class GoldenStore {
  GoldenStore({this.path = goldensPath});

  /// Path to the store file (default: `benchmarks.json` next to the runner).
  final String path;

  /// Recorded golden for [metric], preferring the references in [preferRefs]
  /// (default: `android`, then `any`), then — when [fallbackAny] — the first
  /// recorded value. Null when the file is missing, corrupt, or has no
  /// entry. Head-to-head refs (android-scv, android-tcm) plug in via
  /// [preferRefs].
  num? load(
    String metric, {
    List<String> preferRefs = const ['android', 'any'],
    bool fallbackAny = true,
  }) {
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final metricsDoc = (doc['metrics'] as Map?)?.cast<String, dynamic>();
      final byRef =
          ((metricsDoc?[metric] as Map?)?['goldens'] as Map?)
                  ?.cast<String, dynamic>() ??
              const <String, dynamic>{};
      for (final ref in preferRefs) {
        final value = byRef[ref];
        if (value is num) return value;
      }
      // When no preferred ref matches, optionally fall back to whatever ref
      // recorded this metric. Rival columns pass fallbackAny: false — a
      // rival must never inherit hintful's numbers.
      if (!fallbackAny) return null;
      return byRef.values.whereType<num>().firstOrNull;
    } on FormatException {
      return null;
    }
  }

  /// Records [measured] medians as goldens for [ref] and writes the store
  /// when anything changed. Prints one `recorded` line per metric and a
  /// final `wrote` line — the CLI log the CI publishes.
  void record(Map<String, num> measured, {required String ref}) {
    final file = File(path);
    final dynamic doc = file.existsSync()
        ? jsonDecode(file.readAsStringSync())
        : <String, Object?>{'metrics': <String, Object?>{}};
    final metrics =
        (doc['metrics'] as Map<String, dynamic>).cast<String, Object?>();

    var changed = false;
    final keys = measured.keys.toList()..sort();
    for (final metric in keys) {
      final golden = measured[metric];
      if (golden == null) continue;
      final metricDoc = metrics.putIfAbsent(
        metric,
        () => <String, Object?>{'unit': metric, 'goldens': <String, Object?>{}},
      ) as Map<String, dynamic>;
      final goldens = metricDoc.putIfAbsent(
          'goldens', () => <String, Object?>{}) as Map<String, dynamic>;
      goldens[ref] = golden;
      stdout.writeln('recorded $metric = $golden (ref=$ref)');
      changed = true;
    }
    if (changed) {
      file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(doc));
      stdout.writeln('wrote $goldensPath');
    }
  }

  /// Checks [measured] medians against the recorded goldens of [ref]: every
  /// metric is "lower is better", so the gate is one-sided — measured worse
  /// than the golden by more than the [slack] fails, measured better always
  /// passes. Missing goldens (a check before any record) print a warning and
  /// do not fail — the first recording on a reference establishes them.
  ///
  /// Prints one line per metric and a summary. Returns the number of
  /// regressions (0 = pass).
  int check(
    Map<String, num> measured, {
    required String ref,
    double slack = 0.3,
  }) {
    final file = File(path);
    final dynamic doc = file.existsSync()
        ? jsonDecode(file.readAsStringSync())
        : <String, Object?>{'metrics': <String, Object?>{}};
    final metrics =
        (doc['metrics'] as Map<String, dynamic>).cast<String, Object?>();

    var failures = 0;
    final keys = measured.keys.toList()..sort();
    for (final metric in keys) {
      final value = measured[metric]!;
      final metricDoc = metrics[metric] as Map<String, dynamic>?;
      final goldens =
          metricDoc?['goldens'] as Map<String, dynamic>? ?? const {};
      final golden = goldens[ref] ?? goldens['any'];
      if (golden == null) {
        stdout.writeln('  $metric: no golden under ref "$ref" — run '
            '"--record" once on the reference to establish it');
        continue;
      }
      final g = golden as num;
      final limit = (g * slack).abs().ceil().clamp(1, 1 << 62);
      if (value > g + limit) {
        stderr.writeln('  FAIL $metric: measured $value, golden $g '
            '(worse by more than ${slack * 100}%)');
        failures++;
      } else {
        stdout.writeln('  $metric: $value ≤ golden $g + ${slack * 100}% '
            '(regression gate)');
      }
    }
    if (failures > 0) {
      stderr.writeln('REGRESSION: $failures metric(s) outside the golden '
          'envelope');
    } else {
      stdout.writeln('OK: all measured metrics within their goldens');
    }
    return failures;
  }
}
