# Reading someone else's file: ask the file what is in it, then take
# one value by name. See README.md for the data and the output.
import os
import mestra

path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                    "..", "mesh_two_rows.mes")
print("valid:", mestra.validate(path).ok)

with mestra.read(path) as d:
    print(d.n_rows, "rows, aligned:", d.aligned)
    print("keys:", [(n, d.keys[n].role) for n in d.key_names()])
    print("scalars:", sorted(d.scalars))
    for name, s in d.supports.items():
        print("support", name, s.kind, s.n_nodes, "nodes", s.n_cells, "cells")
        print("  node arrays:", sorted(s.node_arrays))
        print("  cell arrays:", sorted(s.cell_arrays))
    p = d.supports["s0"].node_arrays["pressure"]
    print("pressure", p.dims, p.units, p.varies)
    print("pressure at row 1 node 3:", p.values.at(row=1, node=3, component=0))
    print("row 0 alone:", p.read(slice(0, 1)).shape)
    region = d.supports["s0"].cell_arrays["region"]
    print("region is a", region.role, "over", list(d.categories["region"]))
