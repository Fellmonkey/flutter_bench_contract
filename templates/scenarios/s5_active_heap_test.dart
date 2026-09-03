// GENERATED from flutter_bench_contract (template v1) — do not edit by hand.
// Regenerate: dart run flutter_bench_contract:contract init --force
//
// S5 active_heap (spec §5.6): retained-heap delta "idle → shown" — the
// price of showing content. Needs the VM service (`flutter drive --no-dds
// --profile`); under a plain `flutter test` host run the sample degrades to
// null and only the "content shown" assert runs.
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_bench_contract/collectors.dart';
import 'package:flutter_bench_contract/report.dart';
import 'package:flutter_bench_contract/scene.dart';

{{apiImport}}
{{driverImport}}

const int _kTimeoutFrames = 625;
const int _kWarmups = 3; // methodology: M cycles before heap samples

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
  fail('S5: show($state) did not become visible and stable');
}

Future<void> _hideGone(WidgetTester tester, LibraryDriver driver,
    int state) async {
  await driver.hide();
  for (var i = 0; i < _kTimeoutFrames; i++) {
    if (driver.currentContent(state).evaluate().isEmpty) {
      await tester.pump(const Duration(milliseconds: 16));
      return;
    }
    await tester.pump(const Duration(milliseconds: 16));
  }
  fail('S5: content $state still present after hide()');
}

void main() {
  testWidgets('S5 active_heap', (tester) async {
    final spec = SceneSpec();
    addTearDown(spec.dispose);
    final driver = {{driverNew}};

    await tester.pumpWidget(driver.buildScene(withLibrary: true, spec: spec));
    await tester.pumpAndSettle();

    // Warm-up (methodology): M show→hide cycles settle caches, so the
    // measured "idle" and "active" points are post-warm-up states.
    for (var i = 0; i < _kWarmups; i++) {
      await _showStable(tester, driver, 1);
      await _hideGone(tester, driver, 1);
    }
    await tester.pumpAndSettle();

    // runAsync: Service.getInfo() is an engine call that never completes in
    // the FakeAsync zone of a plain `flutter test` run (it would hang the
    // host); real-async contexts (device, integration binding) are unaffected.
    final heap = await tester.runAsync(VmServiceHeap.connect);
    int? idleBytes;
    int? activeBytes;
    if (heap != null) {
      // Idle point: nothing shown, GC'd, median of 3 snapshots.
      await driver.hide();
      await tester.pumpAndSettle();
      idleBytes = await heap.usedBytesMedian(samples: 3);

      // Active point: content shown and stable, GC'd, median of 3 — and the
      // delta must measure an actually shown state (S2's assert re-checked).
      await _showStable(tester, driver, 1);
      await tester.pumpAndSettle();
      expect(driver.currentContent(1).evaluate().isNotEmpty, isTrue,
          reason: 'S5: content not visible at the active heap point');
      activeBytes = await heap.usedBytesMedian(samples: 3);

      await heap.dispose();
    }

    final delta = (idleBytes == null || activeBytes == null)
        ? null
        : activeBytes - idleBytes;
    if (delta == null) {
      // ignore: avoid_print
      print('S5: no VM service (run with flutter drive --no-dds --profile) '
          '— heap delta not measured');
    }
    reportMetric('active_heap', delta,
        extra: delta == null
            ? const {'status': 'degraded'}
            : {
                // delta != null ⇒ both samples exist; ?? 0 keeps the map
                // literal non-nullable without flow analysis across the
                // ternary.
                'idle_bytes': idleBytes ?? 0,
                'active_bytes': activeBytes ?? 0,
              });

    await _hideGone(tester, driver, 1);

    // Async-teardown settle (methodology): see S2 — overlay solutions leave
    // short-lived dismiss timers that must flush before the test ends; the
    // metric was reported above and is unaffected.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
  });
}
