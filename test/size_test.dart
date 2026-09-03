// S7 size (lib/size.dart): the manifest `size:` config model and the
// host-build output parsers (analyze-size package-subtree bytes, web
// main.dart.js delta). No flutter build runs here — the byte arithmetic is
// the part that must be exact (goldens are SDK+ABI-pinned).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_bench_contract/flutter_bench_contract.dart';

/// A tree in the `flutter build apk --analyze-size` JSON shape: nodes carry
/// `n` (name), optional own `value`, optional `children` (the tool's own
/// DevTools summary format — container nodes can be value-less).
Map<String, dynamic> node(String name, {int? value, List<Object>? children}) =>
    {
      'n': name,
      if (value != null) 'value': value,
      if (children != null) 'children': children,
    };

void main() {
  group('SizeConfig.fromYaml', () {
    test('null when the section is absent', () {
      expect(SizeConfig.fromYaml(null), isNull);
    });

    test('native-only config', () {
      final config = SizeConfig.fromYaml({
        'native': {'package': 'hintful'},
      })!;
      expect(config.hasNative, isTrue);
      expect(config.hasWeb, isFalse);
      expect(config.nativePackage, 'hintful');
      expect(config.entry, SizeConfig.defaultEntry);
      expect(config.arch, SizeConfig.defaultArch);
    });

    test('web config with only `without` defaults `with` to the default '
        'target', () {
      final config = SizeConfig.fromYaml({
        'web': {'without': 'lib/main_baseline.dart'},
      })!;
      expect(config.hasWeb, isTrue);
      expect(config.webWithEntry, SizeConfig.defaultWebWith);
      expect(config.webWithout, 'lib/main_baseline.dart');
    });

    test('web-only config with explicit targets', () {
      final config = SizeConfig.fromYaml({
        'web': {'with': 'lib/main.dart', 'without': 'lib/main_baseline.dart'},
      })!;
      expect(config.hasNative, isFalse);
      expect(config.hasWeb, isTrue);
      expect(config.webWithEntry, 'lib/main.dart');
      expect(config.webWithout, 'lib/main_baseline.dart');
    });

    test('overrides of entry and arch', () {
      final config = SizeConfig.fromYaml({
        'native': {
          'package': 'hintful',
          'entry': 'lib/custom_main.dart',
          'arch': 'arm64',
        },
      })!;
      expect(config.entry, 'lib/custom_main.dart');
      expect(config.arch, 'arm64');
    });

    test('rejects a non-map section', () {
      expect(() => SizeConfig.fromYaml('nope'), throwsFormatException);
      expect(
          () => SizeConfig.fromYaml({
                'native': 'not-a-map',
              }),
          throwsFormatException);
    });
  });

  group('packageSubtreeBytes', () {
    test('sums own value and every descendant', () {
      // Mirror of the real apk-code-size-analysis JSON: package:hintful is a
      // value-less container whose leaves carry the bytes.
      final tree = node('Root', children: [
        node('lib', value: 1000),
        node('package:hintful', children: [
          node('lib/hintful.dart', value: 50000),
          node('lib/tooltip.dart', value: 20000),
          node('assets', value: 2669),
        ]),
      ]);
      expect(packageSubtreeBytes(tree, 'hintful'), 72669);
    });

    test('returns null when the package node is missing', () {
      final tree = node('Root', children: [node('package:other', value: 5)]);
      expect(packageSubtreeBytes(tree, 'hintful'), isNull);
    });

    test('packageSubtreeBytesFromJson decodes text first', () {
      final tree = node('Root', children: [node('package:foo', value: 42)]);
      expect(packageSubtreeBytesFromJson(jsonEncode(tree), 'foo'), 42);
      expect(packageSubtreeBytesFromJson('not json', 'foo'), isNull);
    });
  });

  group('analysisPathFromBuildOutput', () {
    test('extracts the sentinel path from flutter build output', () {
      const output = 'Gradle build output noise...\n'
          'A summary of your APK analysis can be found at: '
          '/home/user/.flutter-devtools/apk-code-size-analysis_12.json\n'
          'more noise';
      expect(analysisPathFromBuildOutput(output),
          '/home/user/.flutter-devtools/apk-code-size-analysis_12.json');
    });

    test('null when no sentinel line', () {
      expect(analysisPathFromBuildOutput('no summary here'), isNull);
    });
  });
}
