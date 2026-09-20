"""Dataset 3, scalars only, no support: geometries times incidences,
lift and drag.  The "not everything is a field" case.

Run:  python d3_scalars.py OUT.mes
"""
import sys

import numpy as np

import mestra

out = sys.argv[1] if len(sys.argv) > 1 else "d3_scalars.mes"

geometries = ["g0", "g1", "g2"]
incidences = [0., 4., 8., 12.]

geom_of_row, inc_of_row, camber, thickness = [], [], [], []
for gi, _ in enumerate(geometries):
    for inc in incidences:
        geom_of_row.append(gi)
        inc_of_row.append(inc)
        camber.append(0.02 + 0.01 * gi)
        thickness.append(0.10 + 0.02 * gi)

n = len(geom_of_row)
rng = np.random.default_rng(3)
cl = 0.1 * np.array(inc_of_row) + rng.random(n) * 0.01
cd = 0.01 + 0.0005 * np.array(inc_of_row) ** 2
cm = -0.05 - 0.001 * np.array(inc_of_row)

ds = mestra.Dataset(writer="ergonomics review 3")
ds.add_key("camber", camber, role="design", units="1")
ds.add_key("thickness", thickness, role="design", units="1")
ds.add_key("incidence", inc_of_row, role="condition", units="degree")
ds.add_key("geometry", geom_of_row, role="group", categories=geometries,
           generalisation=True)

ds.add_scalar("CL", cl, units="1")
ds.add_scalar("CD", cd, units="1")
ds.add_scalar("CM", cm, units="1")

mestra.write(ds, out)
print("wrote", out)

report = mestra.validate(out)
print("validate:", report.ok, report.error_ids, report.warning_ids)
for finding in report.errors + report.warnings:
    print("   ", finding)
