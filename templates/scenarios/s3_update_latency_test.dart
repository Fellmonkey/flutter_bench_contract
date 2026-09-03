// GENERATED from flutter_bench_contract (template v1) — do not edit by hand.
// Regenerate: dart run flutter_bench_contract:contract init --force
//
// S3 update_latency (spec §5.4): wall ms from `update(state)` to the frame
// where the NEW ContractCard is visible, the OLD one is gone and the state
// is stable. Three transitions per run, the metric is their median — a
// smeared transition cannot win: wall time is paid by whoever transitions.
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_bench_contract/report.dart';
import 'package:flutter_bench_contract/scene.dart';

{{apiImport}}
{{driverImport}}

const int _kTimeoutFrames = 625; // 10 s @ 16 ms (methodology)

/// One `update()` transition: pumps until the new content is visible, the
/// old is gone and the driver reports stability. Returns wall ms.
Future<double> _transitionMs(
  WidgetTester tester,
  LibraryDriver driver,
  int from,
  int to,
) async {
  final t0 = DateTime.now();
  await driver.update(to);
  for (var i = 0; i < _kTimeoutFrames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    final newVisible = driver.currentContent(to).evaluate().isNotEmpty;
    final oldGone = driver.currentContent(from).evaluate().isEmpty;
    if (newVisible && oldGone && driver.isStable()) {
      return DateTime.now().difference(t0).inMicroseconds / 1000.0;
    }
  }
  fail('S3: update($to) did not replace content $from within 10 s '
      '(newVisible='
      '${driver.currentContent(to).evaluate().isNotEmpty}, '
      'oldGone=${driver.currentContent(from).evaluate().isEmpty}, '
      'isStable()=${driver.isStable()})');
}

void main() {
  testWidgets('S3 update_latency', (tester) async {
    final spec = SceneSpec();
    addTearDown(spec.dispose);
    final driver = {{driverNew}};

    await tester.pumpWidget(driver.buildScene(withLibrary: true, spec: spec));
    await tester.pumpAndSettle();

    // S2 brings the scene to a shown state 1.
    await driver.show(1);
    var shown = false;
    for (var i = 0; i < _kTimeoutFrames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (driver.currentContent(1).evaluate().isNotEmpty &&
          driver.isStable()) {
        shown = true;
        break;
      }
    }
    expect(shown, isTrue, reason: 'S3: setup show(1) never stabilized');

    // Three transitions 1→2, 2→1, 1→2 — the metric is their median.
    final ms = <double>[
      await _transitionMs(tester, driver, 1, 2),
      await _transitionMs(tester, driver, 2, 1),
      await _transitionMs(tester, driver, 1, 2),
    ];
    reportMetric('update_latency', medianOf(ms).round(),
        extra: {'transitions_ms': ms.map((m) => m.round()).toList()});

    // No traces: after hide() the card must leave the tree.
    await driver.hide();
    var gone = false;
    for (var i = 0; i < _kTimeoutFrames; i++) {
      if (driver.currentContent(2).evaluate().isEmpty) {
        gone = true;
        break;
      }
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(gone, isTrue,
        reason: 'S3: ContractCard(2) still present after hide()');
  });
}
