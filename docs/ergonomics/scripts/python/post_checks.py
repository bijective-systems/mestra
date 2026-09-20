"""The four post-processing helpers of python/README.md, used on the
five files, exactly as the README spells them.

Run:  python post_checks.py DIR
"""
import sys

import mestra
from mestra import post

d = sys.argv[1] if len(sys.argv) > 1 else "."


def attempt(label, fn):
    print("---", label)
    try:
        print("   ", fn())
    except Exception as exc:              # noqa: BLE001 - this is the point
        print("    %s: %s" % (type(exc).__name__, exc))


ds1 = mestra.read(d + "/d1_family.mes")
ds2 = mestra.read(d + "/d2_cascade.mes")
ds3 = mestra.read(d + "/d3_scalars.mes")
ds4 = mestra.read(d + "/d4_transient.mes")
ds5 = mestra.read(d + "/d5_axis.mes")

attempt("field_statistics(ds1, 'pressure')",
        lambda: post.field_statistics(ds1, "pressure").as_table())
attempt("field_statistics(ds1, 'pressure', label='topo_face_id')",
        lambda: post.field_statistics(ds1, "pressure",
                                      label="topo_face_id").as_table())
# the README's own example: integrate over a weight called "area".
# Nothing in the README says how a weight array gets into a file.
attempt("integrate(ds1, 'pressure', weight='area')",
        lambda: post.integrate(ds1, "pressure", weight="area"))
attempt("integrate(ds1, 'pressure')",
        lambda: post.integrate(ds1, "pressure"))
attempt("time_series(ds4, 'u', node=2, trajectory='r001')",
        lambda: post.time_series(ds4, "u", node=2, trajectory="r001"))
attempt("grouped_split(ds3, {'train': .8, 'test': .2}, seed=0)",
        lambda: post.grouped_split(ds3, {"train": 0.8, "test": 0.2}, seed=0))
attempt("split_leaks(ds2)", lambda: post.split_leaks(ds2))
attempt("field_statistics(ds5, 'overpressure')",
        lambda: post.field_statistics(ds5, "overpressure").as_table())
# a scalar, not a field: the natural next thing a user asks for
attempt("field_statistics(ds3, 'CL')",
        lambda: post.field_statistics(ds3, "CL").as_table())
