#!/usr/bin/env python3
"""Write the hostile corpus: files that are legal HDF5 and are not
this format, made to steer a reader rather than to be read.

Each one starts as a copy of a corpus case and then breaks exactly one
thing, so that what the reader meets is otherwise a file it knows.
None of them is a conformance case: the corpus under vectors/ says
what a conforming file means, and these say only that a reader must
come back with a finding rather than a signal.

    python3 make_hostile.py [output_directory]

The default output directory is the one holding this file.  It needs
h5py and numpy, and nothing here is a mestra implementation.
"""

import os
import shutil
import sys

import h5py
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "..", "..", "..", "vectors", "cases")
BASE = os.path.join(CORPUS, "mesh_two_rows", "case.mes")

# Deeper than the limit a reader walks a dictionary to, and no deeper:
# the file grows by about a kilobyte a level and the point is the
# limit, not the size.  A file that overflowed the stack of the
# unhardened reader took thirty thousand levels and thirty megabytes;
# raise this to reproduce that.
DICT_DEPTH = 80

# Wider than any attribute this format names, and wide enough that a
# reader that took one element's worth of stack for it would be
# writing thirty-two kilobytes into eight bytes.
ATTRIBUTE_WIDTH = 4096

# A variable-length element costs sixteen bytes on disk, and an object
# header message may not pass sixty-four kilobytes, so the
# variable-length case is narrower than the rest.  The point is the
# count, not the width.
VLEN_WIDTH = 512


def fresh(out, name):
    path = os.path.join(out, name)
    shutil.copy(BASE, path)
    return path


def attr_array_int(out):
    """A root attribute this version does not know, stored as four
    thousand int64s rather than the one the encoding implies."""
    path = fresh(out, "attr_array_int.mes")
    with h5py.File(path, "r+") as f:
        f.attrs.create("probe", np.arange(ATTRIBUTE_WIDTH, dtype="<i8"))
    return path


def attr_array_float(out):
    """The same, as float64."""
    path = fresh(out, "attr_array_float.mes")
    with h5py.File(path, "r+") as f:
        f.attrs.create("probe", np.arange(ATTRIBUTE_WIDTH, dtype="<f8"))
    return path


def attr_array_named(out):
    """An attribute section 18 names, `lower`, with a dataspace that
    is not the scalar the section requires."""
    path = fresh(out, "attr_array_named.mes")
    with h5py.File(path, "r+") as f:
        key = f["/keys/mach"]
        del key.attrs["lower"]
        key.attrs.create("lower", np.zeros(ATTRIBUTE_WIDTH, dtype="<f8"))
    return path


def attr_array_vlen(out):
    """Five hundred variable-length strings in one attribute: the kind
    section 18 forbids, in a count that would have been read into one
    pointer and leaked."""
    path = fresh(out, "attr_array_vlen.mes")
    with h5py.File(path, "r+") as f:
        text = h5py.string_dtype(encoding="utf-8")
        f.attrs.create("probe",
                       np.array(["x" * 8] * VLEN_WIDTH, dtype=object),
                       dtype=text)
    return path


def dict_deep(out):
    """A callable whose dictionary nests groups further than any
    reader will walk."""
    path = fresh(out, "dict_deep.mes")
    with h5py.File(path, "r+") as f:
        callable_group = f.create_group("callables").create_group("c0")
        callable_group.attrs.create(
            "type", b"affine",
            dtype=h5py.string_dtype(encoding="utf-8", length=6))
        here = callable_group
        for _ in range(DICT_DEPTH):
            here = here.create_group("g")
    return path


def link_soft_dangling(out):
    """A soft link under /keys that points at nothing."""
    path = fresh(out, "link_soft_dangling.mes")
    with h5py.File(path, "r+") as f:
        f["/keys/ghost"] = h5py.SoftLink("/keys/does_not_exist")
    return path


def link_external(out):
    """An external link under /scalars.  A reader that followed one
    would open a file a crafted dataset named, so this one points at a
    neighbour that is not there and the point stands either way."""
    path = fresh(out, "link_external.mes")
    with h5py.File(path, "r+") as f:
        f["/scalars/out"] = h5py.ExternalLink("elsewhere.mes", "/keys/mach")
    return path


def filter_unknown(out):
    """A dataset carrying a filter nobody has registered, with twelve
    client-data values: more than a fixed buffer of eight holds, and
    H5Pget_filter2 reports the twelve whether or not it wrote them."""
    path = fresh(out, "filter_unknown.mes")
    with h5py.File(path, "r+") as f:
        del f["/scalars/cl"]
        dcpl = h5py.h5p.create(h5py.h5p.DATASET_CREATE)
        dcpl.set_chunk((2,))
        # H5Z_FLAG_OPTIONAL, so that the library writes the dataset
        # without the filter rather than refusing to.
        dcpl.set_filter(32017, h5py.h5z.FLAG_OPTIONAL,
                        tuple(range(12)))
        space = h5py.h5s.create_simple((2,), (h5py.h5s.UNLIMITED,))
        dset = h5py.h5d.create(f.id, b"/scalars/cl",
                               h5py.h5t.IEEE_F64LE, space, dcpl)
        dset.write(h5py.h5s.ALL, h5py.h5s.ALL,
                   np.array([0.25, 0.55], dtype="<f8"))
        cl = f["/scalars/cl"]
        cl.attrs.create("units", b"1",
                        dtype=h5py.string_dtype(encoding="utf-8", length=1))
        cl.attrs.create("source", b"data",
                        dtype=h5py.string_dtype(encoding="utf-8", length=4))
        cl.dims[0].attach_scale(f["/row"])
    return path


def member_named_type(out):
    """A committed datatype under /keys: a member that is neither a
    group nor a dataset."""
    path = fresh(out, "member_named_type.mes")
    with h5py.File(path, "r+") as f:
        f["/keys/committed"] = np.dtype("<i8")
    return path


def shape_enormous(out):
    """A dataset that declares a trillion elements and stores none.
    The file stays small; a reader that sized a buffer from the shape
    would not."""
    path = fresh(out, "shape_enormous.mes")
    with h5py.File(path, "r+") as f:
        del f["/scalars/cl"]
        cl = f.create_dataset("/scalars/cl", shape=(2 ** 40,),
                              maxshape=(None,), chunks=(1024,),
                              dtype="<f8")
        cl.attrs.create("units", b"1",
                        dtype=h5py.string_dtype(encoding="utf-8", length=1))
        cl.attrs.create("source", b"data",
                        dtype=h5py.string_dtype(encoding="utf-8", length=4))
        cl.dims[0].attach_scale(f["/row"])
    return path


CASES = [attr_array_int, attr_array_float, attr_array_named,
         attr_array_vlen, dict_deep, link_soft_dangling, link_external,
         filter_unknown, member_named_type, shape_enormous]


def main(argv):
    out = argv[1] if len(argv) > 1 else HERE
    for case in CASES:
        path = case(out)
        print("%-28s %8d bytes  %s"
              % (os.path.basename(path), os.path.getsize(path),
                 case.__doc__.split("\n")[0]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
