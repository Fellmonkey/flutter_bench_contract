// Self-test of the smart scenario bodies (lib/scenarios.dart): a fake
// zero-idle driver runs the S1 body through the same public entry the
// generated consumer bridges call (`runContractScenario`). The body's own
// in-test asserts (determinism of idle mounts, element-count procedure) run
// as part of this suite; the numeric gate against recorded goldens is the
// CLI's job (consumers run it on their own hardware).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_bench_contract/flutter_bench_contract.dart';

/// A driver whose solution adds nothing while idle and shows nothing at all
/// — S1 must measure a 0 element diff and stay deterministic across mounts.
class _ZeroIdleDriver implements LibraryDriver {
  @override
  String get name => 'fake';

  @override
  bool get scrollCoupled => false;

  @override
  Widget buildScene({required bool withLibrary, required SceneSpec spec}) =>
      buildContractScene(
        spec,
        withLibrary: withLibrary,
        wrapRow: (index, row) => row,
      );

  @override
  Future<void> show(int state) async {}

  @override
  Future<void> update(int state) async {}

  @override
  Future<void> hide() async {}

  @override
  bool isStable() => true;

  @override
  Finder currentContent(int state) =>
      find.byKey(Key(contractCardKey(state)), skipOffstage: false);
}

void main() {
  // Registers the S1 body as a test of this suite (a scenario registers a
  // testWidgets — it must run at the top level, like any test).
  runContractScenario('idle_zero', driver: _ZeroIdleDriver());

  test('unknown scenario id is rejected at registration', () {
    expect(
      () => runContractScenario('no_such_scenario', driver: _ZeroIdleDriver()),
      throwsArgumentError,
    );
  });
}
