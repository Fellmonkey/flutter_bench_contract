// The bench-contract CLI (phase 2): scaffolding a consumer and running the
// declared scenarios.
//
//   init   — generate the consumer contract files from the package templates
//            (driver API + scenario tests + a driver skeleton when missing)
//            and write bench_contract.yaml.
//   run    — run the manifest's declared scenarios (flutter drive --profile
//            on a device, or flutter test on the host when no --device is
//            given) into build/contract_report.jsonl, then check the
//            samples against the recorded goldens or record them.
//   verify — templates/manifest consistency (template version, driver file,
//            generated scenario files).
//
// Usage (cwd: the consumer root, or --dir <root>):
//   dart run flutter_bench_contract:contract init [--force] [--scenarios a,b]
//   dart run flutter_bench_contract:contract run [--device <id>]
//       [--mode check|record] [--ref android] [--slack 0.3] [--scenarios ...]
//   dart run flutter_bench_contract:contract verify
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bench_contract/goldens.dart';
import 'package:flutter_bench_contract/manifest.dart';
import 'package:flutter_bench_contract/report.dart';
import 'package:flutter_bench_contract/size.dart';

// ── Package/template root resolution ───────────────────────────────────────

/// Resolves the directory holding the package's templates/ folder: the
/// flutter_bench_contract package root.
///
/// `dart run flutter_bench_contract:contract` executes the real bin source
/// (path dep or pub cache), so bin/.. is the package root — valid from any
/// consumer cwd. The .dart_tool/package_config.json lookup is only a
/// fallback for setups where Platform.script is a snapshot shim.
String resolvePackageRoot(String root) {
  // Running from inside the package itself: templates sit right next to the
  // target root (this also covers the dev loop before any consumer exists).
  if (File('$root/templates/library_driver.dart').existsSync()) {
    return File(root).absolute.path;
  }
  // The consumer's .dart_tool/package_config.json maps the dependency (path
  // or hosted) to its root — resolve against the config's ABSOLUTE directory.
  final configFile = File('$root/.dart_tool/package_config.json');
  if (configFile.existsSync()) {
    try {
      final config =
          jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
      final configDir = File(configFile.absolute.path).parent.uri;
      for (final p in (config['packages'] as List? ?? const [])) {
        final name = (p as Map<String, dynamic>)['name'];
        if (name == 'flutter_bench_contract') {
          final rootUri = (p['rootUri'] as String?) ?? '';
          final resolved = configDir.resolve(rootUri);
          if (resolved.scheme == 'file' &&
              File('${File.fromUri(resolved).path}/templates/library_driver.dart')
                  .existsSync()) {
            return File.fromUri(resolved).path;
          }
        }
      }
    } catch (_) {
      // no config — fall through to the script heuristic
    }
  }
  // Heuristic: the executable's own source lives in the package's bin/.
  return File(Platform.script.toFilePath()).parent.parent.path;
}

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

// ── Template rendering ─────────────────────────────────────────────────────

const String _kLibraryDriverTemplate = 'library_driver.dart';

/// Scenario id → template file (under templates/scenarios/).
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

/// Renders a template file's tokens.
String renderTemplate(String template, {
  required String driverImport,
  required String apiImport,
  required String driverNew,
  List<String> idleClasses = const [],
}) {
  return template
      .replaceAll('{{driverImport}}', driverImport)
      .replaceAll('{{apiImport}}', apiImport)
      .replaceAll('{{driverNew}}', driverNew)
      .replaceAll('{{idleClasses}}', idleClassesLiteral(idleClasses));
}

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
  final packageRoot = resolvePackageRoot(root);
  final templatesDir = '$packageRoot/templates';

  // Multi-library consumer (a manifest with `libraries:`): render one
  // scenario directory per solution; the manifest is user-authored and is
  // never rewritten here.
  final manifestFile = File('$root/$kManifestFileName');
  Manifest? existingManifest;
  if (manifestFile.existsSync()) {
    existingManifest = Manifest.load(root);
  }
  if (existingManifest != null && existingManifest.libraries.isNotEmpty) {
    return _cmdInitMultiLibrary(
      root,
      force,
      scenarios,
      existingManifest,
      templatesDir,
    );
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

  final contractDir = 'bench/contract';
  Directory('$root/$contractDir').createSync(recursive: true);

  // Driver API copy.
  final apiSource = File('$templatesDir/$_kLibraryDriverTemplate')
      .readAsStringSync();
  final apiFile = File('$root/$contractDir/library_driver.dart');
  if (!apiFile.existsSync() || force) {
    apiFile.writeAsStringSync(apiSource);
    stdout.writeln('wrote $contractDir/library_driver.dart');
  }

  // Driver file (skeleton when missing): a manifest-declared driver that is
  // missing is scaffolded with the manifest's class name; a driver whose
  // file declares no LibraryDriver class is a hard failure.
  final driverFile = File('$root/$driverRel');
  String? declaredClass = driverClassOf(driverFile);
  if (!driverFile.existsSync()) {
    final skeletonClass = driverClass ?? '${_pascal(library)}Driver';
    driverFile.parent.createSync(recursive: true);
    driverFile.writeAsStringSync(_driverSkeleton(
      library,
      skeletonClass,
      relativeImport('bench/drivers', contractDir),
    ));
    stdout.writeln('wrote $driverRel (skeleton — implement show/update/hide/'
        'isStable per bench_contract_specs §1–§3)');
    declaredClass = skeletonClass;
  }
  driverClass ??= declaredClass;
  if (driverClass == null) {
    stderr.writeln('FAIL: $driverRel exists but does not declare a class '
        'implementing LibraryDriver — cannot render the scenario files');
    return 1;
  }

  // Scenario files from the templates: an existing manifest's declared set
  // is preserved unless --scenarios overrides it (otherwise --force after a
  // template bump would silently drop scenarios the consumer added).
  final wanted = scenarios ?? existingManifest?.scenarios ?? kDefaultScenarios;
  final declared = <String>[];
  for (final id in wanted) {
    final templateName = _kScenarioTemplates[id];
    if (templateName == null) {
      if (id == 'size') {
        // S7 has no test-template: it is the host size builds (`contract
        // size`), configured by the manifest `size:` section. It stays a
        // declared scenario but renders no file.
        stdout.writeln('  size: host build — declare a `size:` section and '
            'run `contract size`');
        declared.add(id);
      } else {
        stdout.writeln('  unknown scenario "$id" — skipped');
      }
      continue;
    }
    final target = File('$root/$contractDir/$templateName');
    if (!target.existsSync() || force) {
      final rendered = renderTemplate(
        File('$templatesDir/scenarios/$templateName').readAsStringSync(),
        driverImport:
            "import '${relativeImport(contractDir, driverRel)}';",
        apiImport: "import 'library_driver.dart';",
        driverNew: '$driverClass()',
        idleClasses: existingManifest?.idleClasses ?? const [],
      );
      target.writeAsStringSync(rendered);
      stdout.writeln('wrote $contractDir/$templateName');
    }
    declared.add(id);
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
# S7 size (host release builds, no device; run `contract size`):
#   size:
#     native:                       # one apk --analyze-size build
#       package: <pub-package>      # subtree summed in the code-size tree
#       # entry: lib/main.dart      # app that imports the solution (default)
#       # arch: x64                 # android ABI (default)
#     web:                          # two web builds diffed on main.dart.js
#       # with: lib/main.dart       # structurally identical WITH the solution
#       without: lib/main_baseline.dart
#
# Custom scenarios (Р15, consumer-owned): metric id custom.<name>, OWN
# golden ref, excluded from rivals comparison and public tables. The test
# file reports reportMetric('custom.<name>', value); run/record/check —
# the package machinery (`contract run`).
#   customScenarios:
#     startup_to_show:
#       target: bench/startup_to_show_test.dart
#       ref: android-custom
#       # runs: 1
''');
    stdout.writeln('wrote $kManifestFileName (template v$kTemplateVersion)');
  } else {
    stdout.writeln('$kManifestFileName exists — kept (--force regenerates the '
        'scenario files, never the manifest)');
  }
  stdout.writeln('init done: library=$library, driverClass=$driverClass, '
      'scenarios=[${declared.join(', ')}]');
  return 0;
}

/// Multi-library init: render one scenario directory per manifest library
/// entry (`bench/contract/<name>/`). The manifest is user-authored — it is
/// never rewritten, and missing drivers are a hard error (no skeleton: in a
/// head-to-head consumer the drivers ARE the product).
int _cmdInitMultiLibrary(String root, bool force, List<String>? scenarios,
    Manifest manifest, String templatesDir) {
  final wanted = scenarios ?? manifest.scenarios;
  // ONE shared driver-API copy at the contract root: drivers import it as
  // '../contract/library_driver.dart' regardless of which library they are
  // (their import is user-authored and must be stable), and the per-library
  // scenario files import it as '../library_driver.dart'.
  final apiFile = File('$root/${manifest.contractDir}/library_driver.dart');
  if (!apiFile.existsSync() || force) {
    apiFile.writeAsStringSync(
        File('$templatesDir/$_kLibraryDriverTemplate').readAsStringSync());
    stdout.writeln('wrote ${manifest.contractDir}/library_driver.dart');
  }
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
          // See cmdInit: size is the host build, no per-library test file.
          stdout.writeln('  size: host build — declare a `size:` section and '
              'run `contract size`');
        } else {
          stdout.writeln('  unknown scenario "$id" — skipped');
        }
        continue;
      }
      final target = File('$root/$dir/$templateName');
      if (!target.existsSync() || force) {
        target.writeAsStringSync(renderTemplate(
          File('$templatesDir/scenarios/$templateName').readAsStringSync(),
          driverImport: driverImport,
          // Shared api copy one level up (see above).
          apiImport: "import '../library_driver.dart';",
          driverNew: '${entry.driverClass}()',
          idleClasses: manifest.idleClasses,
        ));
        stdout.writeln('wrote $dir/$templateName');
      }
    }
  }
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

String _driverSkeleton(
        String library, String driverClass, String apiImportRel) =>
    '''
// ${library}_driver.dart — consumer driver skeleton (generated by contract
// init). Implement the verbs against your solution per bench_contract_specs
// §1–§3 (scene keys/geometry: package scene.dart; content: ContractCard).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_bench_contract/flutter_bench_contract.dart';

import '$apiImportRel/library_driver.dart';

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
          // (verified below), run by `contract size`.
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
  // existence is checked when `contract size` actually builds).
  final size = manifest.size;
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
    }
  }
  if (mode != 'check' && mode != 'record') {
    stderr.writeln('FAIL: --mode must be check|record');
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
        if (id == 'size') {
          stdout.writeln('  size: host build — run `contract size` instead');
        }
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

    if (mode == 'record') {
      store.record(samples, ref: entryRef);
    } else {
      final failures = store.check(samples, ref: entryRef, slack: slack);
      if (failures > 0) failedEntry = true;
    }
  }

  // Custom scenarios (Р15): consumer-level (NOT per library), own golden
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
    if (mode == 'record') {
      store.record(samples, ref: custom.ref);
    } else {
      final failures = store.check(samples, ref: custom.ref, slack: slack);
      if (failures > 0) failedEntry = true;
    }
  }
  if (failedEntry) return 1;
  return exitFailures > 0 ? 1 : 0;
}

// ── size (S7, host builds) ─────────────────────────────────────────────────

/// Runs the S7 size measurement (`contract size`): the release host builds
/// declared in the manifest's `size:` section, then checks or records the
/// samples against the golden store. No device, no driver, no test target —
/// sizes are SDK+ABI-pinned, so the golden ref is `any` by default (the
/// caller picks the ref: hintful records native under `android` in the
/// dispatch, bundle_delta under `any` in the bundle CI job).
///
/// Exit code: 0 ok / 1 regression or failed build / 2 usage or config.
Future<int> cmdSize(List<String> args) async {
  var root = '.';
  var mode = 'check';
  var ref = 'any';
  double slack = 0.05; // size slack-class is hard (5%, spec §6)
  String? storePath;
  var legs = 'both'; // native | web | both
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--dir':
        root = args[++i];
      case '--mode':
        mode = args[++i];
      case '--ref':
        ref = args[++i];
      case '--slack':
        slack = double.parse(args[++i]);
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
  root = File(root).absolute.path.replaceAll('\\', '/');
  final manifest = Manifest.load(root);
  final config = manifest.size;
  if (config == null || (!config.hasNative && !config.hasWeb)) {
    stderr.writeln('FAIL: no `size:` section in $root/$kManifestFileName — '
        'declare the S7 legs (see doc/bench_contract_specs.md §5.8)');
    return 2;
  }

  final store = GoldenStore(path: storePath ?? '$root/benchmarks.json');
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
    return 1;
  }
  if (measured.isEmpty) {
    stderr.writeln('FAIL: no size leg measured (legs=$legs, declared: '
        'native=${config.hasNative}, web=${config.hasWeb})');
    return 1;
  }

  final keys = measured.keys.toList()..sort();
  stdout.writeln('samples: $keys (ref=$ref, $mode)');
  if (mode == 'record') {
    store.record(measured, ref: ref);
  } else {
    final failures = store.check(measured, ref: ref, slack: slack);
    if (failures > 0) return 1;
  }
  return 0;
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

int usage() {
  stderr.writeln('''
usage: dart run flutter_bench_contract:contract <command> [options]

  init     scaffold the consumer contract files (driver API, scenario tests,
           driver skeleton) and write bench_contract.yaml
           [--dir ROOT] [--force] [--scenarios idle_zero,show_latency,...]
  run      run the manifest's declared scenarios (contract S1–S7 + custom.*
           consumer scenarios under their own refs) and check/record goldens
           [--dir ROOT] [--device ID] [--mode check|record] [--ref android]
           [--slack 0.3] [--scenarios subset] [--library NAME]
           [--store PATH]
  size     S7: run the host size builds declared in the manifest `size:`
           section and check/record their goldens
           [--dir ROOT] [--mode check|record] [--ref any] [--slack 0.05]
           [--legs native|web|both] [--store PATH]
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
    'size' => await cmdSize(args.sublist(1)),
    _ => usage(),
  };
  exit(code);
}
