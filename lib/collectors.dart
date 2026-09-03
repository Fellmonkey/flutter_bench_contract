// Measurement collectors of the performance contract: frame-timing windows
// and VM-service heap probes, shared by every device scenario.
//
// Phase-1 extraction from hintful's benchmark_utils.dart (moved verbatim).
// The report side (reportMetric / HINTFUL_BENCH_JSON envelope, sample
// parsing, median) now lives in report.dart, the golden store in
// goldens.dart.
//
// Deliberately free of `flutter_test` so the same helpers can later be
// reused by reporting harnesses. Timings are in microseconds.
import 'dart:developer' as developer;

import 'package:flutter/scheduler.dart';
import 'package:vm_service/vm_service.dart' as vm_service;
import 'package:vm_service/vm_service_io.dart';

/// One frame's budget at 60 Hz, in microseconds.
const int kFrameBudgetUs = 16666; // 16.6 ms

/// `getInstances` caps the returned instance refs, never totalCount; the
/// S1r counter only reads totalCount, so a small limit is enough.
const int _kInstanceProbeLimit = 100;

/// A window of [FrameTiming]s collected while a benchmark action ran.
class FrameWindow {
  FrameWindow(this.timings);

  final List<FrameTiming> timings;

  double get _sumBuildUs => timings
      .fold<int>(0, (sum, t) => sum + t.buildDuration.inMicroseconds)
      .toDouble();

  double get _sumRasterUs => timings
      .fold<int>(0, (sum, t) => sum + t.rasterDuration.inMicroseconds)
      .toDouble();

  /// Average build phase per frame, µs.
  double get avgBuildUs => timings.isEmpty ? 0 : _sumBuildUs / timings.length;

  /// Average raster phase per frame, µs.
  double get avgRasterUs => timings.isEmpty ? 0 : _sumRasterUs / timings.length;

  /// Frames whose build+raster exceeded the 60 Hz budget.
  int get slowFrames => timings
      .where((t) =>
          t.buildDuration.inMicroseconds + t.rasterDuration.inMicroseconds >
          kFrameBudgetUs)
      .length;

  @override
  String toString() => '${timings.length} frames · build avg '
      '${avgBuildUs.toStringAsFixed(0)} µs · raster avg '
      '${avgRasterUs.toStringAsFixed(0)} µs · slow >16.6 ms: $slowFrames';
}

/// Collects [FrameTiming]s while [action] runs and returns the window.
Future<FrameWindow> collectFrames(Future<void> Function() action) async {
  final timings = <FrameTiming>[];
  // The callback receives a batch per frame — append, not replace.
  void onTimings(List<FrameTiming> batch) => timings.addAll(batch);
  SchedulerBinding.instance.addTimingsCallback(onTimings);
  try {
    await action();
  } finally {
    SchedulerBinding.instance.removeTimingsCallback(onTimings);
  }
  return FrameWindow(timings);
}

/// Best-effort handle to the heap of the running test isolate.
///
/// Connects like `integration_test`'s timeline API: the address is built
/// from `developer.Service.getInfo()` as `ws://localhost:port/path/ws`. This
/// requires the run NOT to sit behind the DDS proxy — with `flutter drive`,
/// pass `--no-dds`. In plain `flutter test` VM runs `serverUri == null`, so
/// [VmServiceHeap.connect] returns `null` and callers degrade gracefully.
class VmServiceHeap {
  VmServiceHeap._(this._service, this._isolateId);

  final vm_service.VmService _service;
  final String _isolateId;

  /// Connects to the VM service of the running isolate, or `null`.
  ///
  /// The whole connect is time-boxed: under some plain `flutter test` host
  /// contexts `Service.getInfo()` never completes (no service to answer), so
  /// an unguarded await would hang the scenario instead of degrading. On a
  /// `--no-dds --profile` device run the service answers immediately and the
  /// timeout never fires.
  static Future<VmServiceHeap?> connect() async {
    try {
      final info = await developer.Service
          .getInfo()
          .timeout(const Duration(seconds: 3));
      final uri = info.serverUri;
      if (uri == null) return null;
      // Same shape integration_test uses in `enableTimeline()`:
      //   ws://localhost:<port><path>ws
      final address = 'ws://localhost:${uri.port}${uri.path}ws';
      final service = await vmServiceConnectUri(address);
      final vm = await service.getVM();
      final isolate = vm.isolates?.firstWhere(
        (iso) => iso.isSystemIsolate != true,
      );
      if (isolate?.id == null) return null;
      return VmServiceHeap._(service, isolate!.id!);
    } catch (_) {
      return null;
    }
  }

  /// Used heap bytes of the test isolate after a forced GC, or `null`.
  Future<int?> usedBytes() async {
    try {
      final profile = await _service.getAllocationProfile(
        _isolateId,
        gc: true,
      );
      return profile.memoryUsage?.heapUsage;
    } catch (_) {
      return null;
    }
  }

  /// Median of [samples] `usedBytes` reads (each forces a GC).
  ///
  /// Single reads are noisy: the first GC after app start frees megabytes of
  /// accumulated startup garbage (measured: a 10 MB swing between two
  /// consecutive snapshots). Sampling after a warm-up read and taking the
  /// median keeps the phase-to-phase *deltas* stable — the metric the memory
  /// benches rely on.
  Future<int?> usedBytesMedian({int samples = 3}) async {
    final values = <int>[];
    for (var i = 0; i < samples; i++) {
      final v = await usedBytes();
      if (v == null) return null;
      values.add(v);
    }
    values.sort();
    return values[values.length ~/ 2];
  }

  /// Live instances of the class named [className] in the test isolate,
  /// after a forced GC — the S1r `idle_resources` counter (spec §5.2).
  ///
  /// Resolves the class by simple name over the isolate's class list and
  /// sums `getInstances` totalCount across name collisions (two libraries
  /// declaring the same simple name — the consumer's declared names are
  /// solution-specific, so collisions are rare; summing keeps the counter
  /// conservative). The limit caps the returned refs, never totalCount.
  /// Returns null when the class list or the RPC failed (the caller degrades
  /// to the diagnostic path instead of reporting a number).
  Future<int?> instancesOfClass(String className) async {
    try {
      await _service.getAllocationProfile(_isolateId, gc: true);
      final classList = await _service.getClassList(_isolateId);
      var total = 0;
      for (final c in classList.classes ?? const <vm_service.ClassRef>[]) {
        if (c.name == className && c.id != null) {
          final set = await _service.getInstances(
            _isolateId,
            c.id!,
            _kInstanceProbeLimit,
          );
          total += set.totalCount ?? 0;
        }
      }
      return total;
    } catch (_) {
      return null;
    }
  }

  /// Top retained Dart classes by bytes (after a forced GC) — the "where did
  /// the heap delta go" breakdown. Returns `(name, bytes)` pairs, most bytes
  /// first, or an empty list when the profile is unavailable.
  Future<List<(String, int)>> topClasses({int limit = 30}) async {
    try {
      final profile = await _service.getAllocationProfile(
        _isolateId,
        gc: true,
      );
      final rows = <(String, int)>[
        for (final c in profile.members ?? const <vm_service.ClassHeapStats>[])
          if ((c.bytesCurrent ?? 0) > 0)
            (c.classRef?.name ?? '?', c.bytesCurrent!),
      ]..sort((a, b) => b.$2.compareTo(a.$2));
      return rows.take(limit).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> dispose() async => _service.dispose();
}
