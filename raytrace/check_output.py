#!/usr/bin/env python3
"""Check that an optimized raytrace renders exactly the same image.

The raytrace benchmark does not verify its own output, so every optimization
has to be checked separately. This script renders the scene with two copies of
run_benchmark.py, writes both images as PPM and compares their MD5 digests.

    python3 check_output.py bm_raytrace bm_raytrace_opt

An optimization that changes any pixel fails here, even if the benchmark still
runs and reports a lower time.
"""
import argparse
import hashlib
import importlib.util
import os
import sys
import tempfile


def load(bench_dir):
    path = os.path.join(bench_dir, "run_benchmark.py")
    spec = importlib.util.spec_from_file_location(
        "rt_" + os.path.basename(bench_dir), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def render_digest(bench_dir, width, height):
    """Render one frame and return (md5, size in bytes) of the PPM output."""
    bm = load(os.path.abspath(bench_dir))
    with tempfile.TemporaryDirectory() as tmp:
        ppm = os.path.join(tmp, "out.ppm")
        bm.bench_raytrace(1, width, height, ppm)
        data = open(ppm, "rb").read()
    return hashlib.md5(data).hexdigest(), len(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("reference", help="directory of the original benchmark")
    parser.add_argument("candidate", help="directory of the optimized benchmark")
    parser.add_argument("--width", type=int, default=100)
    parser.add_argument("--height", type=int, default=100)
    args = parser.parse_args()

    ref_md5, ref_len = render_digest(args.reference, args.width, args.height)
    cand_md5, cand_len = render_digest(args.candidate, args.width, args.height)

    print(f"{args.reference:24s} {ref_md5}  ({ref_len} bytes)")
    print(f"{args.candidate:24s} {cand_md5}  ({cand_len} bytes)")

    if ref_md5 == cand_md5:
        print(f"\nOK: identical output at {args.width}x{args.height}")
        return 0
    print("\nMISMATCH: the optimized version renders a different image")
    return 1


if __name__ == "__main__":
    sys.exit(main())
