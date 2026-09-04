// Display metadata of the published contract metrics: the canonical label +
// unit of every metric that records a number (device S1–S6 rows + host S7
// size rows). One definition shared by every consumer's card and README
// table — the methodology is the package's, not the consumer's: a consumer
// picks scenarios but never redefines a metric.
//
// Pure Dart (no flutter imports): the readme renderer and the card CLI run
// under the plain VM (`dart run`), which has no dart:ui.
//
// Not in this list: `scroll_coupled` (S4) and `idle_resources` (S1r) record
// no number (two-sided in-scenario asserts / diagnostics), so they cannot be
// a published row; the README footnote explains them.
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
  MetricDef('show_latency', 'Show latency (S2)', 'ms'),
  MetricDef('update_latency', 'Update latency (S3)', 'ms'),
  MetricDef('active_heap', 'Active-step heap (S5)', 'B'),
  MetricDef('hide_retention', 'Heap retained after hide (S6)', 'B'),
];

/// Host-size metrics (release builds, no device) — S7, run by `contract
/// size`. `bundle_delta` is SDK-pinned under ref `any`; `native_size` under
/// `any` + `android`.
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
