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

/// Renders a template file's tokens.
String renderTemplate(String template, {
  required String driverImport,
  required String apiImport,
  required String driverNew,
}) {
  return template
      .replaceAll('{{driverImport}}', driverImport)
      .replaceAll('{{apiImport}}', apiImport)
      .replaceAll('{{driverNew}}', driverNew);
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

  // Library name: the enclosing pub package's name, else the folder name.
  var library = File(root).uri.pathSegments.isNotEmpty
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

  // Driver file (skeleton when missing) + driver class.
  final driverRel = 'bench/drivers/${library}_driver.dart';
  final driverFile = File('$root/$driverRel');
  String? driverClass = driverClassOf(driverFile);
  if (!driverFile.existsSync()) {
    driverFile.parent.createSync(recursive: true);
    driverFile.writeAsStringSync(_driverSkeleton(
      library,
      relativeImport('bench/drivers', contractDir),
    ));
    stdout.writeln('wrote $driverRel (skeleton — implement show/update/hide/'
        'isStable per bench_contract_specs §1–§3)');
    driverClass = '${_pascal(library)}Driver';
  }
  if (driverClass == null) {
    stderr.writeln('FAIL: $driverRel exists but does not declare a class '
        'implementing LibraryDriver — cannot render the scenario files');
    return 1;
  }

  // Scenario files from the templates.
  final wanted = scenarios ?? kDefaultScenarios;
  final declared = <String>[];
  for (final id in wanted) {
    final templateName = _kScenarioTemplates[id];
    if (templateName == null) {
      if (id == 'size') {
        stdout.writeln('  size: S7 is not implemented in template v'
            '$kTemplateVersion yet — skipped');
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
      );
      target.writeAsStringSync(rendered);
      stdout.writeln('wrote $contractDir/$templateName');
    }
    declared.add(id);
  }

  // Manifest (never clobber without --force).
  final manifestFile = File('$root/$kManifestFileName');
  if (!manifestFile.existsSync() || force) {
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
''');
    stdout.writeln('wrote $kManifestFileName (template v$kTemplateVersion)');
  } else {
    stdout.writeln('$kManifestFileName exists — kept (use --force to '
        'regenerate)');
  }
  stdout.writeln('init done: library=$library, driverClass=$driverClass, '
      'scenarios=[${declared.join(', ')}]');
  return 0;
}

String _pascal(String s) {
  final parts = s.split(RegExp(r'[^a-zA-Z0-9]'))
    ..removeWhere((p) => p.isEmpty);
  return parts.map((p) => p[0].toUpperCase() + p.substring(1)).join();
}

String _driverSkeleton(String library, String apiImportRel) => '''
// ${library}_driver.dart — consumer driver skeleton (generated by contract
// init). Implement the verbs against your solution per bench_contract_specs
// §1–§3 (scene keys/geometry: package scene.dart; content: ContractCard).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_bench_contract/flutter_bench_contract.dart';

import '$apiImportRel/library_driver.dart';

class ${_pascal(library)}Driver implements LibraryDriver {
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
  if (driverClassOf(File('$root/${manifest.driver}')) !=
      manifest.driverClass) {
    stderr.writeln('FAIL: ${manifest.driver} does not declare '
        '${manifest.driverClass} implementing LibraryDriver');
    ok = false;
  }
  for (final id in manifest.scenarios) {
    final templateName = _kScenarioTemplates[id];
    if (templateName == null) {
      stderr.writeln('WARN: scenario "$id" has no template in v'
          '$kTemplateVersion');
      continue;
    }
    final file = File(
        '$root/${manifest.contractDir}/$templateName');
    if (!file.existsSync()) {
      stderr.writeln('FAIL: missing $file — run "contract init --force"');
      ok = false;
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
  final reportDir = '$root/build';
  Directory(reportDir).createSync(recursive: true);
  final reportPath = '$reportDir/contract_report.jsonl';
  final report = File(reportPath);
  report.writeAsStringSync('');

  var exitFailures = 0;
  for (final id in manifest.scenarios) {
    if (only != null && !only.contains(id)) continue;
    final templateName = _kScenarioTemplates[id];
    if (templateName == null) {
      if (id == 'size') {
        stdout.writeln('size (S7): host build measurement — not implemented '
            'in template v$kTemplateVersion; skipped');
      }
      continue;
    }
    final targetRel = '${manifest.contractDir}/$templateName';
    if (!File('$root/$targetRel').existsSync()) {
      stderr.writeln('FAIL: missing $targetRel — run "contract init --force"');
      exitFailures++;
      continue;
    }
    final runs = runsForScenario(id);
    for (var i = 1; i <= runs; i++) {
      stdout.writeln('==> $id (${device == null ? 'host' : 'device'}) '
          '— run $i/$runs');
      final ok = device == null
          ? await _runHost(report, root, targetRel)
          : await _runDevice(report, root, targetRel, device);
      if (!ok) exitFailures++;
    }
  }

  final samples = ReportFile(reportPath).samples;
  if (samples.isEmpty) {
    stderr.writeln('FAIL: no samples collected in $reportPath '
        '($exitFailures run failure(s))');
    return 1;
  }
  final measured = samples.keys.toList()..sort();
  stdout.writeln('samples: $measured (ref=$ref, $mode)');

  final store = GoldenStore(path: '$root/benchmarks.json');
  if (mode == 'record') {
    store.record(samples, ref: ref);
  } else {
    final failures = store.check(samples, ref: ref, slack: slack);
    if (failures > 0) return 1;
  }
  return exitFailures > 0 ? 1 : 0;
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
  run      run the manifest's declared scenarios and check/record goldens
           [--dir ROOT] [--device ID] [--mode check|record] [--ref android]
           [--slack 0.3] [--scenarios subset]
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
    _ => usage(),
  };
  exit(code);
}
