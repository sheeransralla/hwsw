#!/usr/bin/env bash
#
# script_pyflate.sh - setup, baseline, profiling, optimized run and
# comparison for the pyperformance "pyflate" benchmark.
#
# Usage:
#   ./script_pyflate.sh setup       install tools, copy the original benchmark
#   ./script_pyflate.sh baseline    pyperformance run of the original benchmark
#   ./script_pyflate.sh profile     cProfile, perf report and flame graph (original)
#   ./script_pyflate.sh optimized   pyperformance run of the optimized benchmark
#   ./script_pyflate.sh profile-opt cProfile, perf report and flame graph (optimized)
#   ./script_pyflate.sh compare     compare baseline and optimized results
#   ./script_pyflate.sh save NAME   snapshot the current optimized results
#   ./script_pyflate.sh all         every stage above, in order
#
# Settings can be overridden from the environment, for example:
#   MODE=--rigorous ./script_pyflate.sh baseline
#   PROFILE_LOOPS=10 ./script_pyflate.sh profile
#   SKIP_APT=1 ./script_pyflate.sh setup      (packages already installed)
#
# Repository layout used by this script:
#   script_pyflate.sh
#   pyflate/bm_pyflate/        original benchmark (copied from pyperformance)
#   pyflate/bm_pyflate_opt/    optimized benchmark (edit run_benchmark.py here)
#   pyflate/MANIFEST_opt       pyperformance manifest for the optimized copy
#   pyflate/bench_driver.py    runs bench_pyflake() directly for profiling
#   pyflate/results/           all generated output
#   tools/FlameGraph/          Brendan Gregg's FlameGraph scripts (cloned)

set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ROOT="$ROOT/pyflate"
ORIG_DIR="$BENCH_ROOT/bm_pyflate"
OPT_DIR="$BENCH_ROOT/bm_pyflate_opt"
OPT_MANIFEST="$BENCH_ROOT/MANIFEST_opt"
DRIVER="$BENCH_ROOT/bench_driver.py"
RESULTS="$BENCH_ROOT/results"
FLAMEGRAPH_DIR="$ROOT/tools/FlameGraph"

# Timing uses the release interpreter; perf uses the debug build, whose
# symbols show CPython's internal C functions in the call graph.
PYTHON="${PYTHON:-python3}"
PYTHON_DBG="${PYTHON_DBG:-python3-dbg}"

MODE="${MODE:-}"                    # "", --fast or --rigorous
PERF_FREQ="${PERF_FREQ:-999}"       # sampling frequency (Hz)
PERF_EVENT="${PERF_EVENT:-cpu-clock}" # sampling event (cycles needs a PMU)
SKIP_APT="${SKIP_APT:-0}"           # 1 = setup skips apt (tools already installed)

# The VM runs as root, where sudo may not be installed; elsewhere it is needed.
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
fi
PROFILE_LOOPS="${PROFILE_LOOPS:-5}" # decompressions per profiling run

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
log()  { printf '\n==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found; run: $0 setup"; }

# pyperformance creates its virtual environments in ./venv, so it runs from
# $BENCH_ROOT (add pyflate/venv/ to .gitignore).
pyperformance_cmd() { (cd "$BENCH_ROOT" && "$PYTHON" -m pyperformance "$@"); }

# pyperformance -p needs an absolute path because it runs from $BENCH_ROOT.
python_path() { command -v "$PYTHON" || die "$PYTHON not found"; }

find_pyspy() {
    command -v py-spy 2>/dev/null && return
    [[ -x "$HOME/.local/bin/py-spy" ]] && echo "$HOME/.local/bin/py-spy"
}

check_file() { [[ -f "$1" ]] || die "missing $1 ($2)"; }

# ----------------------------------------------------------------------------
# Stage: setup
# ----------------------------------------------------------------------------
stage_setup() {
    if [[ "$SKIP_APT" == 1 ]]; then
        log "Skipping system packages (SKIP_APT=1)"
    else
        log "Installing system packages"
        $SUDO apt-get update
        $SUDO apt-get install -y python3 python3-dbg python3-pip python3-venv git perl
        if ! command -v perf >/dev/null 2>&1; then
            $SUDO apt-get install -y "linux-tools-$(uname -r)" \
                || $SUDO apt-get install -y linux-tools-generic
        fi
        # apt lists and cached packages are large; the VM image has little room
        $SUDO apt-get clean
    fi

    log "Allowing perf to sample user and kernel stacks"
    $SUDO sysctl -w kernel.perf_event_paranoid=-1
    $SUDO sysctl -w kernel.kptr_restrict=0

    log "Installing Python packages"
    # Newer distributions refuse installs outside a virtual environment
    # (PEP 668); --break-system-packages is the documented override.
    pip_install() {
        "$PYTHON" -m pip install --user --upgrade "$@" \
            || "$PYTHON" -m pip install --user --upgrade --break-system-packages "$@"
    }
    pip_install pyperformance pyperf \
        || echo "could not install pyperformance/pyperf (already present?)"
    pip_install py-spy \
        || echo "py-spy not installed (optional Python-level profile)"

    log "Fetching FlameGraph scripts"
    if [[ ! -d "$FLAMEGRAPH_DIR" ]]; then
        git clone --depth 1 https://github.com/brendangregg/FlameGraph.git \
            "$FLAMEGRAPH_DIR"
    fi

    log "Copying the original benchmark from the installed pyperformance"
    local src
    src="$("$PYTHON" -c 'import pyperformance, os; print(os.path.dirname(pyperformance.__file__))')/data-files/benchmarks/bm_pyflate"
    [[ -d "$src" ]] || die "bm_pyflate not found in $src"
    mkdir -p "$BENCH_ROOT"
    if [[ ! -d "$ORIG_DIR" ]]; then
        cp -r "$src" "$ORIG_DIR"
        rm -rf "$ORIG_DIR/__pycache__"
    fi

    log "Creating the optimized copy (only if it does not exist yet)"
    if [[ ! -d "$OPT_DIR" ]]; then
        mkdir -p "$OPT_DIR"
        cp "$ORIG_DIR/run_benchmark.py" "$OPT_DIR/"
        cp -r "$ORIG_DIR/data" "$OPT_DIR/"
        # The json result keeps the name "pyflate" (set in run_benchmark.py),
        # so baseline and optimized results can be compared directly.
        cat > "$OPT_DIR/pyproject.toml" <<'EOF'
[project]
name = "pyperformance_bm_pyflate_opt"
requires-python = ">=3.8"
dependencies = ["pyperf"]
version = "1.0.0"

[tool.pyperformance]
name = "pyflate_opt"
EOF
    fi
    printf '[benchmarks]\n\nname\tmetafile\npyflate_opt\t<local>\n' > "$OPT_MANIFEST"

    log "Recording the environment"
    mkdir -p "$RESULTS"
    {
        echo "date: $(date -Iseconds)"
        echo "kernel: $(uname -a)"
        echo "python: $("$PYTHON" --version 2>&1)"
        echo "python-dbg: $("$PYTHON_DBG" --version 2>&1 || echo missing)"
        echo "pyperformance: $("$PYTHON" -m pyperformance --version 2>&1)"
        echo "perf: $(perf --version 2>&1 || echo missing)"
        echo "original run_benchmark.py md5: $(md5sum "$ORIG_DIR/run_benchmark.py" | cut -d' ' -f1)"
        echo
        lscpu
    } > "$RESULTS/environment.txt"
    echo "Environment written to $RESULTS/environment.txt"
}

# ----------------------------------------------------------------------------
# Stage: baseline / optimized pyperformance runs
# ----------------------------------------------------------------------------
stage_baseline() {
    check_file "$ORIG_DIR/run_benchmark.py" "run setup first"
    mkdir -p "$RESULTS"
    log "pyperformance baseline run ${MODE:-(default mode)}"
    rm -f "$RESULTS/baseline.json"
    pyperformance_cmd run -p "$(python_path)" -b pyflate $MODE \
        -o "$RESULTS/baseline.json"
    "$PYTHON" -m pyperf stats "$RESULTS/baseline.json" \
        | tee "$RESULTS/baseline_stats.txt"
}

stage_optimized() {
    check_file "$OPT_DIR/run_benchmark.py" "run setup first"
    check_file "$RESULTS/baseline.json" "run baseline first"
    if cmp -s "$ORIG_DIR/run_benchmark.py" "$OPT_DIR/run_benchmark.py"; then
        echo "WARNING: optimized run_benchmark.py is identical to the original" >&2
    fi
    log "pyperformance optimized run ${MODE:-(default mode)}"
    rm -f "$RESULTS/optimized.json"
    # --same-loops reuses the baseline's loop count, so each measured value
    # covers the same amount of work in both runs.
    pyperformance_cmd run -p "$(python_path)" --manifest "$OPT_MANIFEST" \
        -b pyflate_opt $MODE --same-loops "$RESULTS/baseline.json" \
        -o "$RESULTS/optimized.json"
    "$PYTHON" -m pyperf stats "$RESULTS/optimized.json" \
        | tee "$RESULTS/optimized_stats.txt"
}

# ----------------------------------------------------------------------------
# Stage: profiling (cProfile + perf + flame graphs)
# ----------------------------------------------------------------------------
profile_one() {
    local label="$1" bench_dir="$2"
    check_file "$bench_dir/run_benchmark.py" "run setup first"
    need perf
    [[ -x "$FLAMEGRAPH_DIR/flamegraph.pl" ]] || die "FlameGraph missing; run: $0 setup"
    mkdir -p "$RESULTS"

    log "[$label] cProfile (Python-level functions; timings include profiler overhead)"
    "$PYTHON" "$DRIVER" --bench-dir "$bench_dir" --loops 1 \
        --cprofile "$RESULTS/cprofile_$label.prof" \
        > "$RESULTS/cprofile_$label.txt"
    echo "Written $RESULTS/cprofile_$label.txt"

    log "[$label] perf record with $PYTHON_DBG ($PROFILE_LOOPS loops, ${PERF_FREQ} Hz)"
    # cpu-clock is a timer-based software event. It works in VMs that do not
    # expose a hardware PMU, where the "cycles" event records no samples.
    perf record -e "$PERF_EVENT" -F "$PERF_FREQ" -g \
        -o "$RESULTS/perf_$label.data" -- \
        "$PYTHON_DBG" "$DRIVER" --bench-dir "$bench_dir" --loops "$PROFILE_LOOPS"

    local samples
    samples="$(perf report -i "$RESULTS/perf_$label.data" --stdio 2>/dev/null \
        | awk '/^# Samples:/ && !found {print $3; found = 1}' || true)"
    echo "perf samples recorded: ${samples:-0}"
    [[ "${samples:-0}" != "0" ]] || die "perf recorded no samples; try PERF_EVENT=cpu-clock"

    log "[$label] perf reports"
    # Call-graph view (Children = time including callees), as in the course guide.
    perf report -i "$RESULTS/perf_$label.data" --stdio \
        > "$RESULTS/perf_report_$label.txt" 2>/dev/null
    # Flat view of the hottest functions by their own (self) time.
    perf report -i "$RESULTS/perf_$label.data" --stdio --no-children \
        --sort dso,symbol -g none \
        > "$RESULTS/perf_top_symbols_$label.txt" 2>/dev/null
    echo "Written $RESULTS/perf_report_$label.txt"
    echo "Written $RESULTS/perf_top_symbols_$label.txt"

    log "[$label] flame graph"
    perf script -i "$RESULTS/perf_$label.data" 2>/dev/null \
        | "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" \
        > "$RESULTS/perf_$label.folded"
    "$FLAMEGRAPH_DIR/flamegraph.pl" --title "pyflate ($label) - $PYTHON_DBG" \
        "$RESULTS/perf_$label.folded" > "$RESULTS/flamegraph_$label.svg"
    echo "Written $RESULTS/flamegraph_$label.svg"

    local pyspy
    pyspy="$(find_pyspy || true)"
    if [[ -n "$pyspy" ]]; then
        log "[$label] py-spy: flame graph and raw samples (Python function names)"
        # py-spy can print "No child process" while exiting after it has already
        # written its output, so the files are checked instead of the exit code.
        "$pyspy" record -r "$PERF_FREQ" -o "$RESULTS/pyspy_$label.svg" -- \
            "$PYTHON" "$DRIVER" --bench-dir "$bench_dir" --loops "$PROFILE_LOOPS" \
            >/dev/null 2>&1 || true
        "$pyspy" record -r "$PERF_FREQ" --format raw \
            -o "$RESULTS/pyspy_$label.folded" -- \
            "$PYTHON" "$DRIVER" --bench-dir "$bench_dir" --loops "$PROFILE_LOOPS" \
            >/dev/null 2>&1 || true
        if [[ -s "$RESULTS/pyspy_$label.folded" ]]; then
            echo "Written $RESULTS/pyspy_$label.svg"
            echo "Written $RESULTS/pyspy_$label.folded"
            "$PYTHON" "$ROOT/pyflate/summarize_pyspy.py" \
                "$RESULTS/pyspy_$label.folded" \
                | tee "$RESULTS/pyspy_$label.txt"
        else
            echo "py-spy produced no output (optional); continuing"
        fi
    else
        echo "py-spy not installed (optional); skipping Python-level profile"
    fi
}

stage_profile()     { profile_one original  "$ORIG_DIR"; }
stage_profile_opt() { profile_one optimized "$OPT_DIR"; }

# ----------------------------------------------------------------------------
# Stage: comparison
# ----------------------------------------------------------------------------
stage_compare() {
    check_file "$RESULTS/baseline.json"  "run baseline first"
    check_file "$RESULTS/optimized.json" "run optimized first"
    log "Comparing baseline and optimized results"
    {
        echo "=== pyperf compare_to (baseline -> optimized) ==="
        "$PYTHON" -m pyperf compare_to "$RESULTS/baseline.json" \
            "$RESULTS/optimized.json" --table
        echo
        echo "=== summary ==="
        "$PYTHON" - "$RESULTS/baseline.json" "$RESULTS/optimized.json" <<'EOF'
import sys
import pyperf

base = pyperf.Benchmark.load(sys.argv[1])
opt = pyperf.Benchmark.load(sys.argv[2])
b_mean, b_sd = base.mean(), base.stdev()
o_mean, o_sd = opt.mean(), opt.stdev()
print(f"baseline : {b_mean * 1e3:8.1f} ms +- {b_sd * 1e3:.1f} ms "
      f"({len(base.get_values())} values)")
print(f"optimized: {o_mean * 1e3:8.1f} ms +- {o_sd * 1e3:.1f} ms "
      f"({len(opt.get_values())} values)")
print(f"time reduction: {(1 - o_mean / b_mean) * 100:.1f} %")
print(f"speedup       : {b_mean / o_mean:.2f}x")
print("target (course): at least 7 % improvement -> "
      + ("met" if o_mean <= 0.93 * b_mean else "NOT met"))
EOF
    } | tee "$RESULTS/comparison.txt"
}

# ----------------------------------------------------------------------------
# Stage: save - snapshot the current optimized results under a step name
# ----------------------------------------------------------------------------
stage_save() {
    local name="${1:-}"
    [[ -n "$name" ]] || die "usage: $0 save <step-name>"
    check_file "$RESULTS/optimized.json" "run optimized first"
    cp "$RESULTS/optimized.json" "$RESULTS/opt_$name.json"
    [[ -f "$RESULTS/comparison.txt" ]] &&
        cp "$RESULTS/comparison.txt" "$RESULTS/comparison_$name.txt"
    cp "$OPT_DIR/run_benchmark.py" "$RESULTS/run_benchmark_$name.py"
    echo "Saved results and source snapshot for step '$name'"
}

# ----------------------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------------------
case "${1:-}" in
    setup)       stage_setup ;;
    baseline)    stage_baseline ;;
    profile)     stage_profile ;;
    optimized)   stage_optimized ;;
    profile-opt) stage_profile_opt ;;
    compare)     stage_compare ;;
    save)        stage_save "${2:-}" ;;
    all)
        stage_setup
        stage_baseline
        stage_profile
        stage_optimized
        stage_profile_opt
        stage_compare
        ;;
    *)
        sed -n '3,19p' "$0"
        exit 1
        ;;
esac
