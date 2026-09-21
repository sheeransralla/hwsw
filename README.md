# HWSW Project: Benchmark Optimization, Analysis and Hardware Acceleration

Analysis, software optimization and hardware-acceleration proposals for two
benchmarks from the [pyperformance](https://github.com/python/pyperformance)
suite:

- **pyflate** – a pure-Python bzip2 decompressor
- **raytrace** – a pure-Python ray tracer

Each benchmark has a full report, a script that reproduces every measurement,
the optimized benchmark code, the raw results, and a hardware accelerator in
SystemVerilog with a testbench.

## Results

| Benchmark | Baseline | Optimized | Speedup | Hardware accelerator |
|---|---|---|---|---|
| pyflate | 1122.7 ms ± 13.4 | 396.7 ms ± 3.9 | **2.83×** | inverse-BWT engine |
| raytrace | 798.6 ms ± 8.5 | 283.8 ms ± 2.2 | **2.81×** | ray/scene intersection unit |

Measured with pyperformance in rigorous mode (120 values per result) on
CPython 3.10.12, in a single-vCPU QEMU/KVM virtual machine. The project
requirement is an improvement of at least 7% on two benchmarks.

Every optimization preserves the benchmark's output: pyflate checks the MD5 of
its decompressed data on every run, and raytrace is checked with
`check_output.py`, which compares the rendered image against the original.

## Repository layout

```
.
├── README.md
├── report_pyflate.txt          full report: analysis, optimizations, results,
├── report_raytrace.txt         hardware proposal and conclusion
├── script_pyflate.sh           reproduces every pyflate measurement
├── script_raytrace.sh          reproduces every raytrace measurement
├── prompt.txt                  record of the AI tools used
│
├── pyflate/
│   ├── bm_pyflate_opt/
│   │   └── run_benchmark.py    the optimized benchmark
│   ├── bench_driver.py         runs a benchmark without the pyperf harness,
│   │                           for profiling
│   ├── characterize_pyflate.py counts the workload (symbols, MTF ops, ...)
│   ├── summarize_pyspy.py      summarizes py-spy samples by function and line
│   ├── hw/                     inverse-BWT accelerator, testbench, notes
│   └── results/                baseline, per-step results, profiles,
│                               flame graphs
│
└── raytrace/
    ├── bm_raytrace_opt/
    │   └── run_benchmark.py    the optimized benchmark
    ├── bench_driver.py         (same helpers as pyflate)
    ├── summarize_pyspy.py
    ├── characterize_raytrace.py counts the workload (rays, tests, objects)
    ├── check_output.py         compares the rendered images of two versions
    ├── hw/                     ray/scene intersection accelerator, testbench,
    │                           vector generator
    └── results/
```

Created by `setup` and not committed: `*/bm_pyflate/` and `*/bm_raytrace/`
(the unmodified benchmarks, copied from the installed pyperformance),
`*/venv/` (pyperformance's virtual environments), `tools/FlameGraph/`, and the
large binary profiler outputs (`*.data`, `*.prof`).

## Requirements

- Ubuntu 22.04 (the course VM image), with Python 3.10
- `python3`, `python3-dbg`, `python3-venv`, `git`, `perl`, Linux `perf`
- pyperformance and pyperf (installed by `setup`)
- optional: py-spy, for Python-level flame graphs
- optional: Icarus Verilog (`apt-get install iverilog`), for the hardware
  testbenches

## Reproducing the results

The two scripts have identical stages. Run them from the repository root.

```bash
./script_pyflate.sh setup        # install tools, copy the original benchmark
./script_pyflate.sh baseline     # pyperformance run of the original
./script_pyflate.sh profile      # cProfile, perf, flame graphs, py-spy
./script_pyflate.sh optimized    # pyperformance run of the optimized version
./script_pyflate.sh profile-opt  # the same profiles for the optimized version
./script_pyflate.sh compare      # comparison table and speedup
./script_pyflate.sh all          # every stage above, in order
```

Replace `pyflate` with `raytrace` for the second benchmark.

Settings are read from the environment:

| Variable | Default | Meaning |
|---|---|---|
| `MODE` | *(empty)* | `--fast` or `--rigorous`; the reported results use `--rigorous` |
| `SKIP_APT` | `0` | `1` skips package installation when the tools are already present |
| `PERF_EVENT` | `cpu-clock` | perf sampling event |
| `PERF_FREQ` | `999` | sampling frequency, in Hz |
| `PROFILE_LOOPS` | `5` | benchmark iterations per profiling run |

For example, the reported baselines were recorded with:

```bash
MODE=--rigorous ./script_pyflate.sh baseline
```

The optimized results were recorded one step at a time; `save` keeps a
snapshot of each:

```bash
MODE=--rigorous ./script_raytrace.sh optimized
./script_raytrace.sh compare
./script_raytrace.sh save step1_slots      # results + source of this step
```

### Checking raytrace correctness

The raytrace benchmark does not verify its own output, so every change is
checked by rendering both versions and comparing the images:

```bash
python3 raytrace/check_output.py raytrace/bm_raytrace raytrace/bm_raytrace_opt
```

It must print `OK: identical output`. The reference digest for the default
100 × 100 image is `f3c700588a9b6320fb1e46027142f205`.

### Simulating the accelerators

```bash
cd pyflate/hw
iverilog -g2012 -o tb tb_bwt_accel.sv bwt_accel.sv && vvp tb

cd ../../raytrace/hw
python3 gen_vectors.py ../bm_raytrace        # needs setup to have run
iverilog -g2012 -o tb tb_ray_scene_isect.sv ray_scene_isect.sv fp64_units.sv
vvp tb
```

Both testbenches compare the hardware against vectors produced by the
benchmarks' own Python code. See the `README_hw.md` in each `hw/` folder for
the expected output and the design notes.

## Notes on the measurement environment

Three problems in the course VM affect measurements; the scripts handle them,
but they are worth knowing when reading the results:

- **Background CPU load.** Ubuntu's update checker (`apt-check`) ran during
  early measurements and produced false slowdowns of up to 1.65×, visible as
  two separate clusters in `pyperf dump`. Before measuring, disable it:
  ```bash
  systemctl stop unattended-upgrades apt-daily.timer apt-daily-upgrade.timer
  systemctl disable unattended-upgrades apt-daily.timer apt-daily-upgrade.timer
  ```
  and confirm the CPU is idle with `top`.
- **No hardware performance counters.** The virtual CPU records no samples
  for perf's default `cycles` event, so the scripts sample `cpu-clock`
  instead.
- **Small disk.** The image has a 2 GB root filesystem, and `apt-get update`
  alone can fill it. Use `SKIP_APT=1 ./script_*.sh setup` once the tools are
  installed.

The perf flame graphs show most samples under `[unknown]`: the Ubuntu CPython
build omits frame pointers, so perf cannot reconstruct call stacks. Their
per-symbol percentages remain valid; the py-spy flame graphs provide the call
hierarchy. Both reports discuss this in section 2.

## Reports

Each report follows the structure the assignment requires:

1. Overview – purpose, workload, libraries, algorithms, data structures
2. Initial analysis – environment, baseline, flame graphs, bottlenecks
3. Optimizations – each change, what the profile showed, what it gained
4. Performance comparison – per-step results and the optimized profile
5. Hardware acceleration proposal – design, interfaces, performance estimate,
   trade-offs
6. Conclusion
