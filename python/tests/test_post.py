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
    assert stats.by is None and stats.groups is None
    assert stats.over == "node"
    assert stats.mean[:, 0, 0].tolist() == [302.5, 312.5, 322.5,
                                            332.5, 342.5]
    assert stats.minimum[0, 0, 0] == 300.0
    assert stats.maximum[0, 0, 0] == 305.0
    assert stats.count[0, 0, 0] == 6


def test_statistics_have_no_grouping_column_when_not_grouped():
    """P2: the column was called `region` whatever the label was."""
    table = post.field_statistics(transient(), "u").as_table()
    assert set(table[0]) == {"row", "count", "min", "max", "mean",
                             "std"}


def test_statistics_per_group_are_keyed_by_the_labels_name():
    stats = post.field_statistics(transient(), "u", by="region")
    assert stats.by == "region"
    assert stats.groups == ["nose", "mid", "tail"]
    assert stats.mean[0, :, 0].tolist() == [300.5, 302.5, 304.5]
    table = stats.as_table()
    assert len(table) == 15
    assert table[0]["region"] == "nose"
    assert "region" not in post.field_statistics(
        transient(), "u").as_table()[0]


def test_a_grouping_column_takes_the_name_of_any_label():
    ds = transient()
    ds.supports["s0"].add_node_array(
        "cad_face_id", [11, 11, 12, 12, 12, 13], role="label")
    stats = post.field_statistics(ds, "u", by="cad_face_id")
    assert stats.by == "cad_face_id"
    assert stats.groups == ["11", "12", "13"]
    assert stats.as_table()[0]["cad_face_id"] == "11"


def test_statistics_over_a_scalar():
    """P5: dataset 3 is nothing but scalars."""
    ds = mestra.Dataset(writer="t")
    ds.add_key("geometry", [0, 0, 1, 1], role="group",
               categories=["g000", "g001"])
    ds.add_scalar("cl", [0.2, 0.8, 0.3, 0.9], units="1")
    stats = post.field_statistics(ds, "cl")
    assert stats.over == "row" and stats.rows is None
    assert stats.count[0, 0, 0] == 4
    assert stats.mean[0, 0, 0] == pytest.approx(0.55)
    table = stats.as_table()
    assert len(table) == 1
    assert "row" not in table[0]

    grouped = post.field_statistics(ds, "cl", by="geometry")
    assert grouped.groups == ["g000", "g001"]
    assert grouped.mean[0, :, 0].tolist() == pytest.approx([0.5, 0.6])
    assert grouped.as_table()[1]["geometry"] == "g001"


def test_as_text_is_lines_a_person_can_read():
    """P10: `as_table` gives dictionaries, so do not call them lines."""
    text = post.field_statistics(transient(), "u", by="region").as_text()
    lines = text.split("\n")
    assert lines[0].split() == ["row", "region", "count", "min", "max",
                                "mean", "std"]
    assert len(lines) == 16


def test_a_name_that_is_not_in_the_file_carries_no_rule_id():
    """P4: E05 is a rule about a file, not about a caller's typo."""
    ds = transient()
    with pytest.raises(MestraError) as caught:
        post.field_statistics(ds, "CL")
    assert caught.value.rule == ""
    assert "no array called 'CL'" in str(caught.value)
    assert "u" in str(caught.value)
    with pytest.raises(MestraError) as other:
        post.field_statistics(ds, "u", by="not_a_label")
    assert other.value.rule == ""


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
    nose = post.integrate(ds, "u", weight="w", by="region",
                          region="nose")
    assert nose[:, 0].tolist() == [300.5, 310.5, 320.5, 330.5, 340.5]


def test_integration_defaults_to_the_weight_array_of_the_support():
    """P1: the README's headline call must work on a file."""
    ds = transient()
    assert post.integrate(ds, "u")[:, 0].tolist() == \
        post.integrate(ds, "u", weight="w")[:, 0].tolist()


def test_integration_computes_a_weight_and_says_so():
    ds = transient()
    del ds.supports["s0"].node_arrays["w"]
    with pytest.warns(UserWarning, match="compute_weights"):
        total = post.integrate(ds, "u")
    # Two unit squares lumped onto six nodes: the corners get a
    # quarter and the two shared nodes a half.
    lumped = np.array([0.25, 0.5, 0.25, 0.25, 0.5, 0.25])
    values = np.asarray(ds.supports["s0"].node_arrays["u"].read().values)
    assert total[:, 0] == pytest.approx(
        (values[:, :, 0] * lumped).sum(axis=1))


def test_integration_refuses_an_array_that_is_not_a_weight():
    ds = transient()
    with pytest.raises(MestraError) as caught:
        post.integrate(ds, "u", weight="region")
    assert caught.value.rule == "E02"
    assert "compute_weights" in str(caught.value)


def test_a_time_series_at_one_node():
    times, values = post.time_series(transient(), "u", 2, "r001")
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
    with pytest.raises(MestraError) as caught:
        post.time_series(ds, "u", node=0)
    assert caught.value.rule == ""


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


def test_a_grouped_split_never_returns_an_empty_part():
    """J1 and X8: the whole purpose is an honest generalisation test."""
    ds = mestra.Dataset(writer="t")
    ds.add_key("geometry", [0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2],
               role="group", categories=["g0", "g1", "g2"],
               generalisation=True)
    ds.add_scalar("cl", np.arange(12.0), units="1")
    for seed in range(8):
        parts = post.grouped_split(ds, {"train": 0.8, "test": 0.2},
                                   seed=seed)
        assert sorted(len(p) for p in parts.values()) == [4, 8]
    three = post.grouped_split(ds, {"train": 0.98, "validation": 0.01,
                                    "test": 0.01})
    assert all(len(part) for part in three.values())
    assert sum(len(part) for part in three.values()) == 12


def test_a_grouped_split_with_fewer_units_than_parts_is_refused():
    ds = mestra.Dataset(writer="t")
    ds.add_key("geometry", [0, 0, 1, 1], role="group",
               categories=["g0", "g1"], generalisation=True)
    ds.add_scalar("cl", np.arange(4.0), units="1")
    with pytest.raises(MestraError) as caught:
        post.grouped_split(ds, {"train": 0.5, "validation": 0.25,
                                "test": 0.25})
    assert "2 unit(s)" in str(caught.value)


def test_a_grouped_split_repeats_on_a_seed():
    ds = transient()
    first = post.grouped_split(ds, {"train": 0.5, "test": 0.5}, seed=3)
    again = post.grouped_split(ds, {"train": 0.5, "test": 0.5}, seed=3)
    for name, rows in first.items():
        assert rows.tolist() == again[name].tolist()


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
