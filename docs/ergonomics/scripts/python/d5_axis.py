"""Dataset 5, an axis support: a ground overpressure signature over a
time axis, with a loudness scalar.  Six rows, an eight-sample axis.

Run:  python d5_axis.py OUT.mes
"""
import sys

import numpy as np

import mestra

out = sys.argv[1] if len(sys.argv) > 1 else "d5_axis.mes"

n_rows, n_samples = 6, 8
rng = np.random.default_rng(5)

area_1 = [0.10, 0.10, 0.15, 0.15, 0.20, 0.20]
area_2 = [0.30, 0.30, 0.35, 0.35, 0.40, 0.40]
mach = [1.4, 1.6, 1.4, 1.6, 1.4, 1.6]
altitude = [12000., 12000., 14000., 14000., 16000., 16000.]
design_of_row = [0, 0, 1, 1, 2, 2]

ground_time = np.linspace(0., 0.35, n_samples)
overpressure = np.array([
    a * np.sin(2. * np.pi * ground_time / 0.35) + rng.normal(0., 0.5, n_samples)
    for a in (50., 55., 60., 65., 70., 75.)])
loudness = [78., 80., 82., 84., 86., 88.]

ds = mestra.Dataset(writer="ergonomics review 5")
ds.add_key("area_1", area_1, role="design", units="m^2")
ds.add_key("area_2", area_2, role="design", units="m^2")
ds.add_key("mach", mach, role="condition", units="1")
ds.add_key("altitude", altitude, role="condition", units="m")
ds.add_key("design", design_of_row, role="group",
           categories=["d0", "d1", "d2"], generalisation=True)

ds.add_scalar("loudness", loudness, units="dB")

# the Python README never says how to make an axis support: add_support
# is only ever shown with a mesh and a cells= tuple.  kind="axis" is a
# guess made from SPEC.md's vocabulary, not from any README.
support = ds.add_support("s0", kind="axis", coordinates=ground_time,
                         units="s")
support.add_node_array("overpressure", overpressure, units="Pa",
                       varies="row")

mestra.write(ds, out)
print("wrote", out)

report = mestra.validate(out)
print("validate:", report.ok, report.error_ids, report.warning_ids)
for finding in report.errors + report.warnings:
    print("   ", finding)
