// The contract scenarios — the "smart bench", living here ONCE in the
// package instead of being copied into every consumer. Each scenario is a
// self-contained testWidgets body that drives a [LibraryDriver] through the
// verbs and asserts that the action really happened (content shown, content
// following a scrolled target, nothing leaking after hide), then reports
// its metric on the HINTFUL_BENCH_JSON envelope.
//
// Why this file imports flutter_test (a package dependency, precedent:
// golden_toolkit): the scenario bodies ARE tests — WidgetTester pumping is
// the measurement clock. The package publishes the bodies so consumers
// cannot edit them (anti-tuning: a scenario change is a package version
// bump, not a consumer edit); consumers run them through tiny generated
// bridges (bench/contract/sN_*_test.dart) that only pass their driver:
//
//   void main() => runContractScenario('show_latency', driver: MyDriver());
//
// Protocol constants (timeouts, warm-ups) are the package's methodology —
// identical for every consumer; a consumer can never redefine them.
//
// The per-scenario bridge keeps each scenario in its OWN `flutter test`
// process (fresh app/heap per scenario), which is why `contract run`
// executes one file per scenario rather than one file for all.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'collectors.dart';
import 'driver.dart';
import 'report.dart';
import 'scene.dart';

// ── Shared protocol (methodology) ─────────────────────────────────────────

/// 10 s wall timeout, pumped at a 16 ms frame budget.
const int _kTimeoutFrames = 625;

/// Content state of the first shown card (S2).
const int _kState = 1;

/// Warm-up cycles before heap/instance sampling (S1r/S5/S6).
const int _kWarmups = 3;

/// Measured show/hide cycles of S5/S6 (per-cycle heap baseline).
const int _kMeasuredCycles = 3;

/// Retries when heap floor moves mid-measurement; only a result
/// unphysical on every attempt is treated as degraded (n/a).
const int _kHeapAttempts = 3;

/// Below this per-cycle delta the sample is unphysical: idle→show in KB
/// cannot release MB — the heap floor moved (GC), not retention.
const int _kUnphysicalDriftBytes = -(1 << 20); // -1 MiB

/// Above this per-cycle delta the sample is unphysical (positive floor
/// jump). S5 can legitimately be hundreds of KB; 4 MiB is the absolute
/// ceiling — a `ContractCard` show never costs MB in Dart heap. S6
/// hide_retention should be ~0, so +1 MiB is already unphysical.
const int _kUnphysicalUpperS5 = 4 << 20; // +4 MiB
const int _kUnphysicalUpperS6 = 1 << 20; // +1 MiB

/// Samples and range for the pre-measurement floor-stabilization gate.
const int _kHeapStabilizeSamples = 5;
const int _kHeapStabilizeRange = 512 * 1024; // 512 KiB
const int _kHeapStabilizeAttempts = 3;

/// True if [delta] is outside the physical envelope. Uses absolute
/// bounds: `delta < -1 MiB` or `delta > upper`. Adaptive `golden*3+MAD`
/// is intentionally not in-scenario (no golden here) — stabilization
/// before measurement does the heavy lifting; the guard is only the
/// last defence against a mid-cycle floor jump.
bool _isUnphysical(int delta, int upper) =>
    delta < _kUnphysicalDriftBytes || delta > upper;

/// Floor-stabilization gate: sample the heap `5×` with forced GC and
/// require `max-min < 512 KiB`. Catches a settling floor *before*
/// measured cycles start, so `+3.4 MB` / `-10 MB` hallucinations rarely
/// reach the per-cycle baseline at all. Best-effort — no VM service → no-op.
Future<void> _stabilizeHeap(WidgetTester tester, VmServiceHeap? heap) async {
  if (heap == null) return;
  for (var attempt = 0; attempt < _kHeapStabilizeAttempts; attempt++) {
    final samples = <int>[];
    for (var i = 0; i < _kHeapStabilizeSamples; i++) {
      final v = await heap.usedBytesMedian();
      if (v == null) return;
      samples.add(v);
      await tester.pump(const Duration(milliseconds: 100));
    }
    samples.sort();
    final range = samples.last - samples.first;
    if (range < _kHeapStabilizeRange) return;
    await tester.pumpAndSettle();
    await heap.usedBytes(); // one extra GC probe to let late GC land
  }
}

/// Registers the test body of contract scenario [scenarioId] with
/// [driver]. Called synchronously from a generated bridge's `main()` —
/// exactly one scenario per process.
void runContractScenario(
  String scenarioId, {
  required LibraryDriver driver,
  List<String> idleClasses = const [],
}) {
  switch (scenarioId) {
    case 'idle_zero':
      _s1IdleZero(driver);
    case 'idle_resources':
      _s1rIdleResources(driver, idleClasses);
    case 'show_latency':
      _s2ShowLatency(driver);
    case 'update_latency':
      _s3UpdateLatency(driver);
    case 'scroll_coupled':
      _s4ScrollCoupled(driver);
    case 'active_heap':
      _s5ActiveHeap(driver);
    case 'hide_retention':
      _s6HideRetention(driver);
    default:
      throw ArgumentError.value(scenarioId, 'scenarioId',
          'unknown contract scenario — expected one of: idle_zero, '
          'idle_resources, show_latency, update_latency, scroll_coupled, '
          'active_heap, hide_retention');
  }
}

/// Pumps until `ContractCard([state])` is visible and the driver is stable.
/// The scenario owns pumping (the driver cannot smear the delay).
Future<void> _showStable(
    WidgetTester tester, LibraryDriver driver, int state, String tag) async {
  await driver.show(state);
  for (var i = 0; i < _kTimeoutFrames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (driver.currentContent(state).evaluate().isNotEmpty &&
        driver.isStable()) {
      return;
    }
  }
  fail('$tag: show($state) did not become visible and stable within 10 s');
}

/// Pumps until `ContractCard([state])` left the tree after `hide()`.
Future<void> _hideGone(
    WidgetTester tester, LibraryDriver driver, int state, String tag) async {
  await driver.hide();
  for (var i = 0; i < _kTimeoutFrames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (driver.currentContent(state).evaluate().isEmpty) {
      return;
    }
  }
  fail('$tag: content $state still present after hide()');
}

// ── S1 idle_zero ──────────────────────────────────────────────────────────

/// S1: how many tree elements the solution adds when nothing is shown —
/// the difference between the base scene (no solution) and the with-solution
/// idle scene. "0" is true zero-idle. The count walks the live element
/// tree; there is no self-report the solution could tune.
void _s1IdleZero(LibraryDriver driver) {
  testWidgets('S1 idle_zero', (tester) async {
    // (1) Base scene without the solution → n0.
    final baseSpec = SceneSpec();
    addTearDown(baseSpec.dispose);
    await tester.pumpWidget(driver.buildScene(withLibrary: false, spec: baseSpec));
    await tester.pumpAndSettle();
    final n0 = _countElements(tester);

    // (2) Idle scene with the solution, twice (determinism assert below).
    final idleSpec1 = SceneSpec();
    addTearDown(idleSpec1.dispose);
    await tester
        .pumpWidget(driver.buildScene(withLibrary: true, spec: idleSpec1));
    await tester.pumpAndSettle();
    final n1a = _countElements(tester);

    final idleSpec2 = SceneSpec();
    addTearDown(idleSpec2.dispose);
    await tester
        .pumpWidget(driver.buildScene(withLibrary: true, spec: idleSpec2));
    await tester.pumpAndSettle();
    final n1b = _countElements(tester);

    // Determinism: two independent idle mounts must give the same diff —
    // otherwise the scene (or the solution) is not stable enough to measure.
    expect(n1a, n1b,
        reason: 'S1: idle mounts differ (n1a=$n1a, n1b=$n1b) — the scene is '
            'not deterministic');

    final idleDiff = n1a - n0;
    // Numeric gate: recorded golden (idleDiff ≤ golden ± 1) — checked by the
    // CLI against benchmarks.json, not asserted here. Solutions with honest
    // idle wrappers (thin coach-mark target wrappers) legitimately show a
    // non-zero diff — that is their integration model, visible in the table.
    reportMetric('idle_zero', idleDiff, extra: {'n0': n0, 'n1': n1a});
  });
}

/// Live element count of the whole mounted tree (walk, no self-report).
int _countElements(WidgetTester tester) {
  final root = tester.binding.rootElement!;
  var count = 0;
  void walk(Element e) {
    count++;
    e.visitChildren(walk);
  }

  walk(root);
  return count;
}

// ── S1r idle_resources ────────────────────────────────────────────────────

/// S1r (option `idleClasses:`): declared classes (controller, registry,
/// listeners) must return to baseline after warm-up + hide() — a class leak
/// must not hide behind a heap delta.
///
/// [idleClasses] declared → count live instances per class before/after
/// (exact assert 0, in-test two-sided). Not declared → M1 diagnostic only
/// (top-class growth print), nothing recorded.
void _s1rIdleResources(LibraryDriver driver, List<String> idleClasses) {
  testWidgets('S1r idle_resources', (tester) async {
    final spec = SceneSpec();
    addTearDown(spec.dispose);
    await tester.pumpWidget(driver.buildScene(withLibrary: true, spec: spec));
    await tester.pumpAndSettle();

    // runAsync: Service.getInfo() is an engine call that never completes in
    // the FakeAsync zone of a plain `flutter test` run (it would hang the
    // host); real-async contexts (device, integration binding) are unaffected.
    final heap = await tester.runAsync(VmServiceHeap.connect);
    final precise = heap != null && idleClasses.isNotEmpty;

    Map<String, int>? before;
    Map<String, int>? topBefore;
    if (heap != null) {
      if (precise) {
        before = await _countDeclared(heap, idleClasses);
      } else {
        topBefore = {
          for (final (name, bytes) in await heap.topClasses()) name: bytes
        };
      }
    }

    // Protocol warm-up (methodology): M show→hide cycles.
    for (var i = 0; i < _kWarmups; i++) {
      await _showStable(tester, driver, 1, 'S1r');
      await _hideGone(tester, driver, 1, 'S1r');
    }
    await tester.pumpAndSettle();

    if (precise) {
      final after = await _countDeclared(heap, idleClasses);
      if (before == null || after == null) {
        await heap.dispose();
        // ignore: avoid_print
        print('S1r: VM-service counting failed — degraded, not measured');
        reportMetric('idle_resources', null,
            extra: {'status': 'degraded', 'reason': 'getInstances failed'});
        return;
      }
      // Per-class deltas after warm-up + hide; the scenario metric is the
      // max; the gate is exact.
      final deltas = <(String, int)>[
        for (final name in idleClasses)
          (name, (after[name] ?? 0) - (before[name] ?? 0)),
      ];
      final maxDelta = deltas.map((d) => d.$2).fold<int>(0,
          (a, b) => a > b ? a : b);
      await heap.dispose();
      // ignore: avoid_print
      print('S1r per-class deltas (after−baseline): ${deltas.join(', ')}');
      reportMetric('idle_resources', maxDelta);
      expect(maxDelta, 0,
          reason: 'declared idle classes must return to baseline after '
              'warm-up + hide() — ${deltas.join(', ')}');
    } else {
      // M1 diagnostic: no VM service or no idleClasses declared — classes
      // whose retained bytes grew after the protocol stay visible even
      // before per-class counting, and the reason is reported as degraded.
      String? reason;
      if (heap == null) {
        reason = 'no VM service';
      } else {
        final topAfter = {
          for (final (name, bytes) in await heap.topClasses()) name: bytes
        };
        final growth = <(String, int)>[
          for (final e in topAfter.entries)
            if ((e.value - (topBefore?[e.key] ?? 0)) > 0) (e.key, e.value),
        ]..sort((a, b) => b.$2.compareTo(a.$2));
        if (growth.isNotEmpty) {
          // ignore: avoid_print
          print('S1r diagnostic — top retained classes after warm-up+hide: '
              '${growth.take(10).join(', ')}');
        }
        reason = 'no idleClasses declared (manifest)';
        await heap.dispose();
      }
      // ignore: avoid_print
      print('S1r: $reason — idle_resources not measured');
      reportMetric('idle_resources', null,
          extra: {'status': 'degraded', 'reason': reason});
    }
  });
}

/// Live-instance counters for every [classes] entry, after a forced GC;
/// null when any VM-service call failed (degrade to the diagnostic path).
Future<Map<String, int>?> _countDeclared(
    VmServiceHeap heap, List<String> classes) async {
  final counts = <String, int>{};
  for (final name in classes) {
    final n = await heap.instancesOfClass(name);
    if (n == null) return null;
    counts[name] = n;
  }
  return counts;
}

// ── S2 show_latency ───────────────────────────────────────────────────────

/// S2: wall ms from `show(1)` to the frame where ContractCard(1) is visible
/// and stable. The show is cold — no show has happened before, so the price
/// is the honest first-show cost (no warm-up). Timing is wall-clock; the
/// scenario owns pumping (the driver cannot smear the delay by spreading it
/// over frames — a smeared transition IS a large wall delay).
void _s2ShowLatency(LibraryDriver driver) {
  testWidgets('S2 show_latency', (tester) async {
    final spec = SceneSpec();
    addTearDown(spec.dispose);

    await tester.pumpWidget(driver.buildScene(withLibrary: true, spec: spec));
    await tester.pumpAndSettle();

    final t0 = DateTime.now();
    await driver.show(_kState);
    var stable = false;
    for (var i = 0; i < _kTimeoutFrames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (driver.currentContent(_kState).evaluate().isNotEmpty &&
          driver.isStable()) {
        stable = true;
        break;
      }
    }
    final elapsedMs = DateTime.now().difference(t0).inMicroseconds / 1000.0;

    // Assert: the content really appeared and stabilized before the timeout.
    expect(stable, isTrue,
        reason: 'S2: ContractCard($_kState) not visible and stable within '
            '10 s (content found='
            '${driver.currentContent(_kState).evaluate().isNotEmpty}, '
            'isStable()=${driver.isStable()})');

    // The CLI repeats this scenario (BENCH_RUNS=3, methodology) and the
    // report reducer takes the median — one sample per run here.
    reportMetric('show_latency', elapsedMs.round());

    // No traces: after hide() the card must leave the tree.
    await driver.hide();
    var gone = false;
    for (var i = 0; i < _kTimeoutFrames; i++) {
      if (driver.currentContent(_kState).evaluate().isEmpty) {
        gone = true;
        break;
      }
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(gone, isTrue,
        reason: 'S2: ContractCard($_kState) still present after hide()');

    await _asyncTeardownSettle(tester);
  });
}

// ── S3 update_latency ─────────────────────────────────────────────────────

/// S3: wall ms from `update(state)` to the frame where the NEW
/// ContractCard is visible, the OLD one is gone and the state is stable.
/// Three transitions per run, the metric is their median — a smeared
/// transition cannot win: wall time is paid by whoever transitions.
void _s3UpdateLatency(LibraryDriver driver) {
  testWidgets('S3 update_latency', (tester) async {
    final spec = SceneSpec();
    addTearDown(spec.dispose);

    await tester.pumpWidget(driver.buildScene(withLibrary: true, spec: spec));
    await tester.pumpAndSettle();

    // S2 brings the scene to a shown state 1.
    await _showStable(tester, driver, 1, 'S3');

    // Three transitions 1→2, 2→1, 1→2 — the metric is their median.
    final ms = <double>[
      await _transitionMs(tester, driver, 1, 2),
      await _transitionMs(tester, driver, 2, 1),
      await _transitionMs(tester, driver, 1, 2),
    ];
    reportMetric('update_latency', medianOf(ms).round(),
        extra: {'transitions_ms': ms.map((m) => m.round()).toList()});

    // No traces: after hide() the card must leave the tree.
    await _hideGone(tester, driver, 2, 'S3');

    await _asyncTeardownSettle(tester);
  });
}

/// One `update()` transition: pumps until the new content is visible, the
/// old is gone and the driver reports stability. Returns wall ms.
Future<double> _transitionMs(
  WidgetTester tester,
  LibraryDriver driver,
  int from,
  int to,
) async {
  final t0 = DateTime.now();
  await driver.update(to);
  for (var i = 0; i < _kTimeoutFrames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    final newVisible = driver.currentContent(to).evaluate().isNotEmpty;
    final oldGone = driver.currentContent(from).evaluate().isEmpty;
    if (newVisible && oldGone && driver.isStable()) {
      return DateTime.now().difference(t0).inMicroseconds / 1000.0;
    }
  }
  fail('S3: update($to) did not replace content $from within 10 s '
      '(newVisible='
      '${driver.currentContent(to).evaluate().isNotEmpty}, '
      'oldGone=${driver.currentContent(from).evaluate().isEmpty}, '
      'isStable()=${driver.isStable()})');
}

// ── S4 scroll_coupled ─────────────────────────────────────────────────────

/// S4: content anchored to element B must ride with B under a programmatic
/// scroll — correctness (two-sided assert) and the actual scroll cost as
/// diagnostics. Solutions without an anchor (toasts/popovers) declare
/// scrollCoupled: false → `unsupported` in the report (visible, never a
/// failure, never a removal).
void _s4ScrollCoupled(LibraryDriver driver) {
  testWidgets('S4 scroll_coupled', (tester) async {
    if (!driver.scrollCoupled) {
      // Unsupported is a visible report entry, not a failure and not a
      // removal.
      reportMetric('scroll_coupled', null,
          extra: {'status': 'unsupported', 'reason': 'no anchor to a target'});
      return;
    }

    final spec = SceneSpec();
    addTearDown(spec.dispose);
    await tester.pumpWidget(driver.buildScene(withLibrary: true, spec: spec));
    await tester.pumpAndSettle();

    await _showStable(tester, driver, 1, 'S4');

    // Measure relative to B itself, so the scene's own movement is the
    // reference: content follows ⇔ card delta == B delta (ε = 1 px).
    const scrollDelta = -400.0; // B moves UP = offset grows by 400.
    const epsilon = 1.0; // logical px
    final position = spec.listScroll.position;
    final bFinder = find.byKey(Key(sceneRowKey(kSceneBRow)));
    final cardFinder = driver.currentContent(1);

    final beforeB = tester.getRect(bFinder);
    final beforeCard = tester.getRect(cardFinder);

    // Scroll the scene by |scrollDelta| (B moves up). A children-based
    // ListView estimates maxScrollExtent from the laid-out children only and
    // RECLAIMS the estimate whenever the list returns near its top, so an
    // absolute jump target would clamp to ~one viewport and silently
    // under-scroll. Advance in small steps instead: each jump lays out the
    // newly revealed rows and grows the estimate, so a healthy scene reaches
    // the full delta in a few pumps — and a scene whose real extent is
    // shorter than the delta stalls at its bottom, which the B-delta assert
    // below reports as a scene defect.
    final targetOffset = position.pixels + scrollDelta.abs();
    while (position.pixels < targetOffset) {
      final before = position.pixels;
      final step = math.min(150.0, targetOffset - before);
      position.jumpTo(before + step);
      await tester.pump();
      if (position.pixels - before < 0.01) break; // clamped at the end
    }
    await tester.pumpAndSettle();

    final afterB = tester.getRect(bFinder);
    final afterCard = tester.getRect(cardFinder);

    // Assert the scroll really happened (B moved by ≈ -400). This doubles
    // as the scene-defect guard: a scene that cannot scroll this far fails
    // here loudly, instead of measuring an empty scroll.
    final bDelta = afterB.topLeft.dy - beforeB.topLeft.dy;
    expect((bDelta - scrollDelta).abs() <= 1.0, isTrue,
        reason: 'S4: scene defect — B moved $bDelta px, expected '
            '$scrollDelta (scroll did not go through)');

    // The contract assert (two-sided, cannot be disabled): content followed
    // B within ε. Snapshot-positioned content gives Δ≈0 → fails here.
    final cardDelta = afterCard.topLeft.dy - beforeCard.topLeft.dy;
    final error = (cardDelta - bDelta).abs();
    expect(error <= epsilon, isTrue,
        reason: 'S4: card did not follow B — card moved $cardDelta px, B '
            'moved $bDelta px (error $error px > ε=$epsilon)');

    reportMetric('scroll_coupled', null,
        extra: {'status': 'ok', 'b_delta_px': bDelta, 'card_delta_px': cardDelta});

    // Back-scroll (offset 0) — diagnostics frames are collected by the
    // device runner; here only correctness is asserted.
    spec.listScroll.jumpTo(0);
    await tester.pumpAndSettle();
    await _hideGone(tester, driver, 1, 'S4');

    await _asyncTeardownSettle(tester);
  });
}

// ── S5 active_heap ────────────────────────────────────────────────────────

/// S5: retained-heap delta idle→shown. Needs VM service; without it
/// the sample is degraded (null) and only "content shown" is asserted.
/// Per-cycle idle baseline; if every attempt is unphysical the result is
/// degraded (n/a), not a failure.
void _s5ActiveHeap(LibraryDriver driver) {
  testWidgets('S5 active_heap', (tester) async {
    final spec = SceneSpec();
    addTearDown(spec.dispose);

    await tester.pumpWidget(driver.buildScene(withLibrary: true, spec: spec));
    await tester.pumpAndSettle();

    // Warm-up (methodology): M show→hide cycles settle caches, so the
    // measured points are post-warm-up states.
    for (var i = 0; i < _kWarmups; i++) {
      await _showStable(tester, driver, 1, 'S5');
      await _hideGone(tester, driver, 1, 'S5');
    }
    await tester.pumpAndSettle();

    // runAsync: Service.getInfo() is an engine call that never completes in
    // the FakeAsync zone of a plain `flutter test` run (it would hang the
    // host); real-async contexts (device, integration binding) are unaffected.
    final heap = await tester.runAsync(VmServiceHeap.connect);
    await _stabilizeHeap(tester, heap);

    // Per-cycle idle baseline (median of 3 GC reads) before each show;
    // cancels a settling floor. On unphysical delta retry with GC settle
    // up to _kHeapAttempts times.
    int? delta;
    var attempt = 0;
    List<int> deltas = [];
    List<int> idles = [];
    List<int> actives = [];
    for (; attempt < _kHeapAttempts; attempt++) {
      deltas = <int>[];
      idles = <int>[];
      actives = <int>[];
      for (var i = 0; i < _kMeasuredCycles; i++) {
        await tester.pumpAndSettle();
        final idle = heap == null ? null : await heap.usedBytesMedian();
        await _showStable(tester, driver, 1, 'S5');
        await tester.pumpAndSettle();
        expect(driver.currentContent(1).evaluate().isNotEmpty, isTrue,
            reason: 'S5: content not visible at the active heap point');
        final active = heap == null ? null : await heap.usedBytesMedian();
        if (idle != null && active != null) {
          idles.add(idle);
          actives.add(active);
          deltas.add(active - idle);
        }
        await _hideGone(tester, driver, 1, 'S5');
      }
      delta = deltas.isEmpty
          ? null
          : (deltas.reduce((a, b) => a + b) / deltas.length).round();
      // Accept a null (no VM service — degraded) or a physical delta; retry
      // only an unphysical one, while attempts remain.
      if (delta == null || !_isUnphysical(delta, _kUnphysicalUpperS5)) break;
      if (attempt == _kHeapAttempts - 1) break; // exhausted — guard below fires
      // ignore: avoid_print
      print('S5: attempt ${attempt + 1}/$_kHeapAttempts unphysical '
          '(delta=$delta B) — floor moved, forcing GC and re-measuring');
      await tester.pumpAndSettle();
      await heap?.usedBytes(); // one GC'd probe read to let late GC land
    }

    // Unphysical on every attempt — measurement defect, not retention.
    // Degrade gracefully (n/a) instead of failing. Symmetric guard:
    // negative (<-1 MiB) or positive (>+4 MiB) floor jump.
    if (delta != null && _isUnphysical(delta, _kUnphysicalUpperS5)) {
      final top =
          heap == null ? const <(String, int)>[] : await heap.topClasses();
      final topDesc = top.isEmpty
          ? '(no VM profile)'
          : top.take(8).map((t) => '${t.$1}=${t.$2}').join(', ');
      // ignore: avoid_print
      print('S5: unphysical delta $delta B on all $_kHeapAttempts attempts '
          '(floor moved) — degraded; idles=$idles actives=$actives top: $topDesc');
      reportMetric('active_heap', null, extra: {
        'status': 'unphysical',
        'reason': 'floor moved',
        'deltas_bytes': deltas,
        'idle_bytes': idles,
        'active_bytes': actives,
      });
      if (heap != null) await heap.dispose();
      await _asyncTeardownSettle(tester);
      return;
    }

    if (delta == null) {
      // ignore: avoid_print
      print('S5: no VM service (run with flutter drive --no-dds --profile) '
          '— heap delta not measured');
    }
    reportMetric('active_heap', delta,
        extra: delta == null
            ? const {'status': 'degraded'}
            : {
                'deltas_bytes': deltas,
                'idle_bytes': idles,
                'active_bytes': actives,
              });

    if (heap != null) await heap.dispose();

    await _asyncTeardownSettle(tester);
  });
}

// ── S6 hide_retention ─────────────────────────────────────────────────────

/// S6: (a) no heap growth per show/hide cycle, (b) tree returns exactly
/// to idle snapshot, (c) scene stays interactive (tap on A lands).
/// Heap drift degrades to null without VM service; (b) and (c) always run.
/// Per-cycle idle baseline; if every attempt is unphysical the result is
/// degraded (n/a), not a failure.
void _s6HideRetention(LibraryDriver driver) {
  testWidgets('S6 hide_retention', (tester) async {
    final spec = SceneSpec();
    addTearDown(spec.dispose);

    await tester.pumpWidget(driver.buildScene(withLibrary: true, spec: spec));
    await tester.pumpAndSettle();

    // (b) reference: the idle snapshot before the first show.
    final idleSnapshot = _fingerprint(tester);

    // Warm-up (methodology).
    for (var i = 0; i < _kWarmups; i++) {
      await _showStable(tester, driver, 1, 'S6');
      await _hideGone(tester, driver, 1, 'S6');
    }
    await tester.pumpAndSettle();

    // runAsync: Service.getInfo() is an engine call that never completes in
    // the FakeAsync zone of a plain `flutter test` run (it would hang the
    // host); real-async contexts (device, integration binding) are unaffected.
    final heap = await tester.runAsync(VmServiceHeap.connect);
    await _stabilizeHeap(tester, heap);

    // Per-cycle idle baseline (median of 3 GC reads) before each show;
    // cancels a settling floor. On unphysical drift retry with GC settle
    // up to _kHeapAttempts times.
    var attempt = 0;
    List<int> drifts = [];
    List<int> pres = [];
    List<int> posts = [];
    for (; attempt < _kHeapAttempts; attempt++) {
      drifts = <int>[];
      pres = <int>[];
      posts = <int>[];
      for (var i = 0; i < _kMeasuredCycles; i++) {
        await tester.pumpAndSettle();
        final pre = heap == null ? null : await heap.usedBytesMedian();
        await _showStable(tester, driver, 1, 'S6');
        await _hideGone(tester, driver, 1, 'S6');
        await tester.pumpAndSettle();
        final post = heap == null ? null : await heap.usedBytes();
        if (pre != null && post != null) {
          pres.add(pre);
          posts.add(post);
          drifts.add(post - pre);
        }
      }
      final d = drifts.isEmpty
          ? null
          : (drifts.reduce((a, b) => a + b) / drifts.length).round();
      // Accept a null (no VM service — degraded) or a physical drift; retry
      // only an unphysical one, while attempts remain.
      if (d == null || !_isUnphysical(d, _kUnphysicalUpperS6)) break;
      if (attempt == _kHeapAttempts - 1) break; // exhausted — guard below fires
      // ignore: avoid_print
      print('S6: attempt ${attempt + 1}/$_kHeapAttempts unphysical '
          '(drift=$d B) — floor moved, forcing GC and re-measuring');
      await tester.pumpAndSettle();
      await heap?.usedBytes(); // one GC'd probe read to let late GC land
    }

    // (b) after the last hide() the tree is exactly the idle snapshot.
    final afterSnapshot = _fingerprint(tester);
    expect(afterSnapshot, equals(idleSnapshot),
        reason: 'S6: tree after hide() differs from the idle snapshot — '
            'traces of the shown mechanics are still mounted');

    // (c) the scene is interactive: a tap on element A lands.
    final tapsBefore = spec.aTaps.value;
    await tester.tap(find.byKey(Key(kSceneAKey)));
    await tester.pump();
    expect(spec.aTaps.value, tapsBefore + 1,
        reason: 'S6: tap on A after hide() did not land — an overlay still '
            'eats pointer input (hit-test residue)');

    final driftAvg = drifts.isEmpty
        ? null
        : (drifts.reduce((a, b) => a + b) / drifts.length).round();

    // Unphysical on every attempt — measurement defect, not retention.
    // Degrade gracefully (n/a) instead of failing. Symmetric: ±1 MiB.
    if (driftAvg != null && _isUnphysical(driftAvg, _kUnphysicalUpperS6)) {
      final top = heap == null ? const <(String, int)>[] : await heap.topClasses();
      final topDesc = top.isEmpty
          ? '(no VM profile)'
          : top.take(8).map((t) => '${t.$1}=${t.$2}').join(', ');
      // ignore: avoid_print
      print('S6: unphysical drift $driftAvg B on all $_kHeapAttempts attempts '
          '(floor moved) — degraded; pres=$pres posts=$posts top: $topDesc');
      reportMetric('hide_retention', null, extra: {
        'status': 'unphysical',
        'reason': 'floor moved',
        'drifts_bytes': drifts,
        'pres_bytes': pres,
        'posts_bytes': posts,
      });
      if (heap != null) await heap.dispose();
      await _asyncTeardownSettle(tester);
      return;
    }

    if (driftAvg == null) {
      // ignore: avoid_print
      print('S6: no VM service (run with flutter drive --no-dds --profile) '
          '— heap drift not measured; tree/tap asserts ran');
    }
    reportMetric('hide_retention', driftAvg,
        extra: driftAvg == null
            ? const {'status': 'degraded'}
            : {'drifts_bytes': drifts, 'pres_bytes': pres, 'posts_bytes': posts});

    if (heap != null) await heap.dispose();

    await _asyncTeardownSettle(tester);
  });
}

/// Canonical snapshot of the live tree: sorted list of "runtimeType#key" of
/// every live element (offstage included — hidden leftovers must show up).
List<String> _fingerprint(WidgetTester tester) {
  final root = tester.binding.rootElement!;
  final out = <String>[];
  void walk(Element e) {
    out.add('${e.widget.runtimeType}#${e.widget.key ?? ''}');
    e.visitChildren(walk);
  }

  walk(root);
  out.sort();
  return out;
}

// ── Shared teardown ───────────────────────────────────────────────────────

/// Async-teardown settle (methodology): overlay solutions (dialogs, toasts,
/// popovers) schedule short-lived dismiss timers / delayed completion
/// callbacks; the test binding fails on pending timers when the test ends.
/// Pump well past any dismiss animation so the solution's async teardown
/// completes — the metric was reported before this point and is unaffected.
Future<void> _asyncTeardownSettle(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
  await tester.pump();
}
