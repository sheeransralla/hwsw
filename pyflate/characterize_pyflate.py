"""Workload characterization for the pyflate benchmark.

Counts deterministic properties of one decompression of
data/interpreter.tar.bz2 by wrapping functions of run_benchmark.py.
Run from inside bm_pyflate/ (requires pyperf to be importable).
The reported numbers are used in report_pyflate.txt, sections 1.2 and 1.5.
"""
import bz2
import collections
import hashlib
import time

import run_benchmark as rb

FILE = 'data/interpreter.tar.bz2'
C = collections.Counter()
in_decode = [False]          # True while inside find_next_symbol
in_selectors = [False]       # True while inside compute_selectors_list

# --- Huffman decoding: symbols, entries examined, bit-reader calls ---
orig_fns = rb.HuffmanTable.find_next_symbol
run = {'repeat': 0, 'power': 0}   # RUNA/RUNB accumulator (mirrors main loop)
def find_next_symbol(self, field, reversed=True):
    C['symbols'] += 1
    in_decode[0] = True
    r = orig_fns(self, field, reversed)
    in_decode[0] = False
    if r <= 1:                                  # RUNA / RUNB
        C['run_symbols'] += 1
        if run['repeat'] == 0:
            run['power'] = 1
        run['repeat'] += run['power'] << r
        run['power'] <<= 1
    elif run['repeat'] > 0:                     # run ends at any other symbol
        C['runs'] += 1
        C['run_bytes'] += run['repeat']
        C['longest_run'] = max(C['longest_run'], run['repeat'])
        run['repeat'] = 0
    for i, x in enumerate(self.table):      # position of matched entry
        if x.code == r:
            C['entries_examined'] += i + 1
            break
    return r
rb.HuffmanTable.find_next_symbol = find_next_symbol

orig_snoop, orig_read = rb.RBitfield.snoopbits, rb.RBitfield.readbits
def snoopbits(self, n=8):
    if in_decode[0]:
        C['decode_snoopbits'] += 1
    return orig_snoop(self, n)
def readbits(self, n=8):
    if in_decode[0]:
        C['decode_readbits'] += 1
        C['decode_bits'] += n
    return orig_read(self, n)
rb.RBitfield.snoopbits, rb.RBitfield.readbits = snoopbits, readbits

orig_more = rb.RBitfield._more
def _more(self):
    C['byte_reads'] += 1
    orig_more(self)
rb.RBitfield._more = _more

# --- MTF (used for both selectors and bytes; counted separately) ---
orig_mtf = rb.move_to_front
def move_to_front(l, c):
    kind = 'selector' if in_selectors[0] else 'byte'
    C[kind + '_mtf_ops'] += 1
    C[kind + '_mtf_index_sum'] += c
    orig_mtf(l, c)
rb.move_to_front = move_to_front

# --- block structure ---
orig_used = rb.compute_used
def compute_used(b):
    u = orig_used(b)
    C['used_bytes'] = sum(u)
    return u
rb.compute_used = compute_used

orig_sel = rb.compute_selectors_list
def compute_selectors_list(b, groups):
    in_selectors[0] = True
    s = orig_sel(b, groups)
    in_selectors[0] = False
    C['selectors'] += len(s)
    return s
rb.compute_selectors_list = compute_selectors_list

orig_tables = rb.compute_tables
def compute_tables(b, groups, n):
    t = orig_tables(b, groups, n)
    C['tables'] += groups
    C['alphabet'] = n
    C['min_code_len'] = min(x.min_bits for x in t)
    C['max_code_len'] = max(x.max_bits for x in t)
    return t
rb.compute_tables = compute_tables

orig_blk = rb.decode_huffman_block
def decode_huffman_block(b, out):
    C['blocks'] += 1
    orig_blk(b, out)
rb.decode_huffman_block = decode_huffman_block

# --- inverse BWT and RLE1 (loop replicated for counting only) ---
orig_bwt = rb.bwt_reverse
def bwt_reverse(L, end):
    r = orig_bwt(L, end)
    C['bwt_bytes'] += len(r)
    i = 0
    while i < len(r):
        C['rle1_iterations'] += 1
        if i < len(r) - 4 and r[i] == r[i + 1] == r[i + 2] == r[i + 3]:
            C['rle1_runs'] += 1
            i += 5
        else:
            i += 1
    return r
rb.bwt_reverse = bwt_reverse


def main():
    data = open(FILE, 'rb').read()
    print("compressed bytes          ", len(data))
    print("header                    ", data[:4])
    t0 = time.perf_counter()
    with open(FILE, 'rb') as fp:
        field = rb.RBitfield(fp)
        assert field.readbits(16) == 0x425A
        out = rb.bzip2_main(field)
    dt = time.perf_counter() - t0
    assert out == bz2.decompress(data)
    assert hashlib.md5(out).hexdigest() == "afa004a630fe072901b1d9628b960974"
    print("decompressed bytes        ", len(out))
    for k, v in C.items():
        print(f"{k:26s}{v}")
    print("entries examined / symbol ", round(C['entries_examined'] / C['symbols'], 2))
    print("snoopbits / symbol        ", round(C['decode_snoopbits'] / C['symbols'], 2))
    print("average code length (bits)", round(C['decode_bits'] / C['symbols'], 2))
    print("average byte MTF index    ", round(C['byte_mtf_index_sum'] / C['byte_mtf_ops'], 2))
    print("average selector MTF index", round(C['selector_mtf_index_sum'] / C['selector_mtf_ops'], 2))
    # consistency checks: symbols and bytes are fully accounted for
    assert C['run_symbols'] + C['byte_mtf_ops'] + C['blocks'] == C['symbols']
    assert C['run_bytes'] + C['byte_mtf_ops'] == C['bwt_bytes']
    print("consistency checks         passed")
    print("instrumented time (s)     ", round(dt, 3), "(not a benchmark result)")


if __name__ == '__main__':
    main()
