// GENERATED from flutter_bench_contract (template v1) — do not edit by hand.
// Regenerate: dart run flutter_bench_contract:contract init --force
//
// S1 idle_zero: how many tree elements the solution adds when
// nothing is shown — the difference between the base scene (no solution)
// and the with-solution idle scene. "0" is true zero-idle. The count walks
// the live element tree; there is no self-report the solution could tune.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_bench_contract/report.dart';
import 'package:flutter_bench_contract/scene.dart';

{{driverImport}}

/// Live element count of the whole mounted tree (walk, no self-report).
int _countElements(WidgetTester tester) {
  final root = tester.binding.rootElement!;
  var count = 0;
  void walk(Element e) {
    count++;
    e.visitChildren(walk);
  }

  walk(root);
  return count;
}

void main() {
  testWidgets('S1 idle_zero', (tester) async {
    final driver = {{driverNew}};

    // (1) Base scene without the solution → n0.
    final baseSpec = SceneSpec();
    addTearDown(baseSpec.dispose);
    await tester
        .pumpWidget(driver.buildScene(withLibrary: false, spec: baseSpec));
    await tester.pumpAndSettle();
    final n0 = _countElements(tester);

    // (2) Idle scene with the solution, twice (determinism assert below).
    final idleSpec1 = SceneSpec();
    addTearDown(idleSpec1.dispose);
    await tester
        .pumpWidget(driver.buildScene(withLibrary: true, spec: idleSpec1));
    await tester.pumpAndSettle();
    final n1a = _countElements(tester);

    final idleSpec2 = SceneSpec();
    addTearDown(idleSpec2.dispose);
    await tester
        .pumpWidget(driver.buildScene(withLibrary: true, spec: idleSpec2));
    await tester.pumpAndSettle();
    final n1b = _countElements(tester);

    // Determinism: two independent idle mounts must give the same diff —
    // otherwise the scene (or the solution) is not stable enough to measure.
    expect(n1a, n1b,
        reason: 'S1: idle mounts differ (n1a=$n1a, n1b=$n1b) — the scene is '
            'not deterministic');

    final idleDiff = n1a - n0;
    // Numeric gate: recorded golden (idleDiff ≤ golden ± 1) — checked by the
    // CLI against benchmarks.json, not asserted here. Solutions with honest
    // idle wrappers (thin coach-mark target wrappers) legitimately show a
    // non-zero diff — that is their integration model, visible in the table.
    reportMetric('idle_zero', idleDiff, extra: {'n0': n0, 'n1': n1a});
  });
}
