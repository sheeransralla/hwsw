#!/usr/bin/env python3
"""Workload characterization for the raytrace benchmark.

Counts deterministic properties of one rendered frame of the default scene by
wrapping functions and methods of run_benchmark.py: rays cast, intersection
tests, objects constructed, shadow rays, reflections. These numbers depend
only on the scene and the image size, not on the machine or Python version,
and are used in report_raytrace.txt, sections 1.2 and 1.5.

    python3 characterize_raytrace.py [bench_dir] [width] [height]
"""
import collections
import importlib.util
import os
import sys

C = collections.Counter()


def load(bench_dir):
    path = os.path.join(bench_dir, "run_benchmark.py")
    spec = importlib.util.spec_from_file_location("run_benchmark", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def instrument(bm):
    # --- object construction -------------------------------------------
    for name in ("Vector", "Point", "Ray"):
        cls = getattr(bm, name)
        original = cls.__init__

        def make(counter_name, init):
            def wrapper(self, *args, **kwargs):
                C[counter_name] += 1
                init(self, *args, **kwargs)
            return wrapper

        cls.__init__ = make(name + "_created", original)

    # --- vector arithmetic ---------------------------------------------
    for cls_name, meth in (("Vector", "dot"), ("Vector", "scale"),
                           ("Vector", "normalized"), ("Vector", "magnitude"),
                           ("Vector", "__sub__"), ("Vector", "__add__"),
                           ("Point", "__sub__"), ("Point", "__add__")):
        cls = getattr(bm, cls_name)
        original = getattr(cls, meth)

        def make(counter_name, func):
            def wrapper(self, *args, **kwargs):
                C[counter_name] += 1
                return func(self, *args, **kwargs)
            return wrapper

        setattr(cls, meth, make(f"{cls_name}.{meth}", original))

    # --- intersection tests, per geometry type --------------------------
    for name in ("Sphere", "Halfspace"):
        cls = getattr(bm, name)
        original = cls.intersectionTime

        def make(counter_name, func):
            def wrapper(self, ray):
                C["intersection_tests"] += 1
                C[counter_name] += 1
                t = func(self, ray)
                if t is not None:
                    C[counter_name + "_hit"] += 1
                return t
            return wrapper

        cls.intersectionTime = make(name + "_tests", original)

    # --- rays: primary, shadow, reflection ------------------------------
    scene = bm.Scene
    orig_ray_colour = scene.rayColour
    orig_light_visible = scene._lightIsVisible

    def ray_colour(self, ray):
        C["rays_cast"] += 1
        C["max_recursion"] = max(C["max_recursion"], self.recursionDepth + 1)
        if self.recursionDepth > 0:
            C["reflection_rays"] += 1
        else:
            C["primary_rays"] += 1
        return orig_ray_colour(self, ray)

    def light_is_visible(self, l, p):
        C["shadow_rays"] += 1
        visible = orig_light_visible(self, l, p)
        if visible:
            C["lights_visible"] += 1
        return visible

    scene.rayColour = ray_colour
    scene._lightIsVisible = light_is_visible


def main():
    bench_dir = sys.argv[1] if len(sys.argv) > 1 else "bm_raytrace"
    width = int(sys.argv[2]) if len(sys.argv) > 2 else 100
    height = int(sys.argv[3]) if len(sys.argv) > 3 else 100

    bm = load(os.path.abspath(bench_dir))
    instrument(bm)
    bm.bench_raytrace(1, width, height, None)

    pixels = width * height
    print(f"image .......................... {width} x {height} = {pixels} pixels")
    print(f"objects in the scene ........... 1 large sphere + 6 small spheres"
          f" + 1 halfspace = 8")
    print(f"light sources .................. 2")
    print()
    for key in ("primary_rays", "reflection_rays", "rays_cast", "shadow_rays",
                "lights_visible", "max_recursion", "intersection_tests",
                "Sphere_tests", "Sphere_tests_hit",
                "Halfspace_tests", "Halfspace_tests_hit",
                "Vector_created", "Point_created", "Ray_created",
                "Vector.dot", "Vector.scale", "Vector.normalized",
                "Vector.magnitude", "Vector.__sub__", "Vector.__add__",
                "Point.__sub__", "Point.__add__"):
        if key in C:
            print(f"{key:30s} {C[key]}")

    print()
    print(f"intersection tests per pixel ... {C['intersection_tests'] / pixels:.1f}")
    print(f"objects created per pixel ...... "
          f"{(C['Vector_created'] + C['Point_created'] + C['Ray_created']) / pixels:.1f}")


if __name__ == "__main__":
    main()
