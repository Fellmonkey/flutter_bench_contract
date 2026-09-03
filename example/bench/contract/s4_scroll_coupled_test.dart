// GENERATED from flutter_bench_contract (template v1) — do not edit by hand.
// Regenerate: dart run flutter_bench_contract:contract init --force
//
// S4 scroll_coupled (spec §5.5): content anchored to element B must ride
// with B under a programmatic scroll — correctness (two-sided assert) and
// the actual scroll cost as diagnostics. Solutions without an anchor
// (toasts/popovers) declare scrollCoupled: false → `unsupported` in the
// report (visible, never a failure, never a removal).
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_bench_contract/report.dart';
import 'package:flutter_bench_contract/scene.dart';

import '../drivers/demo_solution_driver.dart';

const double _kScrollDelta = -400; // B moves UP = offset grows by 400.
const double _kEpsilon = 1.0; // logical px (spec: ε = 1)

void main() {
  testWidgets('S4 scroll_coupled', (tester) async {
    final driver = DemoSolutionDriver();
    if (!driver.scrollCoupled) {
      // Unsupported is a visible report entry, not a failure and not a
      // removal (spec §5.5, §7.3).
      reportMetric('scroll_coupled', null,
          extra: {'status': 'unsupported', 'reason': 'no anchor to a target'});
      return;
    }

    final spec = SceneSpec();
    addTearDown(spec.dispose);
    await tester.pumpWidget(driver.buildScene(withLibrary: true, spec: spec));
    await tester.pumpAndSettle();

    await driver.show(1);
    var shown = false;
    for (var i = 0; i < 625; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (driver.currentContent(1).evaluate().isNotEmpty &&
          driver.isStable()) {
        shown = true;
        break;
      }
    }
    expect(shown, isTrue, reason: 'S4: show(1) never stabilized');

    final position = spec.listScroll.position;

    // Materialize the list extent: a children-based ListView is lazy, so
    // maxScrollExtent is ESTIMATED from the laid-out children only (a few
    // rows fit the viewport) and clamps scroll targets until the list has
    // reached its real end once. Converges in a few jumps; without it the
    // -400 scroll below would silently clamp and fail the B-delta assert.
    for (var i = 0; i < 20 && position.pixels < position.maxScrollExtent; i++) {
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
    }
    spec.listScroll.jumpTo(0);
    await tester.pumpAndSettle();

    // Scene sanity: the list must really be scrollable (else the scenario is
    // defective and fails loudly instead of measuring an empty scroll).
    expect(position.maxScrollExtent >= 400, isTrue,
        reason: 'S4: scene defect — maxScrollExtent='
            '${position.maxScrollExtent} < 400');

    // Measure relative to B itself, so the scene's own movement is the
    // reference: content follows ⇔ card delta == B delta (ε = 1 px).
    final bFinder = find.byKey(Key(sceneRowKey(kSceneBRow)));
    final cardFinder = driver.currentContent(1);

    final beforeB = tester.getRect(bFinder);
    final beforeCard = tester.getRect(cardFinder);

    await spec.listScroll.animateTo(
      position.pixels + _kScrollDelta.abs(),
      duration: const Duration(milliseconds: 100),
      curve: Curves.linear,
    );
    await tester.pumpAndSettle();

    final afterB = tester.getRect(bFinder);
    final afterCard = tester.getRect(cardFinder);

    // Assert the scroll really happened (scene moved by ≈ -400).
    final bDelta = afterB.topLeft.dy - beforeB.topLeft.dy;
    expect((bDelta - _kScrollDelta).abs() <= 1.0, isTrue,
        reason: 'S4: scene did not scroll — B moved $bDelta px, expected '
            '$_kScrollDelta (scroll defect)');

    // The contract assert (two-sided, cannot be disabled): content followed
    // B within ε. Snapshot-positioned content gives Δ≈0 → fails here.
    final cardDelta = afterCard.topLeft.dy - beforeCard.topLeft.dy;
    final error = (cardDelta - bDelta).abs();
    expect(error <= _kEpsilon, isTrue,
        reason: 'S4: card did not follow B — card moved $cardDelta px, B '
            'moved $bDelta px (error $error px > ε=$_kEpsilon)');

    reportMetric('scroll_coupled', null,
        extra: {'status': 'ok', 'b_delta_px': bDelta, 'card_delta_px': cardDelta});

    // Back-scroll (offset 0) — diagnostics frames are collected by the
    // device runner; here only correctness is asserted.
    await spec.listScroll.animateTo(0,
        duration: const Duration(milliseconds: 100),
        curve: Curves.linear);
    await tester.pumpAndSettle();
    await driver.hide();
  });
}
