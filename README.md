# InspectCode: results differ when `--caches-home` holds caches from the previous commit

Minimal reproduction for a JetBrains ReSharper Command Line Tools (InspectCode) issue.

When InspectCode runs with a `--caches-home` directory filled by a run on the previous commit, it analyses against
stale state: Razor components, Razor imports, and project data from MSBuild (global usings, analyzer configuration,
props of NuGet packages). The results differ from a run with an empty `--caches-home` on the same commit, which is
correct. `dotnet build` succeeds in every case.

This repository reproduces ten triggers, each a small change from state A (the "previous commit") to state B:

| Scenario | Change in state B | Run with the cache, compared with the run without it |
|---|---|---|
| `new-razor-file` | a new `.razor` file uses an existing component | extra `Razor.UnresolvedComponent` for that component |
| `cs-component-ref` | an existing `.razor` file uses a new component that is declared in C# only (`ComponentBase` subclass), captured with `@ref` | extra error `Cannot convert source type 'Microsoft.AspNetCore.Components.ElementReference' to target type 'RazorCacheRepro.Client.Components.Notice?'` |
| `imports-using` | a `@using` is added to `_Imports.razor`, which makes the same `@using` in an existing file redundant | **missing** `RedundantUsingDirective` |
| `imports-component` | the same `@using` is added to `_Imports.razor`, and an existing `.razor` file that had no such `@using` now uses a component from that namespace | extra `Razor.UnresolvedComponent` in the modified file, **missing** `RedundantUsingDirective` |
| `library-component-ref` | an existing `.razor` file uses a new component (C# only) from a referenced class library, captured with `@ref` | extra error `Cannot convert source type 'ElementReference' to target type 'RazorCacheRepro.Components.Callout?'`, extra `Razor.UnresolvedComponent` |
| `package-component-ref` | a new `PackageReference` to `Microsoft.AspNetCore.Components.QuickGrid`; an existing `.razor` file uses `QuickGrid`, captured with `@ref` | extra error `Cannot convert source type 'ElementReference' to target type 'QuickGrid<…>?'`, two extra `Razor.UnresolvedComponent`, two extra unused-member warnings |
| `analysis-mode` | `<AnalysisMode>All</AnalysisMode>` in `Directory.Build.props` | **missing** Roslyn `CA*` findings |
| `global-using` | a global `<Using Include="RazorCacheRepro.Api" />` in `Directory.Build.props`, which makes a `using` in an existing `.cs` file redundant | **missing** `RedundantUsingDirective` |
| `global-using-dropped` | the same global `<Using>`, and that `.cs` file drops its now redundant `using` | extra error `Cannot resolve symbol 'ApiInfo'` |
| `package-props-using` | only the version of a local package changes in `Directory.Packages.props` (1.0.0 to 1.1.0); the new version's `buildTransitive` props add a global `<Using>` for the package's namespace | **missing** `RedundantUsingDirective` |

## Repository layout

- Commit 1: unmodified `dotnet new blazor -n RazorCacheRepro -o . -int WebAssembly` (SDK 10.0.402).
- Commit 2: the reproduction (state A):
  - `RazorCacheRepro.Client/Components/InfoPanel.razor`: an ordinary component in the client project.
  - `RazorCacheRepro.Client/Pages/Overview.razor`: an existing page that uses `InfoPanel` through its own
    `@using RazorCacheRepro.Client.Components`.
  - `RazorCacheRepro.Client/Services/ApiLabel.cs` and `LabelText.cs`: existing files with a `using` directive for
    `RazorCacheRepro.Api` and for the local package's namespace `RazorCacheRepro.Widgets`.
  - `RazorCacheRepro.Api`: a class library referenced by the client project. `repro.sh` fills it with
    2000 generated model files (`RazorCacheRepro.Api/Generated`, not committed).
  - `RazorCacheRepro.Components`: a Razor class library referenced by the client project.
  - `RazorCacheRepro.slnx`: the template's solution migrated with `dotnet sln migrate`, plus the two libraries.
  - `Directory.Build.props`: empty in state A.
  - `Directory.Packages.props`: central package management, with `RazorCacheRepro.Widgets` 1.0.0.
  - `nuget.config`: nuget.org, plus `repro/feed` for `RazorCacheRepro.Widgets`.
  - `repro/package-sources/RazorCacheRepro.Widgets`: the local package. `repro.sh` packs it into `repro/feed` as
    1.0.0 and 1.1.0; the versions differ only in `buildTransitive/RazorCacheRepro.Widgets.props`, which is empty in
    1.0.0 and adds `<Using Include="RazorCacheRepro.Widgets" />` in 1.1.0.
  - `dotnet-tools.json`: `JetBrains.ReSharper.GlobalTools` 2026.2.3.1 (command `jb`).
  - `repro/scenarios/*.patch`: the change of each scenario ("the next commit").
  - `repro/CompareSarif.cs`: compares the findings of two SARIF files (a .NET 10 file-based app).
  - `repro.sh`: the steps below, scripted.

## Steps

For each scenario, `repro.sh` simulates two CI runs that share a `--caches-home`, plus a cold control. Each
step starts from a fresh `git clone` into the same path, as a CI checkout does, followed by generating the model
files and packing the local package:

1. State A: run InspectCode with `--caches-home=$WORK/cache-<scenario>`.
2. State B (`repro/scenarios/<scenario>.patch` applied): run InspectCode with the same `--caches-home`.
3. State B with an empty `--caches-home` (control).

It then compares all findings of step 2 with step 3.

InspectCode command used in every step, after `dotnet restore`, pinned to one CPU:

```
taskset -c 0 dotnet jb inspectcode RazorCacheRepro.slnx --build --properties:Configuration=Debug --severity=WARNING \
  --exclude='RazorCacheRepro.Api/**' --format=Sarif --output=<file> --caches-home=<dir> --no-updates
```

Run it in the .NET SDK container from a clone of this repository (all scenarios, or name some):

```
docker run --rm --cpus=8 --memory=14g --memory-swap=14g -v "$PWD":/repo:ro \
  mcr.microsoft.com/dotnet/sdk:10.0.402@sha256:0d99ebf1ccad15037b5c98c9fe8979d6b8dbac23812feae2277a0b277b5c5ffa bash /repo/repro.sh /repo [scenario...]
```

`repro.sh` exits with code 1 when any scenario's step 2 differs from its step 3.

The image is pinned by digest to the build that produced the output below; the `10.0.402` tag itself is rebuilt for OS
updates. The digest is a multi-platform index (linux/amd64, linux/arm64).

Without Docker, `repro.sh` also runs on a machine with .NET SDK 10.0.402. Where `taskset` does not exist (macOS), run it
unpinned with `REPRO_CPUS= bash repro.sh "$PWD" [scenario...]`; most scenarios then reproduce only occasionally (see
[What it takes to reproduce](#what-it-takes-to-reproduce)).

## Expected

For every scenario, step 2 reports the same findings as step 3.

## Actual

Step 2 differs from step 3 in every scenario (`+` only with the cache, `-` only without):

```
== new-razor-file
    + warning Razor.UnresolvedComponent RazorCacheRepro.Client/Pages/NewPage.razor:4 It appears like the 'InfoPanel' markup element is a component. Do you want to add the missing namespace import directive?
    6 findings with the cache, 5 without; 1 extra, 0 missing
== cs-component-ref
    + error .CSharpErrors RazorCacheRepro.Client/Pages/Overview.razor:8 Cannot convert source type 'Microsoft.AspNetCore.Components.ElementReference' to target type 'RazorCacheRepro.Client.Components.Notice?'
    6 findings with the cache, 5 without; 1 extra, 0 missing
== imports-using
    - warning RedundantUsingDirective RazorCacheRepro.Client/Pages/Overview.razor:2 Using directive is not required by the code and can be safely removed
    5 findings with the cache, 6 without; 0 extra, 1 missing
== imports-component
    + warning Razor.UnresolvedComponent RazorCacheRepro.Client/Pages/Counter.razor:8 It appears like the 'InfoPanel' markup element is a component. Do you want to add the missing namespace import directive?
    - warning RedundantUsingDirective RazorCacheRepro.Client/Pages/Overview.razor:2 Using directive is not required by the code and can be safely removed
    6 findings with the cache, 6 without; 1 extra, 1 missing
== library-component-ref
    + error .CSharpErrors RazorCacheRepro.Client/Pages/Overview.razor:9 Cannot convert source type 'Microsoft.AspNetCore.Components.ElementReference' to target type 'RazorCacheRepro.Components.Callout?'
    + warning Razor.UnresolvedComponent RazorCacheRepro.Client/Pages/Overview.razor:9 It appears like the 'Callout' markup element is a component. Do you want to add the missing namespace import directive?
    7 findings with the cache, 5 without; 2 extra, 0 missing
== package-component-ref
    + error .CSharpErrors RazorCacheRepro.Client/Pages/Overview.razor:9 Cannot convert source type 'Microsoft.AspNetCore.Components.ElementReference' to target type 'Microsoft.AspNetCore.Components.QuickGrid.QuickGrid<RazorCacheRepro.Client.Pages.Overview.Row>?'
    + warning NotAccessedPositionalProperty.Local RazorCacheRepro.Client/Pages/Overview.razor:22 Positional property 'RazorCacheRepro.Client.Pages.Overview.Row.Name' is never accessed (except in implicit Equals/ToString implementations)
    + warning Razor.UnresolvedComponent RazorCacheRepro.Client/Pages/Overview.razor:10 It appears like the 'PropertyColumn' markup element is a component. Do you want to add the missing namespace import directive?
    + warning Razor.UnresolvedComponent RazorCacheRepro.Client/Pages/Overview.razor:9 It appears like the 'QuickGrid' markup element is a component. Do you want to add the missing namespace import directive?
    + warning UnusedMember.Local RazorCacheRepro.Client/Pages/Overview.razor:19 Field '_rows' is never used
    10 findings with the cache, 5 without; 5 extra, 0 missing
== analysis-mode
    - warning CA1515 RazorCacheRepro.Client/Services/ApiLabel.cs:5 Because an application's API isn't typically referenced from outside the assembly, types can be made internal
    - warning CA1515 RazorCacheRepro.Client/Services/LabelText.cs:5 Because an application's API isn't typically referenced from outside the assembly, types can be made internal
    - warning CA2007 RazorCacheRepro.Client/Program.cs:5 Consider calling ConfigureAwait on the awaited task
    7 findings with the cache, 10 without; 0 extra, 3 missing
== global-using
    - warning RedundantUsingDirective RazorCacheRepro.Client/Services/ApiLabel.cs:1 Using directive is not required by the code and can be safely removed
    5 findings with the cache, 6 without; 0 extra, 1 missing
== global-using-dropped
    + error .CSharpErrors RazorCacheRepro.Client/Services/ApiLabel.cs:5 Cannot resolve symbol 'ApiInfo'
    6 findings with the cache, 5 without; 1 extra, 0 missing
== package-props-using
    - warning RedundantUsingDirective RazorCacheRepro.Client/Services/LabelText.cs:1 Using directive is not required by the code and can be safely removed
    5 findings with the cache, 6 without; 0 extra, 1 missing
== Reproduced: new-razor-file cs-component-ref imports-using imports-component library-component-ref package-component-ref analysis-mode global-using global-using-dropped package-props-using
```

This is the output of the command above in a new container from a fresh copy of this repository (exit code 1).

## What it takes to reproduce

The problem is timing-dependent. All of the following were in place for every scenario:

- **InspectCode limited to one CPU** (`taskset -c 0`, the `repro.sh` default `REPRO_CPUS=0`).
- **A large referenced class library**: 2000 generated model files in `RazorCacheRepro.Api`.
- **The library's project name sorting before the client project's** (`RazorCacheRepro.Api` before
  `RazorCacheRepro.Client`). The position of the project in the `.slnx` did not matter.
- **An `.slnx` solution.**

With pinning, `imports-component`, `library-component-ref`, `package-component-ref`, `analysis-mode`, `global-using`,
`global-using-dropped` and `package-props-using` reproduced in 2 of 2 runs each (the run above and one earlier run on
another pinned CPU).

Without CPU pinning (a container limited to four CPUs, `REPRO_CPUS=` empty), one run per scenario: only
`analysis-mode` reproduced (also unpinned on 18 CPUs on macOS). `new-razor-file` 0 of 4; `cs-component-ref` and
`imports-using` 0 of 2 each; `imports-component`, `library-component-ref`, `package-component-ref`, `global-using`,
`global-using-dropped` and `package-props-using` 0 of 1 each.

The conditions other than pinning were established for `new-razor-file` (see below); the other scenarios were only
run with them in place.

In the larger solution where the problem was first seen, all of these triggers occurred without any CPU limit.

### Variations that still reproduced (`new-razor-file`)

With the conditions above in place (one CPU, 2000-file library named to sort first, `.slnx`), these changes
did not stop it (hits / attempts). These runs used an earlier state A without `RazorCacheRepro.Components`,
`Directory.Build.props`, central package management and the local package:

- Component as a single `.razor` file, or with a `.razor.cs` code-behind (8/8, 4/4).
- New page with only the component and some markup; with `@rendermode InteractiveAuto` and a nested
  component; or capturing the component with `@ref` (8/8, 4/4, 2/2 and the `repro.sh` runs).
- Component in `Components` or in `Components/General` namespace (2/2, 8/8).
- New page named `NewPage.razor` or `Probe.razor` (2/2, 8/8).
- With or without `EmitCompilerGeneratedFiles=true` in `Directory.Build.props` (8/8, 2/2).
- Library files committed, or generated after checkout (8/8, 2/2).
- New page committed in state B, or copied in after checkout (8/8, 2/2).
- State B using a copy of the cache directory, or the same directory in place (8/8, 2/2).
- Library excluded from analysis with `--exclude`, or analysed (4/4, 4/4).
- 200 additional components in the client project, plus more package references, analyzers and a second
  class library (6/6).
- An existing page using the component through its own `@using` in state A (2/2).

A hit is a cached state-B run that reports `Razor.UnresolvedComponent` in the new page. Where cold controls of
the same layout were run, they reported none.

## Looked at, did not reproduce (`new-razor-file`)

Same steps, cached run compared with a cold run, with the earlier state A described above. These are small samples
of a timing-dependent problem, so they show where it was *not* observed, not that a factor is irrelevant.

With the reproducing layout, changing one condition:

- No CPU pinning: 0/4. The larger variant above (6/6 on one CPU): 0/6 unpinned, 0/4 on two CPUs, 0/4 on
  four CPUs.
- Library with 500 generated files: 0/4.
- Library named `RazorCacheRepro.Models` (sorts after the client project): 0/6.
- `.sln` instead of `.slnx`: 0/2.

Without a large referenced library:

- 200 client components of about 90 lines each (forms, loops, nested components): 0/4 on one CPU.
- 320 trivial client components in 16 folders: 0/8 unpinned, 0/8 on one CPU.
- 100 client components that inject `IStringLocalizer<T>` and have three culture `.resx` files each:
  0/8 unpinned, 0/8 on one CPU.
- A deliberately slow (30 s) source generator in the client project: 0/4 unpinned.

Single unpinned runs on the small template without a large library (each 0/1; these lacked the conditions
above, so they do not rule the factor out):

- CleanupCode (`--no-build`, same `--caches-home`) before InspectCode, with formatted and unformatted sources.
- New component used from a modified existing page or from a new page; component in a new namespace imported
  through `_Imports.razor` or `@using`; page and component in the client or in the server project.
- `@ref` to the component; `EmitCompilerGeneratedFiles=true`; sibling culture `.resx` files; a new
  `PackageReference`.
- Source generator packages (`NetEscapades.EnumGenerators`, `StronglyTypedId`), `Microsoft.CodeAnalysis.BannedApiAnalyzers`
  with an extra `AdditionalFiles` item, `JetBrains.Annotations`, a Razor component library package.
- Existing components inheriting `Editor<T>`, with `T` from the same project or from a referenced project.
- C# raw string literals in existing `.razor` files. (These make InspectCode log
  `Roslyn Source Generator error from RazorSourceGenerator from Unterminated string literal` in some runs,
  cached or cold; that is a separate symptom.)
- 800 trivial components (client and server project); a cache built over several earlier runs; linux-x64
  (emulated) instead of linux-arm64.

A fresh checkout into a different path does not reuse the cache at all: `--caches-home` stores caches per
solution path, so that run is a cold run.

## Tested versions

- JetBrains.ReSharper.GlobalTools 2026.2.3.1 (the output above).
- JetBrains.ReSharper.GlobalTools 2026.3.0-eap07 (`JetBrains Inspect Code 2026.3 EAP 7`): all ten scenarios
  reproduced with the same output, with `dotnet-tools.json` changed to that version and InspectCode pinned to another
  CPU.
- .NET SDK 10.0.402, runtime 10.0.13, `mcr.microsoft.com/dotnet/sdk:10.0.402@sha256:0d99ebf1ccad15037b5c98c9fe8979d6b8dbac23812feae2277a0b277b5c5ffa` (Ubuntu 24.04), linux-arm64.
- macOS (arm64) with .NET SDK 10.0.402, unpinned (`REPRO_CPUS=`): `analysis-mode` reproduced.
