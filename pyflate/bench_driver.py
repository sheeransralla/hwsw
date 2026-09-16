#!/usr/bin/env python3
"""Run the pyflate benchmark function directly, without the pyperf harness.

pyperf.Runner spawns worker processes and calibrates loops, which makes
perf/cProfile output noisy and hard to attribute. This driver imports
run_benchmark.py from a given benchmark directory and calls bench_pyflake()
in the current process, so profilers see only the decompression work.

Usage:
  python3 bench_driver.py --bench-dir bm_pyflate --loops 5
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


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--bench-dir", required=True,
                        help="directory containing run_benchmark.py and data/")
    parser.add_argument("--loops", type=int, default=5,
                        help="number of full decompressions (default: 5)")
    parser.add_argument("--cprofile", metavar="FILE",
                        help="profile with cProfile and write stats to FILE")
    parser.add_argument("--top", type=int, default=30,
                        help="rows to print from cProfile stats (default: 30)")
    args = parser.parse_args()

    bench_dir = os.path.abspath(args.bench_dir)
    bm = load_benchmark(bench_dir)
    data = os.path.join(bench_dir, "data", "interpreter.tar.bz2")

    if args.cprofile:
        profiler = cProfile.Profile()
        dt = profiler.runcall(bm.bench_pyflake, args.loops, data)
        profiler.dump_stats(args.cprofile)
        stats = pstats.Stats(args.cprofile)
        print("=== sorted by tottime (time inside the function itself) ===")
        stats.sort_stats("tottime").print_stats(args.top)
        print("=== sorted by cumtime (time including callees) ===")
        stats.sort_stats("cumtime").print_stats(args.top)
    else:
        dt = bm.bench_pyflake(args.loops, data)

    # bench_pyflake() raises if the MD5 of the output is wrong.
    print(f"{args.loops} loops: {dt:.3f} s total, "
          f"{dt / args.loops * 1000:.1f} ms per loop (MD5 verified)",
          file=sys.stderr)


if __name__ == "__main__":
    main()
