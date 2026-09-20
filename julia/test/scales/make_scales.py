"""Write julia/test/scales/lost_reference_list.mes.

Section 21 calls REFERENCE_LIST informational: a reader resolves an
axis through the dataset's own DIMENSION_LIST and the map it builds
during its own walk, and "a scale whose REFERENCE_LIST is missing,
short or stale is not an error, and no rule in section 14 is about
it".

That is not a hypothetical.  A scale created without attribute
creation order tracked takes at most 4085 attachments, and the 4086th
H5DSattach_scale deletes the REFERENCE_LIST it was extending before it
fails (SPEC.md section 21, docs/scale/report.md 1.2).  What is left on
disk is a file every reader and every validator accepts, with the
forward references intact and the back references gone.  A reader that
resolved an axis by asking the library whether a scale is attached --
H5DSis_attached consults REFERENCE_LIST -- answers "no scale" on that
file and calls the axis unknown.  `docs/scale/report.md` 6.5 measured
exactly that.

So this file is `vectors/cases/mesh_two_rows/case.mes` with two edits
and nothing else:

  - the `row` scale loses REFERENCE_LIST entirely, which is what the
    failed attachment leaves;
  - the `component_1` scale keeps a REFERENCE_LIST of one entry where
    three datasets are attached to it, which is the stale case.

Every DIMENSION_LIST in the file is untouched, so every axis still has
its name and the file is still valid.  h5py is used rather than
HDF5.jl because deleting one attribute and rewriting another with its
own compound datatype is two lines here.

    python make_scales.py [output_directory]

The default output directory is the directory holding this file.
"""

import os
import shutil
import sys

import h5py

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.normpath(
    os.path.join(HERE, "..", "..", "..", "vectors", "cases",
                 "mesh_two_rows", "case.mes"))


def main(argv):
    out = argv[1] if len(argv) > 1 else HERE
    if not os.path.isdir(out):
        os.makedirs(out)
    path = os.path.join(out, "lost_reference_list.mes")
    shutil.copyfile(SOURCE, path)
    os.chmod(path, 0o644)
    with h5py.File(path, "r+") as f:
        del f["row"].attrs["REFERENCE_LIST"]
        rl = f["component_1"].attrs["REFERENCE_LIST"]
        short = rl[:1]
        del f["component_1"].attrs["REFERENCE_LIST"]
        f["component_1"].attrs.create("REFERENCE_LIST", short,
                                      dtype=rl.dtype)
        assert "REFERENCE_LIST" not in f["row"].attrs
        assert len(f["component_1"].attrs["REFERENCE_LIST"]) == 1
        assert "DIMENSION_LIST" in f["/scalars/cl"].attrs
    print("wrote %s" % path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
