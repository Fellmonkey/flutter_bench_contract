// GENERATED from flutter_bench_contract (template v1) — do not edit by hand.
// Regenerate: dart run flutter_bench_contract:contract init --force
//
// S1r idle_resources (spec §5.2, option `idleClasses:`): live instances of
// the solution's declared classes (controller / registry / listeners /
// timers) must return to their baseline after warm-up + hide() — a class
// leak must not hide behind a heap delta.
//
// Two modes, decided by the rendered `idleClasses:` list:
//   - classes declared: the scenario counts live instances of every declared
//     class via the VM service (`getInstances` after a forced GC) before and
//     after the warm-up protocol, reports the max per-class delta and
//     asserts it is EXACTLY 0 (the in-test assert is the two-sided gate;
//     the store check is the one-sided regression layer on the value).
//   - no classes declared: degrades to the M1 diagnostic (retained top-class
//     growth print) and reports no value — nothing is recorded or gated.
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_bench_contract/collectors.dart';
import 'package:flutter_bench_contract/report.dart';
import 'package:flutter_bench_contract/scene.dart';

{{apiImport}}
{{driverImport}}

/// Declared solution classes whose live instances must return to baseline
/// (manifest `idleClasses:`; rendered by `contract init`). Empty → M1
/// diagnostic mode, no value recorded.
const List<String> _kIdleClasses = {{idleClasses}};

const int _kTimeoutFrames = 625;
const int _kWarmups = 3; // methodology

Future<void> _showStable(
    WidgetTester tester, LibraryDriver driver, int state) async {
  await driver.show(state);
  for (var i = 0; i < _kTimeoutFrames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (driver.currentContent(state).evaluate().isNotEmpty &&
        driver.isStable()) {
      return;
    }
  }
  fail('S1r: show($state) did not become visible and stable');
}

Future<void> _hideGone(
    WidgetTester tester, LibraryDriver driver, int state) async {
  await driver.hide();
  for (var i = 0; i < _kTimeoutFrames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (driver.currentContent(state).evaluate().isEmpty) {
      return;
    }
  }
  fail('S1r: content $state still present after hide()');
}

/// Live-instance counters for every declared class, after a forced GC; null
/// when any VM-service call failed (degrade to the diagnostic path).
Future<Map<String, int>?> _countDeclared(VmServiceHeap heap) async {
  final counts = <String, int>{};
  for (final name in _kIdleClasses) {
    final n = await heap.instancesOfClass(name);
    if (n == null) return null;
    counts[name] = n;
  }
  return counts;
}

void main() {
  testWidgets('S1r idle_resources', (tester) async {
    final spec = SceneSpec();
    addTearDown(spec.dispose);
    final driver = {{driverNew}};

    await tester.pumpWidget(driver.buildScene(withLibrary: true, spec: spec));
    await tester.pumpAndSettle();

    // runAsync: Service.getInfo() is an engine call that never completes in
    // the FakeAsync zone of a plain `flutter test` run (it would hang the
    // host); real-async contexts (device, integration binding) are unaffected.
    final heap = await tester.runAsync(VmServiceHeap.connect);
    final precise = heap != null && _kIdleClasses.isNotEmpty;

    Map<String, int>? before;
    Map<String, int>? topBefore;
    if (heap != null) {
      if (precise) {
        before = await _countDeclared(heap);
      } else {
        topBefore = {
          for (final (name, bytes) in await heap.topClasses()) name: bytes
        };
      }
    }

    // Protocol warm-up (methodology): M show→hide cycles.
    for (var i = 0; i < _kWarmups; i++) {
      await _showStable(tester, driver, 1);
      await _hideGone(tester, driver, 1);
    }
    await tester.pumpAndSettle();

    if (precise) {
      final after = await _countDeclared(heap);
      if (before == null || after == null) {
        await heap.dispose();
        // ignore: avoid_print
        print('S1r: VM-service counting failed — degraded, not measured');
        reportMetric('idle_resources', null,
            extra: {'status': 'degraded', 'reason': 'getInstances failed'});
        return;
      }
      // Per-class deltas after warm-up + hide; the scenario metric is the
      // max (spec §5.2) and the gate is exact.
      final deltas = <(String, int)>[
        for (final name in _kIdleClasses)
          (name, (after[name] ?? 0) - (before[name] ?? 0)),
      ];
      final maxDelta = deltas.map((d) => d.$2).fold<int>(0,
          (a, b) => a > b ? a : b);
      await heap.dispose();
      // ignore: avoid_print
      print('S1r per-class deltas (after−baseline): ${deltas.join(', ')}');
      reportMetric('idle_resources', maxDelta);
      expect(maxDelta, 0,
          reason: 'declared idle classes must return to baseline after '
              'warm-up + hide() — ${deltas.join(', ')}');
    } else {
      // M1 diagnostic: no VM service or no idleClasses declared — classes
      // whose retained bytes grew after the protocol stay visible even
      // before per-class counting, and the reason is reported as degraded.
      String? reason;
      if (heap == null) {
        reason = 'no VM service';
      } else {
        final topAfter = {
          for (final (name, bytes) in await heap.topClasses()) name: bytes
        };
        final growth = <(String, int)>[
          for (final e in topAfter.entries)
            if ((e.value - (topBefore?[e.key] ?? 0)) > 0) (e.key, e.value),
        ]..sort((a, b) => b.$2.compareTo(a.$2));
        if (growth.isNotEmpty) {
          // ignore: avoid_print
          print('S1r diagnostic — top retained classes after warm-up+hide: '
              '${growth.take(10).join(', ')}');
        }
        reason = 'no idleClasses declared (manifest)';
        await heap.dispose();
      }
      // ignore: avoid_print
      print('S1r: $reason — idle_resources not measured');
      reportMetric('idle_resources', null,
          extra: {'status': 'degraded', 'reason': reason});
    }
  });
}