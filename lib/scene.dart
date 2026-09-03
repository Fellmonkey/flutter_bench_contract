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
