"""The command line: `mestra validate FILE` and `mestra info FILE`."""

from __future__ import annotations

from mestra.cli import main
from tests import corpus


def test_validate_a_clean_file(capsys):
    status = main(["validate", corpus.case_path("mesh_two_rows")])
    out = capsys.readouterr().out
    assert status == 0
    assert "no error and no warning" in out


def test_validate_reports_the_rule_ids(capsys):
    status = main(["validate", corpus.case_path("err_e11")])
    out = capsys.readouterr().out
    assert status == 1
    assert "E11" in out
    assert "a field carries units" in out


def test_validate_reports_warnings_and_still_passes(capsys):
    status = main(["validate", corpus.case_path("warn_w05")])
    out = capsys.readouterr().out
    assert status == 0
    assert "W05" in out
    assert "valid" in out


def test_validate_quietly(capsys):
    main(["validate", "--quiet", corpus.case_path("warn_w05")])
    out = capsys.readouterr().out
    assert out.count("\n") == 1


def test_validate_several_files(capsys):
    status = main(["validate", corpus.case_path("mesh_two_rows"),
                   corpus.case_path("err_e11")])
    assert status == 1
    assert capsys.readouterr().out.count("\n") >= 2


def test_validate_a_file_that_is_not_there(capsys):
    assert main(["validate", "/no/such/file.mes"]) == 1
    assert "cannot be read" in capsys.readouterr().out


def test_info_is_one_screen(capsys):
    status = main(["info", corpus.case_path("mesh_two_rows")])
    out = capsys.readouterr().out
    assert status == 0
    lines = out.strip().split("\n")
    assert len(lines) <= 24
    assert "mestra/0" in out
    assert "2 row(s), aligned, generalisation unit member" in out
    assert "mach" in out and "condition" in out
    assert "bounds [0.1, 0.9]" in out
    assert "categories member (wing_a, wing_b)" in out
    assert "96df395d80ef548444562292de441525ba0b5c8ad00a8dadff19a19c9" \
        "43936c7" in out
    assert "(row, node, component)" in out
    assert "units Pa" in out
    assert "data" in out


def test_info_names_the_callables(capsys):
    main(["info", corpus.case_path("affine_zero_rows")])
    out = capsys.readouterr().out
    assert "m1" in out and "affine" in out
    assert "callable:m1" in out
    assert "output pressure" in out


def test_info_on_an_unreadable_file(capsys):
    assert main(["info", corpus.case_path("err_e01")]) == 1
    assert "E01" in capsys.readouterr().out


def test_no_command_prints_help(capsys):
    assert main([]) == 2
    assert "usage" in capsys.readouterr().out
