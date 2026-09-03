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
    // controller — verify it actually drives a ListView it is attached to.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            key: const Key(kSceneListKey),
            controller: spec.listScroll,
            children: [
              for (var i = 0; i < kSceneRowCount; i++)
                SizedBox(
                  key: Key(sceneRowKey(i)),
                  height: kSceneRowHeight,
                  child: Text('Row $i'),
                ),
              const SizedBox(height: kSceneScrollMargin),
            ],
          ),
        ),
      ),
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
}
