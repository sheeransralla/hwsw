# Ray/scene intersection accelerator (raytrace, Section 5)

`ray_scene_isect.sv` replaces the object scan inside `Scene.rayColour()` and
`Scene._lightIsVisible()`. The host submits one ray; the accelerator tests it
against the whole scene (7 spheres + 1 halfspace held locally) and returns the
selected hit.

Two modes match the two callers:

- **nearest** – smallest `t > -EPSILON`, earlier object on a tie
  (`firstIntersection`)
- **any-hit** – first object with `t > EPSILON` (`_lightIsVisible`)

Arithmetic is IEEE-754 **binary64** in the same evaluation order as the Python
code, including the discriminant as `r*r - (c2 - v*v)`. The behavioural
simulation matched the Python reference bit for bit on all 300 captured test
rays; that is evidence of equivalence for this scene, not a proof for every
possible input or IP configuration.

## Files

| file | contents |
|---|---|
| `ray_scene_isect.sv` | the accelerator: datapath, FSM, scene registers |
| `fp64_units.sv` | pipelined binary64 add/sub, multiply, sqrt, divide, compare |
| `tb_ray_scene_isect.sv` | testbench checking 300 real rays |
| `gen_vectors.py` | captures the scene and rays from the benchmark |
| `scene.hex`, `rays.hex` | generated vectors with expected results |

## Reproduce

```
python3 gen_vectors.py ../raytrace/bm_raytrace
iverilog -g2012 -o tb tb_ray_scene_isect.sv ray_scene_isect.sv fp64_units.sv
vvp tb
```

Expected:

```
loaded 300 rays

checked 300 rays (160 nearest, 140 any-hit)
cycles per ray: 388 average, 423 worst
All results match the Python reference bit for bit.
```

The 300 vectors are real rays captured from a render (primary, reflection and
shadow), with the result the Python code computed for each, so the hardware is
checked against the software it replaces.

## Note on performance

This implementation shares one adder, three multipliers, one square root and
one divider across all objects, so each object waits out the latency of a
chain of dependent operations: 388 cycles per ray. It is area-efficient rather
than fast. Section 5.6 of the report discusses the pipelined variant that
processes one object per cycle, and what each costs.

The FSM, scene storage and datapath connections are written in
synthesizable-style RTL. The binary64 operators in `fp64_units.sv` are
behavioural simulation models standing for vendor floating-point IP: they use
`$bitstoreal`, `$realtobits`, `$sqrt` and the `real` type, which are not
synthesizable. Synthesis requires replacing them with configured binary64 add,
multiply, divide, square-root and comparison IP cores presenting the same
valid/latency interface (modelled here as MUL 3, ADD 3, SQRT 8, DIV 10
cycles).
