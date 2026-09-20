"""Dataset 4, a transient inside a parametric family: a time key whose
trajectories have unequal length.  Three runs of 4, 3 and 5 steps on a
fixed five-node line mesh.

Run:  python d4_transient.py OUT.mes
"""
import sys

import numpy as np

import mestra

out = sys.argv[1] if len(sys.argv) > 1 else "d4_transient.mes"

runs = ["r000", "r001", "r002"]
steps = [4, 3, 5]
diffusivity = [0.10, 0.25, 0.40]
amplitude = [1.0, 2.0, 3.0]

run_of_row, t_of_row, diff_of_row, amp_of_row = [], [], [], []
for ri, n_steps in enumerate(steps):
    for step in range(n_steps):
        run_of_row.append(ri)
        t_of_row.append(0.1 * (step + 1))
        diff_of_row.append(diffusivity[ri])
        amp_of_row.append(amplitude[ri])

n_rows = len(run_of_row)
n_nodes = 5
x = np.linspace(0., 1., n_nodes).reshape(n_nodes, 1)

u = np.array([[amp_of_row[r] * np.exp(-diff_of_row[r] * t_of_row[r])
               * np.sin(np.pi * xi) for xi in x[:, 0]]
              for r in range(n_rows)])

ds = mestra.Dataset(writer="ergonomics review 4")
ds.add_key("diffusivity", diff_of_row, role="design", units="m^2/s")
ds.add_key("amplitude", amp_of_row, role="design", units="K")
# the README lists trajectory_group as an attribute of Key but never
# shows how to set it; trajectory_group= is a guess that worked.
ds.add_key("t", t_of_row, role="time", units="s", trajectory_group="run")
ds.add_key("run", run_of_row, role="group", categories=runs,
           generalisation=True)

support = ds.add_support(
    "s0", coordinates=x, units="m",
    cells=(np.array([3, 3, 3, 3], dtype=np.uint8),
           np.array([0, 2, 4, 6, 8], dtype=np.int64),
           np.array([0, 1, 1, 2, 2, 3, 3, 4], dtype=np.int64)))

support.add_node_array("u", u, units="K", varies="row")

mestra.write(ds, out)
print("wrote", out)

report = mestra.validate(out)
print("validate:", report.ok, report.error_ids, report.warning_ids)
for finding in report.errors + report.warnings:
    print("   ", finding)
