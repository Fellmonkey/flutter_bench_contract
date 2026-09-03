// The generic renderer of a consumer's published "Performance" README
// section (plan §6 readme.dart): rows come from the canonical metric defs
// (lib/defs.dart — ONE label/unit per metric, shared by every consumer),
// values from the golden store, and everything consumer-specific (which
// solutions form the table columns, the intro/footnote copy, the card
// image) from the manifest `readme:` section — the consumer owns the
// marketing text, the package owns the machinery.
//
// Pure Dart (no flutter imports): `contract readme` runs this under plain
// `dart run`, so no dart:ui is pulled in.
library;

import 'defs.dart';
import 'goldens.dart';

/// README markers delimiting the rendered block (hintful's original
/// `<!-- bench:start -->` / `<!-- bench:end -->` markers, kept verbatim so
/// existing READMEs migrate without touching the surrounding prose).
const String kReadmeStart = '<!-- bench:start -->';
const String kReadmeEnd = '<!-- bench:end -->';

/// One table column: a solution name and the store refs its numbers are
/// read under (e.g. hintful → `android` (+ `any` fallback), a rival →
/// `android-scv`, never inheriting another solution's numbers).
class ReadmeColumn {
  const ReadmeColumn({
    required this.label,
    this.refs = const ['android', 'any'],
    this.fallbackAny = true,
  });

  /// Column header (solution name).
  final String label;

  /// Golden refs to prefer, in order (see GoldenStore.load).
  final List<String> refs;

  /// Whether any recorded ref may stand in when none of [refs] has a value
  /// (false for rival columns — a rival never inherits the host's numbers).
  final bool fallbackAny;
}

/// The consumer-owned content of the section (manifest `readme:`). The
/// package renders the table machinery; the consumer writes the marketing
/// copy (intro, footnote, image, stamp).
class ReadmeContent {
  const ReadmeContent({
    required this.intro,
    required this.columns,
    required this.footnote,
    this.title = 'Performance',
    this.image,
    this.imageAlt,
    this.stamp,
  });

  /// Heading text (`## $title`).
  final String title;

  /// Prose paragraph under the heading.
  final String intro;

  /// Table columns, left to right.
  final List<ReadmeColumn> columns;

  /// Footnote under the table (explains `n/a`, diagnostics and rows that
  /// are not published — never silently dropped).
  final String footnote;

  /// Image path relative to the README file (the metrics card PNG).
  final String? image;

  /// Markdown alt text of [image].
  final String? imageAlt;

  /// Stamped line under the image; `{ts}` is replaced with the render
  /// timestamp (`2026-09-04 12:34 UTC`). Absent → no stamped line.
  final String? stamp;
}

/// Renders the whole README section for [content]: markers, heading,
/// intro, the metric table (one row per publishable def, cells read from
/// the store via [store], default `benchmarks.json` in the cwd), footnote,
/// image and stamp.
///
/// Rows are the publishable defs that have a recorded value anywhere in the
/// store — a consumer that does not record `size` metrics gets no size
/// rows, and a metric with no golden under any column renders `n/a` (never
/// a fabricated number).
String renderReadmeSection(
  ReadmeContent content, {
  GoldenStore? store,
  DateTime? now,
}) {
  final s = store ?? GoldenStore();
  final ts = now ?? DateTime.now().toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp = '${ts.year}-${two(ts.month)}-${two(ts.day)} '
      '${two(ts.hour)}:${two(ts.minute)} UTC';

  // One row per publishable def that any column has a value for; cells are
  // the def's canonical unit + formatTableValue (shared with the card).
  final rows = <String>[];
  for (final def in kPublishableMetricDefs) {
    final hasAny = content.columns.any((c) =>
        s.load(def.key, preferRefs: c.refs, fallbackAny: c.fallbackAny) !=
        null);
    if (!hasAny) continue;
    final cells = StringBuffer('| ${def.label} |');
    for (final column in content.columns) {
      final value =
          s.load(def.key, preferRefs: column.refs, fallbackAny: column.fallbackAny);
      cells.write(' ${formatTableValue(value, def.unit)} |');
    }
    rows.add(cells.toString());
  }

  final header =
      '| Metric | ${content.columns.map((c) => c.label).join(' | ')} |';
  final divider =
      '|${List.filled(content.columns.length + 1, '---').join('|')}|';

  final buffer = StringBuffer()
    ..writeln(kReadmeStart)
    ..writeln('## ${content.title}')
    ..writeln()
    ..writeln(content.intro.trim())
    ..writeln()
    ..writeln(header)
    ..writeln(divider)
    ..writeln(rows.join('\n'))
    ..writeln()
    ..writeln(content.footnote.trim());
  if (content.image != null) {
    buffer
      ..writeln()
      ..writeln('![${content.imageAlt ?? ''}](${content.image})');
  }
  if (content.stamp != null) {
    buffer
      ..writeln()
      ..writeln(content.stamp!.replaceAll('{ts}', stamp));
  }
  buffer.write(kReadmeEnd);
  return buffer.toString();
}

/// Replaces the block between [kReadmeStart] and [kReadmeEnd] in [text]
/// with [section]; appends the section when the markers are absent.
String replaceReadmeSection(String text, String section) {
  final s = text.indexOf(kReadmeStart);
  final e = text.indexOf(kReadmeEnd);
  return (s >= 0 && e > s)
      ? text.replaceRange(s, e + kReadmeEnd.length, section)
      : '${text.trimRight()}\n\n$section\n';
}
