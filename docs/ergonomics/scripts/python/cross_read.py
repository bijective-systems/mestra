"""Read files written by the other languages, permute by name, and check
one value that every writer must agree on: the family coordinates.

Instance 1 (the second member), node 2, component 0 is 2.0 * 1.5 = 3.0,
and it is deterministic, unlike anything drawn from a generator.

Run:  python cross_read.py LABEL=DIR [LABEL=DIR ...]
"""
import sys

import mestra

for arg in sys.argv[1:]:
    label, _, d = arg.partition("=")
    print("##### d1_family written by %s #####" % label)
    with mestra.read(d + "/d1_family.mes") as ds:
        print("   ", ds.n_rows, "rows, aligned =", ds.aligned)
        print("    key order:", ds.key_names())
        # node_arrays["coordinates"] is a bare KeyError; coordinates is its
        # own attribute of Support, which only the API list says.
        coords = ds.supports["s0"].coordinates
        print("    coordinates dims:", coords.dims)
        v = coords.values
        print("    at(group:member=1, node=2, component=0) =",
              v.at(**{"group:member": 1, "node": 2, "component": 0}))
        p = v.transpose("node", "component", "group:member")
        print("    transposed dims:", p.dims,
              "-> same value", p.at(**{"group:member": 1, "node": 2,
                                       "component": 0}))
        edge = ds.supports["s0"].node_arrays["cad_edge_t"]
        print("    cad_edge_t dims:", edge.dims, "node 3 =",
              edge.values.at(node=3, component=0))
        print("    mach row 1 =", ds.keys["mach"].values[1])
        print("    member categories:", ds.categories["member"])
