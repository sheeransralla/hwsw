#!/usr/bin/env python3
"""Run a pyperformance benchmark function directly, without the pyperf harness.

pyperf.Runner spawns worker processes and calibrates loops, which makes
perf/cProfile output noisy and hard to attribute. This driver imports
run_benchmark.py from a given benchmark directory and calls bench_pyflake()
in the current process, so profilers see only the decompression work.

Usage:
  python3 bench_driver.py --bench-dir bm_pyflate --loops 5
  python3 bench_driver.py --bench-dir bm_raytrace --loops 5
  python3 bench_driver.py --bench-dir bm_pyflate --loops 1 --cprofile out.prof
"""
import argparse
import cProfile
import importlib.util
import os
import pstats
import sys


def load_benchmark(bench_dir):
    path = os.path.join(bench_dir, "run_benchmark.py")
    spec = importlib.util.spec_from_file_location("run_benchmark", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # __name__ != "__main__": no Runner starts
    return module


def bench_call(bm, bench_dir, loops, width, height):
    """Return (function, args) for the benchmark found in this module."""
    if hasattr(bm, "bench_pyflake"):          # pyflate
        data = os.path.join(bench_dir, "data", "interpreter.tar.bz2")
        return bm.bench_pyflake, (loops, data)
    if hasattr(bm, "bench_raytrace"):         # raytrace
        # filename=None: the benchmark then skips writing the PPM image
        return bm.bench_raytrace, (loops, width, height, None)
    for name in dir(bm):                      # any other pyperformance benchmark
        if name.startswith("bench_"):
            return getattr(bm, name), (loops,)
    raise SystemExit("no bench_* function found in run_benchmark.py")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--bench-dir", required=True,
                        help="directory containing run_benchmark.py")
    parser.add_argument("--loops", type=int, default=5,
                        help="iterations of the benchmark body (default: 5)")
    parser.add_argument("--width", type=int, default=100,
                        help="raytrace image width (default: 100)")
    parser.add_argument("--height", type=int, default=100,
                        help="raytrace image height (default: 100)")
    parser.add_argument("--cprofile", metavar="FILE",
                        help="profile with cProfile and write stats to FILE")
    parser.add_argument("--top", type=int, default=30,
                        help="rows to print from cProfile stats (default: 30)")
    args = parser.parse_args()

    bench_dir = os.path.abspath(args.bench_dir)
    bm = load_benchmark(bench_dir)
    func, call_args = bench_call(bm, bench_dir, args.loops, args.width, args.height)

    if args.cprofile:
        profiler = cProfile.Profile()
        dt = profiler.runcall(func, *call_args)
        profiler.dump_stats(args.cprofile)
        stats = pstats.Stats(args.cprofile)
        print("=== sorted by tottime (time inside the function itself) ===")
        stats.sort_stats("tottime").print_stats(args.top)
        print("=== sorted by cumtime (time including callees) ===")
        stats.sort_stats("cumtime").print_stats(args.top)
    else:
        dt = func(*call_args)

    # pyflate raises if the MD5 of its output is wrong, so a completed run of
    # that benchmark is also a correctness check.
    print(f"{args.loops} loops: {dt:.3f} s total, "
          f"{dt / args.loops * 1000:.1f} ms per loop",
          file=sys.stderr)


if __name__ == "__main__":
    main()
