// The bench-contract CLI: scaffolding a consumer (init), running the
// declared scenarios against the golden store (run — check or record; the
// S7 host size builds are a scenario like the rest and run inside `run`)
// and the published-results machinery (card: the metrics-card PNG; readme:
// the root-README section).
//
//   init   — generate the consumer contract files (per-scenario bridges —
//            the smart bodies live in lib/scenarios.dart — the flutter-drive
//            test driver, and a driver skeleton when missing) and write
//            bench_contract.yaml.
//   run    — run the manifest's declared scenarios and check/record the
//            samples against the recorded goldens. S1–S6 execute as flutter
//            drive --profile on a device (or flutter test on the host when
//            no --device is given) into build/contract_*.jsonl; the S7 size
//            legs are host release builds run once per manifest (--legs
//            native|web|both). Custom scenarios run under their own refs.
//   card   — render the manifest `card:` metrics-card PNG from the recorded
//            goldens (fonts ensured, flutter-test golden render, copy to
//            the configured output path).
//   readme — render the manifest `readme:` section into the consumer's
//            README between the bench markers.
//   verify — generated-file/manifest consistency (template version, driver
//            file, scenario bridges).
//
// Usage (cwd: the consumer root, or --dir <root>):
//   dart run flutter_bench_contract:contract init [--force] [--scenarios a,b]
//   dart run flutter_bench_contract:contract run [--device <id>]
//       [--mode check|record] [--ref android] [--slack 0.3] [--scenarios ...]
//       [--legs native|web|both]
//   dart run flutter_bench_contract:contract card
//   dart run flutter_bench_contract:contract readme
//   dart run flutter_bench_contract:contract verify
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bench_contract/charts.dart';
import 'package:flutter_bench_contract/defs.dart';
import 'package:flutter_bench_contract/goldens.dart';
import 'package:flutter_bench_contract/manifest.dart';
import 'package:flutter_bench_contract/readme.dart';
import 'package:flutter_bench_contract/report.dart';
import 'package:flutter_bench_contract/size.dart';

// ── Path helpers ───────────────────────────────────────────────────────────

/// Relative POSIX import path from [fromDir] to [toFile] (both relative to
/// the consumer root, e.g. from 'bench/contract' to 'bench/drivers/x.dart').
String relativeImport(String fromDir, String toFile) {
  final fromParts = fromDir.split('/');
  final toParts = toFile.split('/');
  var i = 0;
  while (i < fromParts.length &&
      i < toParts.length &&
      fromParts[i] == toParts[i]) {
    i++;
  }
  final ups = List.filled(fromParts.length - i, '..');
  return [...ups, ...toParts.sublist(i)].join('/');
}

// ── Bridge rendering ───────────────────────────────────────────────────────

/// Scenario id → generated bridge file (under the consumer's contract dir).
/// Each bridge runs its scenario in its own `flutter test` process (fresh
/// app/heap per scenario); the smart bodies live in lib/scenarios.dart.
const Map<String, String> _kScenarioTemplates = {
  'idle_zero': 's1_idle_zero_test.dart',
  'idle_resources': 's1r_idle_resources_test.dart',
  'show_latency': 's2_show_latency_test.dart',
  'update_latency': 's3_update_latency_test.dart',
  'scroll_coupled': 's4_scroll_coupled_test.dart',
  'active_heap': 's5_active_heap_test.dart',
  'hide_retention': 's6_hide_retention_test.dart',
};

final RegExp _kDriverClass = RegExp(
  r'class\s+(\w+Driver)\b.*?implements\s+LibraryDriver',
  dotAll: true,
);

/// Best-effort driver class name from a driver file, or null.
String? driverClassOf(File driverFile) {
  if (!driverFile.existsSync()) return null;
  final m = _kDriverClass.firstMatch(driverFile.readAsStringSync());
  return m?.group(1);
}

/// Dart list-literal rendering of the manifest's `idleClasses:` (S1r):
/// `['MyController', 'MyRegistry']`, single quotes escaped.
String idleClassesLiteral(List<String> idleClasses) =>
    '[${idleClasses.map((c) => "'${c.replaceAll("'", r"\'")}'").join(', ')}]';

/// Default footer note (absent `card.note:`): points at the package README.
const String _kCardDefaultNote =
    'Methodology: flutter_bench_contract — see the package README '
    '(s1–s7, medians, one-sided gate, anti-tuning).';

/// The dumb-bridge source for one scenario: registers its smart body (in
/// the package's lib/scenarios.dart) with the consumer's driver instance.
String _bridgeSource({
  required String id,
  required String driverImport,
  required String driverNew,
  required List<String> idleClasses,
}) =>
    '''
// GENERATED from flutter_bench_contract (scenario bridge) — do not edit by
// hand. Regenerate: dart run flutter_bench_contract:contract init --force
//
// Dumb bridge: the $id smart body lives in the package (lib/scenarios.dart);
// this file only wires the consumer's driver into its own test process.
import 'package:flutter_bench_contract/scenarios.dart';

$driverImport

void main() {
  runContractScenario(
    '$id',
    driver: $driverNew,
    idleClasses: ${idleClassesLiteral(idleClasses)},
  );
}
''';

// ── init ───────────────────────────────────────────────────────────────────

int cmdInit(List<String> args) {
  var root = '.';
  var force = false;
  List<String>? scenarios;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--dir':
        root = args[++i];
      case '--force':
        force = true;
      case '--scenarios':
        scenarios = args[++i].split(',');
    }
  }
  // Multi-library consumer (a manifest with `libraries:`): render one
  // scenario directory per solution; the manifest is user-authored and is
  // never rewritten here.
  final manifestFile = File('$root/$kManifestFileName');
  Manifest? existingManifest;
  if (manifestFile.existsSync()) {
    existingManifest = Manifest.load(root);
  }
  if (existingManifest != null && existingManifest.libraries.isNotEmpty) {
    return _cmdInitMultiLibrary(root, force, scenarios, existingManifest);
  }

  // Driver identity: an existing bench_contract.yaml is the source of truth
  // (the consumer names the driver file and class freely — init only derives
  // defaults on the first scaffold). --force re-renders the GENERATED files
  // but never overrides the manifest's driver declaration or scenario list.
  var library = existingManifest?.library ?? '';
  var driverRel = existingManifest?.driver ?? '';
  String? driverClass = existingManifest?.driverClass;
  if (existingManifest == null) {
    // Library name: the enclosing pub package's name, else the folder name.
    library = File(root).uri.pathSegments.isNotEmpty
        ? File(root).path.split(Platform.pathSeparator).last
        : 'bench';
    final pubspec = File('$root/pubspec.yaml');
    if (pubspec.existsSync()) {
      for (final line in pubspec.readAsLinesSync()) {
        if (line.startsWith('name:')) {
          library = line.substring(5).trim();
          break;
        }
      }
    }
    driverRel = 'bench/drivers/${library}_driver.dart';
  }

  const contractDir = 'bench/contract';
  Directory('$root/$contractDir').createSync(recursive: true);

  // Driver file (skeleton when missing): a manifest-declared driver that is
  // missing is scaffolded with the manifest's class name; a driver whose
  // file declares no LibraryDriver class is a hard failure.
  final driverFile = File('$root/$driverRel');
  String? declaredClass = driverClassOf(driverFile);
  if (!driverFile.existsSync()) {
    final skeletonClass = driverClass ?? '${_pascal(library)}Driver';
    driverFile.parent.createSync(recursive: true);
    driverFile.writeAsStringSync(_driverSkeleton(library, skeletonClass));
    stdout.writeln('wrote $driverRel (skeleton — implement show/update/hide/'
        'isStable; the LibraryDriver contract comes from the package)');
    declaredClass = skeletonClass;
  }
  driverClass ??= declaredClass;
  if (driverClass == null) {
    stderr.writeln('FAIL: $driverRel exists but does not declare a class '
        'implementing LibraryDriver — cannot render the scenario files');
    return 1;
  }

  // Scenario bridges: an existing manifest's declared set is preserved
  // unless --scenarios overrides it (otherwise --force would silently drop
  // scenarios the consumer added). S7 has no bridge — it is the host size
  // builds (`size:` section), executed by `contract run` with the other
  // scenarios.
  final wanted = scenarios ?? existingManifest?.scenarios ?? kDefaultScenarios;
  final declared = <String>[];
  for (final id in wanted) {
    final bridgeName = _kScenarioTemplates[id];
    if (bridgeName == null) {
      if (id == 'size') {
        stdout.writeln('  size: host builds — declare a `size:` section '
            '(runs with `contract run`, --legs native|web|both)');
        declared.add(id);
      } else {
        stdout.writeln('  unknown scenario "$id" — skipped');
      }
      continue;
    }
    final target = File('$root/$contractDir/$bridgeName');
    if (!target.existsSync() || force) {
      target.writeAsStringSync(_bridgeSource(
        id: id,
        driverImport:
            "import '${relativeImport(contractDir, driverRel)}';",
        driverNew: '$driverClass()',
        idleClasses: existingManifest?.idleClasses ?? const [],
      ));
      stdout.writeln('wrote $contractDir/$bridgeName');
    }
    declared.add(id);
  }

  // flutter-drive test driver (required by device runs — the CLI passes
  // --driver=test_driver/integration_test.dart).
  final driveDir = Directory('$root/test_driver');
  final driveFile = File('${driveDir.path}/integration_test.dart');
  if (!driveFile.existsSync() || force) {
    driveDir.createSync(recursive: true);
    driveFile.writeAsStringSync('''
import 'package:integration_test/integration_test_driver.dart';

/// Driver for `flutter drive --profile` benchmark runs.
Future<void> main() => integrationDriver();
''');
    stdout.writeln('wrote test_driver/integration_test.dart');
  }

  // Manifest: generated once, owned by the consumer afterwards. --force
  // re-renders the GENERATED files but never rewrites an existing manifest
  // (it carries consumer-authored config: size:, idleClasses:,
  // customScenarios:, rivals: — init has no model to round-trip them).
  if (!manifestFile.existsSync()) {
    manifestFile.writeAsStringSync('''
# bench_contract.yaml — generated by flutter_bench_contract (template v$kTemplateVersion).
# The consumer picks SCENARIOS, never metric definitions or protocol values.
library: $library
driver: $driverRel
driverClass: $driverClass
contractDir: $contractDir
scenarios: [${declared.join(', ')}]
# idleClasses: [MyController, MyRegistry]   # for idle_resources (S1r)
# rivals:
#   showcaseview:
#     driver: bench/drivers/scv_driver.dart
#     driverClass: ScvDriver
#
# S7 size (host release builds, no device; runs inside `contract run`):
#   size:
#     native:                       # one apk --analyze-size build
#       package: <pub-package>      # subtree summed in the code-size tree
#       # entry: lib/main.dart      # app that imports the solution (default)
#       # arch: x64                 # android ABI (default)
#     web:                          # two web builds diffed on main.dart.js
#       # with: lib/main.dart       # structurally identical WITH the solution
#       without: lib/main_baseline.dart
#
# Custom scenarios (consumer-owned): metric id custom.<name>, OWN
# golden ref, excluded from rivals comparison and public tables. The test
# file reports reportMetric('custom.<name>', value); run/record/check —
# the package machinery (`contract run`).
#   customScenarios:
#     startup_to_show:
#       target: bench/startup_to_show_test.dart
#       ref: android-custom
#       # runs: 1
#
# Published results (marketing copy is yours; machinery is the package's):
#   card:                         # `contract card` renders the metrics-card
#     out: build/metrics_card.png #   PNG from the recorded goldens
#     title: <library> benchmarks — contract
#     subtitle: profile build · S1–S7 contract scenarios
#     # note: Methodology ...        # footer left; absent → package default
#     # legend: ...                  # footer right; absent → derived from
#     #                               #   the manifest (head-to-head vs not)
#     # subtitles: {metricKey: line} # per-tile marketing line
#   readme:                       # `contract readme` renders the README
#     target: ../README.md        #   section between the bench markers
#     intro: One scene, one solution: ...
#     columns:                    # table columns = solution → store refs
#       <library>: {refs: [android, any]}
#     footnote: '**n/a** = ...'
#     # image: docs/metrics.png / imageAlt: / stamp: '_Recorded {ts}. ...'
''');
    stdout.writeln('wrote $kManifestFileName (template v$kTemplateVersion)');
  } else {
    stdout.writeln('$kManifestFileName exists — kept (--force regenerates the '
        'scenario files, never the manifest)');
  }
  _syncManifestTemplate(root);
  stdout.writeln('init done: library=$library, driverClass=$driverClass, '
      'scenarios=[${declared.join(', ')}]');
  return 0;
}

/// Keeps the manifest's `template:` key at [kTemplateVersion]: rewrites a
/// stale value or inserts the key when missing. Only that one line is
/// touched — consumer-authored keys and comments are never rewritten. This
/// is what makes `contract verify` able to detect generated files that
/// predate a template change (init --force is the documented fix).
void _syncManifestTemplate(String root) {
  final file = File('$root/$kManifestFileName');
  if (!file.existsSync()) return;
  final lines = file.readAsLinesSync();
  final out = <String>[];
  var sawKey = false;
  for (final line in lines) {
    final m = RegExp(r'^template:\s*(\d+)\s*$').firstMatch(line);
    if (m != null) {
      sawKey = true;
      if (m.group(1) != '$kTemplateVersion') out.add('template: $kTemplateVersion');
      continue;
    }
    out.add(line);
  }
  if (sawKey) {
    if (out.join('\n') != lines.join('\n')) {
      file.writeAsStringSync('${out.join('\n')}\n');
    }
    return;
  }
  // No key yet: insert at the top (YAML top-level keys are order-free; the
  // manifest's own header comment stays readable).
  file.writeAsStringSync('template: $kTemplateVersion\n${lines.join('\n')}\n');
}

/// Multi-library init: render one scenario directory per manifest library
/// entry (`bench/contract/<name>/`). The manifest is user-authored — it is
/// never rewritten, and missing drivers are a hard error (no skeleton: in a
/// head-to-head consumer the drivers ARE the product).
int _cmdInitMultiLibrary(String root, bool force, List<String>? scenarios,
    Manifest manifest) {
  final wanted = scenarios ?? manifest.scenarios;
  // Per-solution bridges import the solution's driver; the driver gets
  // LibraryDriver from the package barrel.
  for (final entry in manifest.libraries) {
    final dir = manifest.dirFor(entry);
    Directory('$root/$dir').createSync(recursive: true);

    final driverFile = File('$root/${entry.driver}');
    if (!driverFile.existsSync()) {
      stderr.writeln('FAIL: ${entry.driver} (libraries.${entry.name}) is '
          'missing — write the driver first, then re-run init');
      return 1;
    }
    if (driverClassOf(driverFile) != entry.driverClass) {
      stderr.writeln('FAIL: ${entry.driver} does not declare '
          '${entry.driverClass} implementing LibraryDriver');
      return 1;
    }

    final driverImport = "import '${relativeImport(dir, entry.driver)}';";
    for (final id in wanted) {
      final templateName = _kScenarioTemplates[id];
      if (templateName == null) {
        if (id == 'size') {
          // Size is a host build, no per-library test file — see cmdInit.
          stdout.writeln('  size: host builds — runs with `contract run` '
              '(--legs native|web|both)');
        } else {
          stdout.writeln('  unknown scenario "$id" — skipped');
        }
        continue;
      }
      final target = File('$root/$dir/$templateName');
      if (!target.existsSync() || force) {
        target.writeAsStringSync(_bridgeSource(
          id: id,
          driverImport: driverImport,
          driverNew: '${entry.driverClass}()',
          idleClasses: manifest.idleClasses,
        ));
        stdout.writeln('wrote $dir/$templateName');
      }
    }
  }
  _syncManifestTemplate(root);
  stdout.writeln('init done: libraries='
      '${manifest.libraries.map((e) => e.name).join(', ')}, '
      'scenarios=[${wanted.join(', ')}]');
  return 0;
}

String _pascal(String s) {
  final parts = s.split(RegExp(r'[^a-zA-Z0-9]'))
    ..removeWhere((p) => p.isEmpty);
  return parts.map((p) => p[0].toUpperCase() + p.substring(1)).join();
}

String _driverSkeleton(String library, String driverClass) =>
    '''
// ${library}_driver.dart — consumer driver skeleton (generated by contract
// init). Implement the verbs against your solution (scene keys/geometry:
// package scene.dart; mounted content: the package's ContractCard).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_bench_contract/flutter_bench_contract.dart';

class $driverClass implements LibraryDriver {
  @override
  String get name => '$library';

  @override
  bool get scrollCoupled => false;

  @override
  Widget buildScene({required bool withLibrary, required SceneSpec spec}) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Contract scene')),
        body: ListView(
          key: const Key(kSceneListKey),
          controller: spec.listScroll,
          children: [
            for (var i = 0; i < kSceneRowCount; i++)
              SizedBox(
                key: Key(sceneRowKey(i)),
                height: kSceneRowHeight,
                child: Text('Row \$i'),
              ),
            const SizedBox(height: kSceneScrollMargin),
          ],
        ),
        floatingActionButton: FloatingActionButton(
          key: const Key(kSceneAKey),
          onPressed: () => spec.aTaps.value++,
          child: const Icon(Icons.add),
        ),
      ),
    );
  }

  @override
  Future<void> show(int state) async {
    // TODO: mount ContractCard(state: state) with your solution.
    throw UnimplementedError('show(\$state)');
  }

  @override
  Future<void> update(int state) async {
    throw UnimplementedError('update(\$state)');
  }

  @override
  Future<void> hide() async {
    throw UnimplementedError('hide()');
  }

  @override
  bool isStable() => false;

  @override
  Finder currentContent(int state) =>
      find.byKey(Key(contractCardKey(state)));
}
''';

// ── verify ─────────────────────────────────────────────────────────────────

int cmdVerify(List<String> args) {
  var root = '.';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--dir') root = args[++i];
  }
  final manifest = Manifest.load(root);
  var ok = true;

  if (manifest.template != kTemplateVersion) {
    stderr.writeln('FAIL: manifest template v${manifest.template} vs package '
        'template v$kTemplateVersion — run "contract init --force" to '
        'regenerate the contract files');
    ok = false;
  }
  for (final entry in manifest.entries) {
    if (driverClassOf(File('$root/${entry.driver}')) !=
        entry.driverClass) {
      stderr.writeln('FAIL: ${entry.driver} (${entry.name}) does not declare '
          '${entry.driverClass} implementing LibraryDriver');
      ok = false;
    }
    for (final id in manifest.scenarios) {
      final templateName = _kScenarioTemplates[id];
      if (templateName == null) {
        if (id == 'size') {
          // S7 has no template file: it is the manifest `size:` section
          // (verified below), executed by `contract run`.
          continue;
        }
        stderr.writeln('WARN: scenario "$id" has no template in v'
            '$kTemplateVersion');
        continue;
      }
      final file = File('$root/${manifest.dirFor(entry)}/$templateName');
      if (!file.existsSync()) {
        stderr.writeln('FAIL: missing $file — run "contract init --force"');
        ok = false;
      }
    }
  }
  for (final custom in manifest.customScenarios) {
    if (!File('$root/${custom.target}').existsSync()) {
      stderr.writeln('FAIL: custom scenario ${custom.id}: missing '
          '${custom.target} (the consumer-authored test file)');
      ok = false;
    }
  }
  // size: config shape — a declared native leg needs a package, a web leg
  // needs both entry targets (the files are the consumer's own app targets,
  // existence is checked when `contract run` actually builds).
  final size = manifest.size;
  final sizeDeclared = manifest.scenarios.contains('size');
  if (sizeDeclared && size == null) {
    stderr.writeln('FAIL: scenario "size" is listed but there is no `size:` '
        'section — `contract run` would refuse to measure it');
    ok = false;
  } else if (size != null && !sizeDeclared) {
    stderr.writeln('WARN: `size:` section declared but "size" is not in '
        '`scenarios:` — the legs never run; add it or drop the section');
  }
  if (size != null) {
    if (size.hasNative && size.nativePackage!.isEmpty) {
      stderr.writeln('FAIL: size.native needs a package: (the pub package '
          'whose analyze-size subtree is the native contribution)');
      ok = false;
    }
    if (size.hasWeb && size.webWithout!.isEmpty) {
      stderr.writeln('FAIL: size.web needs without: (the structurally '
          'identical app without the solution)');
      ok = false;
    }
    if (!size.hasNative && !size.hasWeb) {
      stderr.writeln('WARN: `size:` section declares no leg (native or web)');
    }
  }
  stdout.writeln(ok ? 'verify OK (template v${manifest.template})'
      : 'verify FAILED');
  return ok ? 0 : 1;
}

// ── run ────────────────────────────────────────────────────────────────────

Future<int> cmdRun(List<String> args) async {
  var root = '.';
  String? device;
  var mode = 'check';
  var ref = 'android';
  double slack = 0.3;
  List<String>? only;
  String? onlyLibrary;
  String? storePath;
  var legs = 'both'; // S7 size legs: native | web | both
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--dir':
        root = args[++i];
      case '--device':
        device = args[++i];
      case '--mode':
        mode = args[++i];
      case '--ref':
        ref = args[++i];
      case '--slack':
        slack = double.parse(args[++i]);
      case '--scenarios':
        only = args[++i].split(',');
      case '--library':
        onlyLibrary = args[++i];
      case '--store':
        storePath = args[++i];
      case '--legs':
        legs = args[++i];
    }
  }
  if (mode != 'check' && mode != 'record') {
    stderr.writeln('FAIL: --mode must be check|record');
    return 2;
  }
  if (!{'native', 'web', 'both'}.contains(legs)) {
    stderr.writeln('FAIL: --legs must be native|web|both');
    return 2;
  }
  // Absolute root (POSIX separators — dart:io and the flutter subprocess
  // accept them on every platform); targets are relative to it.
  root = File(root).absolute.path.replaceAll('\\', '/');
  final manifest = Manifest.load(root);
  final entries = manifest.entries
      .where((e) => onlyLibrary == null || e.name == onlyLibrary)
      .toList();
  if (entries.isEmpty) {
    stderr.writeln('FAIL: no library selected (--library $onlyLibrary) — '
        'known: ${manifest.entries.map((e) => e.name).join(', ')}');
    return 2;
  }
  final reportDir = '$root/build';
  Directory(reportDir).createSync(recursive: true);
  final store = GoldenStore(path: storePath ?? '$root/benchmarks.json');

  // Run artifacts (written once all checks ran): chart points for every
  // measured metric@ref and the per-metric verdicts of the checks.
  final chartPoints = <ChartPoint>[];
  final checkRows = <MetricCheck>[];

  var exitFailures = 0;
  var failedEntry = false;
  // --scenarios filters which contract ids run per entry; when the filter
  // selects none (e.g. only a custom.* id), the entry is skipped cleanly
  // instead of failing on an intentionally empty report.
  final requestedContract = manifest.scenarios
      .where((id) => only == null || only.contains(id))
      .toList();
  for (final entry in entries) {
    final entryRef = entry.ref ?? ref;
    final reportPath = '$reportDir/contract_${entry.name}.jsonl';
    final report = File(reportPath);
    report.writeAsStringSync('');

    var entryRuns = 0;
    for (final id in requestedContract) {
      final templateName = _kScenarioTemplates[id];
      if (templateName == null) {
        // `size` is not per-library (no bridge): it is a manifest-level
        // host build, run once after the entries (see below).
        continue;
      }
      final targetRel = '${manifest.dirFor(entry)}/$templateName';
      if (!File('$root/$targetRel').existsSync()) {
        stderr.writeln('FAIL: missing $targetRel — run "contract init --force"');
        exitFailures++;
        continue;
      }
      final runs = runsForScenario(id);
      entryRuns += runs;
      for (var i = 1; i <= runs; i++) {
        stdout.writeln('==> ${entry.name}/$id (${device == null ? 'host' : 'device'}) '
            '— run $i/$runs');
        final ok = device == null
            ? await _runHost(report, root, targetRel)
            : await _runDevice(report, root, targetRel, device);
        if (!ok) exitFailures++;
      }
    }
    if (entryRuns == 0) {
      stdout.writeln('  (${entry.name}: no contract scenarios selected — '
          'skipped)');
      continue;
    }

    final samples = ReportFile(reportPath).samples;
    if (samples.isEmpty) {
      stderr.writeln('FAIL(${entry.name}): no samples collected in $reportPath '
          '($exitFailures run failure(s))');
      failedEntry = true;
      continue;
    }
    final measured = samples.keys.toList()..sort();
    stdout.writeln('samples (${entry.name}): $measured (ref=$entryRef, $mode)');
    for (final m in measured) {
      chartPoints.add(
          ChartPoint(m, entryRef, samples[m]!, chartUnitFor(m)));
    }

    if (mode == 'record') {
      store.record(samples, ref: entryRef);
    } else {
      final rows = store.check(samples, ref: entryRef, slack: slack);
      checkRows.addAll(rows);
      if (rows.any((r) => r.regression)) failedEntry = true;
    }
  }

  // Custom scenarios: consumer-level (NOT per library), own golden
  // ref, own report — excluded from rivals comparison and public tables.
  // The consumer writes the test; the machinery (run, goldens, gate) is the
  // package's. --scenarios matches the full id (custom.<name>) or the key.
  for (final custom in manifest.customScenarios) {
    if (only != null &&
        !only.contains(custom.id) &&
        !only.contains(custom.name)) {
      continue;
    }
    if (!File('$root/${custom.target}').existsSync()) {
      stderr.writeln('FAIL: missing custom scenario ${custom.target} — write '
          'the test first');
      exitFailures++;
      continue;
    }
    final reportPath = '$reportDir/custom_${custom.name}.jsonl';
    final report = File(reportPath);
    report.writeAsStringSync('');
    for (var i = 1; i <= custom.runs; i++) {
      stdout.writeln('==> custom/${custom.id} (${device == null ? 'host' : 'device'}) '
          '— run $i/${custom.runs}');
      final ok = device == null
          ? await _runHost(report, root, custom.target)
          : await _runDevice(report, root, custom.target, device);
      if (!ok) exitFailures++;
    }
    final samples = ReportFile(reportPath).samples;
    if (samples.isEmpty) {
      stderr.writeln('FAIL(custom/${custom.id}): no samples in $reportPath '
          '($exitFailures run failure(s))');
      failedEntry = true;
      continue;
    }
    if (!samples.containsKey(custom.id)) {
      stderr.writeln('WARN(custom/${custom.id}): report carries '
          '${samples.keys.join(', ')} — expected ${custom.id} (the test must '
          "reportMetric('${custom.id}', value)");
    }
    final customKeys = samples.keys.toList()..sort();
    for (final m in customKeys) {
      chartPoints.add(ChartPoint(m, custom.ref, samples[m]!, chartUnitFor(m)));
    }
    if (mode == 'record') {
      store.record(samples, ref: custom.ref);
    } else {
      final rows = store.check(samples, ref: custom.ref, slack: slack);
      checkRows.addAll(rows);
      if (rows.any((r) => r.regression)) failedEntry = true;
    }
  }

  // S7 size legs: manifest-level (not per library), host release builds,
  // run once when `size` is among the selected scenarios. Per-metric golden
  // refs (bundle_delta under `any`, native_size under the invocation ref).
  if (requestedContract.contains('size')) {
    if (manifest.size == null) {
      stderr.writeln('FAIL: scenario "size" selected but the manifest has no '
          '`size:` section — declare the S7 legs (native/web) under `size:`');
      failedEntry = true;
    } else {
      stdout.writeln('==> size (S7, host builds, legs=$legs)...');
      final ok = await runSizeLegs(root, manifest.size, mode, ref, legs,
          store, chartPoints: chartPoints, checkRows: checkRows);
      if (!ok) failedEntry = true;
    }
  }
  _writeRunArtifacts(
      root: root, mode: mode, points: chartPoints, rows: checkRows);
  if (failedEntry) return 1;
  return exitFailures > 0 ? 1 : 0;
}

/// Writes the run artifacts under `build/` for the external tooling:
/// `benchmark-data.json` (github-action-benchmark chart points, any mode)
/// and `check-report.json` (per-metric verdicts, check mode only).
void _writeRunArtifacts({
  required String root,
  required String mode,
  required List<ChartPoint> points,
  required List<MetricCheck> rows,
}) {
  final dir = '$root/build';
  if (points.isNotEmpty) {
    File('$dir/benchmark-data.json')
        .writeAsStringSync(chartDataJson(points));
    stdout.writeln('wrote build/benchmark-data.json '
        '(${points.length} chart points)');
  }
  if (mode == 'check') {
    File('$dir/check-report.json').writeAsStringSync(checkReportJson(rows));
    stdout.writeln('wrote build/check-report.json (${rows.length} metrics)');
  }
}

// ── size (S7, host builds) ─────────────────────────────────────────────────

/// Runs the S7 size legs of the manifest's `size:` section: the release
/// host builds (no device, no driver, no test target), then records or
/// checks each metric under its OWN golden ref — `bundle_delta` is
/// SDK-pinned under `any`; `native_size` follows the invocation ref (the
/// docker dispatch records it under `android`). Returns true when all
/// measured legs passed (check) or recorded (record); false otherwise.
///
/// [root] is the absolute consumer root; [legs] is native|web|both.
/// [chartPoints]/[checkRows] collect the run artifacts when given (the CLI
/// passes its accumulators; tests may omit them).
Future<bool> runSizeLegs(
  String root,
  SizeConfig? config,
  String mode,
  String ref,
  String legs,
  GoldenStore store, {
  List<ChartPoint>? chartPoints,
  List<MetricCheck>? checkRows,
}) async {
  if (config == null || (!config.hasNative && !config.hasWeb)) {
    stderr.writeln('WARN: scenario "size" declared but the `size:` section '
        'declares no leg (native/web) — nothing to measure');
    return true;
  }
  final measured = <String, num>{};
  var buildFailed = false;

  if (config.hasNative && (legs == 'both' || legs == 'native')) {
    final bytes = await _measureNativeSize(root, config);
    if (bytes == null) {
      buildFailed = true;
    } else {
      measured['native_size'] = bytes;
    }
  }
  if (config.hasWeb && (legs == 'both' || legs == 'web')) {
    final delta = await _measureWebDelta(root, config);
    if (delta == null) {
      buildFailed = true;
    } else {
      measured['bundle_delta'] = delta;
    }
  }
  if (buildFailed) {
    stderr.writeln('FAIL: size build failed — see output above');
    return false;
  }
  if (measured.isEmpty) {
    // Explicit --legs that matches no declared leg is a config error, not a
    // silent pass (the old `contract size` failed here too).
    stderr.writeln('FAIL: no size leg measured (legs=$legs, declared: '
        'native=${config.hasNative}, web=${config.hasWeb}) — check --legs '
        'against the manifest `size:` section');
    return false;
  }

  // Per-metric golden refs (defs.dart): bundle_delta is SDK-pinned under
  // `any`, native_size follows the invocation ref.
  var ok = true;
  final native = measured['native_size'];
  if (native != null) {
    stdout.writeln('samples: native_size=$native (ref=$ref, $mode)');
    chartPoints?.add(ChartPoint('native_size', ref, native, 'B'));
    if (mode == 'record') {
      store.record({'native_size': native}, ref: ref);
    } else {
      final rows =
          store.check({'native_size': native}, ref: ref, slack: 0.05);
      checkRows?.addAll(rows);
      if (rows.any((r) => r.regression)) ok = false;
    }
  }
  final delta = measured['bundle_delta'];
  if (delta != null) {
    stdout.writeln('samples: bundle_delta=$delta (ref=any, $mode)');
    chartPoints?.add(ChartPoint('bundle_delta', 'any', delta, 'B'));
    if (mode == 'record') {
      store.record({'bundle_delta': delta}, ref: 'any');
    } else {
      final rows =
          store.check({'bundle_delta': delta}, ref: 'any', slack: 0.05);
      checkRows?.addAll(rows);
      if (rows.any((r) => r.regression)) ok = false;
    }
  }
  return ok;
}

/// Native leg: one release `flutter build apk --analyze-size` of the app
/// that imports the solution; the code-size JSON is walked for the
/// `package:<nativePackage>` node and its subtree bytes summed. Returns the
/// bytes, or null when the build/analysis failed or the package node is
/// missing (the app does not import the solution under that name).
Future<int?> _measureNativeSize(String root, SizeConfig config) async {
  final arch = config.arch;
  final entry = config.entry;
  stdout.writeln('==> size/native: flutter build apk --release --analyze-size '
      '(--target-platform android-$arch, target $entry)...');
  final out = await _runCapture('flutter', [
    'build',
    'apk',
    '--release',
    '--analyze-size',
    '--target-platform',
    'android-$arch',
    '--code-size-directory',
    'build/size',
    if (entry != SizeConfig.defaultEntry) '--target=$entry',
  ], root);
  if (out.exitCode != 0) {
    stderr.writeln('FAIL: native size build failed (exit ${out.exitCode})');
    return null;
  }
  final analysisPath = analysisPathFromBuildOutput(out.output);
  if (analysisPath == null) {
    stderr.writeln('FAIL: could not find the code-size analysis path in the '
        'build output');
    return null;
  }
  final jsonText = File(analysisPath).readAsStringSync();
  final bytes = packageSubtreeBytesFromJson(jsonText, config.nativePackage!);
  if (bytes == null) {
    stderr.writeln('FAIL: package:${config.nativePackage} node not found in '
        'the code-size tree — does the app import the solution under that '
        'pub package name?');
    return null;
  }
  stdout.writeln('  native_size: package:${config.nativePackage} contributes '
      '$bytes bytes (AOT, release, android-$arch)');
  return bytes;
}

/// Web leg: two release web builds of structurally identical targets (with
/// and without the solution), diffed on main.dart.js — the solution's
/// startup-bundle cost. Returns the delta, or null on failure/negative
/// delta (the baseline must not exceed the engine build).
Future<int?> _measureWebDelta(String root, SizeConfig config) async {
  final withEntry = config.webWithEntry;
  final withoutEntry = config.webWithout!;
  stdout.writeln('==> size/web: build $withEntry (with) vs $withoutEntry '
      '(without)...');
  final withBuild = await _runCapture('flutter', [
    'build',
    'web',
    '--release',
    '--target=$withEntry',
    '-o',
    'build/size_web_with',
  ], root);
  if (withBuild.exitCode != 0) {
    stderr.writeln('FAIL: web build of $withEntry failed '
        '(exit ${withBuild.exitCode})');
    return null;
  }
  final withoutBuild = await _runCapture('flutter', [
    'build',
    'web',
    '--release',
    '--target=$withoutEntry',
    '-o',
    'build/size_web_without',
  ], root);
  if (withoutBuild.exitCode != 0) {
    stderr.writeln('FAIL: web build of $withoutEntry failed '
        '(exit ${withoutBuild.exitCode})');
    return null;
  }
  int jsBytes(String dir) {
    final file = File('$root/$dir/$webMainJsFile');
    return file.existsSync() ? file.lengthSync() : 0;
  }

  final engine = jsBytes('build/size_web_with');
  final baseline = jsBytes('build/size_web_without');
  if (engine == 0 || baseline == 0) {
    stderr.writeln('FAIL: main.dart.js missing in one of the size web builds '
        '(engine=$engine, baseline=$baseline)');
    return null;
  }
  final delta = engine - baseline;
  stdout.writeln('  main.dart.js: with=$engine, without=$baseline, '
      'bundle_delta=$delta bytes');
  if (delta < 0) {
    stderr.writeln('FAIL: negative delta — the baseline build must not exceed '
        'the engine build');
    return null;
  }
  return delta;
}

/// Runs a command, capturing combined stdout+stderr without buffering the
/// whole build output: keeps every line that carries a code-size analysis
/// path (the native sentinel can appear anywhere in the stream) plus a
/// bounded tail for diagnostics.
Future<({int exitCode, String output})> _runCapture(
    String executable, List<String> args, String root) async {
  final proc = await Process.start(
    executable,
    args,
    workingDirectory: root,
    runInShell: true,
    includeParentEnvironment: true,
  );
  final kept = <String>[];
  final analysis = RegExp(
      r'A summary of your [A-Za-z]+ analysis can be found at: .+?\.json');
  Future<void> pump(Stream<List<int>> stream) async {
    await for (final chunk in stream.transform(utf8.decoder)) {
      for (final line in chunk.split('\n')) {
        if (analysis.hasMatch(line)) {
          kept.add(line);
        } else {
          kept.add(line);
          if (kept.length > 120) kept.removeAt(0);
        }
      }
    }
  }

  await Future.wait([pump(proc.stdout), pump(proc.stderr)]);
  final code = await proc.exitCode;
  return (exitCode: code, output: kept.join('\n'));
}

/// Rewrites a generated file's relative imports (the driver api, the
/// consumer driver) to absolute file URIs — for copies that run from a
/// different directory (device targets under build/device/).
String _absolutizeRelativeImports(String content, String sourcePath) {
  final baseDir = File(sourcePath).parent.path;
  final rel = RegExp(r"^import '([^']+)';$", multiLine: true);
  final out = StringBuffer();
  for (final line in content.split('\n')) {
    final m = rel.firstMatch(line);
    if (m != null &&
        !line.contains('package:') &&
        !line.contains('dart:')) {
      final resolved = File('$baseDir/${m.group(1)}').absolute;
      out.writeln("import '${Uri.file(resolved.path)}';".replaceAll('\\\\', '/'));
    } else {
      out.writeln(line);
    }
  }
  return out.toString();
}

/// Host run: `flutter test --machine <file>`; machine events carry the app's
/// prints (reportMetric samples) as unescaped 'print' messages.
Future<bool> _runHost(File report, String root, String target) async {
  final proc = await Process.start(
    'flutter',
    ['test', '--machine', target],
    workingDirectory: root,
    runInShell: true,
    includeParentEnvironment: true,
  );
  final sink = report.openWrite(mode: FileMode.append);
  var samples = 0;
  await for (final line in proc.stdout.transform(utf8.decoder)
      .transform(const LineSplitter())) {
    try {
      final decoded = jsonDecode(line);
      // Machine events are JSON objects; the stream can also carry tool
      // noise (e.g. a devtools JSON array) — anything non-event is ignored.
      if (decoded is Map<String, dynamic> &&
          decoded['type'] == 'print' &&
          decoded['message'] is String) {
        sink.writeln(decoded['message'] as String);
        samples++;
      }
    } catch (_) {
      // non-JSON noise between events
    }
  }
  final code = await proc.exitCode;
  await sink.flush();
  await sink.close();
  stderr.writeln('  (host run: exit=$code, sample lines=$samples)');
  return code == 0;
}

/// Device run: `flutter drive --no-dds --profile --target=... -d <device>`;
/// the app's stdout goes to the report verbatim (envelope lines inside).
///
/// On-device runs need the integration_test binding in the target's main
/// (results are reported to the driver over the VM service). The consumer's
/// generated files stay host-clean (no live binding — it would break host
/// `flutter test` pumping), so the device target is an ephemeral copy under
/// build/device/ with the binding prepended. Requires the consumer's
/// dev_dependency on integration_test (sdk).
Future<bool> _runDevice(
    File report, String root, String target, String device) async {
  // [target] is relative to [root]; the drive subprocess runs with cwd=root.
  final source = File('$root/$target');
  var content = source.readAsStringSync();
  var driveTarget = target;
  if (!content.contains('IntegrationTestWidgetsFlutterBinding')) {
    final deviceDir = Directory('$root/build/device');
    deviceDir.createSync(recursive: true);
    final copy = File('${deviceDir.path}/${source.uri.pathSegments.last}');
    content = content.replaceFirst(
      'void main() {',
      'void main() {\n'
          '  IntegrationTestWidgetsFlutterBinding.ensureInitialized();',
    );
    if (!content.contains("import 'package:integration_test/")) {
      content = "import 'package:integration_test/integration_test.dart';\n"
          "$content";
    }
    // The copy moves next to the other scenarios' relative imports — rewrite
    // them to absolute file URIs (package:/dart: imports stay as-is).
    copy.writeAsStringSync(_absolutizeRelativeImports(content, source.path));
    driveTarget = 'build/device/${source.uri.pathSegments.last}';
  }
  final proc = await Process.start(
    'flutter',
    [
      'drive',
      '--no-dds',
      '--profile',
      // Without --driver, flutter drive derives one from the target
      // (test_driver/<dir>/<name>_test.dart) and fails "Test file not
      // found" — the driver must be the consumer's integration_test driver.
      '--driver=test_driver/integration_test.dart',
      '--target=$driveTarget',
      '-d',
      device,
    ],
    workingDirectory: root,
    runInShell: true,
    includeParentEnvironment: true,
  );
  final sink = report.openWrite(mode: FileMode.append);
  proc.stdout.transform(utf8.decoder).listen(sink.write);
  proc.stderr.transform(utf8.decoder).listen(sink.write);
  final code = await proc.exitCode;
  await sink.flush();
  await sink.close();
  return code == 0;
}

// ── card (published metrics-card PNG) ──────────────────────────────────────

/// Renders the manifest `card:` metrics card from the recorded goldens as
/// a golden PNG (generated flutter-test render, real SDK Roboto), then
/// copies it to `card.out:`.
///
/// Exit code: 0 ok / 1 render failed / 2 usage or missing `card:` config.
Future<int> cmdCard(List<String> args) async {
  var root = '.';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--dir') root = args[++i];
  }
  root = File(root).absolute.path.replaceAll('\\', '/');
  final manifest = Manifest.load(root);
  final card = manifest.card;
  if (card == null) {
    stderr.writeln('FAIL: no `card:` section in $root/$kManifestFileName — '
        'declare the card content (title/subtitle/out) first');
    return 2;
  }

  // Rows = publishable defs with a recorded value, in canonical order; the
  // marketing subtitle per tile comes from the manifest.
  final store = GoldenStore(path: '$root/benchmarks.json');
  final values = <String, num>{};
  final rows = <Map<String, Object?>>[];
  for (final def in kPublishableMetricDefs) {
    // Own refs only (android → any): the card must never fall back to a
    // foreign ref's value — a metric recorded only for a rival would
    // otherwise render as the consumer's own number (cross-library
    // contamination). The README renderer applies the same rule per column.
    final value = store.load(def.key, fallbackAny: false);
    if (value == null) continue;
    values[def.key] = value;
    rows.add({
      'key': def.key,
      'label': def.label,
      'unit': def.unit,
      'subtitle': card.subtitles[def.key],
    });
  }
  if (rows.isEmpty) {
    stderr.writeln('FAIL: no recorded values in $root/benchmarks.json to '
        'render — run `contract run --mode record` on the reference first');
    return 1;
  }

  // Footer defaults: note → [_kCardDefaultNote]; legend → head-to-head
  // wording only when the consumer publishes a comparison.
  final hasHeadToHead = manifest.libraries.isNotEmpty ||
      (manifest.readme?.columns.length ?? 0) > 1;
  final note = card.note?.trim() ?? _kCardDefaultNote;
  final legend = card.legend ??
      (hasHeadToHead
          ? 'head-to-head — see the README for the comparison table'
          : null);

  final payload = jsonEncode({
    'title': card.title,
    'subtitle': card.subtitle,
    'note': note, // YAML block scalars add a trailing newline — trimmed above
    'legend': legend,
    'rows': rows,
    'values': values,
  });
  final define = base64Encode(utf8.encode(payload));

  // The render is a flutter test (dart:ui needed for text layout + the
  // golden capture); the harness file is generated next to the build
  // artifacts, so consumers do not maintain a render test.
  final renderDir = Directory('$root/build/card_render');
  renderDir.createSync(recursive: true);
  final testFile = File('${renderDir.path}/card_render_test.dart');
  testFile.writeAsStringSync(_cardRenderTestSource);

  await _ensureSdkFonts();
  stdout.writeln('==> card: flutter test golden render (${rows.length} rows, '
      'values: ${values.keys.join(', ')})...');
  final proc = await Process.start(
    'flutter',
    [
      'test',
      '--update-goldens',
      '--dart-define=CARD_PAYLOAD=$define',
      'build/card_render/card_render_test.dart',
    ],
    workingDirectory: root,
    runInShell: true,
    includeParentEnvironment: true,
  );
  final log = StringBuffer();
  proc.stdout.transform(utf8.decoder).listen(log.write);
  proc.stderr.transform(utf8.decoder).listen(log.write);
  final code = await proc.exitCode;
  if (code != 0) {
    stderr.writeln('FAIL: card render failed (exit $code) — last log lines:');
    final lines = log.toString().split('\n');
    stderr.writeln(lines.length > 60
        ? lines.sublist(lines.length - 60).join('\n')
        : log.toString());
    return 1;
  }

  final golden = File('${renderDir.path}/card_golden.png');
  if (!golden.existsSync() || golden.lengthSync() == 0) {
    stderr.writeln('FAIL: card render produced no PNG at $golden');
    return 1;
  }
  final out = File('$root/${card.out}');
  out.parent.createSync(recursive: true);
  golden.copySync(out.path);
  stdout.writeln('card rendered: ${out.path} '
      '(${golden.lengthSync()} bytes, ${rows.length} metrics)');
  return 0;
}

/// The generated render harness (see [cmdCard]): decodes the payload,
/// loads the SDK fonts, pumps the generic [MetricsCard] at the landscape
/// golden size and captures the PNG via matchesGoldenFile.
const String _cardRenderTestSource = '''
// Generated by `contract card` — do not edit (regenerate: contract card).
// Renders the consumer's metrics card (manifest `card:` + recorded goldens)
// as a golden PNG through flutter test (real Roboto, no device).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_bench_contract/metrics_card.dart';

void main() {
  testWidgets('metrics card golden render', (tester) async {
    const raw = String.fromEnvironment('CARD_PAYLOAD');
    if (raw.isEmpty) {
      throw StateError('CARD_PAYLOAD define missing — run `contract card`');
    }
    final Map<String, dynamic> payload =
        (jsonDecode(utf8.decode(base64Decode(raw))) as Map)
            .cast<String, dynamic>();
    final rows = <MetricsCardRow>[
      for (final r in (payload['rows'] as List).cast<Map<String, dynamic>>())
        MetricsCardRow(
          key: r['key'] as String,
          label: r['label'] as String,
          unit: r['unit'] as String,
          subtitle: r['subtitle'] as String?,
        ),
    ];
    final values =
        (payload['values'] as Map<String, dynamic>).cast<String, num>();

    await loadSdkRobotoFonts();

    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MetricsCard(
      title: payload['title'] as String,
      subtitle: payload['subtitle'] as String,
      rows: rows,
      values: values,
      note: payload['note'] as String?,
      legend: payload['legend'] as String?,
    ));
    await tester.pump(const Duration(milliseconds: 300));

    await expectLater(
      find.byType(MetricsCard),
      matchesGoldenFile('card_golden.png'),
    );
  });
}
''';

/// Ensures the Flutter SDK's material fonts exist (the flutter tool never
/// fetches them for `flutter test`, so a fresh SDK has no
/// material_fonts/) — the same fetch hintful's runner used to curl, now
/// absorbed into the CLI so every consumer gets it for free.
Future<void> _ensureSdkFonts() async {
  final root = await _flutterRoot();
  final fontsDir = Directory('$root/bin/cache/artifacts/material_fonts');
  if (!fontsDir.existsSync()) fontsDir.createSync(recursive: true);
  final hasRegular = fontsDir.listSync().any((e) {
    if (e is! File) return false;
    final name = e.uri.pathSegments.last.toLowerCase();
    return name == 'roboto-regular.ttf' || name == 'roboto-medium.ttf';
  });
  if (hasRegular) return;

  final versionFile = File('$root/bin/internal/material_fonts.version');
  if (!versionFile.existsSync()) {
    throw StateError('SDK material fonts missing and no '
        'bin/internal/material_fonts.version to fetch them from — run any '
        '`flutter` build once, or download the fonts into $fontsDir');
  }
  final url =
      'https://storage.googleapis.com/${versionFile.readAsStringSync().trim()}';
  stderr.writeln('  (fetching SDK material fonts: $url)');
  final zipFile = File('${Directory.systemTemp.path}/material_fonts.zip');
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw StateError('font fetch failed: HTTP ${response.statusCode}');
    }
    final sink = zipFile.openWrite();
    await response.pipe(sink);
    await sink.close();
  } finally {
    client.close();
  }
  final unzip =
      await Process.run('unzip', ['-oq', zipFile.path, '-d', fontsDir.path]);
  if (unzip.exitCode != 0) {
    throw StateError('unzip failed (exit ${unzip.exitCode}): ${unzip.stderr} '
        '— unzip $zipFile into $fontsDir manually');
  }
  stderr.writeln('  (unzipped into $fontsDir)');
}

/// Flutter SDK root: FLUTTER_ROOT, else resolve `flutter` from PATH and
/// climb two levels (bin/flutter lives at `<root>/bin/flutter`).
Future<String> _flutterRoot() async {
  final env = Platform.environment['FLUTTER_ROOT'];
  if (env != null && env.isNotEmpty) return env;
  final pathEnv = Platform.environment['PATH'] ?? '';
  final exe = Platform.isWindows ? 'flutter.bat' : 'flutter';
  for (final dir in pathEnv.split(Platform.pathSeparator)) {
    if (dir.isEmpty) continue;
    final cand = File('$dir${Platform.pathSeparator}$exe');
    if (cand.existsSync()) {
      final resolved = cand.resolveSymbolicLinksSync();
      return File(resolved).parent.parent.path;
    }
  }
  throw StateError('cannot locate the Flutter SDK: FLUTTER_ROOT unset and '
      '`flutter` not on PATH');
}

// ── readme (published README section) ─────────────────────────────────────

/// Renders the manifest `readme:` section into the consumer's README
/// between the bench markers: table rows from the canonical defs, cells
/// from the store under each column's refs, prose from the manifest.
///
/// Exit code: 0 ok / 1 write failed / 2 usage or missing `readme:` config.
int cmdReadme(List<String> args) {
  var root = '.';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--dir') root = args[++i];
  }
  root = File(root).absolute.path.replaceAll('\\', '/');
  final manifest = Manifest.load(root);
  final config = manifest.readme;
  if (config == null) {
    stderr.writeln('FAIL: no `readme:` section in $root/$kManifestFileName — '
        'declare the section content (target/intro/columns/footnote) first');
    return 2;
  }
  final store = GoldenStore(path: '$root/benchmarks.json');
  final section = renderReadmeSection(
    ReadmeContent(
      title: config.title,
      intro: config.intro,
      columns: config.columns,
      footnote: config.footnote,
      image: config.image,
      imageAlt: config.imageAlt,
      stamp: config.stamp,
      chartsUrl: config.chartsUrl,
    ),
    store: store,
  );
  final target = File('$root/${config.target}');
  final text =
      target.existsSync() ? target.readAsStringSync() : '';
  target.writeAsStringSync(replaceReadmeSection(text, section));
  stdout.writeln('rendered readme section -> ${target.path}');
  return 0;
}

int usage() {
  stderr.writeln('''
usage: dart run flutter_bench_contract:contract <command> [options]

  init     scaffold the consumer contract files (per-scenario bridges, the
           flutter-drive test driver, a driver skeleton) + bench_contract.yaml
           [--dir ROOT] [--force] [--scenarios idle_zero,show_latency,...]
  run      run the manifest's declared scenarios (contract S1–S7 + custom.*
           consumer scenarios under their own refs) and check/record goldens
           [--dir ROOT] [--device ID] [--mode check|record] [--ref android]
           [--slack 0.3] [--scenarios subset] [--library NAME]
           [--legs native|web|both] [--store PATH]
  card     render the metrics-card PNG (manifest `card:` + recorded
           goldens; fonts ensured, golden render, copy to the `out:` path)
           [--dir ROOT]
  readme   render the README section (manifest `readme:` + recorded
           goldens) between the bench markers in the target README
           [--dir ROOT]
  verify   manifest/template/driver consistency
           [--dir ROOT]

  run without --device executes each scenario with `flutter test` on the host
  (samples degrade to null where the VM service is required); with --device
  it runs `flutter drive --no-dds --profile` on the given emulator/device.''');
  return 2;
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) exit(usage());
  final code = switch (args.first) {
    'init' => cmdInit(args.sublist(1)),
    'verify' => cmdVerify(args.sublist(1)),
    'run' => await cmdRun(args.sublist(1)),
    'card' => await cmdCard(args.sublist(1)),
    'readme' => cmdReadme(args.sublist(1)),
    _ => usage(),
  };
  exit(code);
}
