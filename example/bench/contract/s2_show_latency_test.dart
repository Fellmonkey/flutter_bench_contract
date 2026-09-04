// GENERATED from flutter_bench_contract (template v1) — do not edit by hand.
// Regenerate: dart run flutter_bench_contract:contract init --force
//
// S2 show_latency: wall ms from `show(1)` to the frame where
// ContractCard(1) is visible and stable. The show is cold — no show has
// happened before, so the price is the honest first-show cost (no warm-up).
// Timing is wall-clock; the scenario owns pumping (the driver cannot smear
// the delay by spreading it over frames — a smeared transition IS a large
// wall delay).
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_bench_contract/report.dart';
import 'package:flutter_bench_contract/scene.dart';

import '../drivers/demo_solution_driver.dart';

const int _kState = 1;
// 10 s wall timeout (methodology): pumped at a 16 ms frame budget.
const int _kTimeoutFrames = 625;

void main() {
  testWidgets('S2 show_latency', (tester) async {
    final spec = SceneSpec();
    addTearDown(spec.dispose);
    final driver = DemoSolutionDriver();

    await tester.pumpWidget(driver.buildScene(withLibrary: true, spec: spec));
    await tester.pumpAndSettle();

    final t0 = DateTime.now();
    await driver.show(_kState);
    var stable = false;
    for (var i = 0; i < _kTimeoutFrames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (driver.currentContent(_kState).evaluate().isNotEmpty &&
          driver.isStable()) {
        stable = true;
        break;
      }
    }
    final elapsedMs = DateTime.now().difference(t0).inMicroseconds / 1000.0;

    // Assert: the content really appeared and stabilized before the timeout.
    expect(stable, isTrue,
        reason: 'S2: ContractCard($_kState) not visible and stable within '
            '10 s (content found='
            '${driver.currentContent(_kState).evaluate().isNotEmpty}, '
            'isStable()=${driver.isStable()})');

    // The CLI repeats this scenario (BENCH_RUNS=3, methodology) and the
    // report reducer takes the median — one sample per run here.
    reportMetric('show_latency', elapsedMs.round());

    // No traces: after hide() the card must leave the tree.
    await driver.hide();
    var gone = false;
    for (var i = 0; i < _kTimeoutFrames; i++) {
      if (driver.currentContent(_kState).evaluate().isEmpty) {
        gone = true;
        break;
      }
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(gone, isTrue,
        reason: 'S2: ContractCard($_kState) still present after hide()');
  });
}
