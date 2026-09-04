// Canonical label + unit per published metric, shared by every consumer's
// card/README (pure Dart — the CLIs run under plain `dart run`). S4 records
// no number; S1r is n/a without `idleClasses:`.
library;

/// Display definition of one published metric.
class MetricDef {
  const MetricDef(this.key, this.label, this.unit);

  /// Store/report key of the metric (identical to its scenario id).
  final String key;

  /// Published row label (methodology copy).
  final String label;

  /// Display unit: elements / ms / B.
  final String unit;
}

/// Contract device metrics (profile build, emulator): the published S1–S6
/// rows. Lower is better for all of them.
const List<MetricDef> kDeviceMetricDefs = [
  MetricDef('idle_zero', 'Idle tree diff (S1)', 'elements'),
  MetricDef('idle_resources', 'Idle resources (S1r)', 'instances'),
  MetricDef('show_latency', 'Show latency (S2)', 'ms'),
  MetricDef('update_latency', 'Update latency (S3)', 'ms'),
  MetricDef('active_heap', 'Active-step heap (S5)', 'B'),
  MetricDef('hide_retention', 'Heap retained after hide (S6)', 'B'),
];

/// Host-size metrics (release builds, no device) — S7, a scenario of
/// `contract run` like the rest. `bundle_delta` is SDK-pinned under ref
/// `any`; `native_size` under `any` + `android`.
const List<MetricDef> kSizeMetricDefs = [
  MetricDef('native_size', 'Native AOT size', 'B'),
  MetricDef('bundle_delta', 'Web startup bundle delta', 'B'),
];

/// The metrics a published table/card can show: everything that records a
/// number ([kDeviceMetricDefs] + [kSizeMetricDefs]).
const List<MetricDef> kPublishableMetricDefs = [
  ...kDeviceMetricDefs,
  ...kSizeMetricDefs,
];

/// Def for [key] among [kPublishableMetricDefs], or null.
MetricDef? metricDefOf(String key) {
  for (final def in kPublishableMetricDefs) {
    if (def.key == key) return def;
  }
  return null;
}

/// Compact display value+unit for a table cell: 41632 B -> '41 KB',
/// 72 ms -> '72 ms', 4 -> '4'.
String formatTableValue(num? value, String unit) {
  if (value == null) return 'n/a';
  final v = value.toDouble();
  if (unit == 'B') {
    if (v.abs() >= 1e6) return '${(v / 1e6).toStringAsFixed(1)} MB';
    if (v.abs() >= 1e3) return '${(v / 1e3).round()} KB';
    return '${v.round()} B';
  }
  if (unit == 'ms') return '${v.round()} ms';
  return '${v.round()}';
}

/// Display value for a card tile: bytes as KB/MB, ms as ms (or s above
/// 1000), else as-is.
String formatCardValue(num? value, String unit) {
  if (value == null) return 'n/a';
  final v = value.toDouble();
  if (unit == 'B') {
    if (v.abs() >= 1e6) return '${(v / 1e6).toStringAsFixed(1)} MB';
    if (v.abs() >= 1e3) return '${(v / 1e3).round()} KB';
    return '${v.round()} B';
  }
  if (unit == 'ms') {
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)} s';
    return '${v.round()} ms';
  }
  return '${v.round()}';
}
