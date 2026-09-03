// GENERATED from flutter_bench_contract (template v1) — do not edit by hand.
// Regenerate: dart run flutter_bench_contract:contract init --force
//
// S1r idle_resources (spec §5.2, option `idleClasses:`): live instances of
// the solution's declared classes (controller / registry / listeners /
// timers) must return to their baseline after warm-up + hide() — a class
// leak must not hide behind a heap delta.
//
// NOTE (phase-2 M1): exact per-class instance counting needs VM-service
// `getInstances` (classRef resolution); until it lands, this scenario runs
// the protocol (warm-ups + GC) and reports the retained top-class growth
// diagnostic — declared-class counting is the next step and does not change
// the frozen metric definition (after − baseline == 0).
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_bench_contract/collectors.dart';
import 'package:flutter_bench_contract/report.dart';
import 'package:flutter_bench_contract/scene.dart';

{{apiImport}}
{{driverImport}}

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
    Map<String, int>? before;
    if (heap != null) {
      before = {
        for (final (name, bytes) in await heap.topClasses()) name: bytes
      };
    }

    // Protocol warm-up (methodology): M show→hide cycles.
    for (var i = 0; i < _kWarmups; i++) {
      await _showStable(tester, driver, 1);
      await _hideGone(tester, driver, 1);
    }
    await tester.pumpAndSettle();

    if (heap != null) {
      final after = {
        for (final (name, bytes) in await heap.topClasses()) name: bytes
      };
      // Diagnostic: classes whose retained bytes grew after the protocol —
      // an undeclared leak must stay visible even before per-class counting.
      final growth = <(String, int)>[
        for (final e in after.entries)
          if ((e.value - (before?[e.key] ?? 0)) > 0) (e.key, e.value),
      ]..sort((a, b) => b.$2.compareTo(a.$2));
      if (growth.isNotEmpty) {
        // ignore: avoid_print
        print('S1r diagnostic — top retained classes after warm-up+hide: '
            '${growth.take(10).join(', ')}');
      }
      await heap.dispose();

      reportMetric('idle_resources', null,
          extra: {'status': 'degraded', 'reason': 'per-class getInstances '
              'counting not implemented yet (M1); diagnostics only'});
    } else {
      // ignore: avoid_print
      print('S1r: no VM service (run with flutter drive --no-dds --profile) '
          '— idle_resources not measured');
      reportMetric('idle_resources', null,
          extra: {'status': 'degraded', 'reason': 'no VM service'});
    }
  });
}
