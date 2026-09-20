"""Dataset 2, the varying-geometry aligned cascade: several fields, a
split key and a status column with withheld (NaN) outputs on the test
rows.  Eight rows, each its own geometry on one shared connectivity.

Run:  python d2_cascade.py OUT.mes
"""
import sys

import numpy as np

import mestra

out = sys.argv[1] if len(sys.argv) > 1 else "d2_cascade.mes"

n_rows, n_nodes = 8, 6
rng = np.random.default_rng(1)

base = np.array([[0., 0.], [1., 0.], [2., 0.],
                 [0., 1.], [1., 1.], [2., 1.]])
coords = np.stack([base + rng.normal(0., 0.02, base.shape)
                   for _ in range(n_rows)])

angle_in = [30., 32., 34., 36., 38., 40., 42., 44.]
mach_out = [0.70, 0.75, 0.80, 0.85, 0.90, 0.95, 1.00, 1.05]
split_of_row = [0, 0, 0, 0, 1, 1, 2, 2]          # train, validation, test
case_of_row = list(range(n_rows))
status_of_row = [0, 0, 0, 0, 0, 0, 1, 1]         # last two withheld

mach_field = 0.5 + rng.random((n_rows, n_nodes))
nut_field = 1e-5 * rng.random((n_rows, n_nodes))

power = np.array([100., 110., 120., 130., 140., 150., np.nan, np.nan])
angle_out = np.array([-60., -61., -62., -63., -64., -65., np.nan, np.nan])

ds = mestra.Dataset(writer="ergonomics review 2")
ds.add_key("angle_in", angle_in, role="condition", units="degree")
ds.add_key("mach_out", mach_out, role="condition", units="1")
ds.add_key("split", split_of_row, role="split",
           categories=["train", "validation", "test"])
ds.add_key("case", case_of_row, role="group",
           categories=["c%02d" % i for i in range(n_rows)],
           generalisation=True)
ds.add_key("status", status_of_row, role="status",
           categories=["converged", "partial"])

ds.add_scalar("power", power, units="W")
ds.add_scalar("angle_out", angle_out, units="degree")

support = ds.add_support(
    "s0", coordinates=coords, varies="row",
    cells=(np.array([9, 9], dtype=np.uint8),
           np.array([0, 4, 8], dtype=np.int64),
           np.array([0, 1, 4, 3, 1, 2, 5, 4], dtype=np.int64)))

support.add_node_array("mach", mach_field, units="1", varies="row")
support.add_node_array("nut", nut_field, units="m^2/s", varies="row")

mestra.write(ds, out)
print("wrote", out)

report = mestra.validate(out)
print("validate:", report.ok, report.error_ids, report.warning_ids)
for finding in report.errors + report.warnings:
    print("   ", finding)
