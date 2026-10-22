#!/usr/bin/env bash
# Reproduces InspectCode results that differ when --caches-home holds caches from the previous commit.
#
# Usage (inside the .NET SDK container, see README.md):
#   bash repro.sh <path-or-url-of-this-repository> [scenario...]
#
# Scenarios (patches in repro/scenarios, applied for state B; default: all):
#   new-razor-file         a new .razor file uses an existing component
#   cs-component-ref       an existing .razor file uses a new component declared in C# only, with @ref
#   imports-using          a @using is added to _Imports.razor
#   imports-component      a @using is added to _Imports.razor and a modified .razor file uses a component it imports
#   library-component-ref  a new component in a referenced class library is used with @ref from an existing .razor file
#   package-component-ref  a new package with components (QuickGrid) is used with @ref from an existing .razor file
#   analysis-mode          AnalysisMode=All is set in Directory.Build.props
#   global-using           a global <Using> is added in Directory.Build.props
#   global-using-dropped   the same, and a .cs file drops its own using directive for that namespace
#   package-props-using    a version bump of a local package whose new buildTransitive props add a global <Using>
#
# Environment:
#   REPRO_CPUS   CPU list passed to `taskset -c` for InspectCode (default: 0). Empty disables pinning, which is
#                needed where `taskset` does not exist (macOS); most scenarios then reproduce only occasionally.
#   MODEL_FILES  Number of generated model files in RazorCacheRepro.Api (default: 2000).
#   WORK         Working directory (default: /tmp/repro).
#
# Exit code: 1 if any scenario's cached run differs from its cold run, otherwise 0.
set -euo pipefail

REPO=${1:?usage: repro.sh <path-or-url-of-this-repository> [scenario...]}
shift
SCENARIOS=("$@")
if [ ${#SCENARIOS[@]} -eq 0 ]; then SCENARIOS=(new-razor-file cs-component-ref imports-using imports-component library-component-ref package-component-ref
  analysis-mode global-using global-using-dropped package-props-using); fi
REPRO_CPUS=${REPRO_CPUS-0}
MODEL_FILES=${MODEL_FILES:-2000}
WORK=${WORK:-/tmp/repro}
SRC=$WORK/src
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 MSBUILDDISABLENODEREUSE=1

pin=()
if [ -n "$REPRO_CPUS" ]; then
  command -v taskset > /dev/null || { echo "taskset not found: set REPRO_CPUS= to run InspectCode unpinned"; exit 2; }
  pin=(taskset -c "$REPRO_CPUS")
fi

mkdir -p "$WORK"

# Fresh clone at the same path every time, like a CI checkout: every file gets a new timestamp.
checkout() {
  if [ -d "$SRC" ]; then mv "$SRC" "$(mktemp -d "$WORK/old-src.XXXXXX")"; fi
  git -c safe.directory='*' clone --quiet "$REPO" "$SRC"
  generate_models
  pack_packages
}

# State B: the scenario's change, as a commit on top of state A would bring it.
apply_scenario() {
  git -C "$SRC" apply "repro/scenarios/$1.patch"
}

# A large referenced class library. Its size is what makes the race observable.
generate_models() {
  local dir=$SRC/RazorCacheRepro.Api/Generated
  mkdir -p "$dir"
  for i in $(seq -w 1 "$MODEL_FILES"); do
    {
      echo "namespace RazorCacheRepro.Api;"
      for j in 0 1 2 3 4 5 6 7 8 9; do
        echo
        echo "public sealed class Model${i}x${j}"
        echo "{"
        echo "    public int Id { get; set; }"
        echo "    public string Name { get; set; } = \"\";"
        echo "    public DateTimeOffset Created { get; set; }"
        echo "    public List<string> Tags { get; set; } = [];"
        echo "}"
      done
    } > "$dir/Models$i.cs"
  done
}

# The local package used by package-props-using, in both versions, as a NuGet feed (see nuget.config).
pack_packages() {
  local version
  mkdir -p "$SRC/repro/feed"
  for version in 1.0.0 1.1.0; do
    dotnet pack "$SRC/repro/package-sources/RazorCacheRepro.Widgets" -c Release -p:Version="$version" \
      -o "$SRC/repro/feed" > /dev/null
  done
}

# $1 = caches-home, $2 = label
inspect() {
  (
    cd "$SRC"
    dotnet tool restore > /dev/null
    dotnet restore RazorCacheRepro.slnx > /dev/null
    set +e
    ${pin[@]+"${pin[@]}"} dotnet jb inspectcode RazorCacheRepro.slnx \
      --build \
      --properties:Configuration=Debug \
      --severity=WARNING \
      --exclude='RazorCacheRepro.Api/**' \
      --format=Sarif \
      --output="$WORK/$2.sarif" \
      --caches-home="$1" \
      --no-updates > "$WORK/$2.log" 2>&1
    echo "  $2: inspectcode exit code $?"
    set -e
    dotnet build-server shutdown > /dev/null 2>&1 || true
  )
}

echo "SDK $(dotnet --version), $(uname -m), REPRO_CPUS='${REPRO_CPUS}', MODEL_FILES=$MODEL_FILES"
reproduced=()
for scenario in "${SCENARIOS[@]}"; do
  echo "== $scenario"
  echo "  1. State A (parent commit): build the cache"
  checkout
  [ -f "$SRC/repro/scenarios/$scenario.patch" ] || { echo "unknown scenario: $scenario"; exit 2; }
  inspect "$WORK/cache-$scenario" "$scenario-1-state-a"
  echo "  2. State B (repro/scenarios/$scenario.patch applied), fresh checkout, same --caches-home"
  checkout
  apply_scenario "$scenario"
  inspect "$WORK/cache-$scenario" "$scenario-2-state-b-cached"
  echo "  3. State B, fresh checkout, empty --caches-home (control)"
  checkout
  apply_scenario "$scenario"
  inspect "$WORK/cache-$scenario-cold" "$scenario-3-state-b-cold"
  echo "  Findings of run 2 (with the cache) compared with run 3 (without):"
  if dotnet run "$SRC/repro/CompareSarif.cs" -- "$WORK/$scenario-2-state-b-cached.sarif" "$WORK/$scenario-3-state-b-cold.sarif"; then
    echo "  $scenario: not reproduced in this run (the problem is timing-dependent; see README.md)."
  else
    echo "  $scenario: REPRODUCED: the run with the cache differs from the run without it."
    reproduced+=("$scenario")
  fi
done

echo "== Reproduced: ${reproduced[*]:-none}"
[ ${#reproduced[@]} -eq 0 ]
