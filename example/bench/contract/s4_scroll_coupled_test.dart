// GENERATED from flutter_bench_contract (template v1) — do not edit by hand.
// Regenerate: dart run flutter_bench_contract:contract init --force
//
// S4 scroll_coupled: content anchored to element B must ride
// with B under a programmatic scroll — correctness (two-sided assert) and
// the actual scroll cost as diagnostics. Solutions without an anchor
// (toasts/popovers) declare scrollCoupled: false → `unsupported` in the
// report (visible, never a failure, never a removal).
import 'dart:math' as math;

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
      // removal (a visible report entry).
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

    // Measure relative to B itself, so the scene's own movement is the
    // reference: content follows ⇔ card delta == B delta (ε = 1 px).
    final position = spec.listScroll.position;
    final bFinder = find.byKey(Key(sceneRowKey(kSceneBRow)));
    final cardFinder = driver.currentContent(1);

    final beforeB = tester.getRect(bFinder);
    final beforeCard = tester.getRect(cardFinder);

    // Scroll the scene by |_kScrollDelta| (B moves up). A children-based
    // ListView estimates maxScrollExtent from the laid-out children only and
    // RECLAIMS the estimate whenever the list returns near its top, so an
    // absolute jump target would clamp to ~one viewport and silently
    // under-scroll. Advance in small steps instead: each jump lays out the
    // newly revealed rows and grows the estimate, so a healthy scene reaches
    // the full delta in a few pumps — and a scene whose real extent is
    // shorter than the delta stalls at its bottom, which the B-delta assert
    // below reports as a scene defect.
    final targetOffset = position.pixels + _kScrollDelta.abs();
    while (position.pixels < targetOffset) {
      final before = position.pixels;
      final step = math.min(150.0, targetOffset - before);
      position.jumpTo(before + step);
      await tester.pump();
      if (position.pixels - before < 0.01) break; // clamped at the end
    }
    await tester.pumpAndSettle();

    final afterB = tester.getRect(bFinder);
    final afterCard = tester.getRect(cardFinder);

    // Assert the scroll really happened (B moved by ≈ -400). This doubles
    // as the scene-defect guard: a scene that cannot scroll this far fails
    // here loudly, instead of measuring an empty scroll.
    final bDelta = afterB.topLeft.dy - beforeB.topLeft.dy;
    expect((bDelta - _kScrollDelta).abs() <= 1.0, isTrue,
        reason: 'S4: scene defect — B moved $bDelta px, expected '
            '$_kScrollDelta (scroll did not go through)');

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
    spec.listScroll.jumpTo(0);
    await tester.pumpAndSettle();
    await driver.hide();
  });
}
