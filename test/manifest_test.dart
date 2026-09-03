// Consumer manifest (lib/manifest.dart) — bench_contract.yaml loading and
// the scenario constants the init/run CLI builds on. Tests cover the parse
// contract (fields + defaults + failure modes) and the fixed scenario ids /
// run-count methodology the CLI schedules by.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_bench_contract/flutter_bench_contract.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bench_contract_test_');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows: file handles may linger briefly; the test already passed.
    }
  });

  String writeManifest(String body) {
    final file = File('${tmp.path}/$kManifestFileName');
    file.writeAsStringSync(body);
    return tmp.path;
  }

  group('kContractScenarioIds / defaults', () {
    test('scenario id set matches the frozen spec (S1–S1r–S7)', () {
      expect(
        kContractScenarioIds,
        {
          'idle_zero',
          'idle_resources',
          'show_latency',
          'update_latency',
          'scroll_coupled',
          'active_heap',
          'hide_retention',
          'size',
        },
      );
    });

    test('host-runnable defaults are a subset of the contract ids', () {
      expect(kDefaultScenarios.toSet().difference(kContractScenarioIds),
          isEmpty);
      // Device-free runnable set: no VM-service heap and no device build.
      expect(kDefaultScenarios, isNot(contains('active_heap')));
      expect(kDefaultScenarios, isNot(contains('size')));
    });

    test('runsForScenario: wall-latency repeats 3x, others single', () {
      expect(runsForScenario('show_latency'), 3);
      expect(runsForScenario('update_latency'), 1);
      expect(runsForScenario('idle_zero'), 1);
      expect(runsForScenario('scroll_coupled'), 1);
    });
  });

  group('Manifest.load', () {
    test('throws FileSystemException with guidance when missing', () {
      final empty = Directory.systemTemp.createTempSync('bench_contract_');
      try {
        expect(
          () => Manifest.load(empty.path),
          throwsA(isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            contains('contract init'),
          )),
        );
      } finally {
        empty.deleteSync(recursive: true);
      }
    });

    test('throws FormatException on unparseable yaml', () {
      final root = writeManifest('library: [unclosed');
      expect(() => Manifest.load(root), throwsFormatException);
    });

    test('throws FormatException when the document is not a map', () {
      final root = writeManifest('- just\n- a\n- list');
      expect(() => Manifest.load(root), throwsFormatException);
    });

    test('minimal manifest applies defaults', () {
      final root = writeManifest('''
library: my_package
driver: bench/drivers/my_driver.dart
driverClass: MyDriver
scenarios: [idle_zero, show_latency]
''');
      final m = Manifest.load(root);
      expect(m.library, 'my_package');
      expect(m.driver, 'bench/drivers/my_driver.dart');
      expect(m.driverClass, 'MyDriver');
      expect(m.scenarios, ['idle_zero', 'show_latency']);
      expect(m.contractDir, 'bench/contract');
      expect(m.idleClasses, isEmpty);
      expect(m.template, kTemplateVersion);
    });

    test('full manifest round-trips every field', () {
      final root = writeManifest('''
library: my_package
driver: bench/drivers/my_driver.dart
driverClass: MyDriver
contractDir: bench/generated
scenarios: [idle_zero, idle_resources, show_latency, update_latency,
            scroll_coupled, active_heap, hide_retention, size]
idleClasses: [MyController, MyRegistry]
template: 1
''');
      final m = Manifest.load(root);
      expect(m.contractDir, 'bench/generated');
      expect(m.idleClasses, ['MyController', 'MyRegistry']);
      expect(m.scenarios, hasLength(8));
    });

    test('size section parses into a SizeConfig', () {
      final root = writeManifest('''
library: my_package
driver: bench/drivers/my_driver.dart
driverClass: MyDriver
scenarios: [size]
size:
  native:
    package: my_package
    entry: lib/main.dart
    arch: x64
  web:
    with: lib/main.dart
    without: lib/main_baseline.dart
''');
      final m = Manifest.load(root);
      expect(m.size, isNotNull);
      expect(m.size!.hasNative, isTrue);
      expect(m.size!.hasWeb, isTrue);
      expect(m.size!.nativePackage, 'my_package');
      expect(m.size!.webWithout, 'lib/main_baseline.dart');
    });

    test('no size section stays null', () {
      final root = writeManifest('''
library: my_package
driver: bench/drivers/my_driver.dart
driverClass: MyDriver
scenarios: [idle_zero]
''');
      expect(Manifest.load(root).size, isNull);
    });

    test('non-int template falls back to the current version', () {
      final root = writeManifest('''
library: my_package
driver: bench/drivers/my_driver.dart
driverClass: MyDriver
scenarios: [idle_zero]
template: latest
''');
      expect(Manifest.load(root).template, kTemplateVersion);
    });
  });
}
