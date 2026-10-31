# FrenchExDev.Mutator.PoSh

Mutator manages PowerShell and C# mutation campaigns under **PowerShell 7.6+ Core**. It prepares isolated project copies, checks tests before mutation, allocates workers, retains evidence, and provides monitoring in the terminal and on an HTML page.

It uses **PSMutant** for PowerShell and **Stryker.NET** for configured C# projects. The modules under test provide their sources, tests, and mutation configuration.

## Prerequisites

- PowerShell 7.6 or later, Core edition.
- PSMutant **0.6.0** and Pester **6.2.0** for PowerShell mutations.
- Windows campaigns: Windows Sandbox and its `wsb.exe` CLI on a Windows host, with PowerShell Core 7.6+ and the pinned tools installed locally to prepare the private copy.
- Linux campaigns: Podman and a local Linux image containing PowerShell Core 7.6+, Pester 6.2.0, and PSMutant 0.6.0.
- `powershell-yaml` **0.4.12** to read and write container engine YAML configuration.
- For C#: the .NET SDK, Stryker.NET, and the dependencies required by the project, prepared in the selected execution environment.
- For containers: Podman or Docker and a working connection. Docker builds require Buildx.
- For Windows guests: a Linux host with KVM and nested virtualization, along with a prepared Windows image.

Importing the module and viewing reports do not start a campaign, install tools, or start a watchdog.

## Mandatory PSMutant isolation

| Mutant OS | Required environment |
| --- | --- |
| Windows | Windows Sandbox |
| Linux | Podman container |

`-OS Windows` or `-OS Linux` selects the target OS independently of the host.
Without `-OS`, the target is the host OS. A Windows campaign requires a Windows
host. Campaign mutants must never execute directly on the host:
a missing or unavailable environment causes a failure, with no fallback.
Docker and the legacy KVM Windows guest are not PSMutant campaign environments.
Rechecks follow the same rule: `Invoke-MutatorRecheck -OS Windows` uses
Windows Sandbox, while `-OS Linux` uses Podman. The public entry point never runs
PSMutant on the host. Without `-OS`, it uses the host OS.

Windows Sandbox receives read-only sources and tools, prepares a
private working copy, and writes reports/progress to the only
writable share. Networking and the clipboard are disabled. Each
package has its own Sandbox ID; stopping it targets only that ID. The
PowerShell Core runtime and tools come from the host, with no downloads inside
the guest. This adapter supports PSMutant; a project using Stryker must
select `-SkipStryker` for this Windows campaign.

For Linux, the module recipe or definition takes precedence, even if
the binary exists on the host. If no definition is available, explicitly supply
`-ContainerBaseImage` with a ready-to-use local image; the launcher
uses its immutable ID and performs no automatic pull.

```powershell
Invoke-MutatorRun -ModulePath ../MonModule.PoSh -OS Windows -SkipStryker -Background
Invoke-MutatorRun -ModulePath ../MonModule.PoSh -OS Linux -ContainerEngine Podman `
    -ContainerBaseImage localhost/mon-runtime-tests:stable -Background
```

Monitoring distinguishes the required environment from the one actually started.
An older run executed on the host displays `Host`, even if its configuration
mentions Podman. `Pending (WindowsSandbox)` or `Pending (Podman)` indicates that
the required environment has not started yet.

By default, reports remain in the PowerShell software under test:
`<module under test>/test/Artifacts/mutator/<run-id>/packages/<package-id>/`.
`mutation.json` and its context receipt are retained there, along with logs
and partial reports. `-RunRoot` explicitly selects another
destination; it is mandatory when selecting multiple modules.
In Windows Sandbox, `C:\MutatorRun` is only the guest path of this package's
`sandbox-run` share. `C:\MutatorRun\stop.json` is a stop signal,
not a report location on the host. Package metadata exposes
`HostReportDirectory`, `HostExchangeDirectory`, and `GuestExchangeDirectory`.

## Quick start

The following examples start from the Mutator directory. `../MonModule.PoSh` refers to a neighboring module; replace it with the project to test.

```powershell
Import-Module ./FrenchExDev.Mutator.PoSh.psd1 -DisableNameChecking

# Run once for a module that already has tests.
New-MutatorConfiguration -ModulePath ../MonModule.PoSh

# Start an explicit campaign in an interactive terminal.
mutator -ModulePath ../MonModule.PoSh -UI
```

`mutator` is the alias for `Invoke-MutatorRun`. Without `-UI` or `-Background`, the command waits for the run to finish and returns its state. To work in the background:

```powershell
$run = Invoke-MutatorRun -ModulePath ../MonModule.PoSh `
    -WorkerBudget 4 -ThrottleLimit 2 -MemoryBudgetMiB 4096 -Background

Get-MutatorProgress -Path $run.Path
Get-MutatorFailure -Path $run.Path -MaxItems 20
```

Background workers launch without an interactive window. Mutator retains native logs locally; monitoring commands provide access to progress and issues without displaying those logs.

## Define the scope

Each selected module must have `test/psmutant.config.json`. This configuration declares the sources, their test associations, thresholds, and subtrees allowed in the sandbox.

`New-MutatorConfiguration` inventories the root module declared in the manifest, PowerShell scripts at the root, and `.ps1` and `.psm1` files under `src` and `resources`. It associates each source with all discovered test files and sets `coveredLinesOnly` to `false`.

```powershell
# Also declare neighboring modules required by the tests.
New-MutatorConfiguration -ModulePath ../MonModule.PoSh `
    -Dependency MonProjet.Common.PoSh

# Explicitly replace an existing configuration.
New-MutatorConfiguration -ModulePath ../MonModule.PoSh `
    -Dependency MonProjet.Common.PoSh -Force
```

Dependencies must be declared in `sandboxSubtrees`. A source or test outside the allowed scope causes preparation to fail. The configuration must be maintained when adding sources, tests, or dependencies.

A module path selects that module. A root path selects its child modules that have a mutation configuration; `-Include` filters their names:

```powershell
mutator -Path .. -Include 'MonProjet.*.PoSh' -UI -Parallel -RunRoot ./test/Artifacts/mutator
```

`-ModulePath` also accepts multiple modules. They must all be under the same `SourceRoot`, which defaults to the parent of the first selected module.

## Campaign lifecycle

Each package has its own process and sandbox. The lifecycle includes source and tool preparation, baseline tests, mutant discovery, execution, and result retention. When an image must be built, the `Building Container` phase precedes testing; a build failure retains the logs and failed phase without starting tests.

The PSMutant adapter creates a private copy of the pinned tool and checks the expected adaptation points. It disables TestRegistry and Pester's internal parallelism, then adds progress reporting and cooperative stopping. The original installation is preserved.

`-TestOrder FocusedFirst`, the default, places unit tests close to the source before integration tests. `-TestOrder Configured` preserves the declared order. These options reorder associations without removing any test or mutant.

Each mutant requires a fresh code load. Between test files for the same mutant, supported module states are restored; a state that cannot be safely restored triggers a full reimport.

For modules with `engine/dotnet-tools.json`, Stryker.NET is selected unless `-SkipStryker` is supplied. `engine/mutator.json` must name `Project` and `TestProject`, and the dotnet SDK must be present on the host: `-StrykerRuntime` accepts `Auto` and `Host`. Restore and tooling errors remain failures.

## Success criteria

The mutation gate requires nonempty discovery, a passing baseline, and **100% raw mutation score** across the full scope.

- No survivors, sampling, or covered-lines-only filtering are accepted.
- Equivalence exclusions are rejected during generation, launch, and final validation.
- A score rounded to 100% with a survivor is still a failure.
- Missing associations, tool errors, and modified sources prevent validation.
- A partial report has no final score.

Legacy equivalence declarations and adjusted reports may be retained as historical diagnostics. They do not constitute evidence of passing the strict gate. Stryker reports distinguish ignored or noncompiling mutants from scored results.

## Parallelism and budgets

```powershell
mutator -Path .. -Include 'MonProjet.*.PoSh' -UI -Parallel -RunRoot ./test/Artifacts/mutator `
    -ThrottleLimit 4 -Workers 2 -WorkerBudget 8 -MemoryBudgetMiB 8192
```

| Parameter | Purpose |
| --- | --- |
| `WorkerBudget` | Maximum number of mutation workers allocatable to the run. |
| `ThrottleLimit` | Maximum number of simultaneously active packages. |
| `Workers` | Number of workers requested per package. |
| `MemoryBudgetMiB` | Memory budget used by the scheduler for reservations. |
| `Parallel` | Automatically adjusts package concurrency when `ThrottleLimit` is not supplied. |
| `RunRoot` | Storage root for runs and their shared resource pool. |

The example allows up to four packages with two workers each, within available resources. PSMutant can distribute mutants across workers; Pester remains sequential inside each worker.

Runs sharing a `RunRoot` share a pool protected by a lock. The first run sets its budgets; reservations for workers that are still alive are accounted for before any new launch. Separate roots do not share this pool.

Scheduler reservations are not a physical memory cap enforced by the operating system. Container limits and the host watchdog have separate roles.

## Terminal and dashboard monitoring

```powershell
Watch-MutatorRun -Path $run.Path
Get-MutatorProgress -Path $run.Path
Get-MutatorFailure -Path $run.Path -MaxItems 20 -Skip 0

Show-MutatorDashboard -Open
Get-MutatorRun
```

The `-UI` interface displays active phases, packages, workers, evaluated mutants, survivors, errors, and memory. `S` or `Ctrl+C` requests a cooperative stop; `Q` detaches the view while leaving the run active. `Watch-MutatorRun` can then attach a terminal to the run again.

The interactive interface requires a console with nonredirected input and output. For scripts or agents, use `Get-MutatorProgress`, `Get-MutatorFailure`, or `Watch-MutatorRun -Once`.

`Get-MutatorFailure` returns execution errors and PowerShell/C# survivors, with their files, lines, operators, and reports. Results are bounded to 20 items and 8192 bytes by default. `Truncated` and `NextSkip` indicate pagination; `-MaxItems`, `-MaxOutputBytes`, and `-Skip` control retrieval.

The dashboard presents history, status/platform/module filters, run details, and evidence links. The supervisor regenerates the page during execution; the browser reloads it every five seconds. Actual hourly observations are retained in `hourly.jsonl`.

Mutant percentages cover scopes already discovered. Package progress is not an estimate of remaining time. Unknown dates and intervals without observations are not reconstructed.

Translation catalogs for the terminal, dashboard, and validation reports are under `resources/localization/`, with French and English text.

## Stop and resume

```powershell
Stop-MutatorRun -Path $run.Path

# As a last resort: terminate the identified processes belonging to this run.
Stop-MutatorRun -Path $run.Path -Force

# After stopping, resume a single module from the interrupted run.
$resumed = Resume-MutatorRun -Path $run.Path `
    -ModulePath ../MonModule.PoSh -Background
```

A cooperative stop allows PSMutant to write a partial report before cleanup. A forced stop or crash may prevent that final write; evidence already retained remains available.

The Git driver retains diagnostics from a failed container inspection. Before stopping a Linux workload that fails during mutation, it requests a cooperative stop and waits for reports. Its stopped container is retained for diagnosis; only successful workloads are removed automatically. A selected OS awaiting execution is marked `Pending`, distinct from `NotSelected`.

Git definitions belong to CliEnvironment: use `Export-CliEnvironmentGitDefinition`. The legacy `Export-MutatorContainerDefinition` generator refuses to overwrite them, including with `-Force`. Other existing definitions retain their current contract.

The driver also freezes CliEnvironment sources: environment preparation code is part of the campaign dependencies, even when it is not a Git mutation target.

For Git Windows guests, Mutator prepares the shared report directory tree before startup. The guest writes evidence files to these directories; its working sources and sandboxes remain on its local disk. This avoids SMB directory creation operations that the Windows/WSL bridge may report as failures after actually creating the directories.

Under memory pressure, Podman cache reclamation also compacts free pages when the kernel supports it. This allows WSL to return freed pages to Windows without restarting the VM; the receipt records whether compaction actually ran. The watchdog can also compact a VM whose cache has already been cleared but that still holds a large amount of available memory.

Resuming requires the partial report and its context receipt. Source, test, and dependency contents, effective configuration, runtime, Pester, and adapter must match. An old receipt imported on its own does not allow resuming. No interrupted run resumes automatically when the module is imported or the dashboard is opened.

## Recheck survivors

```powershell
Invoke-MutatorRecheck -ModulePath ../MonModule.PoSh `
    -ReportPath ./test/Artifacts/mutator/mon-run/packages/p0000/mutation.json
```

This check reruns recorded survivors in a frozen copy, using current tests and one worker. Production sources and operators must match the original report.
The initial report is frozen in a read-only copy and identified by
SHA-256 before the worker starts. The tool cache and working copy
remain inside the isolated environment; no host fallback is allowed.
The recheck uses one worker and supports cooperative stopping.

```powershell
$run = Invoke-MutatorRecheck -ModulePath ../MonModule.PoSh `
    -ReportPath ./mon-rapport/mutation.json -OS Windows -Background
Watch-MutatorRun -Path $run.Path
```

For Linux, add `-OS Linux -ContainerBaseImage localhost/mon-runtime-tests:stable`
if the module does not have its own image definition.
By default, evidence is retained under
`<module under test>/test/Artifacts/mutator/rechecks/`: `mutation.recheck.json`,
`recheck.json`, and run metadata. `-OutputDirectory` explicitly selects
another root. In synchronous mode, `Report`, `Proof`, and `RunPath`
return host paths; in background mode, monitoring tools display
`Mode=Recheck` and dedicated counters. Survivors also appear in
`Get-MutatorFailure`. A recheck cannot be resumed like a full campaign:
start a new one from its initial survivor report.

It retains its provenance, its own report, and the `Rechecked`, `NowKilled`, and `Survived` counters. It does not modify the baseline or produce an overall score: `FullGateSatisfied` remains `false`. A full campaign is still required to validate fixes.

## Podman and Docker configuration

Mutator stores its settings in **`~/.mutator/config.yaml`**. The **`MUTATOR_CONFIG_PATH`** variable selects another file. The `docker` and `podman` sections define endpoints, enablement, and the default engine:

```yaml
docker:
  pipe: '\\.\pipe\docker_engine'
  enabled: true
  default: false
podman:
  pipe: '\\.\pipe\podman-ma-machine'
  enabled: true
  default: true
```

```powershell
Get-MutatorEngine
Set-MutatorEngine -Podman '\\.\pipe\podman-ma-machine' -PodmanEnabled:$true
Set-MutatorEngine -DefaultEngine Podman
Get-MutatorEngine -Default

# Select the engine and connection for the Mutator session.
Set-MutatorContainerEngine -Engine Docker -Connection mon-contexte-docker

# Or explicitly select the engine for a run.
mutator -ModulePath ../MonModule.PoSh `
    -ContainerEngine Podman -ContainerConnection ma-connexion -UI
```

Only one engine may have `default: true`, and it must be enabled. Without an explicit marker, selection prefers Podman if enabled, then Docker. It fails if no engine is enabled. An empty string passed to `-Docker` or `-Podman` clears the corresponding endpoint; `-WhatIf` prepares changes without writing them.

`-ContainerConnection` identifies a Podman connection or Docker context. Calls use `podman --connection` or `docker --context` without changing the CLI's global context. A disabled engine is rejected even with an explicit connection. Configuration does not start any service.

The engine and its settings are retained in run receipts. Selecting the Docker CLI does not, by itself, prove that a separate Docker daemon is used: a context may point to a Podman API.

## Run tests in a Linux container

A module can declare a recipe in `test/mutator.container.psd1`:

```powershell
@{
    Binary = 'mon-outil'
    UseWhen = 'Missing'
    PackageManager = 'apk'
    Packages = @('mon-paquet=version-revision')
}
```

`UseWhen = 'Windows'` selects the container on Windows; `Missing` selects it when the native binary is absent; `Always` selects it on all hosts. A missing binary is not sufficient without a supported recipe or definition.

Custom recipes require an explicit local base compatible with `apk` or `apt`, containing PowerShell 7.6+, Pester 6.2.0, and PSMutant 0.6.0. The C# workflow also requires its SDK and tools.

```powershell
New-MutatorToolImage -RecipePath ../MonModule.PoSh/test/mutator.container.psd1 `
    -BaseImage localhost/mon-runtime-tests:stable `
    -OutputDirectory ./test/Artifacts/images/mon-outil

mutator -ModulePath ../MonModule.PoSh `
    -ContainerBaseImage localhost/mon-runtime-tests:stable -UI
```

`New-MutatorToolImage` prepares the image without starting a campaign. The cache depends on the Containerfile and the full base identity; the receipt retains recipe and image fingerprints. A built image does not, on its own, validate tests or mutations.

Sources are mounted read-only and reports are writable. Tests run without networking. CPU and memory limits depend on available cgroup controllers; their absence appears in `Container.ResourceWarning`, while scheduler reservations remain active.

With Podman, Mutator can select a sibling rootful connection when the current connection cannot enforce the memory limit. An explicitly supplied connection disables this automatic selection. Receipts retain the connection and limits actually used.

## Mutations in a Windows guest

`-WindowsGuestImage` selects an already prepared Windows module image. This choice takes precedence over the module's Linux recipe:

```powershell
mutator -ModulePath ../MonModule.PoSh `
    -WindowsGuestImage localhost/mon-module:windows `
    -ContainerConnection ma-connexion-root -MemoryBudgetMiB 6144 `
    -WorkerBudget 1 -Workers 1 -SkipStryker -UI
```

The backend uses `dockurr/windows`: Windows runs in a VM hosted by a Linux container. Selecting a prepared image triggers neither Windows installation nor an image rebuild.

Each guest reserves 6144 MiB in the scheduler, applies that cap to the container, and allocates 4096 MiB to Windows, with two vCPUs. PSMutant workers remain limited to one per guest; multiple packages can each receive a VM if budgets allow.

The baseline, full discovery, and mutations execute in a sandbox local to Windows. States and reports are copied back to the share; guest evidence is retained under `windows-reports`. Stryker participates for configured C# projects unless `-SkipStryker` is supplied.

`-WindowsGuestTimeoutMinutes`, 120 by default, includes startup. `-WindowsGuestJobTimeoutSeconds` adds a limit after preparation; the first deadline reached applies. A timeout requests a partial report before stopping, without guaranteeing that a mutation report exists if discovery has not started. Final publication and ACPI shutdown may extend the shutdown time.

Disks and logs are retained. The `Start-MutatorGuestBase`, `Get-MutatorGuestBase`, `Wait-MutatorGuestBase`, `Stop-MutatorGuestBase`, `Restart-MutatorGuestBase`, and `Export-MutatorGuestBase` commands cover the lifecycle of managed bases. Export requires a verified base that has been shut down cleanly.

## Validation by suite and operating system

From the Mutator directory:

```powershell
./Invoke-Validation.ps1 -Test Unit,Integration -OS Linux

./Invoke-Validation.ps1 -Test Unit,Integration,Mutations `
    -OS Linux,Windows -ContainerConnection ma-connexion-root -UI -Ram 40go

# macOS requires a suitable machine and an already prepared base.
./Invoke-Validation.ps1 -OS MacOS -MacOSConnection ma-connexion-macos
```

The script uses `Invoke-MutatorValidation`. By default, it selects Mutator, all three suites, and Linux/Windows. The `-Test` and `-OS` parameters accept lists. `-ModulePath` selects other modules neighboring Mutator with their complete configuration.

Operating systems run sequentially; each environment runs Unit, Integration, then Mutations. Linux runs PowerShell in its container; Windows and macOS run it in their guest. A missing or outdated base, or one requiring manual preparation, may block validation. macOS remains `NotSelected` unless requested; actual support must be qualified on a suitable machine.

The initial budget is 6144 MiB, with `Workers = 1` and `WorkerBudget = 2`. The `-OutputDirectory` directory must be new or empty. Evidence is retained under `test/Artifacts/validation/<run-id>/`: `summary.json`, `index.html`, frozen sources, logs, and reports by operating system, suite, and module.

Full gates require 100% command, line, and branch coverage, along with a 100% raw mutation score. A partial selection does not satisfy the full gate. Linux success does not qualify Windows or macOS; a successful build does not prove execution in the guest operating system.

## Git driver with reusable bases

`Invoke-MutatorGitImageValidation` uses definitions and bases prepared by `FrenchExDev.CliEnvironment.PoSh`. It runs Unit, Integration, full coverage, and PSMutant with one worker, first on Linux and then in a Windows guest. Mounted sources remain read-only; mutations work in local copies. Module and dependency fingerprints must remain identical throughout the campaign.

From the workspace root:

```powershell
Invoke-MutatorGitImageValidation -ModuleRoot ./PoSh/FrenchExDev `
    -OS Linux,Windows -Connection podman-frenchexdev-root -Ram 40go -UI

# On a Windows host: a controller independent of the calling terminal.
$run = Invoke-MutatorGitImageValidation -ModuleRoot ./PoSh/FrenchExDev `
    -OS Linux,Windows -Connection podman-frenchexdev-root -Ram 40go -Background
$run.Path
```

Detached mode retains `controller.request.json`, the actual process identity in `controller.json`, and its result in `controller.result.json`. Monitoring remains available in `summary.json` and `index.html`. It does not resume an old campaign or use partial success as a final score. `-BaselineOnly` omits mutations and never satisfies the full gate.

Windows execution uses a `Bypass` policy limited to the guest PowerShell process, required for unsigned development modules loaded from the share. The host execution policy is not changed.

## Windows host memory watchdog

`mutator ... -Ram 40go` enables or reconfigures an independent watchdog, with a 40 GB threshold and 2 GB of preventive headroom. `40go` and `40GB` use decimal units; `40GiB` and `40Gio` use binary units. Without `-Ram`, a run does not change the existing watchdog.

```powershell
Start-MutatorMemoryWatchdog -LimitGB 50 -HeadroomGB 2 -PollSeconds 2
Get-MutatorMemoryWatchdog
Stop-MutatorMemoryWatchdog
```

The threshold applies to total physical RAM used on the workstation, across all software. The watchdog runs in a hidden, independent process. It acts only on registered Mutator workers and supervisors: script path, run directory, PID, and creation time must match. PowerShell sessions and editors outside these runs are excluded.

For an identified Mutator worker, it first requests a stop with evidence retention. An exclusive lock prevents concurrent recovery operations; all owned processes must stop before a restart. Unfinished packages can then restart in new runs: resume with valid context, or run in full if no usable partial report exists. Worker, engine, and timeout parameters are preserved. Packages that have already succeeded are not rerun.

`-PodmanMachine` also enables reclamation of clean Linux cache from an identified Podman machine. Interventions and measurements remain under `test/Artifacts/memory-watchdog`. The watchdog remains active until explicitly stopped or the Windows session ends; it is not installed to run at workstation startup. Its sampling does not provide a guaranteed hardware cap.

## Reports and integration

| Default location | Contents |
| --- | --- |
| `src/` and `resources/` | Module code, adapters, templates, and catalogs. |
| `test/Artifacts/mutator/<run-id>/` | `run.json` plan, package states, events, reports, and receipts. |
| `test/Artifacts/validation/<run-id>/` | Summary and evidence of validation by operating system. |
| `test/Artifacts/mutator/rechecks/` | Targeted survivor rechecks. |
| `.cache/mutation-tools/` | Private copies of adapted tools. |

`-RunRoot` relocates campaign storage. States and full/partial reports retain their provenance; an error, interruption, or incomplete result does not become a success when viewed.

```powershell
Export-MutatorReport -Path $run.Path -RunId validation-locale
```

This command copies evidence to each tested module's artifact directory, with mutation reports, a summary, and a receipt comparing source fingerprints. `Import-MutatorRun` references old receipts in the dashboard without executing mutations. An imported receipt does not, on its own, provide the context required to resume.

Dashboard viewing is bounded to 100 runs by default (`-MaxRuns`). It does not modify the history of completed runs. A rendering error is retained in `dashboard-error.json` and does not interrupt supervision.

Retention is explicit and disabled by default:

```powershell
Get-MutatorRetentionPlan -RunRoot ./test/Artifacts/runs -KeepLast 20
Remove-MutatorRun -RunRoot ./test/Artifacts/runs -KeepLast 20 -WhatIf
```

Only old, successful native runs are candidates after the default 30-day delay. Incomplete, imported, active, or linked runs are retained. `Remove-MutatorRun` requests confirmation again and checks paths and eligibility at deletion time; importing, testing, or viewing the dashboard never triggers a purge.

## Verify Mutator

See [test/README.md](test/README.md) for prerequisites, expected behavior by suite, retained evidence and the limits of each validation result.

```powershell
# Module unit tests.
./test/Invoke-Tests.ps1

# Integration tests using small isolated projects.
./test/Invoke-Tests.ps1 -Path ./test/Integration

# Coverage of Mutator's production scope.
./test/Invoke-Tests.ps1 -CoverageModulePath .
```

Integration tests may run PSMutant on small real fixtures. Development reports are retained under `test/Artifacts/development/`.

The coverage harness retains `tests.xml`, `sources.json`, `coverage.xml`, and `coverage.json`. Pester 6.2 provides command coverage but does not measure branches. The report flags this limitation with `MissingMetrics = ['BranchCoverage']` and `FullGateSatisfied = false`; zero-valued XML counters do not prove full branch coverage.

Mutator retains results and diagnostics. Fixing sources and tests remains an explicit action by their author.

## Git validation: stopping and evidence

The driver now selects Linux by default. Ongoing qualification work runs in a Linux container with --init; no Windows guest should be launched until the applicable Linux matrix is complete.

`Invoke-MutatorGitImageValidation` first checks the mutation configuration of the `FrenchExDev.QuietCli.Git.PoSh` module. If it is missing, the command fails before creating a validation or watchdog. Current tests under `dev/` and CliEnvironment images still require separate qualification; this driver does not constitute Git validation.

`Stop-MutatorGitImageValidation -Path <validation>` requests a cooperative stop tied to the run's identity. The controller forwards the signal to the workload. Silent Pester child processes also receive this signal through QuietCli. For a mutation, the workload requests that the child run stop, waits for it to terminate, then retains its evidence; a final state is not sufficient if an owned worker is still alive.

A copy error remains the primary error even if stopping or the final copy also fails. Mirror copying and JSON writes share bounded atomic replacement: only the same completed temporary file is retried, never a test command or campaign. The previous destination is preserved and the temporary file is cleaned up. Progress readers allow replacement of the open file.

An unsuccessful Git workload retains its sandbox and writes retained-sandbox.json. A stopped run or partial report has no final mutation score. The only sandboxes automatically deleted by this wrapper are those whose validation succeeded.
