// demo_solution_driver.dart — example consumer of flutter_bench_contract:
// a toast/popover-like "solution" (bottom card, no anchor). Hand-written over
// the generated skeleton (bench_contract_specs §1–§3): the scene is built by
// the driver, the content is the package's ContractCard, the verbs are the
// solution's own calls. No external library is involved — the demo shows the
// shape of a driver for an unanchored overlay class (S4 → unsupported).
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_bench_contract/flutter_bench_contract.dart';

import '../contract/library_driver.dart';

/// Demo solution: a bottom card that toggles on show/update/hide. The whole
/// driver state is one `ValueNotifier<int?>` — idle adds no per-step
/// machinery (S1 sees only the always-on overlay host subtree).
class DemoSolutionDriver implements LibraryDriver {
  /// The visible content state (null = nothing shown).
  final ValueNotifier<int?> _content = ValueNotifier<int?>(null);

  @override
  String get name => 'demo_solution';

  /// Bottom-toast style: nothing is anchored to element B → S4 unsupported.
  @override
  bool get scrollCoupled => false;

  @override
  Future<void> show(int state) async => _content.value = state;

  @override
  Future<void> update(int state) async => _content.value = state;

  @override
  Future<void> hide() async => _content.value = null;

  /// Stable when the rebuild triggered by the last verb has been painted.
  @override
  bool isStable() => !SchedulerBinding.instance.hasScheduledFrame;

  /// The ContractCard root — keyed by the package's contract (spec §2), so
  /// the finder is the same regardless of how the card is mounted.
  @override
  Finder currentContent(int state) =>
      find.byKey(Key(contractCardKey(state)), skipOffstage: false);

  @override
  Widget buildScene({required bool withLibrary, required SceneSpec spec}) {
    final list = ListView(
      key: const Key(kSceneListKey),
      controller: spec.listScroll,
      children: [
        for (var i = 0; i < kSceneRowCount; i++)
          SizedBox(
            key: Key(sceneRowKey(i)),
            height: kSceneRowHeight,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Row $i'),
            ),
          ),
        const SizedBox(height: kSceneScrollMargin),
      ],
    );

    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Contract scene')),
        body: withLibrary
            ? Stack(
                children: [
                  list,
                  // The solution's always-on host: idle renders nothing, an
                  // active state renders the measured ContractCard.
                  ValueListenableBuilder<int?>(
                    valueListenable: _content,
                    builder: (context, state, _) {
                      if (state == null) return const SizedBox.shrink();
                      return Positioned(
                        left: 0,
                        right: 0,
                        bottom: 24,
                        child: Center(
                          child: ContractCard(state: state),
                        ),
                      );
                    },
                  ),
                ],
              )
            : list,
        floatingActionButton: FloatingActionButton(
          key: const Key(kSceneAKey),
          onPressed: () => spec.aTaps.value++,
          child: const Icon(Icons.add),
        ),
      ),
    );
  }
}
