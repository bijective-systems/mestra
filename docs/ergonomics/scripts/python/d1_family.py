"""Dataset 1, the parametric family, built the way python/README.md
leads a first-time user.  Three members, two freestream conditions,
six rows; a six-node mesh of two quadrilaterals shared by every
member, with each member's own coordinates.

Run:  python d1_family.py OUT.mes
"""
import sys

import numpy as np

import mestra

out = sys.argv[1] if len(sys.argv) > 1 else "d1_family.mes"

# ---- the plain arrays a user already has -----------------------------
members = ["cone_a", "cone_b", "cone_c"]
base = np.array([[0., 0., 0.], [1., 0., 0.], [2., 0., 0.],
                 [0., 1., 0.], [1., 1., 0.], [2., 1., 0.]])
coords = np.stack([base * [s, 1., 1.] for s in (1.0, 1.5, 2.0)])

cell_types = np.array([9, 9], dtype=np.uint8)
cell_offsets = np.array([0, 4, 8], dtype=np.int64)
cell_conn = np.array([0, 1, 4, 3, 1, 2, 5, 4], dtype=np.int64)

member_of_row = [0, 0, 1, 1, 2, 2]
mach = [0.5, 0.8, 0.5, 0.8, 0.5, 0.8]
altitude = [1000., 1000., 5000., 5000., 9000., 9000.]
total_length = [2.0, 2.0, 3.0, 3.0, 4.0, 4.0]
half_angle = [10., 10., 15., 15., 20., 20.]
nose_radius = [0.05, 0.05, 0.08, 0.08, 0.11, 0.11]
status_of_row = [0, 0, 0, 0, 0, 1]

rng = np.random.default_rng(0)
pressure = 1000. + rng.random((6, 6)) * 10.
heat_flux = 500. + rng.random((6, 6)) * 10.
cad_face_id = np.array([11, 11, 12, 12, 13, 13], dtype=np.int32)
topo_face_id = np.array([1, 2], dtype=np.int32)
cad_edge_t = np.linspace(0., 1., 6)

# ---- the file --------------------------------------------------------
ds = mestra.Dataset(writer="ergonomics review 1")
ds.add_key("total_length", total_length, role="design", units="m")
ds.add_key("half_angle", half_angle, role="design", units="degree")
ds.add_key("nose_radius", nose_radius, role="design", units="m")
ds.add_key("mach", mach, role="condition", units="1")
ds.add_key("altitude", altitude, role="condition", units="m")
ds.add_key("member", member_of_row, role="group", categories=members,
           generalisation=True)
# attempt 3: categories=["ok", "failed"] validated, but warned W02 on
# every row including the good ones.  Only SPEC.md says the word the
# validator wants is "converged"; no README and no mapping says it.
ds.add_key("status", status_of_row, role="status",
           categories=["converged", "failed"])

support = ds.add_support(
    "s0", coordinates=coords, varies="group:member",
    cells=(cell_types, cell_offsets, cell_conn))

# attempt 2: with six rows and six nodes the shape (6, 6) is ambiguous
# and add_node_array refuses it; varies="row" has to be said by hand.
support.add_node_array("pressure", pressure, units="Pa", varies="row")
support.add_node_array("heat_flux", heat_flux, units="W/m^2",
                       varies="row")
support.add_node_array("cad_face_id", cad_face_id, role="label")
support.add_node_array("cad_edge_t", cad_edge_t, role="field", units="1")
support.add_cell_array("topo_face_id", topo_face_id, role="label")

mestra.write(ds, out)
print("wrote", out)

report = mestra.validate(out)
print("validate:", report.ok, report.error_ids, report.warning_ids)
for finding in report.errors + report.warnings:
    print("   ", finding)
