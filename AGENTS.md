# Mutator reading paths

PowerShell 7.6+ Core. Read README.md for the run lifecycle, terminal UI and retained reports.

- This module owns mutation preparation, tool adapters, package scheduling, worker budgets, cancellation, resume validation and monitoring.
- DevPoSh module creation and manifest synchronization belong to `FrenchExDev.DevPoSh.PoSh`.
- Start an explicitly requested run with `Invoke-MutatorRun` / `mutator`; use `-UI` in a human terminal, `-Background` for a detached run, `-Parallel` for automatic module concurrency.
- Agents consume `Get-MutatorProgress` and bounded `Get-MutatorFailure` results. Keep captures and native logs local. Native tool calls belong in the module's captured process boundary.
- Never start or resume a campaign automatically when importing a module, opening a dashboard or reading reports.
- A partial report has no mutation score. Resume only with the retained partial report and matching complete source/test/dependency/runtime/tool fingerprints.
- Preserve complete mutation discovery and test associations. Do not use sampling or covered-lines-only filtering to improve a gate.
- Workers own separate sandboxes/processes. PSMutant workers can run concurrently; Pester inside each worker remains serial unless separately qualified.
- PSMutant isolation is mandatory: Windows target = Windows Sandbox; Linux target = Podman. `Invoke-MutatorRun -OS Windows|Linux` selects the target OS; the default is the host OS. Never execute campaign mutants directly on the host or silently fall back to it. An absent/unavailable adapter is an explicit failure. Development unit tests with mocked mutation tools do not constitute a campaign.
- Keep source/tool shares read-only and only the owned report/control directory writable. Stop only the Sandbox ID or container owned by the run. Preserve full/partial reports on failure and cancellation. Monitoring must distinguish the required runtime from the actual runtime; a configured engine is not evidence of container execution.
- Run state, generated dashboards, tool copies and fixtures are artifacts. Production code and templates stay in this module's `src` and `resources`.
- Development tests: `test/Invoke-Tests.ps1`. Integration tests create small isolated fixture runs; they do not authorize a campaign on real modules.
- Native execution, cancellation and diagnostic masking use QuietCli. Resolve it directly or under `QuietCliEcosystem`; do not import archived providers.
- The memory watchdog may recover only registered Mutator workers and supervisors. Preserve their options and wait for every owned process before restarting.
- Retention requires an explicit run root. Read `Get-MutatorRetentionPlan` before an authorized `Remove-MutatorRun`; never purge artifacts as part of routine validation.
- Image definitions and runtime pins belong under `resources/containers`. A native tool smoke test does not qualify a provider or satisfy the complete mutation gate.
