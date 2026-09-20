# Uncertainty as draws: four whole fields per row, and two summaries.
# See README.md in this directory for the data and the output.
import numpy as np
import mestra

xy = np.array([[0., 0.], [1., 0.], [2., 0.],
               [0., 1.], [1., 1.], [2., 1.]])
base = np.array([[101., 102., 103., 104., 105., 106.],
                 [201., 202., 203., 204., 205., 206.]])
draws = base[:, None, :] + np.array([-1., -1., 1., 1.])[None, :, None]

ds = mestra.Dataset(writer="mestra examples 1")
ds.add_key("mach", [0.4, 0.8], role="condition", units="1")
support = ds.add_support(
    "s0", coordinates=xy,
    cells=(np.array([9, 9]), np.array([0, 4, 8]),
           np.array([0, 1, 4, 3, 1, 2, 5, 4])))
support.add_node_array("pressure", draws, units="Pa",
                       dims=("row", "draw", "node"), statistic="draw")
support.add_node_array("pressure_mean", draws.mean(axis=1), units="Pa",
                       dims=("row", "node"), statistic="mean", of="pressure")
support.add_node_array("pressure_std", draws.std(axis=1), units="Pa",
                       dims=("row", "node"), statistic="std", of="pressure")
mestra.write(ds, "draws.mes")

with mestra.read("draws.mes") as d:
    s = d.supports["s0"]
    p = s.node_arrays["pressure"]
    print("pressure", p.dims, p.statistic)
    print("draw 0 of row 0:", p.values[0, 0, :, 0])
    for name in ("pressure_mean", "pressure_std"):
        a = s.node_arrays[name]
        print(name, a.statistic, "of", a.of,
              "at row 0, node 0:", a.values.at(row=0, node=0, component=0))
