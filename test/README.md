# Mutator test contracts

The tests specify the observable behavior Mutator must preserve: complete source/test scope, mandatory isolation, truthful outcomes, owned resource control and retained evidence. Each test file starts with an English contract describing its expected results. Each `It` name states a scenario-specific expectation; every expanded `-ForEach` case must satisfy its assertions.

A passing negative test means the unsafe, stale, incomplete or unsupported request was rejected as asserted. It does not mean that the rejected operation succeeded. A mocked green receipt proves only that the surrounding code handles that fixture correctly.

## Run the development tests

Use PowerShell 7.6+ Core and Pester 6.2.0. Keep `FrenchExDev.DevPoSh.PoSh` and `QuietCliEcosystem/FrenchExDev.QuietCli.PoSh` available beside Mutator under the common module root. Tests exercising the private adapter also need the installed pinned PSMutant 0.6.0. The harness imports existing tools; it does not install missing prerequisites.

From the Mutator directory:

```powershell
# Default: the Unit directory, with Pester parallelism disabled.
./test/Invoke-Tests.ps1

# Select one contract while investigating a failure.
./test/Invoke-Tests.ps1 -Path ./test/Unit/RecheckIsolation.Tests.ps1

# Explicit integration selection: review the prerequisites below first.
./test/Invoke-Tests.ps1 -Path ./test/Integration

# Select both suites explicitly.
./test/Invoke-Tests.ps1 -Path ./test

# Retain command coverage for the complete production scope.
./test/Invoke-Tests.ps1 -CoverageModulePath .
```

Unit tests use temporary files, generated fixtures and declared mocks. Some also start local PowerShell children or prepare a private tool copy; the directory name alone does not mean that a test is purely in memory. Windows APIs, native tools, installers, guest preparation and campaign execution are simulated wherever the case declares a mock. Test sentinels deliberately throw when an operation escapes a required mock.

`Integration/NativeEngine.Tests.ps1` and `Integration/ValidationNativeStop.Tests.ps1` exercise actual captured child processes, encoding, cancellation, timeouts and cleanup. `Integration/GitWorkloadRetention.Tests.ps1` runs the workload entrypoint with a stub workload to check sandbox retention; it does not qualify the Git provider.

`Integration/Run.Tests.ps1` explicitly requests real mutations against small generated modules. It requires the target's isolation adapter and pinned runtime/tools: Windows Sandbox with `wsb.exe` on Windows, or a usable Podman environment and required Linux runtime definition/image. Missing isolation must fail rather than execute mutants on the host. Review the actual fixture and target configuration before selecting this suite. Its small fixture results do not certify a production module or another operating system.

## Expected harness result

The harness writes a compact JSON summary and retains its evidence under `test/Artifacts/development/<run-id>/`:

| Evidence | Expected meaning |
| --- | --- |
| `Passed`, `Failed`, `Skipped`, `DiscoveryErrors` | Actual expanded Pester results. A normal successful test run has a nonzero pass count and zero failures, skips and discovery errors. |
| `tests.xml` | Retained NUnit-format test results for diagnosing the exact case and assertion. |
| `sources.json` and `SourceUnchanged` | Source fingerprints before/after execution. All monitored source roots must remain unchanged during the run. |
| `coverage.xml`, `coverage.json` | Present when coverage is requested; retain command locations, source fingerprints and missing metrics. |
| Exit code | Zero only when the harness's selected requirements pass. Inspect the structured summary and evidence when it returns one. |

The harness disables Pester's TestRegistry and internal parallelism and redirects Mutator/QuietCli configuration to run-local files. Native streams and generated fixtures remain local evidence.

Pester command coverage alone does not measure branches. A coverage run can have every assertion passing and still return exit one because `MissingMetrics` includes `BranchCoverage` and `FullGateSatisfied` remains `false`. Command, line, branch and mutation evidence must be checked separately; a command-coverage percentage is not a complete quality gate.

A complete mutation gate requires nonempty complete discovery, a passing baseline, exact counters, no survivors or exclusions, and 100% raw detection for unchanged sources and dependencies. Rounded scores, partial reports, imported receipts, native exit zero and mocked success files cannot replace that evidence. Rechecks retain `Score = null` and `FullGateSatisfied = false`, even when every selected survivor is now killed.

## Suite expectations

The table lists source-level `It` declarations, not the number of expanded Pester cases. Follow each file for its concrete inputs, mocks and assertions. The expected behaviors below describe requirements, not a claim that the suite has passed on every platform.

### Unit

| Test file | It declarations | Expected behavior |
| --- | ---: | --- |
| [AtomicFileBudget.Tests.ps1](Unit/AtomicFileBudget.Tests.ps1) | 3 | Persistent file locks must exhaust a bounded budget without changing retained bytes. Released locks permit a complete read; replacement follows the host's actual sharing semantics. |
| [AtomicRetryContracts.Tests.ps1](Unit/AtomicRetryContracts.Tests.ps1) | 8 | Only the same completed file/read may retry recognized sharing conflicts, within exactly 40 attempts. Other errors propagate immediately, old state survives, handles close and staging rejects links. |
| [BranchCoverage.Tests.ps1](Unit/BranchCoverage.Tests.ps1) | 2 | Instrumented code must return the same results as original code, preserving short-circuiting, fallthrough and scalar/null/collection enumeration. Early break must remain lazy and must not invent an unobserved loop exit. |
| [BranchMerge.Tests.ps1](Unit/BranchMerge.Tests.ps1) | 3 | Merge only identical branch definitions and source identities with successful semantic tests. Union complementary observed outcomes, including singleton switch hits, and reject inconsistent evidence. |
| [BranchObserverIsolation.Tests.ps1](Unit/BranchObserverIsolation.Tests.ps1) | 3 | Observer namespaces must not alter original source or branch identity. Reject executable identifier syntax and preserve an enclosing observer when cloning an instrumented recorder. |
| [ContainerBase.Tests.ps1](Unit/ContainerBase.Tests.ps1) | 8 | Generated bases must contain verified pinned runtime inputs and stable canonical identities. Bootstrap/SDK changes invalidate the correct identities, while live or failed guest disks cannot be exported as valid seeds. |
| [ContainerBaseGeneration.Tests.ps1](Unit/ContainerBaseGeneration.Tests.ps1) | 4 | Generate complete pinned recipes without building images; repeated generation is idempotent. WhatIf writes nothing, and a missing shared bootstrap boundary fails explicitly. |
| [ContainerBootstrap.Tests.ps1](Unit/ContainerBootstrap.Tests.ps1) | 3 | Entrypoint arguments and quoting must survive forwarding. Select the native dependency for the requested RID and reject a missing target rather than using the build host's library. |
| [ContainerBuild.Tests.ps1](Unit/ContainerBuild.Tests.ps1) | 12 | Reuse requires exact build identity; explicit bases resolve to immutable images and dependency changes invalidate reuse. Builds retain resources/logs, never retry automatically, and reject bad inspection or WhatIf allocation. |
| [ContainerDefinitions.Tests.ps1](Unit/ContainerDefinitions.Tests.ps1) | 10 | Contributor metadata must produce complete platform definitions with existing COPY inputs. Preserve recipe ownership, canonical platform names, explicit incompatibility and manual edits unless regeneration is authorized. |
| [ContainerDependency.Tests.ps1](Unit/ContainerDependency.Tests.ps1) | 6 | Resolve transitive manifest dependencies exactly once without importing code. Include active QuietCli dependencies and reject unsafe names, missing modules, foreign roots and linked paths. |
| [ContainerEngine.Tests.ps1](Unit/ContainerEngine.Tests.ps1) | 13 | Preserve native arguments and use the selected engine's connection flags without changing global defaults. Normalize only reported capabilities, retain failures and require Podman for isolated Linux campaigns. |
| [ContainerProfileContracts.Tests.ps1](Unit/ContainerProfileContracts.Tests.ps1) | 10 | Use the reviewed installer, binary, package pins and platform constraints for every tool profile. Unknown tools, missing pins and unsupported Apple-only tools must fail before installation is claimed. |
| [ContainerQualification.Tests.ps1](Unit/ContainerQualification.Tests.ps1) | 9 | Qualification requires an immutable image, matching source/runtime identity, valid report and successful native execution. WhatIf allocates nothing and existing evidence or source drift cannot be overwritten or accepted. |
| [ContainerRegeneration.Tests.ps1](Unit/ContainerRegeneration.Tests.ps1) | 8 | Generate bases before selected modules, preserve existing macOS definitions and report exact changed paths. Reject foreign/empty selections and occupied report directories while retaining failed-generation evidence. |
| [Containers.Tests.ps1](Unit/Containers.Tests.ps1) | 10 | Custom recipes require explicit verified bases and safe inputs; discovery must not silently substitute host execution. Retain build phases/failures, run workers offline and apply only reported resource controls. |
| [ContainerWorkerContracts.Tests.ps1](Unit/ContainerWorkerContracts.Tests.ps1) | 6 | Workers use immutable images and read-only inputs, including resume reports. Inner business failures remain failures despite client exit zero; cleanup targets only the generated container name. |
| [ContextIdentity.Tests.ps1](Unit/ContextIdentity.Tests.ps1) | 6 | Context hashes cover sources, tests, dependencies, effective configuration, tools, runtime and image identity. Ignore cache location, artifacts and timestamps; missing Pester or changed retained inputs invalidate identity. |
| [CoverageMerge.Tests.ps1](Unit/CoverageMerge.Tests.ps1) | 3 | Union exact command spans and branch outcomes only for identical sources and valid semantic passes. Reject drift, incompatible metadata, incomplete proof and fabricated counters. |
| [DetachedWorker.Tests.ps1](Unit/DetachedWorker.Tests.ps1) | 5 | Detached launch requires a retained owned plan, hidden startup and the actual process identity. Creation failure cannot claim success; supervisors, watchdogs and Git controllers retain their distinct request contracts. |
| [DockerBuild.Tests.ps1](Unit/DockerBuild.Tests.ps1) | 7 | Bounded BuildKit uses verified local OCI bases, explicit resource limits and retained step evidence. Reject unsupported options/unverified stages; failed builds remain failed after owned cleanup. |
| [DockerImageLayout.Tests.ps1](Unit/DockerImageLayout.Tests.ps1) | 4 | Extract only contained regular files and convert exactly one inspected image to an OCI layout. Verify configuration/layer identity and reject traversal, links, malformed manifests and inconsistent image IDs. |
| [EditorRestartContracts.Tests.ps1](Unit/EditorRestartContracts.Tests.ps1) | 4 | Editor recovery must verify automatic replacements, parent ownership, one window, focus and the exact restart command. Ambiguous UI state or absent replacement must fail without sending unrelated keystrokes. |
| [EngineConfiguration.Tests.ps1](Unit/EngineConfiguration.Tests.ps1) | 11 | Engine YAML must preserve typed canonical settings and reject malformed, duplicate or unknown data. Persistence/migration must honor WhatIf, atomic replacement and unrelated source settings. |
| [EngineSettings.Tests.ps1](Unit/EngineSettings.Tests.ps1) | 12 | Resolve explicit selection, retained context, preferences and saved defaults in order. Validate endpoints, reject disabled engines and preserve CLI global contexts while resolving managed Podman pipes unambiguously. |
| [EquivalenceConfiguration.Tests.ps1](Unit/EquivalenceConfiguration.Tests.ps1) | 3 | Strict mutation configuration must reject equivalence exclusions instead of using them to improve the score. Invalid or stale declarations cannot become accepted gate evidence. |
| [FailurePaginationContracts.Tests.ps1](Unit/FailurePaginationContracts.Tests.ps1) | 4 | Return complete masked failure entries within item/UTF-8 byte limits. Pagination must expose omitted data and the next offset without silently skipping an oversized entry. |
| [GeneratedRouting.Tests.ps1](Unit/GeneratedRouting.Tests.ps1) | 6 | Generated definitions must determine the selected runtime and remain unchanged between scheduling and build. Missing/unsupported metadata fails explicitly instead of falling back to the host. |
| [GitImageValidation.Tests.ps1](Unit/GitImageValidation.Tests.ps1) | 19 | Default selection contacts Linux only and uses CliEnvironment-owned builds with frozen dependencies. Stops, failed builds, stale proof and source drift remain visible; baseline-only or partial work never satisfies the full gate. |
| [GuestBase.Tests.ps1](Unit/GuestBase.Tests.ps1) | 25 | Provisioning requires owned storage, verified KVM/resources and matching readiness pins. Cancellation, OOM, abnormal exits and installation failures cannot be overridden by late green proof; restart/stop must preserve ownership. |
| [GuestBaseExportContracts.Tests.ps1](Unit/GuestBaseExportContracts.Tests.ps1) | 6 | Export only a clean stopped matching guest with valid standalone qcow2 files, byte counts and hashes. Preserve occupied seeds and incomplete exports; WhatIf must copy nothing. |
| [GuestControl.Tests.ps1](Unit/GuestControl.Tests.ps1) | 1 | Serve fresh health/stop state only for canonical paths and the matching job owner. Foreign, malformed or unreadable requests return explicit rejection/error statuses. |
| [GuestJobExecution.Tests.ps1](Unit/GuestJobExecution.Tests.ps1) | 14 | Bind each job to its owner, fixture/descriptor hashes and valid deadline; preserve argv, both streams and actual exit. Do not replay completed jobs; cancellation/timeout and report mirroring retain distinct proof. |
| [GuestModule.Tests.ps1](Unit/GuestModule.Tests.ps1) | 11 | Prepare a fresh owned overlay/share and require matching base/module/payload identity. Provisioning/job failures remain failed, WhatIf allocates nothing and no foreign or occupied share may be reused. |
| [GuestMutationPreparation.Tests.ps1](Unit/GuestMutationPreparation.Tests.ps1) | 6 | Stage one complete source-bound package with explicit runtime, stop path and Stryker selection. Reject existing sandboxes, drift, escaping descriptors and incomplete discovery before executing the package. |
| [GuestSeed.Tests.ps1](Unit/GuestSeed.Tests.ps1) | 4 | Independent overlay volumes must share only the immutable seed, with verified backing identity. Native probe failure or stale/foreign proof cannot pass; WhatIf creates no volumes. |
| [HostPowerShell.Tests.ps1](Unit/HostPowerShell.Tests.ps1) | 3 | VM-host recipes must include and execute pinned Core without changing the guest disk identity. Host-template changes invalidate the controller fingerprint, not an unrelated prepared guest base. |
| [ImageInstallerContracts.Tests.ps1](Unit/ImageInstallerContracts.Tests.ps1) | 16 | Installers must preserve pins, verify hashes before extraction/execution and use the selected platform manager. Empty inputs do no work; native/reboot/failure exits, executable permissions and alias failures stay explicit. |
| [ImagePrerequisite.Tests.ps1](Unit/ImagePrerequisite.Tests.ps1) | 2 | Build only recognized missing local bases under the dependency boundary. Unknown localhost references fail before native work rather than being pulled implicitly. |
| [ImageRecipeExecution.Tests.ps1](Unit/ImageRecipeExecution.Tests.ps1) | 18 | Execute only a valid reviewed recipe and verify release/artifact hashes before installation. Mocked package managers must receive exact pins, arguments and platform paths; incompatible or ambiguous assets fail closed. |
| [ImageSources.Tests.ps1](Unit/ImageSources.Tests.ps1) | 1 | Resolve the explicitly requested rootless image storage while respecting explicit rootful selection. Do not invent a sibling or silently change a selected connection. |
| [ImportIsolation.Tests.ps1](Unit/ImportIsolation.Tests.ps1) | 4 | Restore nested mutable module state within the same mutant epoch and remove test-added values. A new epoch, replaced function/module or opaque state must trigger a fresh import. |
| [InstallerPinning.Tests.ps1](Unit/InstallerPinning.Tests.ps1) | 1 | Missing installer version pins must be rejected before any download or release API request. Download/API sentinels deliberately fail if validation happens too late. |
| [Isolation.Tests.ps1](Unit/Isolation.Tests.ps1) | 11 | Campaign target determines mandatory Windows Sandbox or Podman isolation without host fallback. Reports must identify required versus actually started runtimes and retain evidence while stopping only the owned session. |
| [LifecycleAudit.Tests.ps1](Unit/LifecycleAudit.Tests.ps1) | 3 | Recognize workers from actual script/run arguments rather than command strings mentioning a filename. Dashboard errors remain advisory with masked retained diagnostics. |
| [Localization.Tests.ps1](Unit/Localization.Tests.ps1) | 6 | French/English catalogs must share keys and translate labels without changing counts, module names or endpoints. Unknown discovery, completion and enforced-versus-reserved memory remain semantically accurate. |
| [MacOSBootstrapContracts.Tests.ps1](Unit/MacOSBootstrapContracts.Tests.ps1) | 12 | Only verified base/module preparation may publish readiness with matching ownership and payload hashes. Mocked commands must preserve arguments/exit behavior; missing shares, invalid versions and failed stages retain diagnostics. |
| [MacOSProfileContracts.Tests.ps1](Unit/MacOSProfileContracts.Tests.ps1) | 4 | Use the explicit macOS installer and launcher, including manual constraints. Infrastructure must not gain an invented binary; unknown recipes and host-service substitutions are refused. |
| [MemoryLimit.Tests.ps1](Unit/MemoryLimit.Tests.ps1) | 3 | Parse decimal French/English and binary RAM units correctly. Requested watchdog limits update policy without changing mutation worker reservations. |
| [MemoryRecoveryContracts.Tests.ps1](Unit/MemoryRecoveryContracts.Tests.ps1) | 3 | Recheck PID/time/parent ownership before stopping anything and exclude ordinary shells. Restart only unfinished packages after all owned workers exit, preserving partial proof and run options. |
| [MemoryWatchdog.Tests.ps1](Unit/MemoryWatchdog.Tests.ps1) | 7 | Pressure is measured across total host RAM, but recovery targets only registered owned workers. Recycled PIDs and editor sessions are excluded; failures remain visible and state-file locking stays bounded. |
| [MemoryWatchdogLoop.Tests.ps1](Unit/MemoryWatchdogLoop.Tests.ps1) | 1 | Retain the actual recovery action/error and honor cooldowns. Repeated pressure must not cause unbounded duplicate recovery or invent an owned process target. |
| [NativeBoundaryContracts.Tests.ps1](Unit/NativeBoundaryContracts.Tests.ps1) | 7 | Keep native streams local, preserve actual exit codes and emit only consistent advisory counters. Worker argv/identity and platform routing must stay literal and owned. |
| [Orchestration.Tests.ps1](Unit/Orchestration.Tests.ps1) | 11 | Preserve all test associations and source scope while enforcing resource budgets and valid resume context. Monitoring must retain partial/torn-write progress, distinguish failures and escape dashboard data. |
| [PackageExecutionContracts.Tests.ps1](Unit/PackageExecutionContracts.Tests.ps1) | 1 | Every simulated package scenario must retain its correct outcome, phase and evidence. Mutation/C# boundaries are mocked; no real campaign is authorized or qualified by these cases. |
| [PodmanMemory.Tests.ps1](Unit/PodmanMemory.Tests.ps1) | 5 | Act only on the verified running machine with substantial clean cache or available pages. Record whether compaction actually ran; unavailable kernel controls cannot be reported as enforced recovery. |
| [PortableContainerIdentity.Tests.ps1](Unit/PortableContainerIdentity.Tests.ps1) | 1 | Canonical container JSON uses LF independent of host while preserving Unicode and newlines inside data. Equivalent inputs must retain the same identity. |
| [PowerShellGate.Tests.ps1](Unit/PowerShellGate.Tests.ps1) | 2 | Accept only complete nonempty consistent raw detection. Partial, excluded, surviving, unmapped or contradictory mutation evidence must fail even if the displayed score rounds to 100. |
| [PowerShellQualityGate.Tests.ps1](Unit/PowerShellQualityGate.Tests.ps1) | 2 | Write success only when exact production-source identity, full coverage and complete mutation proof agree. Missing, stale or misleading evidence must fail before publishing success. |
| [Preview.Tests.ps1](Unit/Preview.Tests.ps1) | 1 | List-only discovery stages only allowed source dependencies and excludes generated artifacts. The owned preview stage must be removed without executing real mutants. |
| [ProductionScope.Tests.ps1](Unit/ProductionScope.Tests.ps1) | 2 | Include manifest entrypoint, root scripts and executable resources while excluding declarative data and artifacts. Missing or escaping entrypoints fail before configuration generation. |
| [Recheck.Tests.ps1](Unit/Recheck.Tests.ps1) | 3 | Recheck retains dedicated counts and an unchanged baseline with no overall score/full gate. Mocked tool failure and cancellation must retain explicit failed/interrupted proof rather than invented counters. |
| [RecheckIsolation.Tests.ps1](Unit/RecheckIsolation.Tests.ps1) | 8 | Route each target to its mandatory runtime with a frozen read-only baseline and one worker. Host execution, changed inputs and missing summaries fail; retained survivors remain diagnostic rather than a full score. |
| [ReportContracts.Tests.ps1](Unit/ReportContracts.Tests.ps1) | 11 | Import historical evidence read-only and export complete hash-bound package proof only within authorized artifact paths. Missing/changed/C# evidence stays explicit and invalid IDs or redirected metadata cannot escape storage. |
| [ResourceEntryContracts.Tests.ps1](Unit/ResourceEntryContracts.Tests.ps1) | 8 | Entrypoints must dispatch the intended worker/workload using current runtime paths and return actual outcomes. Stubbed workers/installers must retain diagnostics without launching real supervisors or watchdog recovery. |
| [ResourcePool.Tests.ps1](Unit/ResourcePool.Tests.ps1) | 3 | Reserve workers/memory under a shared lease and refresh idle stale policy. Reject impossible reservations before launch and block additional allocation at capacity. |
| [Retention.Tests.ps1](Unit/Retention.Tests.ps1) | 2 | Plan only old successful eligible runs without altering files. Bound displayed candidates while keeping exact eligibility counts. |
| [RetentionRemoval.Tests.ps1](Unit/RetentionRemoval.Tests.ps1) | 3 | WhatIf preserves evidence; actual removal affects only the explicitly eligible test run. A candidate containing its original source tree must be refused. |
| [RunObservation.Tests.ps1](Unit/RunObservation.Tests.ps1) | 4 | Report startup failures separately from interrupted local runs and do not query foreign-host PIDs. Preserve exact discovered/evaluated counts, including historical equivalence observations. |
| [StateCloneContracts.Tests.ps1](Unit/StateCloneContracts.Tests.ps1) | 6 | Clone supported nested collections while preserving comparers and immutable identities. Unsupported, computed, cyclic or excessive-depth state must fail rather than sharing partially copied mutable graphs. |
| [Stop.Tests.ps1](Unit/Stop.Tests.ps1) | 3 | Respect WhatIf and stop only owned run processes, including orphan handling for deleted directories. Retain reports and interrupted states without recreating absent run metadata. |
| [Stryker.Tests.ps1](Unit/Stryker.Tests.ps1) | 3 | Require nonempty complete detection and shared worker allocation. Restore failures block mutation and ignored, unknown or pending verdicts cannot become successful detection. |
| [StrykerHostContracts.Tests.ps1](Unit/StrykerHostContracts.Tests.ps1) | 6 | Keep host logs/progress/report hashes and forward cancellation to restore and mutation. Missing settings, removed runtimes, interrupted restore and excluded mutants must fail explicitly. |
| [Terminal.Tests.ps1](Unit/Terminal.Tests.ps1) | 4 | Display completion separately from mutation success and keep authoring ownership in DevPoSh. Agent failures/survivors must be actionable, bounded and secret-masked. |
| [TerminalInteractionContracts.Tests.ps1](Unit/TerminalInteractionContracts.Tests.ps1) | 7 | Once returns structured state without console access; redirected streams refuse interactive mode. Q detaches, stop keys signal cooperatively and all exit/error paths restore terminal state. |
| [TestDiscoveryContracts.Tests.ps1](Unit/TestDiscoveryContracts.Tests.ps1) | 4 | Discover every semantic test while pruning artifacts before descent and validating paths once. Reject invalid entries and links without deleting repeated valid associations. |
| [ToolAdapter.Tests.ps1](Unit/ToolAdapter.Tests.ps1) | 10 | Patch only verified PSMutant boundaries without changing installed bytes. Concurrent complete publication may be reused; incomplete/conflicting layouts, unsafe staging and wrong pins must fail. |
| [ToolIdentity.Tests.ps1](Unit/ToolIdentity.Tests.ps1) | 1 | Fresh processes using different private caches must produce identical adapter identity and executable hashes. Tests require the installed pinned tool, not an arbitrary compatible replacement. |
| [Validation.Tests.ps1](Unit/Validation.Tests.ps1) | 12 | Honor selected suites/platforms and configured engines, freeze sources and retain per-platform errors. WhatIf starts nothing; partial selections, impossible budgets and blocked preparation never imply a complete gate. |
| [ValidationContainer.Tests.ps1](Unit/ValidationContainer.Tests.ps1) | 19 | Run only an owned source-bound payload with explicit budgets and matching module/suite manifests. Native exit contradictions, missing reports and stale identities fail; retain containers when proof recovery fails. |
| [ValidationControl.Tests.ps1](Unit/ValidationControl.Tests.ps1) | 8 | Accept only owner-matched stop signals, wait for every child worker and then export partial proof. Copy failures remain secondary and WhatIf must not write stop files. |
| [ValidationEntry.Tests.ps1](Unit/ValidationEntry.Tests.ps1) | 7 | The thin script forwards selections and typed budgets and returns structured JSON plus exit zero only for success. Failed gates and orchestration exceptions return exit one with retained diagnostics. |
| [ValidationEvidenceContracts.Tests.ps1](Unit/ValidationEvidenceContracts.Tests.ps1) | 7 | Freeze each dependency once and prove live/copied identity. Regenerate only inside the copy; reports must escape data, expose evidence links and preserve actual console/progress observations. |
| [ValidationMirrorAtomic.Tests.ps1](Unit/ValidationMirrorAtomic.Tests.ps1) | 4 | Mirror the same completed bytes within the exact sharing-conflict budget. Preserve previous proof and relative package paths; unrelated errors fail immediately and clean temporary files. |
| [ValidationWorkload.Tests.ps1](Unit/ValidationWorkload.Tests.ps1) | 23 | Check frozen sources/OS before suites and enforce semantic, command, branch and mutation evidence independently. Failed prerequisites block mutation; stopping waits for owned children while retaining the primary error and partial proof. |
| [WatchdogLifecycleContracts.Tests.ps1](Unit/WatchdogLifecycleContracts.Tests.ps1) | 8 | Arm/stop only the requested private watchdog with exact policy and actual counters. WhatIf preserves files, incompatible living policies are not silently reused and stopped-state/error projection remains truthful. |
| [WindowsBaseRuntime.Tests.ps1](Unit/WindowsBaseRuntime.Tests.ps1) | 4 | Publish readiness only after exact PowerShell, SDK and tool pin verification. Wrong runtimes, absent binaries and ambiguous SDK inputs fail before claiming preparation. |
| [WindowsBootstrapContracts.Tests.ps1](Unit/WindowsBootstrapContracts.Tests.ps1) | 15 | Bootstrap must preserve verified ownership, runtime paths and payload hashes before publishing readiness or registering mocked tasks. Each failed stage retains local/shared diagnostics and cannot be overridden by obsolete proof. |
| [WindowsGuest.Tests.ps1](Unit/WindowsGuest.Tests.ps1) | 14 | Legacy guest contracts require VM reservations, matching ownership/provenance and all configured mutation gates. Transport zero cannot hide survivors/partial proof; failure and timeout retain evidence before owned shutdown. |
| [WindowsGuestOrchestrationContracts.Tests.ps1](Unit/WindowsGuestOrchestrationContracts.Tests.ps1) | 2 | Always attempt owned cleanup while preserving the primary preparation/execution error. Keep resume fingerprints, configured Stryker evidence and cooperative-stop forwarding intact. |
| [WindowsResume.Tests.ps1](Unit/WindowsResume.Tests.ps1) | 5 | Resume only with unchanged exact dependency hashes, report bytes and guest context. Reject duplicates/drift before allocation and preserve target runtime and Stryker selection. |
| [WorkerDiscoveryContracts.Tests.ps1](Unit/WorkerDiscoveryContracts.Tests.ps1) | 6 | Find owned workers from literal Windows/Linux arguments, retaining spaces and dollar signs. Ignore incomplete/unreadable/foreign argv and unsupported ownership platforms. |
| [WorkerRouting.Tests.ps1](Unit/WorkerRouting.Tests.ps1) | 2 | Detach only the Windows supervisor through its durable launcher. Package workers remain attached to their supervisor and retain separate captured streams on each platform. |

### Integration

| Test file | It declarations | Expected behavior |
| --- | ---: | --- |
| [GitWorkloadRetention.Tests.ps1](Integration/GitWorkloadRetention.Tests.ps1) | 1 | Failed workloads retain their sandbox and identity receipt; successful fixture workloads remove only their owned sandbox. Uses a child process with a stub workload, not real Git qualification. |
| [NativeEngine.Tests.ps1](Integration/NativeEngine.Tests.ps1) | 21 | Native execution preserves literal argv and both streams, distinguishes failure/timeout/cancellation, marks truncation and rejects invalid decoding. Secrets must be masked, captures released and caller configuration restored. |
| [Run.Tests.ps1](Integration/Run.Tests.ps1) | 3 | Small real fixture campaigns must respect shared worker budgets, discover a nonempty complete scope and retain progress/context proof. Cooperative stopping must produce a scoreless partial report that resumes only with identical inputs; required isolation must be available. |
| [ValidationNativeStop.Tests.ps1](Integration/ValidationNativeStop.Tests.ps1) | 3 | A quiet child must receive cancellation without emitting another record. Validation forwarding must retain native evidence and avoid starting an already-cancelled child. |

## Maintaining these contracts

When behavior changes, update the function help, the affected test file's contract and its row here. Tests should assert public or retained outcomes, exact identities and owned side effects independently of the implementation. Preserve complete test associations and discovery; do not use sampling, skipped assertions or covered-lines-only filtering to improve a gate.

Keep generated fixtures, logs, dashboards, private tool caches and run state out of production sources. Retain failures and partial evidence with their original provenance. Starting or resuming a production campaign remains an explicit operation.
