// The published metrics card — a landscape golden PNG rendered from the
// recorded goldens. Canvas 1600x900 (README caps images at ~800px); content
// (title/rows/legend) comes from the manifest `card:` — see `contract card`.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'defs.dart';

/// One published metric tile: the def carries key/label/unit; [subtitle] is
/// an optional consumer marketing line under the tile.
class MetricsCardRow {
  const MetricsCardRow({
    required this.key,
    required this.label,
    required this.unit,
    this.subtitle,
  });

  final String key;
  final String label;
  final String unit;
  final String? subtitle;

  /// Row def from a [MetricDef] (canonical label/unit) + optional subtitle.
  factory MetricsCardRow.fromDef(MetricDef def, {String? subtitle}) =>
      MetricsCardRow(
        key: def.key,
        label: def.label,
        unit: def.unit,
        subtitle: subtitle,
      );
}

/// Visual knobs of the card. Defaults reproduce hintful's original look, so
/// a consumer that does not restyle keeps the published snapshot identical.
class MetricsCardStyle {
  const MetricsCardStyle({
    this.sceneBackground = const Color(0xFFE6ECF0),
    this.cardBackground = const Color(0xFFF4F7F9),
    this.tileBackground = Colors.white,
    this.headerGradient = const LinearGradient(
      colors: [Color(0xFF004D40), Color(0xFF26A69A)],
    ),
    this.headerText = Colors.white,
    this.accent = const Color(0xFF00796B),
    this.labelColor = const Color(0xFF263238),
    this.subtitleColor = const Color(0xFF78909C),
  });

  final Color sceneBackground;
  final Color cardBackground;

  /// Tile card fill (white).
  final Color tileBackground;
  final Gradient headerGradient;
  final Color headerText;
  final Color accent;
  final Color labelColor;
  final Color subtitleColor;
}

/// The marketing card: header (title + subtitle + "lower is better" badge),
/// a grid of metric tiles ([rows], values from [values] by row key) and a
/// bottom [legend]. Rendered at a fixed landscape size by the render
/// harness (`contract card`), not laid out for arbitrary screens.
///
/// Deliberately no progress bar per tile: rows carry incommensurable units
/// (ms, KB, elements), so a shared 0-100% fill would be meaningless — the
/// value + unit is the data.
class MetricsCard extends StatelessWidget {
  const MetricsCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.rows,
    required this.values,
    this.note,
    this.legend,
    this.lowerIsBetter = 'lower is better',
    this.style = const MetricsCardStyle(),
  });

  final String title;
  final String subtitle;

  /// Metric tiles in display order (first column first).
  final List<MetricsCardRow> rows;

  /// metric key -> recorded value.
  final Map<String, num> values;

  /// Extra tile text in the last right-column slot (methodology note).
  final String? note;

  /// Bottom bar text (legend).
  final String? legend;

  /// Header badge; null hides it (not every metric set is lower-is-better).
  final String? lowerIsBetter;

  final MetricsCardStyle style;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: style.accent),
        fontFamily: 'Roboto',
      ),
      home: Scaffold(
        backgroundColor: style.sceneBackground,
        body: Center(
          child: Container(
            width: 1488,
            height: 828,
            margin: const EdgeInsets.symmetric(horizontal: 56, vertical: 36),
            padding: const EdgeInsets.all(26),
            decoration: BoxDecoration(
              color: style.cardBackground,
              borderRadius: BorderRadius.circular(24),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x22000000),
                  blurRadius: 28,
                  offset: Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(
                  title: title,
                  subtitle: subtitle,
                  lowerIsBetter: lowerIsBetter,
                  style: style,
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: _TilesGrid(
                    rows: rows,
                    values: values,
                    style: style,
                  ),
                ),
                const SizedBox(height: 12),
                _Footer(note: note, legend: legend, style: style),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.subtitle,
    required this.lowerIsBetter,
    required this.style,
  });

  final String title;
  final String subtitle;
  final String? lowerIsBetter;
  final MetricsCardStyle style;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: style.headerGradient,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: style.headerText,
                      fontFamily: 'RobotoBold',
                      fontSize: 40,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      // withAlpha (not withOpacity) — the non-deprecated
                      // primitive; keeps the SDK floor at Flutter 3.24.
                      color: style.headerText.withAlpha((0.9 * 255).round()),
                      fontSize: 19,
                    ),
                  ),
                ],
              ),
            ),
            if (lowerIsBetter != null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                decoration: BoxDecoration(
                  color: style.headerText.withAlpha(66),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  lowerIsBetter!,
                  style: TextStyle(
                    color: style.headerText,
                    fontFamily: 'RobotoMedium',
                    fontSize: 15,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TilesGrid extends StatelessWidget {
  const _TilesGrid({
    required this.rows,
    required this.values,
    required this.style,
  });

  final List<MetricsCardRow> rows;
  final Map<String, num> values;
  final MetricsCardStyle style;

  @override
  Widget build(BuildContext context) {
    // Rows without a recorded value are dropped before splitting — a tile
    // for a missing metric would fabricate a '0' number. `contract card`
    // only sends recorded rows; this guard keeps a stale config honest.
    final withValues =
        rows.where((r) => values.containsKey(r.key)).toList();
    // Two balanced columns (left takes ceil(n/2) tiles, right the rest).
    final leftCount = (withValues.length + 1) ~/ 2;
    final left = withValues.take(leftCount).toList();
    final right = withValues.skip(leftCount).toList();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final def in left) _tile(def)],
          ),
        ),
        const SizedBox(width: 22),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final def in right) _tile(def)],
          ),
        ),
      ],
    );
  }

  Widget _tile(MetricsCardRow def) => _MetricTile(
        row: def,
        value: values[def.key]?.toDouble() ?? 0,
        style: style,
      );
}


class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.row,
    required this.value,
    required this.style,
  });

  final MetricsCardRow row;
  final double value;
  final MetricsCardStyle style;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 5),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: style.tileBackground,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(
            color: Color(0x120D2B2A),
            blurRadius: 14,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  row.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w600,
                    color: style.labelColor,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Text(
                formatCardValue(value, row.unit),
                style: TextStyle(
                  fontSize: 56,
                  fontFamily: 'RobotoBold',
                  color: style.accent,
                ),
              ),
            ],
          ),
          if (row.subtitle != null && row.subtitle!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                row.subtitle!,
                style: TextStyle(fontSize: 13, color: style.subtitleColor),
              ),
            ),
        ],
      ),
    );
  }
}

/// Bottom row: methodology note (left) + legend (right).
class _Footer extends StatelessWidget {
  const _Footer({
    required this.note,
    required this.legend,
    required this.style,
  });

  final String? note;
  final String? legend;
  final MetricsCardStyle style;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Text(
            note ?? '',
            style: TextStyle(fontSize: 13, color: style.subtitleColor),
          ),
        ),
        const SizedBox(width: 24),
        if (legend != null && legend!.isNotEmpty)
          Text(
            legend!,
            style: TextStyle(
              fontSize: 15,
              fontFamily: 'RobotoMedium',
              color: style.subtitleColor,
            ),
          ),
      ],
    );
  }
}

/// Loads the Roboto family from the Flutter SDK's material fonts (present in
/// every SDK's `bin/cache/artifacts/material_fonts`), so golden renders use
/// real glyphs without vendoring fonts into the repo. `contract card`
/// ensures the fonts exist before running the render; FLUTTER_ROOT is set by
/// the flutter tool for test processes.
Future<void> loadSdkRobotoFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  final dir = root == null || root.isEmpty
      ? null
      : '$root${Platform.pathSeparator}bin'
          '${Platform.pathSeparator}cache${Platform.pathSeparator}artifacts'
          '${Platform.pathSeparator}material_fonts';
  if (dir == null) {
    throw StateError('FLUTTER_ROOT is not set — cannot load SDK fonts for '
        'the metrics-card golden render');
  }
  // Names differ by platform: the flutter tool lowercases them locally, the
  // storage.zip ships capitalized — match case-insensitively.
  String? findFont(String name) {
    final wanted = name.toLowerCase();
    for (final entry in Directory(dir).listSync()) {
      if (entry is File &&
          entry.path.split(Platform.pathSeparator).last.toLowerCase() ==
              wanted) {
        return entry.path;
      }
    }
    return null;
  }

  Future<ByteData> read(String name) async {
    final path = findFont(name);
    if (path == null) {
      throw StateError('SDK font missing for the metrics-card golden: '
          '$name in $dir (FLUTTER_ROOT=$root).');
    }
    return ByteData.view(File(path).readAsBytesSync().buffer);
  }

  await Future.wait<void>([
    (FontLoader('Roboto')..addFont(read('roboto-regular.ttf'))).load(),
    (FontLoader('RobotoMedium')..addFont(read('roboto-medium.ttf'))).load(),
    (FontLoader('RobotoBold')..addFont(read('roboto-bold.ttf'))).load(),
  ]);
}
