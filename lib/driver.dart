// The per-solution driver contract — the ONLY code a consumer writes: it
// builds the neutral scene with the solution's own widgets and maps the
// scenario verbs (show/update/hide) onto the solution. Everything else —
// scenario procedures, collectors, goldens, gates — belongs to the package.
//
// This file lives in lib/ (unlike in the early template design) because the
// scenario bodies that drive it are the package's own tests
// (lib/scenarios.dart): the package depends on flutter_test (precedent:
// golden_toolkit), so the driver contract can too. The consumer's DRIVER
// still lives consumer-side (bench/drivers/...): it imports the solution,
// which the package must never depend on.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'scene.dart';

/// Per-solution driver of the bench contract. Consumers implement this in a
/// driver file (e.g. bench/drivers/my_driver.dart) and the generated
/// scenario bridges pass an instance to [runContractScenario].
abstract class LibraryDriver {
  /// Solution name — the column label of reports/tables.
  String get name;

  /// Builds the neutral contract scene: `MaterialApp` (Material 3) with an
  /// `AppBar(title: 'Contract scene')`, a `ListView` of 12 rows (row 5 =
  /// element B, the anchor), a 1200 px scroll margin after the rows, and a
  /// fixed `FloatingActionButton` (element A). Keys and geometry are the
  /// package's constants (scene.dart); [spec.listScroll] must drive the
  /// ListView and element A must increment [SceneSpec.aTaps].
  ///
  /// [withLibrary] selects between two mounts of the same scene:
  ///   false — the base scene, the solution is absent from the tree (S1);
  ///   true  — the scene as the solution is really used, nothing shown (idle).
  Widget buildScene({required bool withLibrary, required SceneSpec spec});

  /// Mounts the content card `ContractCard(state)` by the solution's own
  /// mechanism (tooltip / toast / dialog / overlay). Contract: when this
  /// future completes, the content is on its way; the scenario decides when
  /// it is *stable* by pumping frames and polling [isStable].
  Future<void> show(int state);

  /// Switches the visible content to [state] without hiding first (S3).
  Future<void> update(int state);

  /// Removes the content: after `hide()` the card must leave the tree.
  Future<void> hide();

  /// Predicate "my work on the current step is finished" — NOT an action.
  /// The scenario owns pumping: it pumps a frame and polls this predicate
  /// until the timeout. Returning true means there is nothing more to pump
  /// (entrance/exit animation finished, state stable).
  bool isStable();

  /// The visible `ContractCard(state)` — the scenario asserts presence,
  /// absence and screen geometry through this finder.
  Finder currentContent(int state);

  /// Whether content follows element B under scroll (S4). Solutions without
  /// an anchor (toasts/popovers) return false → the scenario reports
  /// `unsupported`, it is not a failure and not a removal.
  bool get scrollCoupled;
}
