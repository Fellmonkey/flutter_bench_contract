// Scene contract (lib/scene.dart) — the neutral scene geometry/keys shared
// by every scenario (spec §1). The scenario files and the drivers find A, B
// and the list by these constants, so the tests pin them down; SceneSpec
// additionally carries the per-mount handles the scenarios own.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_bench_contract/flutter_bench_contract.dart';

void main() {
  test('geometry guarantees a scrollable scene', () {
    expect(kSceneRowCount, 12);
    expect(kSceneBRow, lessThan(kSceneRowCount));
    expect(kSceneRowHeight, greaterThan(0));
    // Spec §1: scroll margin >= 1000 px on any target screen. Content extent
    // (12 rows + margin) must exceed that even if the viewport were huge.
    final contentExtent = kSceneRowCount * kSceneRowHeight + kSceneScrollMargin;
    expect(kSceneScrollMargin, greaterThanOrEqualTo(1000));
    expect(contentExtent, greaterThan(1000));
  });

  test('keys are the fixed finder contract', () {
    expect(kSceneListKey, 'scene.list');
    expect(kSceneAKey, 'scene.a');
    expect(sceneRowKey(kSceneBRow), 'scene.row.5');
    expect(sceneRowKey(0), 'scene.row.0');
    expect(sceneRowKey(11), 'scene.row.11');
  });

  test('SceneSpec starts with an unattached list scroll and zero taps', () {
    final spec = SceneSpec();
    addTearDown(spec.dispose);
    expect(spec.listScroll.hasClients, isFalse);
    expect(spec.aTaps.value, 0);
    expect(spec.listScroll.initialScrollOffset, 0);
  });

  testWidgets('aTaps notifies listeners on tap-count increments',
      (tester) async {
    final spec = SceneSpec();
    addTearDown(spec.dispose);
    var seen = 0;
    spec.aTaps.addListener(() => seen++);
    spec.aTaps.value++;
    expect(spec.aTaps.value, 1);
    expect(seen, 1);
  });

  testWidgets('listScroll attached to a ListView is usable by scenarios',
      (tester) async {
    final spec = SceneSpec();
    addTearDown(spec.dispose);
    // The S4 scenario scrolls the scene programmatically through this
    // controller — verify it actually drives the neutral scene's ListView.
    await tester.pumpWidget(
      buildContractScene(spec, withLibrary: false, wrapRow: (_, row) => row),
    );
    expect(spec.listScroll.hasClients, isTrue);
    final position = spec.listScroll.position;
    // A children-based ListView is lazy: maxScrollExtent is ESTIMATED from
    // the laid-out children only (a few rows fit the viewport), so the real
    // extent is unknowable until the list is scrolled to its end. The S4
    // template materializes it the same way before trusting the value.
    for (var i = 0; i < 20 && position.pixels < position.maxScrollExtent; i++) {
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
    }
    expect(position.maxScrollExtent, greaterThan(1000));
    position.jumpTo(400);
    await tester.pump();
    expect(position.pixels, 400);
  });

  testWidgets('neutral scene exposes A (tappable FAB), the list and the rows',
      (tester) async {
    final spec = SceneSpec();
    addTearDown(spec.dispose);
    await tester.pumpWidget(
      buildContractScene(spec, withLibrary: false, wrapRow: (_, row) => row),
    );
    // Element A is tappable and increments the spec's counter (S6 asserts
    // the scene is interactive again after hide()).
    expect(find.byKey(const Key(kSceneAKey)), findsOneWidget);
    await tester.tap(find.byKey(const Key(kSceneAKey)));
    await tester.pump();
    expect(spec.aTaps.value, 1);
    // The list and element B are findable by the fixed keys.
    expect(find.byKey(const Key(kSceneListKey)), findsOneWidget);
    expect(find.byKey(Key(sceneRowKey(kSceneBRow))), findsOneWidget);
    // wrapRow sees only valid row indices (lazy list: not every row is
    // built on first layout, but every built row is in range and carries
    // its contract key).
    final seen = <int>[];
    await tester.pumpWidget(
      buildContractScene(spec,
          withLibrary: false, wrapRow: (index, row) {
        seen.add(index);
        return KeyedSubtree(key: Key('seen.$index'), child: row);
      }),
    );
    expect(seen, isNotEmpty);
    expect(seen.toSet().containsAll([0, kSceneBRow]), isTrue,
        reason: 'the top rows and element B are laid out first');
    // A children-based ListView is lazy: rows outside the (shrinking)
    // layout estimate are built then discarded, so only the index range is
    // contractual — every row the builder saw is a valid scene row.
    for (final index in seen) {
      expect(index, inInclusiveRange(0, kSceneRowCount - 1));
    }
    // Element B is findable by its contract key.
    expect(find.byKey(Key(sceneRowKey(kSceneBRow))), findsOneWidget);
  });

  testWidgets('app-level wiring (navigatorObservers/appBuilder) flows to '
      'the MaterialApp', (tester) async {
    // Phase-3 hook: dialog/toast solutions (flutter_smart_dialog etc.) mount
    // their overlay host through MaterialApp's navigatorObservers/builder.
    // The driver supplies them; the scene passes them through verbatim.
    final spec = SceneSpec();
    addTearDown(spec.dispose);
    final observer = _RecordingObserver();
    await tester.pumpWidget(
      buildContractScene(
        spec,
        withLibrary: true,
        wrapRow: (index, row) => row,
        navigatorObservers: [observer],
        appBuilder: (context, child) =>
            ColoredBox(color: const Color(0xFF00FF00), child: child!),
      ),
    );
    await tester.pumpAndSettle();
    // The builder wrapped the navigator with our host widget (matched by
    // color — Flutter's Navigator itself uses a transparent ColoredBox).
    expect(
      find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == const Color(0xFF00FF00)),
      findsOneWidget,
    );
    // The observer was attached to the navigator and sees route pushes.
    expect(observer.pushed, isNotEmpty);
  });

  testWidgets('app-level wiring is absent when not supplied (base scene)',
      (tester) async {
    final spec = SceneSpec();
    addTearDown(spec.dispose);
    await tester.pumpWidget(buildContractScene(
      spec,
      withLibrary: false,
      wrapRow: (index, row) => row,
    ));
    await tester.pumpAndSettle();
    // No appBuilder supplied → no green host (the internal transparent
    // ColoredBox of the Navigator is Flutter's, not the solution's).
    expect(
      find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == const Color(0xFF00FF00)),
      findsNothing,
    );
  });
}

/// Records the pushes it observes (route change = the observer is attached
/// to the navigator).
class _RecordingObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}
