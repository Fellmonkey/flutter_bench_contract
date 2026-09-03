// ContractCard (lib/card.dart) — the measured content of the contract
// scenarios (spec §2). These tests pin the contract surface that every
// S2–S4 driver must mount: the root key, the exact texts of both content
// states, the semantics label, the fixed card size, and the failure mode
// for an unknown state. Drivers and goldens depend on these staying put.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_bench_contract/flutter_bench_contract.dart';

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  test('content table covers exactly the two contract states', () {
    expect(kContractCardContent.keys.toSet(), {1, 2});
    for (final state in kContractCardContent.keys) {
      final (title, description) = kContractCardContent[state]!;
      expect(title, isNotEmpty);
      expect(description, isNotEmpty);
      expect(title, isNot(equals(description)));
    }
    expect(kContractCardContent[1], isNot(equals(kContractCardContent[2])));
  });

  testWidgets('state 1 mounts contract.card.1 with state-1 content',
      (tester) async {
    await tester.pumpWidget(_wrap(const ContractCard(state: 1)));
    expect(find.byKey(Key(contractCardKey(1))), findsOneWidget);
    expect(find.byKey(Key(contractCardKey(2))), findsNothing);
    final (title, description) = kContractCardContent[1]!;
    expect(find.text(title), findsOneWidget);
    expect(find.text(description), findsOneWidget);
  });

  testWidgets('state 2 mounts contract.card.2 with state-2 content',
      (tester) async {
    await tester.pumpWidget(_wrap(const ContractCard(state: 2)));
    expect(find.byKey(Key(contractCardKey(2))), findsOneWidget);
    expect(find.byKey(Key(contractCardKey(1))), findsNothing);
    final (title, description) = kContractCardContent[2]!;
    expect(find.text(title), findsOneWidget);
    expect(find.text(description), findsOneWidget);
  });

  testWidgets('card is announced with its label and content', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_wrap(const ContractCard(state: 1)));
    // getSemantics locates the semantics node covering the card and returns
    // the boundary it is announced under. With container: true the node
    // merges its children into one unit, so a reader hears the presence
    // label AND the content (spec §2) — assert both are announced.
    final label = tester.getSemantics(find.byKey(Key(contractCardKey(1)))).label;
    final (title, description) = kContractCardContent[1]!;
    expect(label, contains('Contract card'));
    expect(label, contains(title));
    expect(label, contains(description));
    handle.dispose();
  });

  testWidgets('card has the fixed contract size (260x88)', (tester) async {
    await tester.pumpWidget(_wrap(const ContractCard(state: 1)));
    expect(
      tester.getSize(find.byKey(Key(contractCardKey(1)))),
      const Size(ContractCard.width, ContractCard.height),
    );
    expect(ContractCard.width, 260);
    expect(ContractCard.height, 88);
  });

  testWidgets('unknown state throws ArgumentError at build', (tester) async {
    // Build errors are captured by the test framework, not thrown through
    // pumpWidget — takeException is the canonical way to assert them.
    await tester.pumpWidget(_wrap(const ContractCard(state: 3)));
    expect(tester.takeException(), isA<ArgumentError>());
  });
}
