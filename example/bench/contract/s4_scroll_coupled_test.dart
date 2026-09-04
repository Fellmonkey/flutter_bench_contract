// GENERATED from flutter_bench_contract (scenario bridge) — do not edit by
// hand. Regenerate: dart run flutter_bench_contract:contract init --force
//
// Dumb bridge: the scroll_coupled smart body lives in the package (lib/scenarios.dart);
// this file only wires the consumer's driver into its own test process.
import 'package:flutter_bench_contract/scenarios.dart';

import '../drivers/demo_solution_driver.dart';

void main() {
  runContractScenario(
    'scroll_coupled',
    driver: DemoSolutionDriver(),
    idleClasses: [],
  );
}
