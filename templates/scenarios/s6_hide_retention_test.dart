// GENERATED from flutter_bench_contract (template v1) — do not edit by hand.
// Regenerate: dart run flutter_bench_contract:contract init --force
//
// S6 hide_retention (spec §5.7): after hide() the solution (a) does not grow
// the heap per show/hide cycle, (b) returns the tree exactly to the idle
// snapshot (no hidden mechanics left, precise equality), and (c) leaves the
// scene interactive — a tap on element A after hide() must land (no hit-test
// residue of the overlay). Heap drift degrades to null under a plain
// `flutter test` host run; asserts (b) and (c) always run.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_bench_contract/collectors.dart';
import 'package:flutter_bench_contract/report.dart';
import 'package:flutter_bench_contract/scene.dart';

{{apiImport}}
{{driverImport}}

const int _kTimeoutFrames = 625;
const int _kWarmups = 3; // methodology
const int _kMeasuredCycles = 3;

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
  fail('S6: show($state) did not become visible and stable');
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
  fail('S6: content $state still present after hide()');
}

/// Canonical snapshot of the live tree: sorted list of "runtimeType#key" of
/// every live element (offstage included — hidden leftovers must show up).
List<String> _fingerprint(WidgetTester tester) {
  final root = tester.binding.rootElement!;
  final out = <String>[];
  void walk(Element e) {
    out.add('${e.widget.runtimeType}#${e.widget.key ?? ''}');
    e.visitChildren(walk);
  }

  walk(root);
  out.sort();
  return out;
}

void main() {
  testWidgets('S6 hide_retention', (tester) async {
    final spec = SceneSpec();
    addTearDown(spec.dispose);
    final driver = {{driverNew}};

    await tester.pumpWidget(driver.buildScene(withLibrary: true, spec: spec));
    await tester.pumpAndSettle();

    // (b) reference: the idle snapshot before the first show.
    final idleSnapshot = _fingerprint(tester);

    // Warm-up (methodology).
    for (var i = 0; i < _kWarmups; i++) {
      await _showStable(tester, driver, 1);
      await _hideGone(tester, driver, 1);
    }
    await tester.pumpAndSettle();

    // runAsync: Service.getInfo() is an engine call that never completes in
    // the FakeAsync zone of a plain `flutter test` run (it would hang the
    // host); real-async contexts (device, integration binding) are unaffected.
    final heap = await tester.runAsync(VmServiceHeap.connect);
    final base = heap == null ? null : await heap.usedBytesMedian();

    // Measured cycles: show → hide → GC → heap sample; drift per cycle
    // against the post-warm-up base.
    final drifts = <int>[];
    for (var i = 0; i < _kMeasuredCycles; i++) {
      await _showStable(tester, driver, 1);
      await _hideGone(tester, driver, 1);
      await tester.pumpAndSettle();
      final bytes = heap == null ? null : await heap.usedBytes();
      if (base != null && bytes != null) {
        drifts.add(bytes - base);
      }
    }

    // (b) after the last hide() the tree is exactly the idle snapshot.
    final afterSnapshot = _fingerprint(tester);
    expect(afterSnapshot, equals(idleSnapshot),
        reason: 'S6: tree after hide() differs from the idle snapshot — '
            'traces of the shown mechanics are still mounted');

    // (c) the scene is interactive: a tap on element A lands.
    final tapsBefore = spec.aTaps.value;
    await tester.tap(find.byKey(Key(kSceneAKey)));
    await tester.pump();
    expect(spec.aTaps.value, tapsBefore + 1,
        reason: 'S6: tap on A after hide() did not land — an overlay still '
            'eats pointer input (hit-test residue)');

    final driftAvg = drifts.isEmpty
        ? null
        : (drifts.reduce((a, b) => a + b) / drifts.length).round();
    if (driftAvg == null) {
      // ignore: avoid_print
      print('S6: no VM service (run with flutter drive --no-dds --profile) '
          '— heap drift not measured; tree/tap asserts ran');
    }
    reportMetric('hide_retention', driftAvg,
        extra: driftAvg == null
            ? const {'status': 'degraded'}
            : {'drifts_bytes': drifts});

    if (heap != null) await heap.dispose();
  });
}
