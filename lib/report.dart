// Report layer of the performance contract: the machine-readable envelope
// every scenario emits per metric (`HINTFUL_BENCH_JSON:` lines on stdout)
// and the read side — parsing such lines back out of a run report and
// reducing a metric's duplicate samples to the median.
//
// Duplicates are reduced the same way everywhere (record, check, publish),
// so the golden, the gate and the published number always agree.
import 'dart:convert';
import 'dart:io';

/// Prefix of every machine-readable sample line.
const String envelope = 'HINTFUL_BENCH_JSON:';

/// Emits one machine-readable benchmark sample on stdout.
///
/// Format: `HINTFUL_BENCH_JSON:<json>`. Every sample carries `metric` and a
/// nullable `value` (null = could not measure — the collector skips such
/// samples).
void reportMetric(String metric, num? value, {Map<String, Object>? extra}) {
  final payload = <String, Object?>{
    'metric': metric,
    'value': value,
    if (extra != null) ...extra,
  };
  // ignore: avoid_print
  print('$envelope${jsonEncode(payload)}');
}

/// Parses [line] into a (metric, value) sample, or null.
///
/// The envelope is searched anywhere in the line, not only at its start:
/// under `flutter drive` the app's stdout is prefixed by the tool
/// (`I/flutter ( <pid>): ...`), while plain `flutter test` prints raw.
Map<String, Object?>? parseSample(String line) {
  final start = line.indexOf(envelope);
  if (start < 0) return null;
  final payload = line.substring(start + envelope.length).trim();
  final decoded = jsonDecode(payload) as Map<String, dynamic>;
  return decoded.cast<String, Object?>();
}

/// Median of [values] (sorted, middle element).
///
/// Runners emit several samples per noisy metric (frame benches swing
/// run-to-run on the same device); every consumer reduces duplicates with
/// this — the recorded golden, the check and the published tables all show
/// the median, not the last (or best) run.
num medianOf(List<num> values) {
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2];
}

/// One bench run report: a `.jsonl` file of log lines with embedded
/// [envelope] samples. Reading a report reduces every metric's samples to
/// its median — the number the golden CLI records and checks against.
class ReportFile {
  ReportFile(this.path);

  /// Path to the report file (`.jsonl`).
  final String path;

  /// Per-metric medians of the samples in the report. An empty map when the
  /// file holds no samples.
  Map<String, num> get samples {
    final raw = <String, List<num>>{};
    for (final line in File(path).readAsLinesSync()) {
      final sample = parseSample(line);
      if (sample == null) continue;
      final metric = sample['metric'] as String?;
      final value = sample['value'];
      if (metric == null || value == null) continue;
      raw.putIfAbsent(metric, () => []).add(value as num);
    }
    return {for (final e in raw.entries) e.key: medianOf(e.value)};
  }
}
