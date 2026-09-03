// GENERATED from flutter_bench_contract (template v1) — do not edit by hand.
// Regenerate: dart run flutter_bench_contract:contract init --force
//
// The driver contract (bench_contract_specs §3). This file is copied into
// the consumer (NOT into the published package's lib/): the driver runs in
// the flutter_test context and returns flutter_test types, which must not
// become a dependency of the published package.
//
// The driver is the ONLY code a consumer writes: it builds the neutral scene
// with the solution's own widgets and maps the scenario verbs
// (show/update/hide) onto the solution. Everything else — scenario
// procedures, collectors, goldens, gates — belongs to the package.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_bench_contract/flutter_bench_contract.dart';

/// Per-solution driver of the bench contract.
abstract class LibraryDriver {
  /// Solution name — the column label of reports/tables.
  String get name;

  /// Builds the neutral contract scene (spec §1): `MaterialApp` (Material 3)
  /// with `AppBar(title: 'Contract scene')`, a `ListView` of 12 rows (row 5
  /// = element B, the anchor), a 1200 px scroll margin after the rows, and a
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
  /// The scenario owns pumping (spec Р7): it pumps a frame and polls this
  /// predicate until the 10 s timeout. Returning true means there is
  /// nothing more to pump (entrance/exit animation finished, state stable).
  bool isStable();

  /// The visible `ContractCard(state)` — the scenario asserts presence,
  /// absence and screen geometry through this finder.
  Finder currentContent(int state);

  /// Whether content follows element B under scroll (S4). Solutions without
  /// an anchor (toasts/popovers) return false → the scenario reports
  /// `unsupported`, it is not a failure and not a removal.
  bool get scrollCoupled;
}
