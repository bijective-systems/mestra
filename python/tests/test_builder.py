"""Building a dataset from arrays, and the messages a mistake gets.

A user should reach a valid file in a handful of calls, and a
mistake should name the rule it breaks.
"""

from __future__ import annotations

import numpy as np
import pytest

import mestra
from mestra.errors import MestraError
from tests import corpus

XY = np.array([[0., 0.], [1., 0.], [2., 0.],
               [0., 1.], [1., 1.], [2., 1.]])
CELLS = (np.array([9, 9]), np.array([0, 4, 8]),
         np.array([0, 1, 4, 3, 1, 2, 5, 4]))


def build_example():
    """docs/example.md file one, built from arrays."""
    ds = mestra.Dataset(writer="mestra examples 0",
                        created="2026-09-19T00:00:00Z")
    ds.add_key("mach", [0.40, 0.80], role="condition", units="1",
               lower=0.1, upper=0.9)
    ds.add_key("member", [0, 1], role="group",
               categories=["wing_a", "wing_b"], generalisation=True)
    ds.add_scalar("cl", [0.25, 0.55], units="1")
    support = ds.add_support(
        "s0", coordinates=np.stack([XY, XY * [1.5, 1.0]]),
        varies="group:member", cells=CELLS)
    support.add_node_array(
        "pressure", [[101., 102., 103., 104., 105., 106.],
                     [201., 202., 203., 204., 205., 206.]], units="Pa")
    support.add_cell_array("region", [0, 1], role="label",
                           categories=["inlet", "outlet"])
    return ds


def test_a_built_file_is_the_worked_example(tmp_path):
    """Eight calls reach the file docs/example.md lists."""
    path = str(tmp_path / "built.mes")
    mestra.write(build_example(), path)
    assert mestra.validate(path).error_ids == []
    assert corpus.structural_diff(corpus.case_path("mesh_two_rows"),
                                  path) == []


def test_the_builder_fills_in_what_it_can():
    ds = build_example()
    support = ds.supports["s0"]
    assert ds.aligned is True
    assert ds.n_rows == 2
    assert support.n_nodes == 6 and support.n_cells == 2
    assert support.support_id.startswith("96df395d")
    assert support.node_arrays["pressure"].components == 1
    assert support.node_arrays["pressure"].dims == (
        "row", "node", "component")
    assert support.coordinates.dims == (
        "group:member", "node", "component")


def test_bounds_default_to_the_observed_range():
    ds = mestra.Dataset(writer="t")
    key = ds.add_key("alpha", [-2.0, 4.0, 10.0], role="condition",
                     units="degree")
    assert (key.lower, key.upper) == (-2.0, 10.0)
    other = ds.add_key("beta", [1.0, 2.0, 3.0], role="condition",
                       units="1", bounds=None)
    assert (other.lower, other.upper) == (None, None)


def test_a_scalar_only_file_needs_no_support(tmp_path):
    ds = mestra.Dataset(writer="t")
    ds.add_key("geometry", [0, 0, 1, 1], role="group",
               categories=["g000", "g001"], generalisation=True)
    ds.add_key("incidence", [2.0, 8.0, 2.0, 8.0], role="condition",
               units="degree")
    ds.add_scalar("cl", [0.2, 0.8, 0.3, 0.9], units="1")
    path = str(tmp_path / "scalars.mes")
    mestra.write(ds, path)
    assert mestra.validate(path).error_ids == []


def test_an_axis_support(tmp_path):
    ds = mestra.Dataset(writer="t")
    ds.add_key("mach", [1.4, 1.6], role="condition", units="1")
    support = ds.add_support("s0", kind="axis",
                             coordinates=[0.0, 0.25, 0.5, 0.75],
                             units="s")
    support.add_node_array("overpressure",
                           [[10., 11., 12., 13.],
                            [20., 21., 22., 23.]], units="Pa")
    path = str(tmp_path / "axis.mes")
    mestra.write(ds, path)
    assert mestra.validate(path).error_ids == []
    with mestra.read(path) as back:
        assert back.supports["s0"].kind == "axis"
        assert back.supports["s0"].n_nodes == 4
        assert back.supports["s0"].coordinates.dims == ("node",
                                                        "component")


def test_a_shape_that_fits_two_readings_is_refused():
    ds = mestra.Dataset(writer="t")
    support = ds.add_support("s0", coordinates=XY, cells=CELLS)
    with pytest.raises(MestraError) as caught:
        support.add_node_array("p", np.zeros((6, 6)), units="Pa")
    assert caught.value.rule == "E04"
    assert "varies" in str(caught.value)


def test_a_shape_that_fits_nothing_says_so():
    ds = mestra.Dataset(writer="t")
    support = ds.add_support("s0", coordinates=XY, cells=CELLS)
    with pytest.raises(MestraError) as caught:
        support.add_node_array("p", np.zeros((2, 5)), units="Pa")
    assert caught.value.rule == "E05"


def test_a_role_that_is_not_in_section_3():
    ds = mestra.Dataset(writer="t")
    with pytest.raises(MestraError) as caught:
        ds.add_key("x", [1.0], role="input", units="1")
    assert caught.value.rule == "E02"


def test_a_reserved_name():
    ds = mestra.Dataset(writer="t")
    with pytest.raises(MestraError) as caught:
        ds.add_key("mestra_mach", [1.0], role="condition", units="1")
    assert caught.value.rule == "E33"


def test_a_name_netcdf4_would_refuse():
    ds = mestra.Dataset(writer="t")
    with pytest.raises(MestraError) as caught:
        ds.add_key("mach number", [1.0], role="condition", units="1")
    assert caught.value.rule == "E33"


def test_rows_must_agree():
    ds = mestra.Dataset(writer="t")
    ds.add_key("mach", [0.4, 0.8], role="condition", units="1")
    with pytest.raises(MestraError) as caught:
        ds.add_scalar("cl", [0.1, 0.2, 0.3], units="1")
    assert caught.value.rule == "E16"


def test_a_categorical_key_is_an_integer():
    ds = mestra.Dataset(writer="t")
    with pytest.raises(MestraError) as caught:
        ds.add_key("split", [0.0, 1.0], role="split",
                   categories=["train", "test"])
    assert caught.value.rule == "E20"


def test_two_supports_need_a_row_support(tmp_path):
    ds = mestra.Dataset(writer="t")
    ds.add_key("mach", [0.4, 0.5, 0.6], role="condition", units="1")
    ds.add_support("s0", coordinates=XY, cells=CELLS)
    ds.add_support("s1", coordinates=XY[:4],
                   cells=(np.array([9]), np.array([0, 4]),
                          np.array([0, 1, 3, 2])))
    assert ds.aligned is False
    report = mestra.validate(ds)
    assert "E28" in report.error_ids
    ds.set_row_support([0, 1, 0])
    assert mestra.validate(ds).error_ids == []
    assert list(ds.rows_on("s0")) == [0, 2]
    path = str(tmp_path / "two.mes")
    mestra.write(ds, path)
    assert mestra.validate(path).error_ids == []
    assert mestra.validate(path).warning_ids == ["W05"]


def test_a_dataset_validates_in_memory():
    ds = build_example()
    assert mestra.validate(ds).ok
    ds.scalars["cl"].units = None
    assert "E11" in mestra.validate(ds).error_ids


def test_named_arrays_permute_by_name():
    ds = build_example()
    pressure = ds.supports["s0"].node_arrays["pressure"].values
    assert pressure.at(row=1, node=3, component=0) == 204.0
    other = pressure.transpose("component", "node", "row")
    assert other.shape == (1, 6, 2)
    assert other.at(row=1, node=3, component=0) == 204.0
    with pytest.raises(KeyError):
        pressure.at(cell=0)


def test_the_support_id_is_the_worked_example():
    """Section 24: six nodes and two quadrilaterals."""
    assert mestra.support_digest(6, [9, 9], [0, 4, 8],
                                 [0, 1, 4, 3, 1, 2, 5, 4]) == (
        "96df395d80ef548444562292de441525ba0b5c8ad00a8dadff19a19c943936c7")
    assert mestra.support_digest(
        4, axis_coordinates=[0.0, 0.5, 1.0, 1.5]) == (
        "57467fe7370808bdb0ad01b95d963f59e8bc6762f90f96049453ae33bb05a54c")
    assert mestra.support_digest(0) == (
        "af5570f5a1810b7af78caf4bc70a660f0df51e42baf91d4de5b2328de0e83dfc")
