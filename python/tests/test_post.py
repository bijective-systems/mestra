"""The generic post-processing, on files built for the purpose."""

from __future__ import annotations

import numpy as np
import pytest

import mestra
from mestra import post
from mestra.errors import MestraError
from tests import corpus

XY = np.array([[0., 0.], [1., 0.], [2., 0.],
               [0., 1.], [1., 1.], [2., 1.]])
CELLS = (np.array([9, 9]), np.array([0, 4, 8]),
         np.array([0, 1, 4, 3, 1, 2, 5, 4]))


def transient():
    """Two runs of three and two steps on a fixed mesh."""
    ds = mestra.Dataset(writer="t")
    ds.add_key("run", [0, 0, 0, 1, 1], role="group",
               categories=["r000", "r001"], generalisation=True)
    ds.add_key("t", [0.0, 0.1, 0.3, 0.0, 0.25], role="time",
               units="s", trajectory_group="run")
    support = ds.add_support("s0", coordinates=XY, cells=CELLS)
    support.add_node_array(
        "u", [[300. + 10 * i + j for j in range(6)] for i in range(5)],
        units="K")
    support.add_node_array("region", [0, 0, 1, 1, 2, 2], role="label",
                           categories=["nose", "mid", "tail"])
    support.add_node_array("w", np.full(6, 0.5), role="weight",
                           units="m2", recomputed=True)
    return ds


def test_statistics_per_row():
    stats = post.field_statistics(transient(), "u")
    assert list(stats.rows) == [0, 1, 2, 3, 4]
    assert stats.regions is None
    assert stats.mean[:, 0, 0].tolist() == [302.5, 312.5, 322.5,
                                            332.5, 342.5]
    assert stats.minimum[0, 0, 0] == 300.0
    assert stats.maximum[0, 0, 0] == 305.0
    assert stats.count[0, 0, 0] == 6


def test_statistics_per_region():
    stats = post.field_statistics(transient(), "u", label="region")
    assert stats.regions == ["nose", "mid", "tail"]
    assert stats.mean[0, :, 0].tolist() == [300.5, 302.5, 304.5]
    table = stats.as_table()
    assert len(table) == 15
    assert table[0]["region"] == "nose"


def test_statistics_leave_out_what_is_not_finite():
    ds = mestra.Dataset(writer="t")
    ds.add_key("mach", [0.4, 0.8], role="condition", units="1")
    support = ds.add_support("s0", coordinates=XY, cells=CELLS)
    support.add_node_array("u", [[np.nan] * 6,
                                 [1., 2., 3., 4., 5., 6.]], units="K")
    stats = post.field_statistics(ds, "u")
    assert stats.count[:, 0, 0].tolist() == [0, 6]
    assert np.isnan(stats.mean[0, 0, 0])
    assert stats.mean[1, 0, 0] == 3.5


def test_integration_over_a_support_and_over_a_region():
    ds = transient()
    whole = post.integrate(ds, "u", weight="w")
    assert whole[:, 0].tolist() == [907.5, 937.5, 967.5, 997.5, 1027.5]
    nose = post.integrate(ds, "u", weight="w", label="region",
                          region="nose")
    assert nose[:, 0].tolist() == [300.5, 310.5, 320.5, 330.5, 340.5]


def test_integration_needs_a_weight_array():
    ds = transient()
    with pytest.raises(MestraError) as caught:
        post.integrate(ds, "u", weight="region")
    assert caught.value.rule == "E02"


def test_a_time_series_at_one_node():
    times, values = post.time_series(transient(), "u", node=2,
                                     trajectory="r001")
    assert times.tolist() == [0.0, 0.25]
    assert values.tolist() == [332.0, 342.0]


def test_a_time_series_by_category_id():
    times, values = post.time_series(transient(), "u", node=0,
                                     trajectory=0)
    assert times.tolist() == [0.0, 0.1, 0.3]
    assert values.tolist() == [300.0, 310.0, 320.0]


def test_a_time_series_needs_a_time_key():
    ds = mestra.Dataset(writer="t")
    ds.add_key("mach", [0.4], role="condition", units="1")
    support = ds.add_support("s0", coordinates=XY, cells=CELLS)
    support.add_node_array("u", [[1., 2., 3., 4., 5., 6.]], units="K")
    with pytest.raises(MestraError):
        post.time_series(ds, "u", node=0)


def test_a_grouped_split_moves_whole_units():
    ds = transient()
    parts = post.grouped_split(ds, {"train": 0.5, "test": 0.5}, seed=3)
    rows = np.concatenate(list(parts.values()))
    assert sorted(rows.tolist()) == [0, 1, 2, 3, 4]
    runs = np.asarray(ds.keys["run"].values)
    for taken in parts.values():
        assert len(set(runs[taken].tolist())) <= 1


def test_a_grouped_split_is_refused_without_a_unit():
    ds = mestra.Dataset(writer="t")
    ds.add_key("mach", [0.4, 0.8], role="condition", units="1")
    with pytest.raises(MestraError) as caught:
        post.grouped_split(ds)
    assert caught.value.rule == "W01"
    assert "unit of generalisation" in str(caught.value)


def test_a_leaking_split_is_named():
    with mestra.read(corpus.case_path("warn_w01")) as ds:
        leaks = post.split_leaks(ds)
    assert set(leaks) == {"wing_a", "wing_b"}


def test_a_split_that_does_not_leak():
    with mestra.read(corpus.case_path("scalars_only")) as ds:
        assert post.split_leaks(ds) == {}


def test_post_processing_runs_on_the_corpus():
    """The same calls on a file this package did not write."""
    with mestra.read(corpus.case_path("transient_fixed_mesh")) as ds:
        stats = post.field_statistics(ds, "u")
        assert stats.count[0, 0, 0] == 6
        times, values = post.time_series(ds, "u", node=1,
                                         trajectory="r001")
        assert times.tolist() == [0.0, 0.25]
        assert values.tolist() == [331.0, 341.0]


def test_an_unaligned_file_keeps_its_row_mapping():
    """Section 22: the leading index is a position on the support."""
    name = "two_supports_row_varying"
    with mestra.read(corpus.case_path(name)) as ds:
        stats = post.field_statistics(ds, "s0/pressure")
        assert stats.rows.tolist() == [0, 2]
        assert stats.minimum[:, 0, 0].tolist() == [100.0, 300.0]
