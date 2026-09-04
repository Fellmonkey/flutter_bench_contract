// The measured content of the contract scenarios: one card with
// two text rows per content state, mounted by the solution's own mechanism
// (tooltip / toast / dialog / overlay) when `show(state)` is called.
//
// Size and texts are part of the contract — they must not change (drivers of
// every solution mount exactly this widget; a golden at textScale 2.0 is
// part of the package's own tests).
import 'package:flutter/material.dart';

/// Root key of the `ContractCard` for [state] — the scenario asserts content
/// presence by this key, no matter how the solution mounted the card.
String contractCardKey(int state) => 'contract.card.$state';

/// The two content states of the card.
const Map<int, (String, String)> kContractCardContent = {
  1: ('Contract title one', 'Contract description one.'),
  2: ('Contract title two', 'Contract description two.'),
};

/// The content every solution that declares S2–S4 must mount on
/// `show(state)`. Root carries `Key('contract.card.<state>')` and the
/// `Semantics(label: 'Contract card')` announcement.
class ContractCard extends StatelessWidget {
  const ContractCard({super.key, required this.state});

  /// Content state (1 or 2).
  final int state;

  /// Fixed card size — part of the contract.
  static const double width = 260;
  static const double height = 88;

  /// Inner padding — part of the contract.
  static const double padding = 16;

  @override
  Widget build(BuildContext context) {
    final content = kContractCardContent[state];
    if (content == null) {
      throw ArgumentError.value(state, 'state',
          'unknown ContractCard state (content exists for states 1 and 2)');
    }
    final (title, description) = content;
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // container: true — the card must be its own semantics node: a label
    // on a plain Semantics wrapper is merged into nothing when the children
    // (the two Texts) create their own nodes, so readers would never hear
    // the 'Contract card' label.
    return Semantics(
      container: true,
      label: 'Contract card',
      child: Container(
        key: Key(contractCardKey(state)),
        width: width,
        height: height,
        padding: const EdgeInsets.all(padding),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.titleMedium
                  ?.copyWith(color: scheme.onSurface),
            ),
            const SizedBox(height: 4),
            Text(
              description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
