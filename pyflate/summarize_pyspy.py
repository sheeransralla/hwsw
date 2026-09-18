#!/usr/bin/env python3
"""Summarize a py-spy raw ("folded") profile by function and by source line.

py-spy writes one line per sampled stack, ending with the sample count. The
leaf frame of each stack is the code that was executing, so counting leaves
gives self time. Usage:

    python3 summarize_pyspy.py results/pyspy_original.folded [top_n]
"""
import collections
import re
import sys

FRAME = re.compile(r"(\S+) \((\S+):(\d+)\)")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    top_n = int(sys.argv[2]) if len(sys.argv) > 2 else 15

    by_function = collections.Counter()   # self time
    by_line = collections.Counter()       # self time, per source line
    inclusive = collections.Counter()     # time including callees
    total = 0

    with open(path) as handle:
        for raw in handle:
            raw = raw.strip()
            if not raw:
                continue
            stack, _, count = raw.rpartition(" ")
            try:
                count = int(count)
            except ValueError:
                continue
            total += count
            frames = [m for m in (FRAME.match(f) for f in stack.split(";")) if m]
            if not frames:
                continue
            leaf = frames[-1]
            by_function[leaf.group(1)] += count
            by_line[f"{leaf.group(1)}:{leaf.group(3)}"] += count
            for name in {f.group(1) for f in frames}:
                inclusive[name] += count

    if total == 0:
        sys.exit(f"{path}: no samples found")

    print(f"{path}: {total} samples\n")
    print("=== self time by function ===")
    for name, n in by_function.most_common(top_n):
        print(f"{100 * n / total:6.2f}%  {name}")
    print("\n=== total time by function (including callees) ===")
    for name, n in inclusive.most_common(top_n):
        print(f"{100 * n / total:6.2f}%  {name}")
    print("\n=== self time by source line ===")
    for name, n in by_line.most_common(top_n):
        print(f"{100 * n / total:6.2f}%  {name}")


if __name__ == "__main__":
    main()
