// The shared scene contract (spec §1): one neutral scene for every scenario.
// The solution's driver builds the scene with its own widgets; the structure
// (AppBar + element A + 12 rows with element B + scroll margin) and the
// keys below are the package's contract.
import 'package:flutter/material.dart';

// ── Geometry (spec §1) ────────────────────────────────────────────────────

/// Rows in the scene's ListView.
const int kSceneRowCount = 12;

/// Row index of element B (the anchor row).
const int kSceneBRow = 5;

/// Height of one row, in logical px.
const double kSceneRowHeight = 72;

/// `SizedBox` after the rows — guarantees `maxScrollExtent >= 1000` on any
/// target screen; a scenario whose scene cannot scroll that far is a scene
/// defect and fails instead of measuring an empty scroll.
const double kSceneScrollMargin = 1200;

// ── Keys (spec §1: the scenario finds A, B and the list by these) ─────────

/// Key of the scrollable list (`ScrollController` owner).
const String kSceneListKey = 'scene.list';

/// Key of element A — the fixed, tappable FloatingActionButton.
const String kSceneAKey = 'scene.a';

/// Key of row [index] (`kSceneBRow` = element B).
String sceneRowKey(int index) => 'scene.row.$index';

/// Builds the neutral contract scene (spec §1) for a [LibraryDriver]: the
/// AppBar + element A (FAB, increments [SceneSpec.aTaps]) + the ListView of
/// 12 rows (element B at `kSceneBRow`) + the scroll margin, all under a
/// MaterialApp. The consumer's driver supplies only the library-specific
/// parts:
///
/// - [wrapRow]: called once per row with the neutral row; the driver wraps
///   the rows its solution anchors (A/B are always rows [kSceneBRow] and the
///   driver's own second target). Called for every row so a driver can also
///   *replace* row content if its solution needs it.
/// - [wrapHome]: wraps the whole `MaterialApp.home` — for solutions that
///   need a live context / host above the scene (e.g. tcm's context
///   capture). Receives the neutral `Scaffold`.
/// - [navigatorObservers] / [appBuilder]: app-level wiring some solutions
///   need (dialog/toast hosts mount their overlay through MaterialApp's
///   `navigatorObservers`/`builder`). Passed through verbatim; the base
///   scene (S1) must leave them null so it does not touch the solution.
///
/// [withLibrary] selects the with-library vs the base scene; the base scene
/// (S1) must not touch the solution at all, so the driver must return the
/// neutral row/home unchanged when `withLibrary` is false.
Widget buildContractScene(
  SceneSpec spec, {
  required bool withLibrary,
  required Widget Function(int index, Widget row) wrapRow,
  Widget Function(Widget home)? wrapHome,
  ThemeData? theme,
  List<NavigatorObserver>? navigatorObservers,
  Widget Function(BuildContext, Widget?)? appBuilder,
}) {
  Widget neutralRow(int index) => SizedBox(
        key: Key(sceneRowKey(index)),
        height: kSceneRowHeight,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text('Row $index'),
        ),
      );

  final list = ListView(
    key: const Key(kSceneListKey),
    controller: spec.listScroll,
    children: [
      for (var i = 0; i < kSceneRowCount; i++) wrapRow(i, neutralRow(i)),
      const SizedBox(height: kSceneScrollMargin),
    ],
  );

  final scaffold = Scaffold(
    appBar: AppBar(title: const Text('Contract scene')),
    floatingActionButton: FloatingActionButton(
      key: const Key(kSceneAKey),
      onPressed: () => spec.aTaps.value++, // S6: tap on A after hide
      child: const Icon(Icons.add),
    ),
    body: list,
  );

  return MaterialApp(
    theme: theme ??
        ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          useMaterial3: true,
        ),
    navigatorObservers: navigatorObservers ?? const [],
    builder: appBuilder,
    home: wrapHome != null ? wrapHome(scaffold) : scaffold,
  );
}

/// Per-scene runtime handles (spec §1): created fresh per scene mount, owned
/// by the scenario (dispose in the test), wired by the driver's `buildScene`.
///
/// - [listScroll] must be attached to the scene's ListView — the scenario
///   scrolls the scene programmatically through it (S4), never by pointer
///   drags (overlays of some solutions consume pointer input; that is their
///   property, not the scenario's).
/// - [aTaps] must be incremented by element A's tap handler — the scenario
///   asserts the scene is interactive again after `hide()` (S6).
class SceneSpec {
  SceneSpec();

  /// Scroll controller of the scene list — owned by the scenario.
  final ScrollController listScroll = ScrollController();

  /// Tap counter of element A — owned by the scenario.
  final ValueNotifier<int> aTaps = ValueNotifier<int>(0);

  /// Releases the handles. Call in the test's teardown.
  void dispose() {
    listScroll.dispose();
    aTaps.dispose();
  }
}
