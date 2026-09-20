# A support and a field: the same six rows on a two-quad mesh.
# See README.md in this directory for the data and the output.
import numpy as np
import mestra

xy = np.array([[0., 0.], [1., 0.], [2., 0.],
               [0., 1.], [1., 1.], [2., 1.]])
coordinates = np.stack([xy * [s, 1.] for s in (1.0, 1.5, 2.0)])
pressure = np.array([[100. * (r + 1) + n for n in range(1, 7)]
                     for r in range(6)])

ds = mestra.Dataset(writer="mestra examples 1")
ds.add_key("mach", [0.4, 0.8, 0.4, 0.8, 0.4, 0.8],
           role="condition", units="1")
ds.add_category_table("member", ["wing_a", "wing_b", "wing_c"])
ds.add_key("member", [0, 0, 1, 1, 2, 2],
           role="group", category="member")
ds.set_generalisation_group("member")
support = ds.add_support(
    "s0", coordinates=coordinates, varies="group:member",
    cells=(np.array([9, 9]), np.array([0, 4, 8]),
           np.array([0, 1, 4, 3, 1, 2, 5, 4])))
support.add_node_array("pressure", pressure, units="Pa",
                       dims=("row", "node"))
mestra.write(ds, "family.mes")

with mestra.read("family.mes") as d:
    s = d.supports["s0"]
    p = s.node_arrays["pressure"]
    print("aligned:", d.aligned, "nodes:", s.n_nodes, "cells:", s.n_cells)
    print("pressure", p.dims, p.units)
    print("pressure at row 1 node 3:", p.values.at(row=1, node=3, component=0))
    print("x of node 2 for wing_b:",
          s.coordinates.values.at(instance=1, node=2, component=0))
