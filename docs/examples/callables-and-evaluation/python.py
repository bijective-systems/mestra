# A callable and evaluation: a file with no rows that produces rows.
# See README.md in this directory for the data and the output.
import numpy as np
import mestra

xy = np.array([[0., 0.], [1., 0.], [2., 0.],
               [0., 1.], [1., 1.], [2., 1.]])
model = mestra.Affine(
    ["mach", "alpha"],
    {"cl": {"A": [[2.0, 0.1]], "b": [0.05], "shape": []},
     "pressure": {"A": [[1., 0.], [2., 0.], [3., .5],
                        [4., .5], [5., 1.], [6., 1.]],
                  "b": [0., .1, .2, .3, .4, .5], "shape": [6, 1]}})

ds = mestra.Dataset(writer="mestra examples 1")
ds.add_key("mach", [], role="condition", units="1", lower=0.1, upper=0.9)
ds.add_key("alpha", [], role="condition", units="degree", lower=0., upper=8.)
ds.add_callable("m1", model)
support = ds.add_support(
    "s0", coordinates=xy,
    cells=(np.array([9, 9]), np.array([0, 4, 8]),
           np.array([0, 1, 4, 3, 1, 2, 5, 4])))
support.add_callable_slot("pressure", units="Pa", callable="m1",
                          output="pressure", components=1)
ds.add_callable_slot("cl", units="1", callable="m1", output="cl")
mestra.write(ds, "model.mes")

with mestra.read("model.mes") as d:
    print("rows:", d.n_rows, "callables:", sorted(d.callables))
    print("cl source:", d.scalars["cl"].source)
    out = mestra.evaluate(d, {"mach": [0.5], "alpha": [4.0]})
print("evaluated rows:", out.n_rows, "source:", out.scalars["cl"].source)
print("cl:", out.scalars["cl"].values.at(row=0))
print("pressure:", out.supports["s0"].node_arrays["pressure"].values[0, :, 0])
