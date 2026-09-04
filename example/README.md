# Example: demo consumer

`demo_solution` is a minimal consumer of `flutter_bench_contract`: a fake
toast/popover-like solution (a bottom card, no scroll anchor) driven by a
hand-written driver. It shows the only library-specific code a consumer
writes — the driver — and how the generated scenario bridges wire it into
the contract. No external package is involved.

Layout:

- `bench/drivers/demo_solution_driver.dart` — the driver
  (`show`/`update`/`hide`/`isStable`/`currentContent`/`buildScene`). A
  toast has no anchor, so S4 scroll coupling is declared `unsupported`.
- `bench/contract/` — generated scenario bridges (S1–S4), byte-identical to
  what `contract init` produces.
- `bench_contract.yaml` — the consumer manifest.
- `test_driver/integration_test.dart` — the device entrypoint that
  `contract run --device` compiles.

Run on the host (no device needed):

```bash
dart run flutter_bench_contract:contract verify
flutter test bench/contract/s1_idle_zero_test.dart
```

Run on a device (records goldens under a ref):

```bash
dart run flutter_bench_contract:contract run --mode record --ref android
```

Write your own consumer by copying this layout and replacing the driver.
