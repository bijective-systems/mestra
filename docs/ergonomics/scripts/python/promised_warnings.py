"""docs/mappings.md promises two validator behaviours for these
datasets.  A user who chose the format for them would check.

  dataset 3: "warns on any split that puts one geometry on both sides"
  dataset 4: "errors if t is not strictly increasing within a run"

Run:  python promised_warnings.py OUTDIR
"""
import sys

import numpy as np

import mestra

out = sys.argv[1] if len(sys.argv) > 1 else "."

# --- a split that leaks the unit of generalisation --------------------
ds = mestra.Dataset(writer="ergonomics review leak")
ds.add_key("incidence", [0., 4., 0., 4.], role="condition", units="degree")
ds.add_key("geometry", [0, 0, 1, 1], role="group", categories=["g0", "g1"],
           generalisation=True)
# g0 is on both sides, which is the optimistic split
ds.add_key("split", [0, 1, 0, 0], role="split",
           categories=["train", "test"])
ds.add_scalar("CL", [0.1, 0.2, 0.3, 0.4], units="1")
mestra.write(ds, out + "/leaky_split.mes")
r = mestra.validate(out + "/leaky_split.mes")
print("leaky split ->", r.error_ids, r.warning_ids)
for f in r.warnings:
    print("   ", f)

# --- a time key that goes backwards inside a run ----------------------
ds = mestra.Dataset(writer="ergonomics review backwards")
ds.add_key("t", [0.1, 0.3, 0.2, 0.1], role="time", units="s",
           trajectory_group="run")
ds.add_key("run", [0, 0, 0, 1], role="group", categories=["r0", "r1"],
           generalisation=True)
ds.add_scalar("e", [1., 2., 3., 4.], units="J")
mestra.write(ds, out + "/backwards_t.mes")
r = mestra.validate(out + "/backwards_t.mes")
print("backwards t ->", r.error_ids, r.warning_ids)
for f in r.errors + r.warnings:
    print("   ", f)

# --- a key value outside its declared bounds (W04) --------------------
ds = mestra.Dataset(writer="ergonomics review bounds")
ds.add_key("mach", [0.5, 1.5], role="condition", units="1",
           lower=0.1, upper=0.9)
ds.add_scalar("cl", [1., 2.], units="1")
mestra.write(ds, out + "/out_of_bounds.mes")
r = mestra.validate(out + "/out_of_bounds.mes")
print("out of bounds ->", r.error_ids, r.warning_ids)
for f in r.errors + r.warnings:
    print("   ", f)

# --- a unit made up on the spot (W10) ---------------------------------
ds = mestra.Dataset(writer="ergonomics review units")
ds.add_key("mach", [0.5, 0.8], role="condition", units="1")
ds.add_scalar("q", [1., 2.], units="BTU per fortnight")
mestra.write(ds, out + "/bad_units.mes")
r = mestra.validate(out + "/bad_units.mes")
print("bad units ->", r.error_ids, r.warning_ids)
for f in r.errors + r.warnings:
    print("   ", f)
_ = np
