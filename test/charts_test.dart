// Self-tests of the run-artifact encoders (lib/charts.dart): the chart-data
// array fed to benchmark-action/github-action-benchmark and the machine-
// readable check report. Pure Dart — no device, no golden store file.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_bench_contract/charts.dart';
import 'package:flutter_bench_contract/goldens.dart';

void main() {
  group('chartDataJson — github-action-benchmark input', () {
    test('one {name, unit, value} entry per metric@ref point', () {
      final entries = jsonDecode(chartDataJson(const [
        ChartPoint('show_latency', 'android', 912, 'ms'),
        ChartPoint('bundle_delta', 'any', 48690, 'B'),
        ChartPoint('custom.startup_to_show', 'android-custom', 2),
      ])) as List;
      expect(entries, [
        {'name': 'show_latency@android', 'unit': 'ms', 'value': 912},
        {'name': 'bundle_delta@any', 'unit': 'B', 'value': 48690},
        {'name': 'custom.startup_to_show@android-custom', 'value': 2},
      ]);
    });

    test('chartUnitFor resolves the published defs only', () {
      expect(chartUnitFor('show_latency'), 'ms');
      expect(chartUnitFor('active_heap'), 'B');
      expect(chartUnitFor('idle_zero'), 'elements');
      expect(chartUnitFor('custom.x'), '');
    });
  });

  group('checkReportJson — machine-readable verdicts', () {
    MetricCheck row({
      required num measured,
      num? golden = 100,
      int? limit = 30,
    }) =>
        MetricCheck(
          metric: 'show_latency',
          ref: 'android',
          measured: measured,
          golden: golden,
          limit: limit,
          slack: 0.3,
        );

    test('flags regressions and ok=false with the delta percent', () {
      final json = jsonDecode(checkReportJson([
        row(measured: 912),
        row(measured: 90),
      ])) as Map<String, dynamic>;
      expect(json['ok'], isFalse);
      expect(json['regressions'], 1);
      final metrics = (json['metrics'] as List).cast<Map<String, dynamic>>();
      expect(metrics[0]['status'], 'regression');
      expect(metrics[0]['deltaPct'], 812.0);
      expect(metrics[1]['status'], 'ok');
    });

    test('ok=true when nothing regressed; no-golden rows are not failures', () {
      final json = jsonDecode(checkReportJson([
        row(measured: 90),
        row(measured: 1, golden: null, limit: null),
      ])) as Map<String, dynamic>;
      expect(json['ok'], isTrue);
      final metrics = (json['metrics'] as List).cast<Map<String, dynamic>>();
      expect(metrics[1]['status'], 'no-golden');
      expect(metrics[1].containsKey('golden'), isFalse);
      expect(metrics[1].containsKey('deltaPct'), isFalse);
    });
  });
}
