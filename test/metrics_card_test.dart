// The generic published metrics card (lib/metrics_card.dart): the package
// owns the layout machinery and value formatting; the consumer passes only
// content (title/subtitle/rows/note/legend). Rendered by `contract card` as
// a landscape golden; these tests pin the content contract without fonts
// (flutter_test's Ahem font stands in — presence, not pixels).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_bench_contract/flutter_bench_contract.dart';

void main() {
  // hintful-like numbers: all seven publishable defs recorded.
  final values = <String, num>{
    'idle_zero': 4,
    'show_latency': 72,
    'update_latency': 3,
    'active_heap': 41632,
    'hide_retention': 1520,
    'native_size': 72669,
    'bundle_delta': 48690,
  };

  Future<void> pumpCard(WidgetTester tester, MetricsCard card) async {
    tester.view.physicalSize = const Size(2400, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(card);
    await tester.pump(const Duration(milliseconds: 300));
  }

  test('rows from the canonical defs + per-tile marketing subtitles', () {
    final rows = [
      for (final def in kPublishableMetricDefs)
        MetricsCardRow.fromDef(def,
            subtitle: def.key == 'idle_zero' ? 'zero means no idle tax' : null),
    ];
    expect(rows, hasLength(7));
    expect(rows.first.key, 'idle_zero');
    expect(rows.first.label, 'Idle tree diff (S1)');
    expect(rows.first.unit, 'elements');
    expect(rows.first.subtitle, 'zero means no idle tax');
    expect(rows.last.key, 'bundle_delta');
  });

  testWidgets('renders every tile value with its canonical formatting',
      (tester) async {
    await pumpCard(
      tester,
      MetricsCard(
        title: 'hintful benchmarks — contract',
        subtitle: 'profile build · Android x64 · S1–S7 contract scenarios',
        rows: [
          for (final def in kPublishableMetricDefs) MetricsCardRow.fromDef(def),
        ],
        values: values,
      ),
    );
    // Header copy.
    expect(find.text('hintful benchmarks — contract'), findsOneWidget);
    expect(find.text('lower is better'), findsOneWidget);
    // Every value is visible with the card's formatting (shared with the
    // table: KB for bytes, seconds above 1000 ms).
    expect(find.text('4'), findsOneWidget);
    expect(find.text('72 ms'), findsOneWidget);
    expect(find.text('3 ms'), findsOneWidget);
    expect(find.text('42 KB'), findsOneWidget);
    expect(find.text('2 KB'), findsOneWidget); // hide_retention 1520 B
    expect(find.text('73 KB'), findsOneWidget);
    expect(find.text('49 KB'), findsOneWidget);
  });

  testWidgets('note slot, legend and subtitles render when provided',
      (tester) async {
    await pumpCard(
      tester,
      MetricsCard(
        title: 't',
        subtitle: 's',
        rows: [
          MetricsCardRow.fromDef(metricDefOf('idle_zero')!,
              subtitle: 'zero means no idle tax'),
          MetricsCardRow.fromDef(metricDefOf('show_latency')!),
          MetricsCardRow.fromDef(metricDefOf('update_latency')!),
          MetricsCardRow.fromDef(metricDefOf('active_heap')!),
          MetricsCardRow.fromDef(metricDefOf('hide_retention')!),
        ],
        values: {'idle_zero': 4, 'show_latency': 72},
        note: 'Methodology: README.md.',
        legend: 'see the README for the head-to-head table',
      ),
    );
    expect(find.text('Methodology: README.md.'), findsOneWidget);
    expect(find.text('see the README for the head-to-head table'),
        findsOneWidget);
    expect(find.text('zero means no idle tax'), findsOneWidget);
  });

  testWidgets('the bar fill paints at a non-zero size (regression: a bare '
      'DecoratedBox with no child collapses to zero and the fill vanishes)',
      (tester) async {
    await pumpCard(
      tester,
      MetricsCard(
        title: 't',
        subtitle: 's',
        rows: [
          for (final def in kPublishableMetricDefs) MetricsCardRow.fromDef(def),
        ],
        values: values,
      ),
    );
    final fills = tester
        .widgetList<Container>(find.byWidgetPredicate((w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).gradient is LinearGradient))
        .toList();
    // One fill per tile bar (7 tiles).
    expect(fills, hasLength(7));
    for (final fill in fills) {
      final r = tester.getRect(find.byWidget(fill));
      expect(r.height, 24, reason: 'bar fill must paint the full bar height');
      expect(r.width, greaterThan(0),
          reason: 'bar fill must paint its fraction width');
    }
  });

  testWidgets('a missing value never fabricates a number (row not rendered)',
      (tester) async {
    await pumpCard(
      tester,
      MetricsCard(
        title: 't',
        subtitle: 's',
        rows: [MetricsCardRow.fromDef(metricDefOf('bundle_delta')!)],
        values: const {},
      ),
    );
    // The tile label is gone because the row has no value — the CLI only
    // sends rows with recorded values, so a blank tile cannot slip in.
    expect(find.text('Web startup bundle delta'), findsNothing);
  });
}
