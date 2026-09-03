// Self-tests of the report layer (report.dart): the HINTFUL_BENCH_JSON
// envelope — parsing sample lines out of a run report, reducing a metric's
// duplicate samples to the median, and emitting new samples. Pure Dart, no
// device needed (flutter test, plain VM).
import 'dart:io';

import 'package:flutter_bench_contract/report.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseSample', () {
    test('parses a bare envelope line', () {
      final sample = parseSample('HINTFUL_BENCH_JSON:{"metric":"m","value":5}');
      expect(sample, {'metric': 'm', 'value': 5});
    });

    test('finds the envelope inside a flutter-drive log prefix', () {
      final sample = parseSample(
          'I/flutter ( 1234): HINTFUL_BENCH_JSON:{"metric":"m","value":2}');
      expect(sample?['metric'], 'm');
      expect(sample?['value'], 2);
    });

    test('returns null when the line carries no envelope', () {
      expect(parseSample('some log noise between samples'), isNull);
    });

    test('keeps a null value (could-not-measure sample)', () {
      final sample =
          parseSample('HINTFUL_BENCH_JSON:{"metric":"m","value":null}');
      expect(sample?['metric'], 'm');
      expect(sample?['value'], isNull);
    });
  });

  group('medianOf', () {
    test('middle element of an odd list, unsorted input', () {
      expect(medianOf([3, 1, 2]), 2);
    });

    test('upper-middle element of an even list', () {
      expect(medianOf([4, 1, 3, 2]), 3);
    });

    test('works on non-integer values', () {
      expect(medianOf([2.5, 1.5, 2]), 2);
    });
  });

  group('ReportFile', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('report_test_'));
    tearDown(() => dir.deleteSync(recursive: true));

    File writeReport(String content) {
      final f = File('${dir.path}/report.jsonl');
      f.writeAsStringSync(content);
      return f;
    }

    test('reduces a metric\'s duplicate samples to its median', () {
      final f = writeReport([
        'a noise line without the envelope',
        'HINTFUL_BENCH_JSON:{"metric":"a","value":10}',
        'HINTFUL_BENCH_JSON:{"metric":"a","value":30}',
        'HINTFUL_BENCH_JSON:{"metric":"a","value":20}',
        'I/flutter ( 1): HINTFUL_BENCH_JSON:{"metric":"b","value":7}',
        'HINTFUL_BENCH_JSON:{"metric":"b","value":9}',
      ].join('\n'));
      expect(ReportFile(f.path).samples, {'a': 20, 'b': 9});
    });

    test('skips null-value samples (collector could not measure)', () {
      final f = writeReport(
          'HINTFUL_BENCH_JSON:{"metric":"a","value":null}\n'
          'HINTFUL_BENCH_JSON:{"metric":"b","value":1}\n');
      expect(ReportFile(f.path).samples, {'b': 1});
    });

    test('a report without samples reduces to nothing', () {
      final f = writeReport('no samples here\nat all\n');
      expect(ReportFile(f.path).samples, isEmpty);
    });

    test('a missing report file throws (broken invocation, like the CLI)',
        () {
      expect(
        () => ReportFile('${dir.path}/nope.jsonl').samples,
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  test('reportMetric emits one envelope sample on stdout', () {
    expectLater(
      () => reportMetric('foo', 7),
      prints(contains('HINTFUL_BENCH_JSON:{"metric":"foo","value":7}')),
    );
  });

  test('reportMetric carries extra fields and null values', () {
    expectLater(
      () => reportMetric('heap', null, extra: const {'ref': 'android'}),
      prints(contains(
          'HINTFUL_BENCH_JSON:{"metric":"heap","value":null,"ref":"android"}')),
    );
  });
}
