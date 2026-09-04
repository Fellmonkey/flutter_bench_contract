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

/// One metric's verdict against its recorded golden (regression gate).
/// Every metric is lower-is-better; a metric with no recorded golden under
/// [ref] or `any` is reported as [noGolden] (a check before the first
/// record — warned, not failed).
class MetricCheck {
  const MetricCheck({
    required this.metric,
    required this.ref,
    required this.measured,
    required this.golden,
    required this.limit,
    required this.slack,
  });

  /// Metric key (scenario id).
  final String metric;

  /// Reference the golden was looked up under (falls back to `any`).
  final String ref;

  /// Measured median of this run.
  final num measured;

  /// Recorded golden under [ref] or `any`, or null when none exists.
  final num? golden;

  /// One-sided gate bound = ceil(|golden * slack|) clamped to ≥ 1.
  /// Null when there is no golden.
  final num? limit;

  /// Slack fraction used for the gate.
  final double slack;

  /// True when this metric was measured but has no recorded golden yet.
  bool get noGolden => golden == null || limit == null;

  /// Regression: measured worse than the golden by more than the slack.
  bool get regression =>
      !noGolden && measured > (golden! + limit!);

  /// Signed percent the measured value deviates from the golden
  /// ((measured − golden) / golden × 100, one decimal), null without a
  /// golden.
  num? get deltaPct {
    final g = golden;
    if (g == null || g == 0) return null;
    return double.parse(((measured - g) / g * 100).toStringAsFixed(1));
  }
}

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
  /// Prints one line per metric and a summary. Returns one [MetricCheck] per
  /// measured metric — regressions are the rows where [MetricCheck.regression]
  /// is true; the number of regressions was the previous return value.
  List<MetricCheck> check(
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

    final rows = <MetricCheck>[];
    final keys = measured.keys.toList()..sort();
    for (final metric in keys) {
      final value = measured[metric]!;
      final metricDoc = metrics[metric] as Map<String, dynamic>?;
      final goldens =
          metricDoc?['goldens'] as Map<String, dynamic>? ?? const {};
      final golden = goldens[ref] ?? goldens['any'];
      final g = golden as num?;
      final limit = g == null
          ? null
          : (g * slack).abs().ceil().clamp(1, 1 << 62);
      rows.add(MetricCheck(
        metric: metric,
        ref: ref,
        measured: value,
        golden: g,
        limit: limit,
        slack: slack,
      ));
      if (g == null) {
        stdout.writeln('  $metric: no golden under ref "$ref" — run '
            '"--record" once on the reference to establish it');
        continue;
      }
      if (value > g + limit!) {
        stderr.writeln('  FAIL $metric: measured $value, golden $g '
            '(worse by more than ${slack * 100}%)');
      } else {
        stdout.writeln('  $metric: $value ≤ golden $g + ${slack * 100}% '
            '(regression gate)');
      }
    }
    final failures = rows.where((r) => r.regression).length;
    if (failures > 0) {
      stderr.writeln('REGRESSION: $failures metric(s) outside the golden '
          'envelope');
    } else {
      stdout.writeln('OK: all measured metrics within their goldens');
    }
    return rows;
  }
}
