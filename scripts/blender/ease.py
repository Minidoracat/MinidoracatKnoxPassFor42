"""Shared ease for every Knox Pass door clip (barrier arm, double boom, two-story roll door, two-story gate leaves).

Trapezoidal speed: the motion speeds up over the first RAMP of the clip, runs at constant speed, and slows down over
the last RAMP (a motor-like start and stop instead of the linear clip's jerk). Bake it into the keyframes: the engine
plays clips at the same cost whatever the curve, and Lua BarrierAnim samples the same clip at linear time, so SP and
MP look the same. Symmetric: ease(1 - t) = 1 - ease(t), so Close stays the exact reverse of Open and the half-way pose
is unchanged. Peak speed = 1 / (1 - RAMP) of the linear clip's.

    import sys; sys.path.insert(0, str(<repo>/scripts/blender)); from ease import ease
"""
RAMP = 0.2


def ease(t: float) -> float:
    t = min(1.0, max(0.0, t))
    v = 1.0 / (1.0 - RAMP)
    if t < RAMP:
        return v * t * t / (2.0 * RAMP)
    if t > 1.0 - RAMP:
        return 1.0 - v * (1.0 - t) ** 2 / (2.0 * RAMP)
    return v * (t - RAMP / 2.0)


if __name__ == "__main__":
    assert ease(0.0) == 0.0 and ease(1.0) == 1.0 and abs(ease(0.5) - 0.5) < 1e-12
    xs = [i / 1000 for i in range(1001)]
    assert all(abs(ease(1 - x) - (1 - ease(x))) < 1e-12 for x in xs), "not symmetric"
    assert all(ease(b) >= ease(a) for a, b in zip(xs, xs[1:])), "not monotonic"
    for k in (RAMP, 1 - RAMP):                                   # value and slope continuous at the ramp ends
        assert abs(ease(k - 1e-9) - ease(k + 1e-9)) < 1e-6
        d = lambda x: (ease(x + 1e-6) - ease(x - 1e-6)) / 2e-6   # noqa: E731
        assert abs(d(k - 1e-4) - d(k + 1e-4)) < 1e-2
    assert ease(1 / 145) < 1e-3, "starts at rest"
    print("ease OK")
