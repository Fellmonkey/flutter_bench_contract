// S7 `size` — the host-build size scenario. Pure parse/config
// side: what a consumer declares in the manifest `size:` section and how
// the two platform measurements read their outputs.
//
// Two legs, both release host builds (no device), both deterministic per
// SDK+ABI (so their goldens are SDK-pinned):
//
//   native  — `flutter build apk --release --analyze-size` on the app that
//             imports the solution; the code-size JSON tree is walked for
//             the `package:<solution>` node and its subtree bytes summed —
//             that IS the solution's AOT contribution (tree-shaken, so the
//             node holds exactly the solution's code that survived).
//             Metric id: `native_size`.
//   web     — two `flutter build web --release` targets (a structurally
//             identical scene with and without the solution), diffed on
//             main.dart.js. Metric id: `bundle_delta`.
//
// The driver-facing orchestration (flutter subprocesses, golden check /
// record) lives in bin/contract.dart (`contract size`); this module holds
// the config model and the output parsers, so the byte-arithmetic is
// unit-testable without any build.
import 'dart:convert';

/// Config of the optional `size:` manifest section (S7). Each leg is
/// optional: the consumer declares the legs it ships.
class SizeConfig {
  const SizeConfig({this.nativePackage, this.nativeEntry, this.nativeArch,
      this.webWith, this.webWithout});

  /// Solution's pub package name (native leg): the analyze-size tree node
  /// `package:<this>` is summed. Null → the native leg is not declared.
  final String? nativePackage;

  /// App target that imports the solution (native analyze-size build).
  /// Default: `lib/main.dart` (the default apk target).
  final String? nativeEntry;

  /// Android ABI of the native analyze-size build.
  /// Default: `x64` (the cheapest single-ABI build; deterministic per ABI).
  final String? nativeArch;

  /// Web target WITH the solution. Null → the web leg is not declared.
  final String? webWith;

  /// Web target WITHOUT the solution (the structurally identical baseline).
  /// Required for the web leg.
  final String? webWithout;

  /// Whether the consumer declared the native leg.
  bool get hasNative => nativePackage != null && nativePackage!.isNotEmpty;

  /// Whether the consumer declared the web leg (with + without targets).
  bool get hasWeb => webWith != null && webWithout != null;

  /// Default app target of the native analyze-size build.
  static const String defaultEntry = 'lib/main.dart';

  /// Default android ABI.
  static const String defaultArch = 'x64';

  /// Default web target that imports the solution.
  static const String defaultWebWith = 'lib/main.dart';

  String get entry => nativeEntry ?? defaultEntry;
  String get arch => nativeArch ?? defaultArch;
  String get webWithEntry => webWith ?? defaultWebWith;

  /// Parses the `size:` map of the manifest; null when the section is
  /// absent (S7 not declared).
  static SizeConfig? fromYaml(dynamic doc) {
    if (doc == null) return null;
    if (doc is! Map) {
      throw FormatException('size: must be a map {native?, web?}');
    }
    Map<String, String>? sub(String key) {
      final v = doc[key];
      if (v == null) return null;
      if (v is! Map) throw FormatException('size.$key must be a map');
      return {
        for (final e in v.entries)
          if (e.value is String) e.key: e.value,
      };
    }

    final native = sub('native');
    final web = sub('web');
    return SizeConfig(
      nativePackage: native?['package'],
      nativeEntry: native?['entry'],
      nativeArch: native?['arch'],
      // A declared `web:` map defaults `with` to the default target (like
      // native's entry): consumers with the with-target at lib/main.dart
      // only declare the baseline.
      webWith: web == null ? null : (web['with'] ?? defaultWebWith),
      webWithout: web?['without'],
    );
  }
}

/// Sums the bytes of the `package:<package>` subtree of an analyze-size
/// JSON tree: the node's own `value` (null on pure containers) plus every
/// descendant's value, exactly as the DevTools size analysis accounts bytes.
///
/// Returns null when no such node exists (the app does not import the
/// solution under that pub package name).
int? packageSubtreeBytes(dynamic tree, String package) {
  if (tree is! Map<String, dynamic>) return null;
  final node = _findNode(tree, 'package:$package');
  if (node == null) return null;
  return _sumNode(node);
}

Map<String, dynamic>? _findNode(Map<String, dynamic> node, String name) {
  if (node['n'] == name) return node;
  final children = node['children'];
  if (children is List) {
    for (final child in children) {
      if (child is! Map) continue;
      final found = _findNode(child.cast<String, dynamic>(), name);
      if (found != null) return found;
    }
  }
  return null;
}

int _sumNode(Map<String, dynamic> node) {
  final value = node['value'];
  var sum = value is int ? value : 0;
  final children = node['children'];
  if (children is List) {
    for (final child in children) {
      if (child is Map) sum += _sumNode(child.cast<String, dynamic>());
    }
  }
  return sum;
}

/// Decodes an analyze-size JSON file's text and sums the solution subtree.
int? packageSubtreeBytesFromJson(String jsonText, String package) {
  final dynamic doc;
  try {
    doc = jsonDecode(jsonText);
  } on FormatException {
    return null;
  }
  if (doc is! Map<String, dynamic>) return null;
  return packageSubtreeBytes(doc, package);
}

/// Extracts the code-size analysis path from `flutter build --analyze-size`
/// output — the tool prints a sentinel line pointing at the JSON it wrote.
///
/// `A summary of your APK analysis can be found at: <path>.json`
String? analysisPathFromBuildOutput(String output) {
  final m = RegExp(
          r'A summary of your [A-Za-z]+ analysis can be found at: (.+?\.json)')
      .firstMatch(output);
  return m?.group(1);
}

/// Parses a `main.dart.js` size out of a web build output directory's
/// manifest-ish file listing, falling back to direct byte counting by the
/// CLI (which owns the file paths). Kept here so the size unit is one
/// definition.
const String webMainJsFile = 'main.dart.js';
