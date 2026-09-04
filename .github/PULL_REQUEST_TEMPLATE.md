## What & why

<!-- One or two sentences: the change and the reason it exists. -->

## Checklist

- [ ] `flutter analyze` clean
- [ ] `flutter test` green (package; affected consumers if protocol/scenario changed)
- [ ] CHANGELOG updated with a dated, one-line-per-change entry
- [ ] Spec (`doc/bench_contract_specs.md`) amended when a protocol or metric
      definition changed (amendments are dated and marked defect-fix)
- [ ] If this change alters any recorded number (golden, protocol, or
      scenario body): name the affected metric(s) and refs, the
      before → after, and why this is a **scenario/protocol defect fix** —
      not tuning to a nicer number. Goldens are re-recorded only under the
      record flow with this reason declared.
