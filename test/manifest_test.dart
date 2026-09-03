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

  group('customScenarios (Р15)', () {
    test('parses entries with defaults (ref custom, runs 1)', () {
      final root = writeManifest('''
library: my_package
driver: bench/drivers/my_driver.dart
driverClass: MyDriver
scenarios: [idle_zero]
customScenarios:
  startup_to_show:
    target: bench/startup_to_show_test.dart
''');
      final m = Manifest.load(root);
      expect(m.customScenarios, hasLength(1));
      final s = m.customScenarios.single;
      expect(s.id, 'custom.startup_to_show');
      expect(s.name, 'startup_to_show');
      expect(s.target, 'bench/startup_to_show_test.dart');
      expect(s.ref, 'custom');
      expect(s.runs, 1);
    });

    test('round-trips ref and runs', () {
      final root = writeManifest('''
library: my_package
driver: bench/drivers/my_driver.dart
driverClass: MyDriver
scenarios: [idle_zero]
customScenarios:
  drag_reorder:
    target: bench/custom/drag_reorder_test.dart
    ref: android-custom
    runs: 3
''');
      final m = Manifest.load(root);
      final s = m.customScenarios.single;
      expect(s.id, 'custom.drag_reorder');
      expect(s.ref, 'android-custom');
      expect(s.runs, 3);
    });

    test('absent section is an empty list', () {
      final root = writeManifest('''
library: my_package
driver: bench/drivers/my_driver.dart
driverClass: MyDriver
scenarios: [idle_zero]
''');
      expect(Manifest.load(root).customScenarios, isEmpty);
    });

    test('key shadowing a contract scenario id is rejected', () {
      final root = writeManifest('''
library: my_package
driver: bench/drivers/my_driver.dart
driverClass: MyDriver
scenarios: [idle_zero]
customScenarios:
  idle_zero:
    target: bench/x_test.dart
''');
      expect(() => Manifest.load(root), throwsFormatException);
    });

    test('a custom.* id in the contract scenarios list is rejected', () {
      final root = writeManifest('''
library: my_package
driver: bench/drivers/my_driver.dart
driverClass: MyDriver
scenarios: [custom.startup_to_show]
''');
      expect(() => Manifest.load(root), throwsFormatException);
    });

    test('missing target is rejected', () {
      final root = writeManifest('''
library: my_package
driver: bench/drivers/my_driver.dart
driverClass: MyDriver
scenarios: [idle_zero]
customScenarios:
  startup_to_show:
    ref: android-custom
''');
      expect(() => Manifest.load(root), throwsFormatException);
    });

    test('runs < 1 is rejected', () {
      final root = writeManifest('''
library: my_package
driver: bench/drivers/my_driver.dart
driverClass: MyDriver
scenarios: [idle_zero]
customScenarios:
  startup_to_show:
    target: bench/x_test.dart
    runs: 0
''');
      expect(() => Manifest.load(root), throwsFormatException);
    });
  });

  group('card: (published metrics-card PNG content)', () {
    test('parses a full card section', () {
      final root = writeManifest('''
library: my_package
driver: bench/drivers/my_driver.dart
driverClass: MyDriver
scenarios: [idle_zero, size]
card:
  out: build/screenshots/metrics_card.png
  title: my_package benchmarks — contract
  subtitle: profile build · S1–S7 contract scenarios
  note: |-
    Methodology: README.md.
    Regenerate: bench-core workflow, record input.
  legend: my_package only — see README
  subtitles:
    idle_zero: scene with solution vs base
    bundle_delta: web startup bundle with − without
''');
      final c = Manifest.load(root).card!;
      expect(c.out, 'build/screenshots/metrics_card.png');
      expect(c.title, contains('benchmarks — contract'));
      expect(c.subtitle, startsWith('profile build'));
      expect(c.note, contains('Methodology: README.md.'));
      expect(c.legend, 'my_package only — see README');
      expect(c.subtitles['idle_zero'], contains('vs base'));
      expect(c.subtitles['bundle_delta'], contains('without'));
    });

    test('absent section stays null', () {
      final root = writeManifest('''
library: my_package
driver: bench/drivers/my_driver.dart
driverClass: MyDriver
scenarios: [idle_zero]
''');
      expect(Manifest.load(root).card, isNull);
    });

    test('missing out (PNG target) is rejected', () {
      final root = writeManifest('''
library: my_package
driver: bench/drivers/my_driver.dart
driverClass: MyDriver
scenarios: [idle_zero]
card:
  title: benchmarks
  subtitle: profile
''');
      expect(() => Manifest.load(root), throwsFormatException);
    });
  });

  group('readme: (published README section content)', () {
    test('parses a full readme section', () {
      final root = writeManifest('''
library: my_package
driver: bench/drivers/my_driver.dart
driverClass: MyDriver
scenarios: [idle_zero]
readme:
  target: ../README.md
  intro: One scene, three solutions.
  footnote: '**n/a** = not applicable.'
  image: docs/metrics.png
  imageAlt: benchmark metrics
  stamp: '_Recorded {ts} UTC. Regenerate: dispatch the workflow.'
  columns:
    my_package:
      refs: [android, any]
      fallbackAny: true
    showcaseview:
      refs: [android-scv]
      fallbackAny: false
''');
      final r = Manifest.load(root).readme!;
      expect(r.target, '../README.md');
      expect(r.title, 'Performance');
      expect(r.intro, 'One scene, three solutions.');
      expect(r.image, 'docs/metrics.png');
      expect(r.imageAlt, 'benchmark metrics');
      expect(r.stamp, contains('{ts}'));
      expect(r.columns, hasLength(2));
      expect(r.columns[0].label, 'my_package');
      expect(r.columns[0].refs, ['android', 'any']);
      expect(r.columns[0].fallbackAny, isTrue);
      expect(r.columns[1].label, 'showcaseview');
      expect(r.columns[1].refs, ['android-scv']);
      expect(r.columns[1].fallbackAny, isFalse);
    });

    test('column defaults: refs [android, any], fallbackAny true', () {
      final root = writeManifest('''
library: my_package
driver: bench/drivers/my_driver.dart
driverClass: MyDriver
scenarios: [idle_zero]
readme:
  target: ../README.md
  intro: One scene.
  footnote: none
  columns:
    my_package: {}
''');
      final r = Manifest.load(root).readme!;
      expect(r.columns.single.label, 'my_package');
      expect(r.columns.single.refs, ['android', 'any']);
      expect(r.columns.single.fallbackAny, isTrue);
    });

    test('absent section stays null', () {
      final root = writeManifest('''
library: my_package
driver: bench/drivers/my_driver.dart
driverClass: MyDriver
scenarios: [idle_zero]
''');
      expect(Manifest.load(root).readme, isNull);
    });

    test('missing target is rejected', () {
      final root = writeManifest('''
library: my_package
driver: bench/drivers/my_driver.dart
driverClass: MyDriver
scenarios: [idle_zero]
readme:
  intro: One scene.
  footnote: none
  columns:
    my_package: {}
''');
      expect(() => Manifest.load(root), throwsFormatException);
    });

    test('empty columns are rejected', () {
      final root = writeManifest('''
library: my_package
driver: bench/drivers/my_driver.dart
driverClass: MyDriver
scenarios: [idle_zero]
readme:
  target: ../README.md
  intro: One scene.
  footnote: none
  columns: {}
''');
      expect(() => Manifest.load(root), throwsFormatException);
    });
  });
}
