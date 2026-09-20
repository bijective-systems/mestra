"""Time the Python reader on a list of files.

    time_py.py PACKAGE_DIR SLOT R0 R1 FILE [FILE ...]

Prints one line per file:

    <file> open=<s> validate=<s> rows=<s> full=<s> rss=<MiB>

`open` is the metadata open of section 29 (`mestra.read`, lazy),
`validate` is `mestra.validate`, `rows` is one lazy read of SLOT for
the half-open row range [R0, R1), which touches no other slot, and
`full` is the whole of SLOT. Each is timed three times and the
smallest is kept, unless the first attempt already took more than five
seconds. R1 may be `-` for the file's row count.
"""

from __future__ import annotations

import gc
import os
import resource
import sys
import time

REPS = 3
LONG = 5.0


def best(fn):
    times = []
    for _ in range(REPS):
        gc.collect()
        t = time.perf_counter()
        fn()
        times.append(time.perf_counter() - t)
        if times[-1] > LONG:
            break
    return min(times)


def slot_of(ds, path):
    parts = path.strip("/").split("/")
    if parts[0] == "scalars":
        return ds.scalars[parts[1]]
    if parts[0] == "keys":
        return ds.keys[parts[1]]
    if parts[0] == "supports" and parts[2] == "node_arrays":
        return ds.supports[parts[1]].node_arrays[parts[3]]
    if parts[0] == "supports" and parts[2] == "cell_arrays":
        return ds.supports[parts[1]].cell_arrays[parts[3]]
    raise KeyError(path)


def rss_mib():
    n = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return n / (1024.0 * 1024.0) if sys.platform == "darwin" else n / 1024.0


def main(argv):
    pkg, slot, r0, r1 = argv[1], argv[2], int(argv[3]), argv[4]
    sys.path.insert(0, pkg)
    import mestra

    for path in argv[5:]:
        holder = {}

        def do_open():
            holder["ds"] = mestra.read(path)

        t_open = best(do_open)
        t_val = best(lambda: mestra.validate(path))
        ds = holder["ds"]
        end = ds.n_rows if r1 == "-" else int(r1)
        s = slot_of(ds, slot)
        t_rows = best(lambda: s.read(slice(r0, end)))
        t_full = best(lambda: s.read(slice(0, ds.n_rows)))
        try:
            ds.close()
        except Exception:                          # noqa: BLE001
            pass
        print("%s open=%.4f validate=%.4f rows=%.4f full=%.4f rss=%.1f"
              % (os.path.basename(path), t_open, t_val, t_rows, t_full,
                 rss_mib()))
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
