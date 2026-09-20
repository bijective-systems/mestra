"""Section 29: what opening a file is allowed to cost.

"Opening a file must not read any array. A reader must be able to
report the row count, the keys with their roles and bounds, the
supports with their ids, and every slot with its attributes, having
read attributes and dataspaces only."

Attributes and dataspaces are linear in the number of objects, so an
open is linear in the number of row-dimensioned datasets or it is not
doing what the sentence says. It was not: finding 4 of the Phase 3
report measured 3.1 s at 125 key columns, 10.6 s at 250, 41.6 s at
500 and 155.5 s at 1000, which quadruples for every doubling and is
the signature of a scan inside a scan. The scan inside the scan was
the section 21 scale index, which maps a scale's object address to
its link name: it was rebuilt from a walk of the whole file once per
dataset, because it was looked up through `dataset.file`, which
hands back a fresh wrapper each time and threw the cache away with
it. One index per pass is what section 21 describes and what the
reader and the validator now build.

A file with a few hundred quantities of interest is an ordinary file,
so these two tests are about an ordinary file and not an exotic one.
They are timings, which are never exact. The second is a ratio and so
is indifferent to how busy the machine is; it is the one that says
what section 29 asks, and the one that fails if the scan inside the
scan ever comes back. The first is an absolute bar, and its number is
chosen rather than derived. A thousand columns opens in about 1.2 s
on the machine this was written on when nothing else is running, and
in 2.6 s on the same machine under a load average of thirty; it took
181 s before. The bar is five seconds, which no machine this is
likely to run on will fail and which nothing quadratic can pass. The
ratio is where the sharp statement lives.

What is left at a thousand columns is not one hot spot but about
1 ms of h5py per object, spent twice: once by the check `read` makes
before it will vouch for a file, and once by the read itself.
"""

from __future__ import annotations

import time

import h5py
import pytest

import mestra
from tests import corpus

#: The two column counts compared. The larger is four times the
#: smaller, so a linear open costs about four times as much and a
#: quadratic one about sixteen.
SMALL, LARGE = 250, 1000

#: How many opens each measurement takes the fastest of. Noise on a
#: shared machine only ever adds time, so the minimum is the honest
#: number and the mean is not.
RUNS = 5


def _with_columns(source: str, path: str, count: int) -> str:
    """A corpus case with `count` extra key columns.

    Each is a copy of an existing key: the same dtype, the same
    attributes with their exact HDF5 types, the same chunk, and the
    file's `row` scale on its one axis. Nothing in the result is
    malformed, which is the point -- this is an ordinary file with
    more columns than the corpus has.
    """
    import shutil

    shutil.copy(source, path)
    with h5py.File(path, "r+") as f:
        keys = f["/keys"]
        model = keys["mach"]
        row = f["row"]
        for at in range(count):
            column = keys.create_dataset(
                "k%05d" % at, data=model[()], dtype=model.dtype,
                maxshape=(None,), chunks=model.chunks, track_times=False)
            for name in model.attrs:
                attr = h5py.h5a.open(model.id, name.encode("utf-8"))
                column.attrs.create(name, model.attrs[name],
                                    dtype=attr.dtype)
            column.dims[0].attach_scale(row)
    return path


def _fastest_open(path: str) -> float:
    """The shortest of `RUNS` opens, in seconds."""
    best = float("inf")
    for _ in range(RUNS):
        started = time.perf_counter()
        mestra.read(path).close()
        best = min(best, time.perf_counter() - started)
    return best


@pytest.fixture(scope="module")
def opens(tmp_path_factory):
    """The two files, and what an open of each costs."""
    where = tmp_path_factory.mktemp("open_cost")
    source = corpus.case_path("mesh_two_rows")
    out = {}
    for count in (SMALL, LARGE):
        path = _with_columns(source, str(where / ("k%d.mes" % count)),
                             count)
        out[count] = _fastest_open(path)
    return out


@pytest.mark.slow
def test_a_thousand_columns_open_in_seconds_and_not_minutes(opens):
    """The file of finding 4, which took 155 s to open.

    A thousand key columns is 2.8 MB and about 1030 row-dimensioned
    datasets: an ordinary file, and one a user will wait for. It now
    costs about a second, and a reader that re-walks the file once
    per dataset cannot come near the bar however idle the machine.
    """
    assert opens[LARGE] < 5.0, (
        "opening a %d column file took %.2f s" % (LARGE, opens[LARGE]))


@pytest.mark.slow
def test_the_open_is_linear_in_the_number_of_columns(opens):
    """Four times the columns costs about four times as much.

    Sixteen is what a scan inside a scan costs, and the bar is set
    at eight: high enough that a slow machine, a cold cache or a
    fixed overhead cannot fail it, and far below anything quadratic.
    """
    ratio = opens[LARGE] / opens[SMALL]
    assert ratio < 8.0, (
        "%d columns cost %.3f s and %d cost %.3f s, a ratio of %.1f "
        "where four times the columns should cost about four times "
        "as much" % (SMALL, opens[SMALL], LARGE, opens[LARGE], ratio))
