// Self-tests of the golden store (goldens.dart): the benchmarks.json format
// (record layout, ref keying), golden lookups (load: ref preference +
// fallback) and the one-sided regression gate (check). Pure Dart, no device
// needed (flutter test, plain VM).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bench_contract/goldens.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late String storePath;
  late GoldenStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('goldens_test_');
    storePath = '${dir.path}/benchmarks.json';
    store = GoldenStore(path: storePath);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Map<String, dynamic> readDoc() =>
      (jsonDecode(File(storePath).readAsStringSync()) as Map)
          .cast<String, dynamic>();

  group('GoldenStore.record — benchmarks.json format', () {
    test('writes the store layout (format contract)', () {
      store.record({'frame_a': 5, 'heap_b': 1200}, ref: 'android');

      final metrics =
          (readDoc()['metrics'] as Map).cast<String, dynamic>();
      expect(metrics.keys.toSet(), {'frame_a', 'heap_b'});
      // unit mirrors the metric key; goldens are keyed per reference.
      expect(metrics['frame_a'], {
        'unit': 'frame_a',
        'goldens': {'android': 5},
      });
      expect(metrics['heap_b'], {
        'unit': 'heap_b',
        'goldens': {'android': 1200},
      });
    });

    test('appends new refs and metrics without clobbering earlier ones', () {
      store.record({'frame_a': 5}, ref: 'android');
      GoldenStore(path: storePath).record({'frame_a': 6, 'frame_b': 2},
          ref: 'any');

      final metrics =
          (readDoc()['metrics'] as Map).cast<String, dynamic>();
      expect((metrics['frame_a']!['goldens'] as Map), {
        'android': 5,
        'any': 6,
      });
      expect(metrics.containsKey('frame_b'), isTrue);
    });

    test('does not write the file when nothing was measured', () {
      store.record(const {}, ref: 'android');
      expect(File(storePath).existsSync(), isFalse);
    });
  });

  group('GoldenStore.load — recorded-golden lookups', () {
    test('prefers refs in order, then falls back to any recorded value', () {
      store.record({'frame_a': 5}, ref: 'android');
      store.record({'frame_a': 9}, ref: 'ci-fast');

      expect(store.load('frame_a'), 5); // default preferRefs: android, any
      expect(store.load('frame_a', preferRefs: ['ci-fast', 'android']), 9);
      // fallbackAny picks the first recorded value (insertion order: android).
      expect(store.load('frame_a', preferRefs: ['missing']), 5);
      expect(
        store.load('frame_a', preferRefs: ['missing'], fallbackAny: false),
        isNull,
      );
    });

    test('returns null for unknown metrics, missing files and corrupt files',
        () {
      expect(store.load('nope'), isNull); // no store file yet
      store.record({'frame_a': 5}, ref: 'android');
      expect(store.load('nope'), isNull);

      File(storePath).writeAsStringSync('{ not json');
      expect(store.load('frame_a'), isNull);
    });
  });

  group('GoldenStore.check — one-sided regression gate', () {
    setUp(() {
      store.record({
        'fast': 100,
        'slow': 100,
        'unrecorded': 1,
      }, ref: 'android');
    });

    test('passes better or equal values', () {
      expect(store.check({'fast': 90}, ref: 'android'), 0);
      // limit = ceil(100 * 0.3) = 30 → value == golden + limit still passes.
      expect(store.check({'slow': 130}, ref: 'android'), 0);
    });

    test('fails only when worse than the golden by more than the slack', () {
      expect(store.check({'slow': 131}, ref: 'android'), 1);
      expect(store.check({'fast': 131}, ref: 'android'), 1);
    });

    test('respects a custom slack', () {
      // slack 0.1 → limit 10: 115 > 110 fails, 110 passes.
      expect(store.check({'slow': 115}, ref: 'android', slack: 0.1), 1);
      expect(store.check({'slow': 110}, ref: 'android', slack: 0.1), 0);
    });

    test('a missing golden warns but does not fail', () {
      expect(store.check({'unrecorded': 1}, ref: 'android'), 0);
    });

    test('falls back to the any ref when the requested ref has no golden', () {
      store.record({'any_only': 100}, ref: 'any');
      expect(store.check({'any_only': 500}, ref: 'new-device'), 1);
      expect(store.check({'any_only': 90}, ref: 'new-device'), 0);
    });
  });
}
