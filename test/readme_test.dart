// Published-results machinery: the canonical metric defs + formatters
// (lib/defs.dart) and the generic README-section renderer (lib/readme.dart)
// — the pure-Dart half of what hintful's tool/render_readme.dart did, now
// generic: rows from the defs, values from the store under each column's
// refs, prose from the manifest.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_bench_contract/flutter_bench_contract.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('bench_readme_test_'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows: lingering handles; test already passed.
    }
  });

  group('defs (canonical display metadata)', () {
    test('publishable set = device S1–S6 rows + host S7 size rows', () {
      expect(
        kPublishableMetricDefs.map((d) => d.key),
        [
          'idle_zero',
          'idle_resources',
          'show_latency',
          'update_latency',
          'active_heap',
          'hide_retention',
          'native_size',
          'bundle_delta',
        ],
      );
      // S1r records a number when idleClasses is declared → publishable.
      expect(metricDefOf('idle_resources'), isNotNull);
      // S4 records no number (two-sided in-scenario assert) → not a row.
      expect(metricDefOf('scroll_coupled'), isNull);
    });

    test('labels carry the scenario ids (published methodology copy)', () {
      expect(metricDefOf('idle_zero')!.label, 'Idle tree diff (S1)');
      expect(metricDefOf('show_latency')!.label, 'Show latency (S2)');
      expect(metricDefOf('bundle_delta')!.label,
          'Web startup bundle delta');
    });

    test('table values: compact B/ms/elements with n/a for null', () {
      expect(formatTableValue(41632, 'B'), '42 KB');
      expect(formatTableValue(48690, 'B'), '49 KB');
      expect(formatTableValue(72, 'ms'), '72 ms');
      expect(formatTableValue(4, 'elements'), '4');
      expect(formatTableValue(null, 'B'), 'n/a');
    });

    test('card values: seconds above 1000 ms, KB/MB for bytes', () {
      expect(formatCardValue(48690, 'B'), '49 KB');
      expect(formatCardValue(72, 'ms'), '72 ms');
      expect(formatCardValue(1520, 'ms'), '1.5 s');
      expect(formatCardValue(4, 'elements'), '4');
      expect(formatCardValue(null, 'B'), 'n/a');
    });
  });

  group('renderReadmeSection', () {
    GoldenStore storeWith(Map<String, num> values, {String ref = 'android'}) {
      final store = GoldenStore(path: '${tmp.path}/benchmarks.json');
      store.record(values, ref: ref);
      return store;
    }

    ReadmeContent content({List<ReadmeColumn>? columns, String? chartsUrl}) =>
        ReadmeContent(
          title: 'Performance',
          intro: 'One scene, three solutions: the contract scenarios S1–S6 '
              'on a profile emulator plus the host size builds (S7).',
          columns: columns ??
              const [
                ReadmeColumn(
                    label: 'hintful', refs: ['android', 'any']),
                ReadmeColumn(
                    label: 'showcaseview',
                    refs: ['android-scv'],
                    fallbackAny: false),
              ],
          footnote: '**n/a** = not applicable for this solution.',
          image: 'docs/hint_metrics.png',
          imageAlt: 'hintful benchmark metrics',
          stamp: '_Recorded {ts}. Regenerate: dispatch the workflow._',
          chartsUrl: chartsUrl,
        );

    test('rows carry both columns; a rival never inherits the host numbers',
        () {
      final store = GoldenStore(path: '${tmp.path}/benchmarks.json');
      store.record({
        'idle_zero': 4,
        'show_latency': 72,
        'active_heap': 41632,
      }, ref: 'android');
      store.record({'idle_zero': 25}, ref: 'android-scv');

      final section = renderReadmeSection(content(),
          store: store, now: DateTime.utc(2026, 9, 4, 12, 30));

      // Marker-wrapped, heading + intro on top.
      expect(section, startsWith(kReadmeStart));
      expect(section, endsWith(kReadmeEnd));
      expect(section, contains('## Performance'));
      expect(section, contains('One scene, three solutions'));

      // Table: canonical labels; hintful's numbers under android, the rival
      // column under android-scv (n/a where the rival has no golden).
      expect(section, contains('| Metric | hintful | showcaseview |'));
      expect(section, contains('| Idle tree diff (S1) | 4 | 25 |'));
      expect(section, contains('| Show latency (S2) | 72 ms | n/a |'));
      expect(section, contains('| Active-step heap (S5) | 42 KB | n/a |'));

      // Footnote, image and the stamped line ({ts} replaced, UTC).
      expect(section, contains('**n/a** = not applicable'));
      expect(section, contains('![hintful benchmark metrics](docs/hint_metrics.png)'));
      expect(section,
          contains('_Recorded 2026-09-04 12:30 UTC. Regenerate: dispatch '
              'the workflow._'));
    });

    test('chartsUrl renders a trend-history link only when declared', () {
      final store = storeWith({'idle_zero': 4});
      final withCharts = renderReadmeSection(
          content(chartsUrl: 'https://owner.github.io/repo/bench/'),
          store: store);
      expect(withCharts,
          contains('**Trend history:** '
              '[charts](https://owner.github.io/repo/bench/)'));
      expect(renderReadmeSection(content(), store: store),
          isNot(contains('Trend history')));
    });

    test('a metric no column recorded is not a row; format n/a never lies',
        () {
      final store = storeWith({'idle_zero': 4});
      final section = renderReadmeSection(content(), store: store);
      expect(section, isNot(contains('Show latency')));
      expect(section, isNot(contains('| Show latency (S2) |')));
    });

    test('rows appear in canonical def order (device then size)', () {
      final store = storeWith({
        'bundle_delta': 48690,
        'idle_zero': 4,
        'native_size': 72669,
      });
      final section = renderReadmeSection(content(), store: store);
      final idleAt = section.indexOf('Idle tree diff');
      final nativeAt = section.indexOf('Native AOT size');
      final bundleAt = section.indexOf('Web startup bundle delta');
      expect(idleAt, lessThan(nativeAt));
      expect(nativeAt, lessThan(bundleAt));
    });
  });

  group('replaceReadmeSection', () {
    test('replaces the block between the markers, keeping surrounding prose',
        () {
      const before = 'Intro text.\n\n$kReadmeStart\nold\n$kReadmeEnd\n'
          'Outro text.\n';
      final out = replaceReadmeSection(before, '$kReadmeStart\nnew\n$kReadmeEnd');
      expect(out, 'Intro text.\n\n$kReadmeStart\nnew\n$kReadmeEnd\nOutro text.\n');
    });

    test('appends when the markers are absent', () {
      const before = 'No section yet.\n';
      final out = replaceReadmeSection(before, '$kReadmeStart\nnew\n$kReadmeEnd');
      expect(out, contains('No section yet.'));
      expect(out, contains(kReadmeStart));
      expect(out.indexOf(kReadmeStart), greaterThan(before.length - 1));
    });
  });
}
