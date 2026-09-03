// The published metrics card — a landscape golden PNG (2400x1080) rendered
// from the recorded goldens. Machinery of the card (layout, value
// formatting, SDK-font loading, the render harness) lives in the package;
// the consumer supplies only its content (title/subtitle/rows/subtitles/
// legend via the manifest `card:` section — see `contract card`).
//
// The layout is ported byte-for-byte from hintful's original card render
// (the marketing snapshot published by its record flow): 7 tiles in two
// columns (4+3) with an optional methodology note in the last right slot.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'defs.dart';

/// One published metric tile: the def carries key/label/unit, [subtitle] is
/// the consumer's marketing line under the tile (optional).
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
    this.sceneBackground = const Color(0xFFEDF1F4),
    this.cardBackground = Colors.white,
    this.headerGradient = const LinearGradient(
      colors: [Color(0xFF00695C), Color(0xFF26A69A)],
    ),
    this.headerText = Colors.white,
    this.accent = const Color(0xFF00695C),
    this.labelColor = const Color(0xFF37474F),
    this.subtitleColor = const Color(0xFF78909C),
    this.barTrack = const Color(0xFFE0E7EA),
    this.barGradient = const LinearGradient(
      colors: [Color(0xFF00897B), Color(0xFF4DB6AC)],
    ),
  });

  final Color sceneBackground;
  final Color cardBackground;
  final Gradient headerGradient;
  final Color headerText;
  final Color accent;
  final Color labelColor;
  final Color subtitleColor;
  final Color barTrack;
  final Gradient barGradient;
}

/// The marketing card: header (title + subtitle + "lower is better"),
/// a grid of metric tiles ([rows], values from [values] by row key) and a
/// bottom [legend]. Rendered at a fixed landscape size by the render
/// harness (`contract card`), not laid out for arbitrary screens.
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
            width: 2260,
            height: 990,
            margin: const EdgeInsets.symmetric(horizontal: 70, vertical: 45),
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: style.cardBackground,
              borderRadius: BorderRadius.circular(28),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x22000000),
                  blurRadius: 36,
                  offset: Offset(0, 12),
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
                const SizedBox(height: 26),
                Expanded(
                  child: _TilesGrid(
                    rows: rows,
                    values: values,
                    note: note,
                    style: style,
                  ),
                ),
                const SizedBox(height: 18),
                _Legend(text: legend, style: style),
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
        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 20),
        child: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: style.headerText,
                    fontFamily: 'RobotoBold',
                    fontSize: 42,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: style.headerText.withValues(alpha: 0.9),
                    fontSize: 21,
                  ),
                ),
              ],
            ),
            const Spacer(),
            if (lowerIsBetter != null)
              Text(
                lowerIsBetter!,
                style: TextStyle(
                  color: style.headerText.withValues(alpha: 0.85),
                  fontFamily: 'RobotoMedium',
                  fontSize: 20,
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
    required this.note,
    required this.style,
  });

  final List<MetricsCardRow> rows;
  final Map<String, num> values;

  /// Methodology note rendered in the last right-column slot (below the
  /// right column's tiles) — the original card's _MethodNote position.
  final String? note;
  final MetricsCardStyle style;

  @override
  Widget build(BuildContext context) {
    // Rows without a recorded value are dropped before splitting — a tile
    // for a missing metric would fabricate a '0' number. `contract card`
    // only sends recorded rows; this guard keeps a stale config honest.
    final withValues =
        rows.where((r) => values.containsKey(r.key)).toList();
    // Two balanced columns: the left takes ceil(n/2) tiles, the right the
    // rest — with 7 metrics that is 4+3, and the last right slot carries
    // the optional methodology note.
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
            children: [
              for (final def in left)
                _MetricTile(
                  row: def,
                  value: values[def.key]?.toDouble() ?? 0,
                  style: style,
                ),
            ],
          ),
        ),
        const SizedBox(width: 36),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final def in right)
                _MetricTile(
                  row: def,
                  value: values[def.key]?.toDouble() ?? 0,
                  style: style,
                ),
              if (note != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    note!,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 15,
                      color: style.subtitleColor,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  row.label,
                  style: TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.w500,
                    color: style.labelColor,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                formatCardValue(value, row.unit),
                style: TextStyle(
                  fontSize: 30,
                  fontFamily: 'RobotoBold',
                  color: style.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Container(
              height: 24,
              color: style.barTrack,
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: _fraction(),
                // Container (not a bare DecoratedBox): with no child a
                // Container expands to its constraints, a DecoratedBox
                // collapses to zero — the fill must paint the full
                // fraction (port of the original card).
                child: Container(
                  decoration:
                      BoxDecoration(gradient: style.barGradient),
                ),
              ),
            ),
          ),
          if (row.subtitle != null && row.subtitle!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                row.subtitle!,
                style: TextStyle(fontSize: 15, color: style.subtitleColor),
              ),
            ),
        ],
      ),
    );
  }

  double _fraction() {
    if (value <= 0) return 0;
    final exp = (math.log(value) / math.ln10).ceil();
    final cap = math.pow(10, exp).toDouble();
    final nice =
        cap / 2 >= value ? cap / 2 : (cap / 5 >= value ? cap / 5 : cap);
    return (value / nice).clamp(0.1, 1.0);
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.text, required this.style});

  final String? text;
  final MetricsCardStyle style;

  @override
  Widget build(BuildContext context) {
    if (text == null || text!.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(
          text!,
          style: TextStyle(
            fontSize: 17,
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
