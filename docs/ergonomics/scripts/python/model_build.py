"""Build a callable file: zero rows, one `affine` callable serving a
scalar slot and a node-array slot on the same support as the family
file, so a tool can match the two by support id.

python/README.md shows how to READ and evaluate a model file and never
how to WRITE one: add_callable is the only call in its API list, and
neither callable_id nor output appears anywhere in the document.  Both
had to be found with inspect.signature on add_scalar; add_node_array
does not even name them, it takes them through **rest.

Run:  python model_build.py OUT.mes
"""
import sys

import numpy as np

import mestra

out = sys.argv[1] if len(sys.argv) > 1 else "model.mes"

A_pressure = np.array([[1., 0.], [2., 0.], [3., .5],
                       [4., .5], [5., 1.], [6., 1.]])
b_pressure = np.array([0., .1, .2, .3, .4, .5])

m = mestra.Affine(
    ["mach", "alpha"],
    {"cl": {"A": [[2.0, 0.1]], "b": [0.05], "shape": []},
     "pressure": {"A": A_pressure.tolist(), "b": b_pressure.tolist(),
                  "shape": [6, 1]}})

xy = np.array([[0., 0.], [1., 0.], [2., 0.],
               [0., 1.], [1., 1.], [2., 1.]])

ds = mestra.Dataset(writer="ergonomics review model")
ds.add_key("mach", [], role="condition", units="1", lower=0.1, upper=0.9)
ds.add_key("alpha", [], role="condition", units="degree",
           lower=-2.0, upper=10.0)
ds.add_callable("m1", m)

support = ds.add_support(
    "s0", coordinates=xy,
    cells=(np.array([9, 9], dtype=np.uint8),
           np.array([0, 4, 8], dtype=np.int64),
           np.array([0, 1, 4, 3, 1, 2, 5, 4], dtype=np.int64)))

ds.add_scalar("cl", units="1", callable_id="m1", output="cl")
support.add_node_array("pressure", units="Pa", callable_id="m1",
                       output="pressure", components=1, varies="row")

mestra.write(ds, out)
print("wrote", out)

report = mestra.validate(out)
print("validate:", report.ok, report.error_ids, report.warning_ids)

with mestra.read(out) as back:
    table = {"mach": np.array([0.5]), "alpha": np.array([4.0])}
    ev = mestra.evaluate(back, table)
    print("cl       =", ev.scalars["cl"].values)
    p = ev.supports["s0"].node_arrays["pressure"].values
    print("pressure =", [p.at(row=0, node=n, component=0) for n in range(6)])
    print("support id:", back.supports["s0"].support_id[:16])
