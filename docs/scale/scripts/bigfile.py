"""Write one file the size a real dataset will be.

    bigfile.py PACKAGE_DIR OUT.mes [ROWS NODES FIELDS]

The default shape is 500 rows on one mesh support of 36,000 nodes
with six node fields, which is 864 MiB of float64 field values before
compression. Every row-dimensioned dataset is chunked by the default
of section 23 and gzipped at level 4, which section 23 allows.

The fields are a smooth function of position and of the row's
parameters plus a small random perturbation, so that they compress
about as well as real field data and not as well as a constant.

It prints the time the builder took, the time `mestra.write` took, the
peak resident size, and the size of the file.
"""

from __future__ import annotations

import os
import resource
import sys
import time

import numpy as np


def rss_mib():
    n = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return n / (1024.0 * 1024.0) if sys.platform == "darwin" else n / 1024.0


def grid(nx, ny):
    """A structured quadrilateral mesh, as coordinates and cells."""
    x = np.linspace(0.0, 4.0, nx)
    y = np.linspace(0.0, 1.0, ny)
    xx, yy = np.meshgrid(x, y, indexing="ij")
    coords = np.stack([xx.ravel(), yy.ravel()], axis=1)
    i, j = np.meshgrid(np.arange(nx - 1), np.arange(ny - 1),
                       indexing="ij")
    a = (i * ny + j).ravel()
    conn = np.stack([a, a + ny, a + ny + 1, a + 1], axis=1).ravel()
    n_cells = conn.size // 4
    types = np.full(n_cells, 9, dtype=np.int64)          # quadrilateral
    offsets = np.arange(n_cells + 1, dtype=np.int64) * 4
    return coords, (types, offsets, conn.astype(np.int64))


def main(argv):
    pkg, out = argv[1], argv[2]
    rows = int(argv[3]) if len(argv) > 3 else 500
    nodes = int(argv[4]) if len(argv) > 4 else 36000
    fields = int(argv[5]) if len(argv) > 5 else 6
    sys.path.insert(0, pkg)
    import mestra
    from mestra.model import Storage

    nx = 200
    ny = nodes // nx
    t0 = time.perf_counter()
    coords, cells = grid(nx, ny)
    rng = np.random.default_rng(20260920)
    mach = np.linspace(0.3, 0.9, rows)
    alpha = np.linspace(-2.0, 8.0, rows)
    member = np.arange(rows) % 4

    ds = mestra.Dataset(writer="mestra scale study 0")
    ds.add_key("mach", mach, role="condition", units="1",
               lower=0.1, upper=0.95)
    ds.add_key("alpha", alpha, role="design", units="deg",
               lower=-5.0, upper=10.0)
    ds.add_category_table("member", ["wing_a", "wing_b", "wing_c",
                                     "wing_d"])
    ds.add_key("member", member, role="group", category="member")
    ds.set_generalisation_group("member")
    ds.add_scalar("cl", 0.1 + 0.5 * mach + 0.02 * alpha, units="1")
    ds.add_scalar("cd", 0.01 + 0.002 * alpha ** 2, units="1")

    support = ds.add_support("s0", coordinates=coords, cells=cells,
                             units="m")
    base = np.sin(3.0 * coords[:, 0]) * np.cos(2.0 * coords[:, 1])
    names = ["pressure", "density", "temperature", "velocity_x",
             "velocity_y", "turbulent_viscosity"]
    units = ["Pa", "kg m-3", "K", "m s-1", "m s-1", "m2 s-1"]
    for k in range(fields):
        v = (1.0e5 * (1.0 + 0.1 * k)
             + 1.0e4 * np.outer(mach, base)
             + 50.0 * alpha[:, None]
             + rng.normal(0.0, 30.0, size=(rows, coords.shape[0])))
        slot = support.add_node_array(names[k], v, units=units[k],
                                      dims=("row", "node"))
        slot.storage = Storage(gzip=4)
    for slot in (ds.scalars["cl"], ds.scalars["cd"]):
        slot.storage = Storage(gzip=4)
    t_build = time.perf_counter() - t0

    t0 = time.perf_counter()
    mestra.write(ds, out)
    t_write = time.perf_counter() - t0

    raw = rows * coords.shape[0] * fields * 8
    print("rows %d, nodes %d, cells %d, fields %d"
          % (rows, coords.shape[0], cells[0].size, fields))
    print("field values %.0f MiB before compression" % (raw / 2 ** 20))
    print("built in %.1f s, written in %.1f s" % (t_build, t_write))
    print("file %d bytes (%.0f MiB), peak resident %.0f MiB"
          % (os.path.getsize(out), os.path.getsize(out) / 2 ** 20,
             rss_mib()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
