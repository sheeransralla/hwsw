# Inverse-BWT accelerator (pyflate, Section 5)

`bwt_accel.sv` replaces `bwt_transform()` + `bwt_reverse()` of the benchmark:
the host streams in the block L with its length and `origPtr`, and streams out
the reconstructed block.

## Simulate

```
iverilog -g2012 -o tb tb_bwt_accel.sv bwt_accel.sv && vvp tb
```

Expected output:

```
PASS  banana     n=6 origPtr=3 -> "banana"
PASS  abab       n=4 origPtr=0 -> "abab"
PASS  aaaa       n=4 origPtr=0 -> "aaaa"
PASS  nban       n=4 origPtr=2 -> "nban"
PASS  mississippi n=11 origPtr=4 -> "mississippi"
PASS  banana-bp  n=6 origPtr=3 -> "banana"   (with backpressure)

All tests passed.
```

All test vectors were produced with the benchmark's own Python functions, so
the hardware is checked against the software it replaces. The `abab` case is
the periodic input whose mapping T splits into short cycles - the case that
broke the original Python loop (see report 1.5(j)).

Install the simulator with `apt-get install iverilog`.
