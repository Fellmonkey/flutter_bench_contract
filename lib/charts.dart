// Run artifacts for external tools: the trend-chart data file consumed by
// benchmark-action/github-action-benchmark and the machine-readable check
// report a CI comment is rendered from. Pure encoders — the CLI (`contract
// run`) writes the files under build/ on every run.
import 'dart:convert';

import 'defs.dart';
import 'goldens.dart';

/// Display unit of [metric] for chart series, or '' for metrics outside the
/// published defs (custom.* scenarios record their own units).
String chartUnitFor(String metric) => metricDefOf(metric)?.unit ?? '';

/// One measured point of a run: a metric under a ref, with its display unit
/// (charts name the series `metric@ref` — one series per reference setup).
class ChartPoint {
  const ChartPoint(this.metric, this.ref, this.value, [this.unit = '']);

  final String metric;
  final String ref;
  final num value;
  final String unit;

  String get name => '$metric@$ref';

  Map<String, Object?> toJson() => {
        'name': name,
        if (unit.isNotEmpty) 'unit': unit,
        'value': value,
      };
}

/// The github-action-benchmark `customSmallerIsBetter` input: a JSON array
/// of {name, unit, value} entries (their custom-tool schema; `range`/`extra`
/// are optional and unused here).
String chartDataJson(List<ChartPoint> points) =>
    jsonEncode([for (final p in points) p.toJson()]);

/// Machine-readable verdicts of one run's checks, keyed for consumers (the
/// action's PR-comment step renders the `regressions` rows).
String checkReportJson(List<MetricCheck> rows) {
  final regressions = rows.where((r) => r.regression).toList();
  return jsonEncode({
    'ok': regressions.isEmpty,
    'regressions': regressions.length,
    'metrics': [
      for (final r in rows)
        {
          'metric': r.metric,
          'ref': r.ref,
          'measured': r.measured,
          if (r.golden != null) 'golden': r.golden,
          'status': r.regression
              ? 'regression'
              : (r.noGolden ? 'no-golden' : 'ok'),
          if (r.deltaPct != null) 'deltaPct': r.deltaPct,
        },
    ],
  });
}
